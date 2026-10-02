#!/usr/bin/env python3
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from typing import Any

from adapters import AgentAdapter, OpenCodeAdapter


HERE = Path(__file__).resolve().parent


@dataclass(frozen=True)
class SkillInfo:
    skill_id: str
    path: Path


@dataclass(frozen=True)
class CaseInfo:
    case_id: str
    skill_id: str
    path: Path
    fixture: Path
    prompt: Path
    verifier: Path
    timeout_seconds: int | None


class BenchmarkError(RuntimeError):
    pass


def load_config(path: Path | None = None) -> dict[str, Any]:
    config_path = path or HERE / "config.json"
    with config_path.open(encoding="utf-8") as handle:
        return json.load(handle)


def discover_skills(skills_root: Path, exclusions: dict[str, str]) -> list[SkillInfo]:
    skills: list[SkillInfo] = []
    for skill_file in sorted(skills_root.glob("*/SKILL.md")):
        skill_id = skill_file.parent.name
        if skill_id not in exclusions:
            skills.append(SkillInfo(skill_id=skill_id, path=skill_file.parent))
    return skills


def discover_cases(cases_root: Path) -> list[CaseInfo]:
    cases: list[CaseInfo] = []
    for manifest in sorted(cases_root.glob("*/*/case.json")):
        data = json.loads(manifest.read_text(encoding="utf-8"))
        case_dir = manifest.parent
        required = ("id", "skill", "fixture", "prompt", "verifier")
        missing = [key for key in required if key not in data]
        if missing:
            raise BenchmarkError(f"{manifest}: missing fields: {', '.join(missing)}")
        cases.append(
            CaseInfo(
                case_id=str(data["id"]),
                skill_id=str(data["skill"]),
                path=case_dir,
                fixture=case_dir / str(data["fixture"]),
                prompt=case_dir / str(data["prompt"]),
                verifier=case_dir / str(data["verifier"]),
                timeout_seconds=(
                    int(data["timeout_seconds"]) if data.get("timeout_seconds") is not None else None
                ),
            )
        )
    return cases


def case_by_selector(cases: list[CaseInfo], selector: str) -> list[CaseInfo]:
    matches = [case for case in cases if case.case_id == selector or case.skill_id == selector]
    if not matches:
        raise BenchmarkError(f"No benchmark case matches '{selector}'.")
    return matches


def stage_skill(skill_source: Path, workspace: Path, skill_id: str, enabled: bool) -> None:
    opencode_dir = workspace / ".opencode"
    skills_dir = opencode_dir / "skills"
    skills_dir.mkdir(parents=True, exist_ok=True)

    target = skills_dir / skill_id
    if enabled:
        shutil.copytree(skill_source, target)
    permission = "allow" if enabled else "deny"
    config = {
        "$schema": "https://opencode.ai/config.json",
        "permission": {"skill": {skill_id: permission}},
    }
    (opencode_dir / "opencode.json").write_text(
        json.dumps(config, indent=2) + "\n",
        encoding="utf-8",
    )


