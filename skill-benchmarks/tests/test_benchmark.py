from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HERE))

from adapters import AgentRunResult
from benchmark import (
    BenchmarkError,
    build_comparisons,
    build_evaluation,
    build_impact_summary,
    discover_cases,
    discover_skills,
    run_case,
    select_run_cases,
    write_report,
)


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
        (workspace / "hello.txt").write_text("hello benchmark\n", encoding="utf-8")
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

    def test_run_all_selects_only_non_excluded_case_skills(self) -> None:
        config = self.config()
        skills = discover_skills(
            (HERE / str(config["skills_root"])).resolve(),
            dict(config["excluded_skills"]),
        )
        cases = discover_cases((HERE / str(config["cases_root"])).resolve())

        selector, selected = select_run_cases(
            "run-all",
            cases,
            skills,
            dict(config["excluded_skills"]),
        )

        self.assertEqual(selector, "all-skills")
        self.assertGreaterEqual(len(selected), 1)
        enabled_skill_ids = {skill.skill_id for skill in skills}
        self.assertTrue(
            all(case.skill_id in enabled_skill_ids for case in selected)
        )

    def test_run_all_rejects_explicit_selector(self) -> None:
        config = self.config()
        skills = discover_skills(
            (HERE / str(config["skills_root"])).resolve(),
            dict(config["excluded_skills"]),
        )
        cases = discover_cases((HERE / str(config["cases_root"])).resolve())

        with self.assertRaisesRegex(
            BenchmarkError,
            "run-all does not accept --skill or --case",
        ):
            select_run_cases(
                "run-all",
                cases,
                skills,
                dict(config["excluded_skills"]),
                selector="commit-trailer",
            )

    def test_both_mode_evaluates_only_with_skill_results(self) -> None:
        results = [
            {"mode": "with-skill", "passed": True},
            {"mode": "without-skill", "passed": False},
        ]
        evaluation = build_evaluation(results, "both")
        self.assertEqual(evaluation["target_mode"], "with-skill")
        self.assertTrue(evaluation["passed"])
        self.assertEqual(evaluation["passed_runs"], 1)
        self.assertEqual(evaluation["failed_runs"], 0)

    def test_impact_summary_aggregates_case_signals(self) -> None:
        comparisons = [
            {"comparison_available": True, "impact_signal": "skill_helped"},
            {"comparison_available": True, "impact_signal": "skill_harmed"},
            {"comparison_available": True, "impact_signal": "case_passes_without_skill"},
            {"comparison_available": True, "impact_signal": "case_fails_with_and_without_skill"},
            {"comparison_available": False},
        ]
        self.assertEqual(
            build_impact_summary(comparisons),
            {
                "cases_compared": 4,
                "skill_helped": 1,
                "skill_harmed": 1,
                "case_passes_without_skill": 1,
                "case_fails_with_and_without_skill": 1,
                "comparison_unavailable": 1,
            },
        )

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


    def test_comparison_reports_changed_checks(self) -> None:
        with_skill = {
            "case": "commit-trailer",
            "mode": "with-skill",
            "passed": True,
            "verifier": {
                "checks": [
                    {"name": "content", "passed": True},
                    {"name": "trailer", "passed": True},
                ]
            },
        }
        without_skill = {
            "case": "commit-trailer",
            "mode": "without-skill",
            "passed": False,
            "verifier": {
                "checks": [
                    {"name": "content", "passed": True},
                    {"name": "trailer", "passed": False},
                ]
            },
        }

        comparison = build_comparisons([without_skill, with_skill])[0]
        self.assertEqual(comparison["impact_signal"], "skill_helped")
        self.assertEqual(
            comparison["check_deltas"],
            [{"name": "trailer", "without_skill": False, "with_skill": True}],
        )

    def test_run_artifacts_include_diagnostic_files_and_skill_snapshot(self) -> None:
        config = self.config()
        case = next(
            case
            for case in discover_cases((HERE / str(config["cases_root"])).resolve())
            if case.case_id == "commit-trailer"
        )
        skill_source = (HERE / ".." / "skills" / case.skill_id).resolve()

        with tempfile.TemporaryDirectory() as temp_dir:
            output = Path(temp_dir) / "run"
            result = run_case(
                case,
                skill_source,
                MockAdapter(),
                mode="with-skill",
                model=None,
                default_timeout=30,
                artifacts_root=output,
            )
            artifact_dir = output / "cases" / "commit-trailer" / "with-skill"
            self.assertTrue(result["passed"], result)
            for filename in (
                "prompt.txt",
                "command.txt",
                "stdout.txt",
                "stderr.txt",
                "verifier.json",
                "git-status.txt",
                "git-log.txt",
                "git-diff.txt",
                "git-show.txt",
            ):
                self.assertTrue((artifact_dir / filename).exists(), filename)
            self.assertTrue(
                (
                    output / "cases" / "commit-trailer" / "input" / "skill" / "SKILL.md"
                ).exists()
            )

    def test_report_json_and_markdown_are_written(self) -> None:
        result = {
            "case": "commit-trailer",
            "skill": "ai-commit-attribution",
            "mode": "with-skill",
            "passed": False,
            "agent_returncode": 0,
            "agent_duration_seconds": 1.2,
            "duration_seconds": 1.3,
            "artifact_dir": "cases/commit-trailer/with-skill",
            "verifier": {
                "passed": False,
                "returncode": 1,
                "checks": [
                    {
                        "name": "commit-message",
                        "passed": False,
                        "expected": "benchmark: update hello",
                        "actual": "wrong message",
                        "evidence": "git log -1 --pretty=%s",
                    }
                ],
            },
        }

        with tempfile.TemporaryDirectory() as temp_dir:
            report_dir = Path(temp_dir)
            write_report(
                report_dir,
                selector="commit-trailer",
                requested_mode="both",
                config_path=HERE / "config.json",
                model=None,
                results=[result],
                started_at="2026-10-02T10:00:00+00:00",
                finished_at="2026-10-02T10:00:02+00:00",
            )
            report_json = json.loads(
                (report_dir / "report.json").read_text(encoding="utf-8")
            )
            report_md = (report_dir / "report.md").read_text(encoding="utf-8")
            self.assertEqual(report_json["schema_version"], 1)
            self.assertEqual(report_json["summary"]["failed_runs"], 1)
            self.assertIn("wrong message", report_md)
            self.assertIn("Expected", report_md)


if __name__ == "__main__":
    unittest.main()
