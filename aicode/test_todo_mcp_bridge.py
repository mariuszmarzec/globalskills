#!/usr/bin/env python3
import importlib.util
import queue
import socket
import threading
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("todo-mcp-local-proxy.py")
WINDOWS_BRIDGE = Path(__file__).with_name("todo-mcp-bridge.ps1")
AICODE = Path(__file__).with_name("aicode")


spec = importlib.util.spec_from_file_location("todo_mcp_local_proxy", SCRIPT)
proxy_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy_module)


class TodoMcpBridgeTests(unittest.TestCase):
    def make_proxy(self, channel_pool):
        proxy = proxy_module.ThreadingProxyServer(("127.0.0.1", 0), channel_pool)
        thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        thread.start()
        self.addCleanup(proxy.server_close)
        self.addCleanup(proxy.shutdown)
        return proxy

    def test_local_proxy_binds_loopback_and_forwards_over_reverse_channel(self):
        pool = proxy_module.ReverseChannelPool("172.24.0.1", max_channels=1)
        local_channel, remote_channel = socket.socketpair()
        pool.channels.put(local_channel)

        def echo():
            with remote_channel:
                while True:
                    payload = remote_channel.recv(4096)
                    if not payload:
                        return
                    remote_channel.sendall(payload)

        echo_thread = threading.Thread(target=echo, daemon=True)
        echo_thread.start()
        self.addCleanup(echo_thread.join, 1)

        proxy = self.make_proxy(pool)
        self.assertEqual("127.0.0.1", proxy.server_address[0])
        payload = (
            b"POST /mcp HTTP/1.1\r\n"
            b"Host: 127.0.0.1:8766\r\n"
            b"Content-Length: 4\r\n\r\n"
            b"test"
        )
        received = bytearray()
        with socket.create_connection(proxy.server_address, timeout=2) as client:
            client.sendall(payload)
            client.shutdown(socket.SHUT_WR)
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                received.extend(chunk)
        self.assertEqual(payload, bytes(received))

    def test_local_proxy_returns_explicit_503_when_reverse_pool_is_empty(self):
        pool = proxy_module.ReverseChannelPool("172.24.0.1", max_channels=1)
        proxy = self.make_proxy(pool)
        with socket.create_connection(proxy.server_address, timeout=2) as client:
            response = client.recv(4096)
        self.assertTrue(response.startswith(b"HTTP/1.1 503 Service Unavailable"))
        self.assertIn(b"Todo MCP reverse bridge unavailable", response)

    def test_reverse_pool_discards_channels_closed_before_assignment(self):
        pool = proxy_module.ReverseChannelPool("172.24.0.1", max_channels=1)
        local_channel, remote_channel = socket.socketpair()
        pool.channels.put(local_channel)
        remote_channel.close()
        with self.assertRaises(queue.Empty):
            pool.acquire(timeout=0.05)

    def test_reverse_addresses_must_be_private_non_loopback_ipv4(self):
        self.assertEqual(
            "172.24.0.1",
            proxy_module.ensure_ipv4_private("172.24.0.1", "test address"),
        )
        for address in ("127.0.0.1", "8.8.8.8", "::1", "224.0.0.1"):
            with self.subTest(address=address):
                with self.assertRaises(ValueError):
                    proxy_module.ensure_ipv4_private(address, "test address")

    def test_windows_bridge_only_initiates_outbound_channels(self):
        source = WINDOWS_BRIDGE.read_text(encoding="utf-8")
        self.assertIn("channel.BeginConnect(relay, relayPort", source)
        self.assertIn("upstream.Connect(IPAddress.Loopback, 8765)", source)
        self.assertIn('output.Add("Host: 127.0.0.1:8765")', source)
        self.assertIn("Only HTTP GET/POST/DELETE requests to /mcp are allowed.", source)
        self.assertIn("Action\\s+(Connect|Serve)", source)
        self.assertNotIn("TcpListener", source)
        self.assertNotIn("New-NetFirewallRule", source)

    def test_aicode_starts_wsl_listener_before_windows_outbound_connector(self):
        source = AICODE.read_text(encoding="utf-8")
        self.assertIn("--reverse-listen-host", source)
        self.assertIn("--allowed-reverse-client", source)
        self.assertIn("--reverse-listen-port 18766", source)
        self.assertIn("-Action Ensure -RelayAddress", source)
        self.assertIn('url: "http://127.0.0.1:8766/mcp"', source)
        self.assertIn("Bearer {env:TODO_LOCAL_MCP_TOKEN}", source)
        self.assertIn('if [ "$http_status" = "401" ]; then', source)
        self.assertNotIn("18765", source)
        self.assertNotIn("observed_client_ip", source)
        self.assertLess(
            source.index("Starting the WSL-side Todo MCP reverse relay"),
            source.index("opens outbound channels to WSL"),
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
