#!/usr/bin/env python3
"""Loopback MCP proxy backed by Windows-initiated reverse TCP channels."""

import argparse
import fcntl
import hashlib
import ipaddress
import json
import os
import queue
import select
import signal
import socket
import socketserver
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path


DEFAULT_LISTEN_HOST = "127.0.0.1"
DEFAULT_LISTEN_PORT = 8766
DEFAULT_REVERSE_LISTEN_PORT = 18766
DEFAULT_CHANNEL_COUNT = 4
DEFAULT_REVERSE_LISTEN_BACKLOG = 128
EXCESS_CHANNEL_LOG_INTERVAL = 64
SCRIPT_PATH = str(Path(__file__).resolve())

def reverse_listen_backlog(max_channels):
    """Keep short connector reconnect bursts out of the kernel's small default backlog."""
    return max(DEFAULT_REVERSE_LISTEN_BACKLOG, max_channels * 8)


def reject_reverse_channel(channel):
    """Reset rejected TCP channels immediately instead of leaving half-closed peers."""
    try:
        channel.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))
    except OSError:
        pass
    try:
        channel.close()
    except OSError:
        pass



def ensure_ipv4_private(value, description):
    try:
        address = ipaddress.ip_address(value)
    except ValueError as error:
        raise ValueError(f"{description} must be an IPv4 address") from error
    if (
        address.version != 4
        or not address.is_private
        or address.is_loopback
        or address.is_multicast
    ):
        raise ValueError(f"{description} must be a private, non-loopback IPv4 address")
    return str(address)


