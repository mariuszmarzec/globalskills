#!/usr/bin/env python3
"""Run a child command with a wall-clock timeout on Linux and macOS."""
from __future__ import annotations

import os
import signal
import subprocess
import sys


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: run-with-timeout.py SECONDS COMMAND [ARGS...]", file=sys.stderr)
        return 2
    try:
        timeout_seconds = float(argv[1])
    except ValueError:
        print("timeout must be a positive number of seconds", file=sys.stderr)
        return 2
    if timeout_seconds <= 0:
        print("timeout must be a positive number of seconds", file=sys.stderr)
        return 2

    try:
        process = subprocess.Popen(argv[2:], start_new_session=True)
    except OSError as exc:
        print(f"unable to start command: {exc}", file=sys.stderr)
        return 127

    try:
        return process.wait(timeout=timeout_seconds)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
        return 124


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
