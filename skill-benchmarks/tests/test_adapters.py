from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import unittest
from unittest.mock import Mock, patch

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))

from adapters import OpenCodeAdapter


class OpenCodeAdapterTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workspace = Path("/tmp/benchmark workspace")
        self.prompt = "Refactor exactly as requested; preserve whitespace.\n"

    @patch("adapters.subprocess.run")
    def test_command_uses_auto_without_dir_and_workspace_as_cwd(self, run: Mock) -> None:
        run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="out", stderr="")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model=None, timeout_seconds=90)
        command = list(result.command)
        self.assertEqual(command[:3], ["opencode", "run", "--auto"])
        self.assertNotIn("--dir", command)
        self.assertNotIn(str(self.workspace), command)
        self.assertEqual(command[-1], self.prompt)
        self.assertEqual(run.call_args.args[0], command)
        self.assertEqual(run.call_args.kwargs["cwd"], self.workspace)

    @patch("adapters.subprocess.run")
    def test_configured_model_is_passed_through(self, run: Mock) -> None:
        run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model="litellm/freeLLMAPI", timeout_seconds=90)
        command = list(result.command)
        model_index = command.index("--model")
        self.assertEqual(command[model_index + 1], "litellm/freeLLMAPI")

    @patch("adapters.subprocess.run")
    def test_none_model_does_not_add_model_argument(self, run: Mock) -> None:
        run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model=None, timeout_seconds=90)
        self.assertNotIn("--model", result.command)

    @patch("adapters.subprocess.run")
    def test_prompt_is_passed_unchanged(self, run: Mock) -> None:
        run.return_value = subprocess.CompletedProcess(args=[], returncode=0, stdout="", stderr="")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model=None, timeout_seconds=90)
        self.assertEqual(result.command[-1], self.prompt)

    @patch("adapters.subprocess.run")
    def test_subprocess_result_is_preserved(self, run: Mock) -> None:
        run.return_value = subprocess.CompletedProcess(args=[], returncode=7, stdout="stdout payload", stderr="stderr payload")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model=None, timeout_seconds=90)
        self.assertEqual(result.returncode, 7)
        self.assertEqual(result.stdout, "stdout payload")
        self.assertEqual(result.stderr, "stderr payload")
        self.assertEqual(result.command, ("opencode", "run", "--auto", self.prompt))

    @patch("adapters.subprocess.run")
    def test_timeout_returns_exit_code_124(self, run: Mock) -> None:
        run.side_effect = subprocess.TimeoutExpired(cmd=["opencode", "run"], timeout=12, output="partial out", stderr="partial err")
        result = OpenCodeAdapter().run(workspace=self.workspace, prompt=self.prompt, model=None, timeout_seconds=12)
        self.assertEqual(result.returncode, 124)
        self.assertEqual(result.stdout, "partial out")
        self.assertIn("partial err", result.stderr)
        self.assertIn("timed out after 12s", result.stderr)
        self.assertEqual(result.command, ("opencode", "run", "--auto", self.prompt))


if __name__ == "__main__":
    unittest.main()
