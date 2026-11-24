#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
from pathlib import Path
import re


def extract_function(source: str, name: str) -> str:
    match = re.search(rf"@Composable\s+fun\s+{re.escape(name)}\s*\(", source)
    if not match:
        return ""
    opening = source.find("{", match.end())
    if opening < 0:
        return ""
    depth = 0
    in_string = False
    escaped = False
    for index in range(opening, len(source)):
        character = source[index]
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[match.start():index + 1]
    return ""


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--mode", required=True)
    args = parser.parse_args()

    source_path = Path(args.workspace) / "TrainingScreen.kt"
    source = source_path.read_text(encoding="utf-8") if source_path.exists() else ""
    checks: list[dict[str, object]] = []

    def add(name: str, passed: bool, expected: str, actual: str, evidence: str) -> None:
        checks.append({"name": name, "passed": bool(passed), "expected": expected, "actual": actual, "evidence": evidence})

    required = ("TrainingHeader", "TrainingSummary", "ExerciseList", "TrainingActions")
    sections = {name: extract_function(source, name) for name in required}
    sections_present = all(sections.values())
    add("semantic-sections-extracted", sections_present, ", ".join(required), ", ".join(name for name, body in sections.items() if body) or "none", "top-level @Composable declarations")

    screen = extract_function(source, "TrainingScreen")
    calls_ok = bool(screen) and all(re.search(rf"\b{name}\s*\(", screen) for name in required)
    add("screen-reads-as-section-outline", calls_ok, "TrainingScreen calls all four named sections", "all section calls present" if calls_ok else "missing screen call(s)", "TrainingScreen body scan")

    state_boundary_ok = bool(screen) and "collectAsStateWithLifecycle()" in screen and "rememberSaveable" in screen and "expandedExerciseId" in screen
    add("state-stays-at-screen-boundary", state_boundary_ok, "state collection and local expansion state remain in TrainingScreen", "screen owns state" if state_boundary_ok else "state ownership moved or missing", "TrainingScreen body scan")

    no_viewmodel_in_children = all("viewModel" not in body and "TrainingViewModel" not in body for body in sections.values())
    add("children-receive-values-not-viewmodel", no_viewmodel_in_children, "child sections accept focused values and callbacks, not ViewModel", "no ViewModel references in children" if no_viewmodel_in_children else "ViewModel reference found in child", "extracted composable source scan")

    modifier_ok = all(re.search(r"modifier\s*:\s*Modifier\s*=\s*Modifier", body) for body in sections.values()) and all(re.search(r"modifier\s*=\s*modifier", body) for body in sections.values())
    add("modifier-api-and-forwarding", modifier_ok, "each section has default Modifier and applies it to its root layout", "modifier contract found" if modifier_ok else "a section is missing modifier parameter or forwarding", "extracted composable signatures and bodies")

    labels = ("Training", "Duration", "Exercises", "Completed", "Summary", "No exercises yet", "Add exercise", "Start training", "Complete", "Back")
    missing_labels = [label for label in labels if f'"{label}"' not in source]
    labels_ok = not missing_labels
    add("visible-content-preserved", labels_ok, "all baseline labels remain", "all labels present" if labels_ok else "missing: " + ", ".join(missing_labels), "literal label scan")

    interactions = ("onBack", "onAddExercise", "onStartTraining", "onComplete", "onExerciseSelected")
    interaction_ok = all(name in source for name in interactions)
    add("user-events-preserved", interaction_ok, ", ".join(interactions), "all event paths present" if interaction_ok else "missing event: " + ", ".join(name for name in interactions if name not in source), "source scan for event handlers")

    result = {"passed": bool(checks) and all(check["passed"] for check in checks), "mode": args.mode, "checks": checks}
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
