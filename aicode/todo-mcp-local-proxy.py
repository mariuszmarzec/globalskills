#!/usr/bin/env python3
"""Loopback-only TCP relay for the Windows Todo MCP bridge."""

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import select
import signal
import socket
import socketserver
import subprocess
import sys
import time
from pathlib import Path


DEFAULT_LISTEN_HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 8766
DEFAULT_UPSTREAM_PORT = 18765
SCRIPT_PATH = str(Path(__file__).resolve())


class ThreadingProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False

    def __init__(self, address, upstream_host, upstream_port):
        self.upstream_host = upstream_host
        self.upstream_port = upstream_port
        super().__init__(address, ProxyHandler)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        try:
            upstream = socket.create_connection(
                (self.server.upstream_host, self.server.upstream_port), timeout=4
            )
        except OSError:
            return

        with upstream:
            upstream.settimeout(None)
            client.settimeout(None)
            sockets = {client, upstream}
            while sockets:
                readable, _, _ = select.select(list(sockets), [], [], 120)
                if not readable:
                    continue
                for source in readable:
                    target = upstream if source is client else client
                    try:
                        data = source.recv(65536)
                    except OSError:
                        data = b""
                    if not data:
                        sockets.discard(source)
                        try:
                            target.shutdown(socket.SHUT_WR)
                        except OSError:
                            pass
                        continue
                    try:
                        target.sendall(data)
                    except OSError:
                        sockets.clear()
                        break


def ensure_ipv4_private(value):
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise ValueError("upstream host must be an IPv4 address") from error
    if address.version != 4 or not address.is_private or address.is_loopback or address.is_multicast:
        raise ValueError("upstream host must be a private, non-loopback IPv4 address")
    return str(address)


def state_payload(pid, upstream_host, upstream_port, listen_port):
    return {
        "pid": pid,
        "listen_host": DEFAULT_LISTEN_HOST,
        "listen_port": listen_port,
        "upstream_host": upstream_host,
        "upstream_port": upstream_port,
        "script_sha256": hashlib.sha256(Path(SCRIPT_PATH).read_bytes()).hexdigest(),
    }


def safe_state_paths(state_dir):
    if state_dir.is_symlink():
        raise RuntimeError("bridge state directory must not be a symlink")
    state_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(state_dir, 0o700)
    state_file = state_dir / "bridge.json"
    lock_file = state_dir / "bridge.lock"
    log_file = state_dir / "bridge.log"
    if state_file.is_symlink() or lock_file.is_symlink() or log_file.is_symlink():
        raise RuntimeError("bridge state files must not be symlinks")
    return state_file, lock_file, log_file


def read_state(state_file):
    try:
        value = json.loads(state_file.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None
    except (OSError, json.JSONDecodeError):
        return None
    return value if isinstance(value, dict) else None


def managed_process(pid):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        argv = [part.decode(errors="replace") for part in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0") if part]
    except (OSError, PermissionError):
        return False
    try:
        script = str(Path(argv[1]).resolve()) if len(argv) >= 2 else ""
    except OSError:
        return False
    return script == SCRIPT_PATH and "--serve" in argv


def process_alive(pid):
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def port_open(port):
    try:
        with socket.create_connection((DEFAULT_LISTEN_HOST, port), timeout=0.3):
            return True
    except OSError:
        return False


def stop_managed_process(pid):
    if not (managed_process(pid) and process_alive(pid)):
        return
    os.kill(pid, signal.SIGTERM)
    for _ in range(30):
        if not process_alive(pid):
            return
        time.sleep(0.1)
    raise RuntimeError("unable to stop the previous managed Todo MCP bridge")


def ensure(args):
    upstream_host = ensure_ipv4_private(args.upstream_host)
    if not 1 <= args.upstream_port <= 65535 or not 1 <= args.listen_port <= 65535:
        raise ValueError("bridge ports must be between 1 and 65535")
    state_dir = Path(args.state_dir).expanduser()
    state_file, lock_file, log_file = safe_state_paths(state_dir)
    with lock_file.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        current = read_state(state_file)
        expected = state_payload(-1, upstream_host, args.upstream_port, args.listen_port)
        keys = ("listen_host", "listen_port", "upstream_host", "upstream_port", "script_sha256")
        if current:
            pid = current.get("pid")
            same_config = all(current.get(key) == expected.get(key) for key in keys)
            if same_config and managed_process(pid) and process_alive(pid) and port_open(args.listen_port):
                print(f"Todo MCP local bridge already running on {DEFAULT_LISTEN_HOST}:{args.listen_port}.")
                return
            stop_managed_process(pid)
            state_file.unlink(missing_ok=True)

        if port_open(args.listen_port):
            raise RuntimeError(f"{DEFAULT_LISTEN_HOST}:{args.listen_port} is occupied by an unmanaged process")

        log_handle = log_file.open("ab")
        os.chmod(log_file, 0o600)
        command = [
            sys.executable,
            SCRIPT_PATH,
            "--serve",
            "--listen-host",
            DEFAULT_LISTEN_HOST,
            "--listen-port",
            str(args.listen_port),
            "--upstream-host",
            upstream_host,
            "--upstream-port",
            str(args.upstream_port),
            "--state-dir",
            str(state_dir.resolve()),
        ]
        child = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=log_handle,
            stderr=subprocess.STDOUT,
            cwd=str(Path(SCRIPT_PATH).parent),
            start_new_session=True,
            close_fds=True,
        )
        log_handle.close()
        for _ in range(50):
            if child.poll() is not None:
                raise RuntimeError(f"Todo MCP local bridge exited during startup; see {log_file}")
            new_state = read_state(state_file)
            if new_state and new_state.get("pid") == child.pid and managed_process(child.pid) and port_open(args.listen_port):
                print(f"Todo MCP local bridge ready on {DEFAULT_LISTEN_HOST}:{args.listen_port}.")
                return
            time.sleep(0.1)
        if process_alive(child.pid) and managed_process(child.pid):
            os.kill(child.pid, signal.SIGTERM)
        raise RuntimeError(f"Todo MCP local bridge did not become ready; see {log_file}")


def serve(args):
    upstream_host = ensure_ipv4_private(args.upstream_host)
    if args.listen_host != DEFAULT_LISTEN_HOST:
        raise ValueError("Todo MCP local bridge must bind to 127.0.0.1 only")
    if not 1 <= args.upstream_port <= 65535 or not 1 <= args.listen_port <= 65535:
        raise ValueError("bridge ports must be between 1 and 65535")
    state_dir = Path(args.state_dir).expanduser()
    state_file, _, _ = safe_state_paths(state_dir)
    with ThreadingProxyServer(
        (DEFAULT_LISTEN_HOST, args.listen_port), upstream_host, args.upstream_port
    ) as server:
        payload = state_payload(os.getpid(), upstream_host, args.upstream_port, args.listen_port)
        tmp = state_file.with_suffix(".json.tmp")
        tmp.write_text(json.dumps(payload), encoding="utf-8")
        os.chmod(tmp, 0o600)
        os.replace(tmp, state_file)
        server.serve_forever(poll_interval=0.2)


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--listen-host", default=DEFAULT_LISTEN_HOST)
    parser.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    parser.add_argument("--upstream-host", required=True)
    parser.add_argument("--upstream-port", type=int, default=DEFAULT_UPSTREAM_PORT)
    parser.add_argument("--state-dir", default="~/.cache/globalskills/todo-mcp-bridge")
    return parser


def main():
    args = build_parser().parse_args()
    try:
        if args.serve:
            serve(args)
        else:
            ensure(args)
    except (OSError, RuntimeError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
