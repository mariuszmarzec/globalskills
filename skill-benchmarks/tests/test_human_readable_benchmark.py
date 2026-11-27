from __future__ import annotations

from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

from benchmark import compose_mode_prompt, skill_activation_check, write_mode_artifacts


class NativeSkillActivationTests(unittest.TestCase):
    def test_with_skill_requires_exact_native_tool_invocation(self) -> None:
        stderr = '\\n→ \\x1b[0mSkill "human-readable-code" \\n'
        result = skill_activation_check(stderr, "human-readable-code", "with-skill")
        self.assertTrue(result["passed"])
        self.assertEqual("native-skill-activation", result["name"])

    def test_with_skill_fails_when_tool_was_not_invoked(self) -> None:
        stderr = '> orchestrator · freeLLMAPI\\n→ Read invoice.py\\n'
        result = skill_activation_check(stderr, "human-readable-code", "with-skill")
        self.assertFalse(result["passed"])

    def test_without_skill_passes_when_tool_was_not_invoked(self) -> None:
        stderr = "Permission denied: skill\\n→ Read invoice.py\\n"
        result = skill_activation_check(stderr, "human-readable-code", "without-skill")
        self.assertTrue(result["passed"])

    def test_without_skill_fails_if_native_tool_was_invoked(self) -> None:
        stderr = '→ Skill "human-readable-code"\\n'
        result = skill_activation_check(stderr, "human-readable-code", "without-skill")
        self.assertFalse(result["passed"])

    def test_mode_prompt_requires_skill_as_first_action_only_with_skill(self) -> None:
        with_prompt = compose_mode_prompt("Refactor the fixture.", "human-readable-code", "with-skill")
        without_prompt = compose_mode_prompt("Refactor the fixture.", "human-readable-code", "without-skill")
        self.assertIn("MANDATORY FIRST ACTION", with_prompt)
        self.assertIn("first tool call", with_prompt)
        self.assertIn("native skill tool", with_prompt)
        self.assertIn("BASELINE MODE", without_prompt)
        self.assertIn("Do not invoke or attempt to invoke", without_prompt)
        self.assertNotIn("MANDATORY FIRST ACTION", without_prompt)


class HumanReadableBenchmarkPromptTests(unittest.TestCase):
    def test_prompt_defines_three_scalar_invoice_operations(self) -> None:
        prompt_path = (
            HERE.parent
            / "cases"
            / "human-readable-code"
            / "invoice-refactor"
            / "prompt.md"
        )
        prompt = prompt_path.read_text(encoding="utf-8").lower()

        self.assertIn("exactly these three calculation operations", prompt)
        self.assertIn("calculate_subtotal(items)", prompt)
        self.assertIn("calculate_discount(subtotal, discount_code)", prompt)
        self.assertIn("calculate_tax(taxable_amount, tax_rate)", prompt)
        self.assertIn("returns only the tax amount as one scalar number", prompt)
        self.assertIn("keep the simple", prompt)
        self.assertIn("inline in", prompt)
        self.assertIn("do not create a", prompt)
        self.assertIn("calculate_tax_and_total", prompt)


class TestableDesignBenchmarkPromptTests(unittest.TestCase):
    def test_prompt_loads_testable_design_skill_only_when_available(self) -> None:
        prompt_path = (
            HERE.parent
            / "cases"
            / "testable-design"
            / "registration-boundary"
            / "prompt.md"
        )
        prompt = prompt_path.read_text(encoding="utf-8").lower()

        self.assertIn("available-skills", prompt)
        self.assertIn("testable-design", prompt)
        self.assertIn("native", prompt)
        self.assertIn("without-skill baseline", prompt)
        self.assertIn("continue without a skill", prompt)


class HumanReadableSkillBoundaryTests(unittest.TestCase):
    def test_explicit_operation_list_is_closed_and_precedes_general_guidance(self) -> None:
        skill_path = HERE.parent.parent / "skills" / "human-readable-code" / "SKILL.md"
        skill = skill_path.read_text(encoding="utf-8").lower()

        priority_rule = skill.index("## priority rule: one requested operation, one result")
        general_guidance = skill.index("## goal")
        self.assertLess(priority_rule, general_guidance)
        self.assertIn("closed and exhaustive", skill)
        self.assertIn("exactly one helper for each named operation", skill)
        self.assertIn("each helper performs only its named operation", skill)
        self.assertIn("returns exactly that operation's result", skill)
        self.assertIn(
            "must not return a tuple, list, dictionary, or object",
            skill,
        )
        self.assertIn("do not combine a named operation with a downstream result", skill)
        self.assertIn("do not add helpers for simple intermediate or derived values", skill)
        self.assertIn("native skill tool before inspecting or editing code", skill)
        self.assertIn("calculate_tax_and_total", skill)
        self.assertIn("return tax, total", skill)
        self.assertIn("tax = calculate_tax(taxable_amount, tax_rate)", skill)
        self.assertIn("total = round(taxable_amount + tax, 2)", skill)

    def test_working_approach_requires_operation_to_result_mapping(self) -> None:
        skill_path = HERE.parent.parent / "skills" / "human-readable-code" / "SKILL.md"
        skill = skill_path.read_text(encoding="utf-8").lower()

        self.assertIn(
            "write down the operation-to-helper-to-result map before editing",
            skill,
        )
        self.assertIn(
            "keep intermediate values and downstream result assembly with the caller",
            skill,
        )


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
            target.write_text("def total():\n    return 1\n", encoding="utf-8")
            subprocess.run(["git", "add", "invoice.py"], cwd=workspace, check=True, capture_output=True)
            subprocess.run(
                ["git", "commit", "-m", "benchmark: baseline"],
                cwd=workspace,
                check=True,
                capture_output=True,
            )
            target.write_text("def total():\n    return 2\n", encoding="utf-8")

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
