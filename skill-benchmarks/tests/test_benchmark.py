from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))

from adapters import AgentRunResult
from benchmark import discover_cases, discover_skills, run_case


class MockAdapter:
    name = "mock"

    def run(
        self,
        *,
        workspace: Path,
        prompt: str,
        model: str | None,
        timeout_seconds: int,
    ) -> AgentRunResult:
        (workspace / "hello.txt").write_text("hello benchmark
", encoding="utf-8")
        with_trailer = (workspace / ".opencode" / "skills" / "ai-commit-attribution").exists()
        commit_body = "Co-authored-by: OpenCode <opencode@ai.local>" if with_trailer else ""
        subprocess.run(
            ["git", "add", "hello.txt"],
            cwd=workspace,
            check=True,
            capture_output=True,
            text=True,
        )
        env = {
            **os.environ,
            "GIT_EDITOR": "true",
            "GIT_COMMITTER_NAME": "Benchmark User",
            "GIT_COMMITTER_EMAIL": "benchmark@example.invalid",
        }
        args = ["git", "commit", "-m", "benchmark: update hello"]
        if commit_body:
            args.extend(["-m", commit_body])
        completed = subprocess.run(
            args,
            cwd=workspace,
            env=env,
            check=True,
            capture_output=True,
            text=True,
        )
        return AgentRunResult(0, 0.001, completed.stdout, completed.stderr, ("mock",))


class BenchmarkTests(unittest.TestCase):
    @staticmethod
    def config() -> dict[str, object]:
        return json.loads((HERE / "config.json").read_text(encoding="utf-8"))

    def test_discovery_respects_exclusions_and_finds_case(self) -> None:
        config = self.config()
        skills = discover_skills(
            (HERE / str(config["skills_root"])).resolve(),
            dict(config["excluded_skills"]),
        )
        skill_ids = {skill.skill_id for skill in skills}
        self.assertNotIn("manul-github-bot", skill_ids)
        cases = discover_cases((HERE / str(config["cases_root"])).resolve())
        self.assertIn("commit-trailer", {case.case_id for case in cases})

    def test_mock_adapter_passes_when_skill_is_present(self) -> None:
        config = self.config()
        case = next(
            case
            for case in discover_cases((HERE / str(config["cases_root"])).resolve())
            if case.case_id == "commit-trailer"
        )
        skill_source = (HERE / ".." / "skills" / case.skill_id).resolve()
        result = run_case(
            case,
            skill_source,
            MockAdapter(),
            mode="with-skill",
            model=None,
            default_timeout=30,
        )
        self.assertTrue(result["passed"], result)
        self.assertTrue(result["verifier"]["passed"])

    def test_mock_adapter_fails_without_skill(self) -> None:
        config = self.config()
        case = next(
            case
            for case in discover_cases((HERE / str(config["cases_root"])).resolve())
            if case.case_id == "commit-trailer"
        )
        skill_source = (HERE / ".." / "skills" / case.skill_id).resolve()
        result = run_case(
            case,
            skill_source,
            MockAdapter(),
            mode="without-skill",
            model=None,
            default_timeout=30,
        )
        self.assertFalse(result["passed"])
        self.assertFalse(result["verifier"]["passed"])


if __name__ == "__main__":
    unittest.main()
