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
    source_path = workspace / "registration.py"
    test_path = workspace / "tests" / "test_registration.py"
    source = source_path.read_text(encoding="utf-8") if source_path.exists() else ""
    tests = test_path.read_text(encoding="utf-8") if test_path.exists() else ""
    checks: list[dict[str, object]] = []

    def add(name: str, passed: bool, expected: str, actual: str, evidence: str) -> None:
        checks.append({"name": name, "passed": bool(passed), "expected": expected, "actual": actual, "evidence": evidence})

    try:
        tree = ast.parse(source)
        test_tree = ast.parse(tests)
        parse_ok = True
        parse_error = "valid"
    except SyntaxError as exc:
        tree = ast.Module(body=[], type_ignores=[])
        test_tree = ast.Module(body=[], type_ignores=[])
        parse_ok = False
        parse_error = f"{exc.msg} at line {exc.lineno}"
    add("valid-python", parse_ok, "production and test files parse", parse_error, "ast.parse(registration.py, test_registration.py)")

    functions = {node.name: node for node in tree.body if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef))}
    register = functions.get("register_user")

    # Find the pure helper: a top-level function (not register_user) that takes one data argument
    # and has no external effects. This is the extracted validation/normalization function.
    pure_helper_name = None
    pure_helper_node = None
    for name, node in functions.items():
        if name == "register_user":
            continue
        if len(node.args.args) == 1:
            # Check if this function is pure (no external effects)
            names = {n.id for n in ast.walk(node) if isinstance(n, ast.Name)}
            attributes = {n.attr for n in ast.walk(node) if isinstance(n, ast.Attribute)}
            calls = {n.func.id for n in ast.walk(node) if isinstance(n, ast.Call) and isinstance(n.func, ast.Name)}
            is_pure = not (names & {"database", "mailer", "datetime", "timezone", "print", "open"}) and not (attributes & {"insert", "send_welcome", "now"}) and not (calls & {"print", "open"})
            if is_pure:
                pure_helper_name = name
                pure_helper_node = node
                break

    helper_ok = pure_helper_name is not None and register is not None
    add("explicit-pure-policy-helper", helper_ok, "a pure helper (one data arg, no effects) and register_user(data, database, mailer) exist", ", ".join(sorted(functions)) or "none", "top-level function definitions")

    pure_ok = False
    if pure_helper_node is not None:
        names = {node.id for node in ast.walk(pure_helper_node) if isinstance(node, ast.Name)}
        attributes = {node.attr for node in ast.walk(pure_helper_node) if isinstance(node, ast.Attribute)}
        calls = {node.func.id for node in ast.walk(pure_helper_node) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        pure_ok = not (names & {"database", "mailer", "datetime", "timezone", "print", "open"}) and not (attributes & {"insert", "send_welcome", "now"}) and not (calls & {"print", "open"})
    add("validation-independent-of-effects", pure_ok, f"{pure_helper_name or 'pure helper'} has no persistence, mail, time, filesystem, or output effects", "no external-effect references" if pure_ok else "external-effect reference found", f"AST inspection of {pure_helper_name or 'pure helper'}")

    delegation_ok = False
    if register is not None and pure_helper_name is not None:
        calls = {node.func.id for node in ast.walk(register) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        attrs = {node.attr for node in ast.walk(register) if isinstance(node, ast.Attribute)}
        delegation_ok = pure_helper_name in calls and "insert" in attrs and "send_welcome" in attrs
    add("entry-point-orchestrates-boundaries", delegation_ok, f"register_user uses {pure_helper_name or 'pure helper'}, then persists and sends welcome email", "delegation present" if delegation_ok else "expected orchestration missing", "AST calls and collaborator operations")

    # Find test functions/methods (functions whose names start with test_)
    # that directly call the pure helper via AST Call with Name id
    # Only count calls in the test function's own body, not in nested functions/classes
    def find_direct_calls_in_body(node, helper_name):
        """Find direct calls to the helper in a function body, excluding nested functions/classes."""
        calls = set()
        for stmt in node.body:
            # Skip nested function and class definitions entirely
            if isinstance(stmt, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                continue
            # Walk this statement, but don't descend into nested functions/classes
            for n in ast.walk(stmt):
                if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    # Don't walk into nested functions/classes
                    continue
                if isinstance(n, ast.Call) and isinstance(n.func, ast.Name) and n.func.id == helper_name:
                    calls.add(helper_name)
        return calls

    test_functions_with_direct_call = []
    if pure_helper_name is not None:
        for node in ast.walk(test_tree):
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name.startswith("test_"):
                direct_calls = find_direct_calls_in_body(node, pure_helper_name)
                if direct_calls:
                    test_functions_with_direct_call.append(node.name)

    test_coverage_ok = len(test_functions_with_direct_call) >= 2
    add("direct-helper-tests", test_coverage_ok, f"at least two distinct test functions directly call {pure_helper_name or 'pure helper'}", ", ".join(sorted(test_functions_with_direct_call)) or "no direct helper tests", f"AST inspection of test_* function bodies for direct Call(Name('{pure_helper_name or 'pure helper'}'))")

    mocks_absent = "unittest.mock" not in tests and "MagicMock" not in tests and "Mock(" not in tests
    add("no-mock-heavy-test-setup", mocks_absent, "use lightweight fakes rather than mocks", "no mock framework usage" if mocks_absent else "mock usage found", "test source scan")

    completed = subprocess.run([sys.executable, "-m", "unittest", "discover", "-s", "tests", "-v"], cwd=workspace, capture_output=True, text=True, check=False)
    tests_ok = completed.returncode == 0
    test_output = (completed.stdout + completed.stderr).strip().splitlines()
    add("registration-tests", tests_ok, "all registration tests pass", test_output[-1] if test_output else f"exit {completed.returncode}", "python -m unittest discover -s tests -v")

    result = {"passed": bool(checks) and all(check["passed"] for check in checks), "mode": args.mode, "checks": checks}
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())