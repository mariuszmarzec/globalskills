from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import subprocess
import time
from typing import Protocol


@dataclass(frozen=True)
class AgentRunResult:
    returncode: int
    duration_seconds: float
    stdout: str
    stderr: str
    command: tuple[str, ...]


class AgentAdapter(Protocol):
    name: str

    def run(
        self,
        *,
        workspace: Path,
        prompt: str,
        model: str | None,
        timeout_seconds: int,
    ) -> AgentRunResult:
        """Run an agent in the supplied workspace."""
        ...


class OpenCodeAdapter:
    """Run benchmark tasks through OpenCode's non-interactive CLI."""

    name = "opencode"

    def __init__(self, binary: str = "opencode") -> None:
        self.binary = binary

    def run(
        self,
        *,
        workspace: Path,
        prompt: str,
        model: str | None,
        timeout_seconds: int,
    ) -> AgentRunResult:
        command = [
            self.binary,
            "run",
            "--auto",
            "--dir",
            str(workspace),
        ]
        if model:
            command.extend(["--model", model])
        command.append(prompt)

        started = time.monotonic()
        try:
            completed = subprocess.run(
                command,
                cwd=workspace,
                text=True,
                capture_output=True,
                timeout=timeout_seconds,
                env=os.environ.copy(),
                check=False,
            )
            return AgentRunResult(
                returncode=completed.returncode,
                duration_seconds=time.monotonic() - started,
                stdout=completed.stdout,
                stderr=completed.stderr,
                command=tuple(command),
            )
        except subprocess.TimeoutExpired as exc:
            return AgentRunResult(
                returncode=124,
                duration_seconds=time.monotonic() - started,
                stdout=exc.stdout or "",
                stderr=(exc.stderr or "") + f"\nOpenCode timed out after {timeout_seconds}s.",
                command=tuple(command),
            )
