#!/usr/bin/env python3
import importlib.util
import queue
import socket
import struct
import threading
import unittest
from unittest.mock import patch
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
        # Exercise the handler's pool-exhaustion response without waiting for
        # the production six-second channel-acquisition deadline. The timeout
        # itself is covered by ReverseChannelPool's bounded-acquire behavior.
        with patch.object(pool, "acquire", side_effect=queue.Empty):
            with socket.create_connection(proxy.server_address, timeout=2) as client:
                response = client.recv(4096)
        self.assertTrue(response.startswith(b"HTTP/1.1 503 Service Unavailable"))
        self.assertIn(b"Todo MCP reverse bridge unavailable", response)

    def test_local_proxy_closes_http_client_after_todo_closes_reverse_channel(self):
        pool = proxy_module.ReverseChannelPool("172.24.0.1", max_channels=1)
        local_channel, remote_channel = socket.socketpair()
        pool.channels.put(local_channel)

        def respond_after_request_body():
            with remote_channel:
                request = bytearray()
                while True:
                    chunk = remote_channel.recv(4096)
                    if not chunk:
                        return
                    request.extend(chunk)
                    if b"\r\n\r\n" not in request:
                        continue
                    header, body = bytes(request).split(b"\r\n\r\n", 1)
                    content_length = 0
                    for line in header.split(b"\r\n")[1:]:
                        if line.lower().startswith(b"content-length:"):
                            content_length = int(line.split(b":", 1)[1].strip())
                    if len(body) >= content_length:
                        remote_channel.sendall(
                            b"HTTP/1.1 401 Unauthorized\r\n"
                            b"Content-Length: 0\r\n"
                            b"Connection: close\r\n\r\n"
                        )
                        return

        responder = threading.Thread(target=respond_after_request_body, daemon=True)
        responder.start()
        self.addCleanup(responder.join, 1)

        proxy = self.make_proxy(pool)
        request = (
            b"POST /mcp HTTP/1.1\r\n"
            b"Host: 127.0.0.1:8766\r\n"
            b"Content-Length: 4\r\n\r\n"
            b"test"
        )
        with socket.create_connection(proxy.server_address, timeout=2) as client:
            client.settimeout(2)
            client.sendall(request)
            received = bytearray()
            while True:
                chunk = client.recv(4096)
                if not chunk:
                    break
                received.extend(chunk)

        self.assertTrue(received.startswith(b"HTTP/1.1 401 Unauthorized"))

    def test_reverse_listener_backlog_handles_short_reconnect_bursts(self):
        self.assertEqual(128, proxy_module.reverse_listen_backlog(4))
        self.assertEqual(128, proxy_module.reverse_listen_backlog(16))
        self.assertEqual(256, proxy_module.reverse_listen_backlog(32))

    def test_rejected_reverse_channels_use_immediate_tcp_reset(self):
        class RecordingSocket:
            def __init__(self):
                self.options = []
                self.closed = False

            def setsockopt(self, level, option, value):
                self.options.append((level, option, value))

            def close(self):
                self.closed = True

        channel = RecordingSocket()
        proxy_module.reject_reverse_channel(channel)
        self.assertEqual(
            [(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))],
            channel.options,
        )
        self.assertTrue(channel.closed)

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

    def test_windows_bridge_reaps_orphans_and_serializes_connector_startup(self):
        source = WINDOWS_BRIDGE.read_text(encoding="utf-8")
        self.assertIn("Get-ManagedConnectorProcesses", source)
        self.assertIn("Get-CimInstance -ClassName Win32_Process", source)
        self.assertIn("todo-mcp-bridge\\.ps1", source)
        self.assertIn('$connectors = @(Get-ManagedConnectorProcesses $RelayAddress $RelayPort)', source)
        self.assertIn("foreach ($connector in $connectors)", source)
        self.assertIn("Stop-ManagedConnectorProcess $connector", source)
        self.assertIn('$connectors.Count -eq 1', source)
        self.assertIn("Global\\GlobalSkillsTodoMcpBridgeEnsure", source)
        self.assertIn("Global\\GlobalSkillsTodoMcpBridgeConnect_", source)
        self.assertIn("$connectMutex.WaitOne(0)", source)

    def test_windows_bridge_only_initiates_outbound_channels(self):
        source = WINDOWS_BRIDGE.read_text(encoding="utf-8")
        self.assertIn("channel.BeginConnect(relay, relayPort", source)
        self.assertIn("upstream.Connect(IPAddress.Loopback, 8765)", source)
        self.assertIn('output.Add("Host: 127.0.0.1:8765")', source)
        self.assertIn("Only HTTP GET/POST/DELETE requests to /mcp are allowed.", source)
        self.assertIn("responsePump.GetAwaiter().GetResult()", source)
        self.assertIn("if source is reverse_channel:", SCRIPT.read_text(encoding="utf-8"))
        self.assertNotIn("Task.WhenAny(requestPump, responsePump)", source)
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