class ReverseChannelPool:
    """Accepts Windows-originated TCP channels and lends each to one MCP request."""

    def __init__(self, allowed_client_address, max_channels):
        self.allowed_client_address = ensure_ipv4_private(
            allowed_client_address, "allowed reverse client"
        )
        self.channels = queue.Queue(maxsize=max_channels)
        self.stop_event = threading.Event()
        self.listener = None
        self.thread = None
        self.rejected_excess_channels = 0

    def start(self, listen_host, listen_port):
        listen_host = ensure_ipv4_private(listen_host, "reverse listen host")
        listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind((listen_host, listen_port))
        listener.listen(reverse_listen_backlog(self.channels.maxsize))
        listener.settimeout(0.5)
        self.listener = listener
        self.thread = threading.Thread(
            target=self._accept_loop, name="todo-mcp-reverse-accept", daemon=True
        )
        self.thread.start()
        print(
            f"Todo MCP reverse relay listening on {listen_host}:{listen_port}; "
            f"allowing Windows peer {self.allowed_client_address}.",
            flush=True,
        )

    def _accept_loop(self):
        while not self.stop_event.is_set():
            try:
                channel, peer = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                if self.stop_event.is_set():
                    return
                print("Todo MCP reverse relay accept failed.", flush=True)
                continue

            peer_address = peer[0]
            if peer_address != self.allowed_client_address:
                print(
                    f"Rejected reverse channel from {peer_address}; "
                    f"expected {self.allowed_client_address}.",
                    flush=True,
                )
                reject_reverse_channel(channel)
                continue

            channel.setblocking(True)
            try:
                self.channels.put(channel, timeout=0.25)
                print("Accepted a Windows-initiated reverse channel.", flush=True)
            except queue.Full:
                self.rejected_excess_channels += 1
                rejected = self.rejected_excess_channels
                if rejected == 1 or rejected % EXCESS_CHANNEL_LOG_INTERVAL == 0:
                    print(
                        f"Rejected excess reverse channels because the pool is full "
                        f"(total rejected: {rejected}).",
                        flush=True,
                    )
                reject_reverse_channel(channel)

    @staticmethod
    def _channel_is_idle_and_open(channel):
        try:
            readable, _, exceptional = select.select([channel], [], [channel], 0)
            if exceptional or readable:
                # A channel must remain silent until the local MCP proxy assigns it.
                # Readability therefore means EOF or unexpected data.
                channel.recv(1, socket.MSG_PEEK | socket.MSG_DONTWAIT)
                return False
            return True
        except (OSError, ValueError):
            return False

    def acquire(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise queue.Empty
            channel = self.channels.get(timeout=remaining)
            if self._channel_is_idle_and_open(channel):
                return channel
            channel.close()

    def close(self):
        self.stop_event.set()
        if self.listener is not None:
            try:
                self.listener.close()
            except OSError:
                pass
        while True:
            try:
                channel = self.channels.get_nowait()
            except queue.Empty:
                break
            try:
                channel.close()
            except OSError:
                pass


class ThreadingProxyServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True
    block_on_close = False

    def __init__(self, address, channel_pool):
        self.channel_pool = channel_pool
        super().__init__(address, ProxyHandler)


class ProxyHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        try:
            reverse_channel = self.server.channel_pool.acquire(timeout=6)
        except queue.Empty:
            body = b"Todo MCP reverse bridge unavailable"
            response = (
                b"HTTP/1.1 503 Service Unavailable\r\n"
                + f"Content-Length: {len(body)}\r\n".encode("ascii")
                + b"Connection: close\r\n"
                + b"Content-Type: text/plain\r\n\r\n"
                + body
            )
            try:
                client.sendall(response)
            except OSError:
                pass
            return

        with reverse_channel:
            client.settimeout(None)
            reverse_channel.settimeout(None)
            sockets = {client, reverse_channel}
            while sockets:
                readable, _, exceptional = select.select(
                    list(sockets), [], list(sockets), 120
                )
                if exceptional:
                    break
                if not readable:
                    continue
                for source in readable:
                    target = reverse_channel if source is client else client
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
                        if source is reverse_channel:
                            # Todo's Connection: close response completes this
                            # one-request channel; do not wait for the local
                            # HTTP client to half-close its request socket.
                            return
                        continue
                    try:
                        target.sendall(data)
                    except OSError:
                        sockets.clear()
                        break


def state_payload(
    pid,
    reverse_listen_host,
    reverse_listen_port,
    allowed_reverse_client,
    channel_count,
    listen_port,
):
    return {
        "pid": pid,
        "listen_host": DEFAULT_LISTEN_HOST,
        "listen_port": listen_port,
        "reverse_listen_host": reverse_listen_host,
        "reverse_listen_port": reverse_listen_port,
        "allowed_reverse_client": allowed_reverse_client,
        "channel_count": channel_count,
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
        argv = [
            part.decode(errors="replace")
            for part in Path(f"/proc/{pid}/cmdline").read_bytes().split(b"\0")
            if part
        ]
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


def validate_args(args):
    reverse_listen_host = ensure_ipv4_private(
        args.reverse_listen_host, "reverse listen host"
    )
    allowed_reverse_client = ensure_ipv4_private(
        args.allowed_reverse_client, "allowed reverse client"
    )
    if (
        not 1 <= args.reverse_listen_port <= 65535
        or not 1 <= args.listen_port <= 65535
    ):
        raise ValueError("bridge ports must be between 1 and 65535")
    if not 1 <= args.channel_count <= 16:
        raise ValueError("channel count must be between 1 and 16")
    return reverse_listen_host, allowed_reverse_client


def ensure(args):
    reverse_listen_host, allowed_reverse_client = validate_args(args)
    state_dir = Path(args.state_dir).expanduser()
    state_file, lock_file, log_file = safe_state_paths(state_dir)
    with lock_file.open("a+", encoding="utf-8") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        current = read_state(state_file)
        expected = state_payload(
            -1,
            reverse_listen_host,
            args.reverse_listen_port,
            allowed_reverse_client,
            args.channel_count,
            args.listen_port,
        )
        keys = (
            "listen_host",
            "listen_port",
            "reverse_listen_host",
            "reverse_listen_port",
            "allowed_reverse_client",
            "channel_count",
            "script_sha256",
        )
        if current:
            pid = current.get("pid")
            same_config = all(current.get(key) == expected.get(key) for key in keys)
            if (
                same_config
                and managed_process(pid)
                and process_alive(pid)
                and port_open(args.listen_port)
            ):
                print(
                    f"Todo MCP reverse relay already running on "
                    f"{DEFAULT_LISTEN_HOST}:{args.listen_port}."
                )
                return
            stop_managed_process(pid)
            state_file.unlink(missing_ok=True)

        if port_open(args.listen_port):
            raise RuntimeError(
                f"{DEFAULT_LISTEN_HOST}:{args.listen_port} is occupied by an unmanaged process"
            )

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
            "--reverse-listen-host",
            reverse_listen_host,
            "--reverse-listen-port",
            str(args.reverse_listen_port),
            "--allowed-reverse-client",
            allowed_reverse_client,
            "--channel-count",
            str(args.channel_count),
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
                raise RuntimeError(
                    f"Todo MCP reverse relay exited during startup; see {log_file}"
                )
            new_state = read_state(state_file)
            if (
                new_state
                and new_state.get("pid") == child.pid
                and managed_process(child.pid)
                and port_open(args.listen_port)
            ):
                print(
                    f"Todo MCP reverse relay ready: local "
                    f"{DEFAULT_LISTEN_HOST}:{args.listen_port}, reverse "
                    f"{reverse_listen_host}:{args.reverse_listen_port}."
                )
                return
            time.sleep(0.1)
        if process_alive(child.pid) and managed_process(child.pid):
            os.kill(child.pid, signal.SIGTERM)
        raise RuntimeError(
            f"Todo MCP reverse relay did not become ready; see {log_file}"
        )


def serve(args):
    reverse_listen_host, allowed_reverse_client = validate_args(args)
    if args.listen_host != DEFAULT_LISTEN_HOST:
        raise ValueError("Todo MCP local bridge must bind to 127.0.0.1 only")

    state_dir = Path(args.state_dir).expanduser()
    state_file, _, _ = safe_state_paths(state_dir)
    pool = ReverseChannelPool(allowed_reverse_client, args.channel_count)
    pool.start(reverse_listen_host, args.reverse_listen_port)
    try:
        with ThreadingProxyServer(
            (DEFAULT_LISTEN_HOST, args.listen_port), pool
        ) as server:
            payload = state_payload(
                os.getpid(),
                reverse_listen_host,
                args.reverse_listen_port,
                allowed_reverse_client,
                args.channel_count,
                args.listen_port,
            )
            tmp = state_file.with_suffix(".json.tmp")
            tmp.write_text(json.dumps(payload), encoding="utf-8")
            os.chmod(tmp, 0o600)
            os.replace(tmp, state_file)
            server.serve_forever(poll_interval=0.2)
    finally:
        pool.close()


def build_parser():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", action="store_true")
    parser.add_argument("--listen-host", default=DEFAULT_LISTEN_HOST)
    parser.add_argument("--listen-port", type=int, default=DEFAULT_LISTEN_PORT)
    parser.add_argument(
        "--reverse-listen-host",
        required=True,
        help="WSL interface address that accepts Windows-initiated channels",
    )
    parser.add_argument(
        "--reverse-listen-port", type=int, default=DEFAULT_REVERSE_LISTEN_PORT
    )
    parser.add_argument(
        "--allowed-reverse-client",
        required=True,
        help="Windows WSL-gateway IPv4 address allowed to open reverse channels",
    )
    parser.add_argument("--channel-count", type=int, default=DEFAULT_CHANNEL_COUNT)
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