def initialize_fixture(workspace: Path) -> None:
    subprocess.run(["git", "init"], cwd=workspace, check=True, capture_output=True, text=True)
    subprocess.run(
        ["git", "config", "user.name", "Benchmark User"],
        cwd=workspace,
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ["git", "config", "user.email", "benchmark@example.invalid"],
        cwd=workspace,
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(["git", "add", "."], cwd=workspace, check=True, capture_output=True, text=True)
    subprocess.run(
        ["git", "commit", "-m", "benchmark: baseline"],
        cwd=workspace,
        check=True,
        capture_output=True,
        text=True,
    )


def read_prompt(path: Path) -> str:
    return path.read_text(encoding="utf-8").strip()


def run_verifier(verifier: Path, workspace: Path, mode: str) -> dict[str, Any]:
    if verifier.suffix == ".py":
        command = [sys.executable, str(verifier), "--workspace", str(workspace), "--mode", mode]
    elif verifier.suffix == ".sh":
        command = ["bash", str(verifier), "--workspace", str(workspace), "--mode", mode]
    else:
        command = [str(verifier), "--workspace", str(workspace), "--mode", mode]
    completed = subprocess.run(
        command,
        cwd=verifier.parent,
        text=True,
        capture_output=True,
        check=False,
    )
    raw_output = completed.stdout.strip()
    try:
        result = json.loads(raw_output)
    except json.JSONDecodeError:
        lines = [line.strip() for line in raw_output.splitlines() if line.strip()]
        try:
            result = json.loads(lines[-1]) if lines else None
        except json.JSONDecodeError as exc:
            return {
                "passed": False,
                "checks": [],
                "error": (
                    completed.stderr.strip()
                    or f"verifier returned invalid JSON: {exc}"
                ),
                "returncode": completed.returncode,
            }
        if result is None:
            return {
                "passed": False,
                "checks": [],
                "error": completed.stderr.strip() or "verifier returned no JSON",
                "returncode": completed.returncode,
            }
    if not isinstance(result, dict):
        return {
            "passed": False,
            "checks": [],
            "error": "verifier result must be an object",
            "returncode": completed.returncode,
        }
    if "passed" not in result or not isinstance(result["passed"], bool):
        return {
            "passed": False,
            "checks": [],
            "error": "verifier result must contain boolean 'passed'",
            "returncode": completed.returncode,
        }
    result["returncode"] = completed.returncode
    if completed.returncode != 0 and result.get("passed") is True:
        result["passed"] = False
        result["error"] = "verifier returned passed=true with non-zero exit code"
    return result


def run_case(
    case: CaseInfo,
    skill_source: Path,
    adapter: AgentAdapter,
    *,
    mode: str,
    model: str | None,
    default_timeout: int,
    artifacts_root: Path | None = None,
) -> dict[str, Any]:
    if not case.fixture.is_dir():
        raise BenchmarkError(f"{case.fixture}: fixture directory does not exist.")
    if not skill_source.is_dir():
        raise BenchmarkError(f"{skill_source}: skill directory does not exist.")
    timeout = case.timeout_seconds or default_timeout

    with tempfile.TemporaryDirectory(prefix=f"skill-bench-{case.case_id}-") as temp_dir:
        workspace = Path(temp_dir) / "workspace"
        shutil.copytree(case.fixture, workspace)
        stage_skill(skill_source, workspace, case.skill_id, enabled=mode == "with-skill")
        initialize_fixture(workspace)

        started = time.monotonic()
        run_result = adapter.run(
            workspace=workspace,
            prompt=read_prompt(case.prompt),
            model=model,
            timeout_seconds=timeout,
        )
        verifier_result = run_verifier(case.verifier, workspace, mode)
        total_duration = time.monotonic() - started

        if artifacts_root is not None:
            artifact_dir = artifacts_root / case.case_id / mode
            artifact_dir.mkdir(parents=True, exist_ok=True)
            (artifact_dir / "stdout.txt").write_text(run_result.stdout, encoding="utf-8")
            (artifact_dir / "stderr.txt").write_text(run_result.stderr, encoding="utf-8")
            (artifact_dir / "verifier.json").write_text(
                json.dumps(verifier_result, indent=2) + "\n",
                encoding="utf-8",
            )
            for artifact_name, git_args in (
                ("git-log.txt", ("git", "log", "--oneline", "--decorate")),
                ("git-diff.txt", ("git", "diff", "HEAD^", "HEAD")),
            ):
                completed = subprocess.run(
                    git_args,
                    cwd=workspace,
                    text=True,
                    capture_output=True,
                    check=False,
                )
                (artifact_dir / artifact_name).write_text(
                    completed.stdout + completed.stderr,
                    encoding="utf-8",
                )

        return {
            "case": case.case_id,
            "skill": case.skill_id,
            "mode": mode,
            "adapter": adapter.name,
            "model": model,
            "agent_returncode": run_result.returncode,
            "agent_duration_seconds": round(run_result.duration_seconds, 3),
            "duration_seconds": round(total_duration, 3),
            "passed": bool(
                run_result.returncode == 0
                and verifier_result.get("returncode") == 0
                and verifier_result.get("passed")
            ),
            "verifier": verifier_result,
            "command": list(run_result.command),
        }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run behavioral benchmarks for Global Skills.")
    parser.add_argument("command", choices=("list", "run", "validate"))
    parser.add_argument("--skill", help="Skill id or benchmark case id.")
    parser.add_argument("--case", dest="case_id", help="Exact benchmark case id.")
    parser.add_argument("--mode", choices=("with-skill", "without-skill", "both"), default="with-skill")
    parser.add_argument("--model", default=None, help="OpenCode model, e.g. litellm/big-pickle.")
    parser.add_argument("--timeout", type=int, default=None)
    parser.add_argument("--artifacts", type=Path, default=None)
    parser.add_argument("--config", type=Path, default=None)
    return parser.parse_args()


def resolve_path(raw: str, base: Path) -> Path:
    path = Path(raw)
    return (base / path).resolve() if not path.is_absolute() else path.resolve()


def main() -> int:
    args = parse_args()
    config = load_config(args.config)

    config_dir = (args.config or HERE).resolve().parent
    skills_root = resolve_path(config["skills_root"], config_dir)
    cases_root = resolve_path(config["cases_root"], config_dir)
    exclusions = dict(config.get("excluded_skills", {}))
    default_timeout = int(config.get("timeout_seconds", 600))
    model = args.model if args.model is not None else config.get("default_model")
    skills = discover_skills(skills_root, exclusions)
    cases = discover_cases(cases_root)

    if args.command == "list":
        benchmark_by_skill: dict[str, list[str]] = {}
        for case in cases:
            benchmark_by_skill.setdefault(case.skill_id, []).append(case.case_id)
        print("Skills:")
        for skill in skills:
            cases_for_skill = benchmark_by_skill.get(skill.skill_id, [])
            suffix = f" ({len(cases_for_skill)} case(s))" if cases_for_skill else " (no benchmark yet)"
            print(f"  ✓ {skill.skill_id}{suffix}")
        print("Excluded:")
        for skill_id, reason in sorted(exclusions.items()):
            print(f"  ⊘ {skill_id}: {reason}")
        print(f"\nBenchmark cases: {len(cases)}")
        for case in cases:
            print(f"  • {case.case_id} [{case.skill_id}]")
        return 0

    if args.command == "validate":
        skill_ids = {skill.skill_id for skill in skills}
        case_skill_ids = {case.skill_id for case in cases}
        missing = sorted(skill_ids - case_skill_ids)
        unknown = sorted(case_skill_ids - skill_ids)
        if missing:
            print("Missing benchmarks:")
            for skill_id in missing:
                print(f"  {skill_id}")
        if unknown:
            print("Cases for unknown/excluded skills:")
            for skill_id in unknown:
                print(f"  {skill_id}")
        if missing or unknown:
            return 1
        print(f"All {len(skill_ids)} benchmarked skills have at least one case.")
        return 0

    selector = args.case_id or args.skill
    if not selector:
        raise BenchmarkError("run requires --skill or --case.")

    selected = case_by_selector(cases, selector)
    if args.case_id and len(selected) != 1:
        raise BenchmarkError(f"--case '{args.case_id}' matched {len(selected)} cases.")

    selected_skill_ids = {case.skill_id for case in selected}
    for skill_id in selected_skill_ids:
        if skill_id in exclusions:
            raise BenchmarkError(f"Skill '{skill_id}' is excluded from benchmarks.")

    adapter_name = config.get("adapter", "opencode")
    if adapter_name != "opencode":
        raise BenchmarkError(f"Unsupported configured adapter '{adapter_name}'.")
    adapter = OpenCodeAdapter()

    modes = ("with-skill", "without-skill") if args.mode == "both" else (args.mode,)
    results: list[dict[str, Any]] = []
    for case in selected:
        skill_source = skills_root / case.skill_id
        for mode in modes:
            print(f"Running {case.case_id} [{mode}]...")
            results.append(
                run_case(
                    case,
                    skill_source,
                    adapter,
                    mode=mode,
                    model=model,
                    default_timeout=args.timeout or default_timeout,
                    artifacts_root=args.artifacts,
                )
            )

    print("\nResults:")
    print(json.dumps(results, indent=2))
    return 0 if all(result["passed"] for result in results) else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except BenchmarkError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
