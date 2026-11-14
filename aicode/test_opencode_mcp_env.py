#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


EXPECTED_AUTHORIZATION = "Bearer ci-caracal-token"


class McpHandler(BaseHTTPRequestHandler):
    seen_authorization = []

    def log_message(self, _format, *_args):
        return

    def _send_json(self, status, payload, session=False):
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("MCP-Protocol-Version", "2025-03-26")
        if session:
            self.send_header("Mcp-Session-Id", "ci-session")
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        McpHandler.seen_authorization.append(self.headers.get("Authorization"))
        if self.headers.get("Authorization") != EXPECTED_AUTHORIZATION:
            self._send_json(401, {"error": "authentication required"})
            return

        payload = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
        method = payload.get("method")
        if isinstance(method, str) and method.startswith("notifications/"):
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.send_header("MCP-Protocol-Version", "2025-03-26")
            self.end_headers()
            return

        result = {}
        if method == "initialize":
            result = {
                "protocolVersion": payload.get("params", {}).get("protocolVersion", "2025-03-26"),
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "globalskills-ci", "version": "1"},
            }
        elif method == "tools/list":
            result = {"tools": []}
        elif method == "prompts/list":
            result = {"prompts": []}
        elif method == "resources/list":
            result = {"resources": []}
        elif method == "resources/templates/list":
            result = {"resourceTemplates": []}

        self._send_json(
            200,
            {"jsonrpc": "2.0", "id": payload.get("id"), "result": result},
            session=method == "initialize",
        )

    def do_GET(self):
        self.send_response(405)
        self.send_header("Allow", "POST")
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()


def main():
    if len(sys.argv) != 2:
        raise SystemExit("usage: test_opencode_mcp_env.py /path/to/opencode")

    opencode = Path(sys.argv[1]).resolve()
    if not opencode.is_file() or not os.access(opencode, os.X_OK):
        raise SystemExit(f"OpenCode executable is missing or not executable: {opencode}")

    McpHandler.seen_authorization = []
    server = ThreadingHTTPServer(("127.0.0.1", 0), McpHandler)
    server.daemon_threads = True
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    try:
        with tempfile.TemporaryDirectory(prefix="globalskills-opencode-mcp-") as home:
            workspace = Path(home) / "workspace"
            workspace.mkdir()
            subprocess.run(["git", "init", "--quiet", str(workspace)], check=True)
            config_path = Path(home) / ".config" / "opencode" / "opencode.json"
            config_path.parent.mkdir(parents=True)
            config = {
                "mcp": {
                    "servers": {
                        "caracal-rag": {
                            "type": "remote",
                            "url": "{env:CARACAL_MCP_URL}",
                            "oauth": False,
                            "disabled": False,
                            "headers": {
                                "Authorization": "Bearer {env:CARACAL_ACCESS_TOKEN}"
                            }
                        }
                    }
                }
            }
            config_path.write_text(json.dumps(config), encoding="utf-8")
            env = {
                "PATH": os.environ.get("PATH", ""),
                "HOME": home,
                "TMPDIR": home,
                "XDG_CONFIG_HOME": str(Path(home) / ".config"),
                "XDG_CACHE_HOME": str(Path(home) / ".cache"),
                "XDG_DATA_HOME": str(Path(home) / ".local" / "share"),
                "XDG_STATE_HOME": str(Path(home) / ".local" / "state"),
                "OPENCODE_CONFIG_DIR": str(config_path.parent),
                "CARACAL_MCP_URL": f"http://127.0.0.1:{server.server_port}/mcp",
                "CARACAL_ACCESS_TOKEN": "ci-caracal-token",
                "NO_COLOR": "1",
                "CI": "true",
            }
            result = subprocess.run(
                [str(opencode), "--standalone", "mcp", "list"],
                cwd=workspace,
                env=env,
                text=True,
                capture_output=True,
                timeout=45,
                check=False,
            )
            output = result.stdout + result.stderr
            if result.returncode != 0 or not re.search(
                r"caracal-rag\s+connected", output, re.IGNORECASE
            ):
                debug = subprocess.run(
                    [str(opencode), "--standalone", "debug", "config"],
                    cwd=workspace,
                    env=env,
                    text=True,
                    capture_output=True,
                    timeout=45,
                    check=False,
                )
                raise AssertionError(
                    "OpenCode did not connect with env-backed URL and bearer header:\n"
                    + output
                    + "\nOpenCode debug config:\n"
                    + debug.stdout
                    + debug.stderr
                )
            if EXPECTED_AUTHORIZATION not in McpHandler.seen_authorization:
                raise AssertionError("MCP server did not receive the env-backed bearer header")
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)

    print("PASS: OpenCode resolves the Caracal URL and bearer header from its process environment.")


if __name__ == "__main__":
    main()
