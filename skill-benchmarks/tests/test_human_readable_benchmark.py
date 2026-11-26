from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from benchmark import write_mode_artifacts


class HumanReadableBenchmarkPromptTests(unittest.TestCase):
    def test_prompt_loads_skill_only_when_available(self) -> None:
        prompt_path = (
            HERE.parent
            / "cases"
            / "human-readable-code"
            / "invoice-refactor"
            / "prompt.md"
        )
        prompt = prompt_path.read_text(encoding="utf-8").lower()

        self.assertIn("available-skills", prompt)
        self.assertIn("human-readable-code", prompt)
        self.assertIn("native", prompt)
        self.assertIn("skill", prompt)
        self.assertIn("without-skill baseline", prompt)
        self.assertIn("continue without a skill", prompt)


class BenchmarkGitDiffArtifactTests(unittest.TestCase):
    def test_git_diff_artifact_captures_uncommitted_workspace_changes(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            workspace = Path(temp_dir) / "workspace"
            workspace.mkdir()
            subprocess.run(["git", "init"], cwd=workspace, check=True, capture_output=True)
            subprocess.run(
                ["git", "config", "user.name", "Benchmark Test"],
                cwd=workspace,
                check=True,
                capture_output=True,
            )
            subprocess.run(
                ["git", "config", "user.email", "benchmark-test@example.invalid"],
                cwd=workspace,
                check=True,
                capture_output=True,
            )

            target = workspace / "invoice.py"
            target.write_text("def total():\\n    return 1\\n", encoding="utf-8")
            subprocess.run(["git", "add", "invoice.py"], cwd=workspace, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "benchmark: baseline"],
                cwd=workspace,
                check=True,
                capture_output=True,
            )
            target.write_text("def total():\\n    return 2\\n", encoding="utf-8")

            artifact_dir = Path(temp_dir) / "artifacts"
            run_result = SimpleNamespace(
                command=("opencode", "run", "--auto", "prompt"),
                stdout="agent output",
                stderr="agent diagnostics",
            )
            write_mode_artifacts(
                artifact_dir,
                run_result,
                {"passed": False, "checks": []},
                "prompt",
                workspace,
            )

            diff = (artifact_dir / "git-diff.txt").read_text(encoding="utf-8")
            self.assertIn("-    return 1", diff)
            self.assertIn("+    return 2", diff)
            self.assertNotIn("ambiguous argument", diff)


if __name__ == "__main__":
    unittest.main()
