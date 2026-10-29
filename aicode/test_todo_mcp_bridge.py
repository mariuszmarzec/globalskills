#!/usr/bin/env python3
import importlib.util
import socket
import socketserver
import threading
import unittest
from pathlib import Path


SCRIPT = Path(__file__).with_name("todo-mcp-local-proxy.py")
WINDOWS_BRIDGE = Path(__file__).with_name("todo-mcp-bridge.ps1")
AICODE = Path(__file__).with_name("aicode")


spec = importlib.util.spec_from_file_location("todo_mcp_local_proxy", SCRIPT)
proxy_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(proxy_module)


class EchoHandler(socketserver.BaseRequestHandler):
    def handle(self):
        while True:
            payload = self.request.recv(4096)
            if not payload:
                return
            self.request.sendall(payload)


class TodoMcpBridgeTests(unittest.TestCase):
    def test_local_proxy_binds_loopback_and_forwards_stream(self):
        upstream = socketserver.ThreadingTCPServer(("127.0.0.1", 0), EchoHandler)
        upstream_thread = threading.Thread(target=upstream.serve_forever, daemon=True)
        upstream_thread.start()
        self.addCleanup(upstream.shutdown)
        self.addCleanup(upstream.server_close)

        proxy = proxy_module.ThreadingProxyServer(
            ("127.0.0.1", 0), "127.0.0.1", upstream.server_address[1]
        )
        proxy_thread = threading.Thread(target=proxy.serve_forever, daemon=True)
        proxy_thread.start()
        self.addCleanup(proxy.shutdown)
        self.addCleanup(proxy.server_close)

        self.assertEqual("127.0.0.1", proxy.server_address[0])
        payload = b"POST /mcp HTTP/1.1\r\nHost: 172.20.0.1:18765\r\nContent-Length: 4\r\n\r\ntest"
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

    def test_upstream_must_be_private_and_non_loopback(self):
        self.assertEqual("172.24.0.1", proxy_module.ensure_ipv4_private("172.24.0.1"))
        for address in ("127.0.0.1", "8.8.8.8", "::1", "224.0.0.1"):
            with self.subTest(address=address):
                with self.assertRaises(ValueError):
                    proxy_module.ensure_ipv4_private(address)

    def test_windows_bridge_is_restricted_to_wsl_and_mcp_path(self):
        source = WINDOWS_BRIDGE.read_text(encoding="utf-8")
        self.assertIn("new TcpListener(bind, port)", source)
        self.assertIn("remote.Address.Equals(allowed)", source)
        self.assertIn("upstream.Connect(IPAddress.Loopback, 8765)", source)
        self.assertIn("Host: 127.0.0.1:8765", source)
        self.assertIn("Only HTTP GET/POST/DELETE requests to /mcp are allowed.", source)
        self.assertIn("return $private", source)
        self.assertNotIn("New-NetFirewallRule", source)

    def test_aicode_only_enables_todo_after_authenticated_endpoint_challenge(self):
        source = AICODE.read_text(encoding="utf-8")
        self.assertIn('http://127.0.0.1:8766/mcp', source)
        self.assertIn('if [ "$http_status" = "401" ]; then', source)
        self.assertIn('TODO_LOCAL_MCP_AVAILABLE=1', source)
        self.assertIn('url: "http://127.0.0.1:8766/mcp"', source)
        self.assertIn('Bearer {env:TODO_LOCAL_MCP_TOKEN}', source)


if __name__ == "__main__":
    unittest.main(verbosity=2)
