#!/usr/bin/env python3
from __future__ import annotations

import argparse
import ast
import json
from pathlib import Path
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--mode", required=True)
    args = parser.parse_args()

    workspace = Path(args.workspace)
    source_path = workspace / "invoice.py"
    source = source_path.read_text(encoding="utf-8") if source_path.exists() else ""
    checks: list[dict[str, object]] = []

    def add(name: str, passed: bool, expected: str, actual: str, evidence: str) -> None:
        checks.append({"name": name, "passed": bool(passed), "expected": expected, "actual": actual, "evidence": evidence})

    try:
        tree = ast.parse(source)
        parse_ok = True
        parse_error = "valid"
    except SyntaxError as exc:
        tree = ast.Module(body=[], type_ignores=[])
        parse_ok = False
        parse_error = f"{exc.msg} at line {exc.lineno}"
    add("valid-python", parse_ok, "invoice.py parses", parse_error, "ast.parse(invoice.py)")

    functions = {node.name: node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    public = functions.get("create_invoice")
    signature_ok = False
    if public is not None:
        positional = [arg.arg for arg in public.args.args]
        signature_ok = positional == ["items", "discount_code", "tax_rate"] and len(public.args.defaults) == 2
    add("public-api-preserved", signature_ok, "create_invoice(items, discount_code=None, tax_rate=0.0)", str([arg.arg for arg in public.args.args]) if public else "missing", "AST function signature")

    expected_helpers = {"_calculate_subtotal", "_calculate_discount", "_calculate_tax"}
    helper_names = [name for name in functions if name.startswith("_")]
    helpers_ok = expected_helpers.issubset(functions) and len(helper_names) <= 4
    add("meaningful-calculation-helpers", helpers_ok, "subtotal, discount, and tax are named helpers without helper proliferation", ", ".join(sorted(helper_names)) or "no private helpers", "top-level function definitions")

    orchestration_ok = False
    if public is not None:
        called = {node.func.id for node in ast.walk(public) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        orchestration_ok = expected_helpers.issubset(called) and not any(isinstance(node, (ast.For, ast.AsyncFor, ast.While)) for node in ast.walk(public))
    add("entry-point-orchestrates-steps", orchestration_ok, "create_invoice calls named operations rather than containing the calculation loop", "orchestration extracted" if orchestration_ok else "calculation details remain in entry point", "AST calls and control-flow inspection")

    no_classes = not any(isinstance(node, ast.ClassDef) for node in tree.body)
    add("no-unneeded-production-types", no_classes, "no classes added for this local refactor", "no classes" if no_classes else "class declaration found", "top-level AST class definitions")

    completed = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"], cwd=workspace, capture_output=True, text=True, check=False)
    tests_ok = completed.returncode == 0
    test_output = (completed.stdout + completed.stderr).strip().splitlines()
    add("existing-behavior-tests", tests_ok, "all existing invoice tests pass", test_output[-1] if test_output else f"exit {completed.returncode}", "python -m unittest discover -s tests -v")

    result = {"passed": bool(checks) and all(check["passed"] for check in checks), "mode": args.mode, "checks": checks}
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
