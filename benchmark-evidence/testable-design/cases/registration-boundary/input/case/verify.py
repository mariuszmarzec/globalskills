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
    prepare = functions.get("prepare_registration")
    register = functions.get("register_user")
    helper_ok = prepare is not None and register is not None
    add("explicit-pure-policy-helper", helper_ok, "prepare_registration(data) and register_user(data, database, mailer) exist", ", ".join(sorted(functions)), "top-level function definitions")

    pure_ok = False
    if prepare is not None:
        names = {node.id for node in ast.walk(prepare) if isinstance(node, ast.Name)}
        attributes = {node.attr for node in ast.walk(prepare) if isinstance(node, ast.Attribute)}
        calls = {node.func.id for node in ast.walk(prepare) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        pure_ok = not (names & {"database", "mailer", "datetime", "timezone", "print", "open"}) and not (attributes & {"insert", "send_welcome", "now"}) and not (calls & {"print", "open"})
    add("validation-independent-of-effects", pure_ok, "prepare_registration has no persistence, mail, time, filesystem, or output effects", "no external-effect references" if pure_ok else "external-effect reference found", "AST inspection of prepare_registration")

    delegation_ok = False
    if register is not None:
        calls = {node.func.id for node in ast.walk(register) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        attrs = {node.attr for node in ast.walk(register) if isinstance(node, ast.Attribute)}
        delegation_ok = "prepare_registration" in calls and "insert" in attrs and "send_welcome" in attrs
    add("entry-point-orchestrates-boundaries", delegation_ok, "register_user uses prepare_registration, then persists and sends welcome email", "delegation present" if delegation_ok else "expected orchestration missing", "AST calls and collaborator operations")

    # Count direct calls in each test method body, but do not recurse into nested scopes.
    def has_direct_helper_call(test_function: ast.AST) -> bool:
        def contains_direct_call(node: ast.AST) -> bool:
            if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef, ast.Lambda)):
                return False
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name):
                if node.func.id == "prepare_registration":
                    return True
            return any(contains_direct_call(child) for child in ast.iter_child_nodes(node))

        return any(contains_direct_call(statement) for statement in test_function.body)

    class TestMethodCollector(ast.NodeVisitor):
        def __init__(self) -> None:
            self.methods: list[ast.AST] = []

        def visit_FunctionDef(self, node: ast.FunctionDef) -> None:
            if node.name.startswith("test_"):
                self.methods.append(node)
            # A nested function is not an independent test method.

        def visit_AsyncFunctionDef(self, node: ast.AsyncFunctionDef) -> None:
            if node.name.startswith("test_"):
                self.methods.append(node)

    collector = TestMethodCollector()
    collector.visit(test_tree)
    test_functions_with_direct_call = [
        node for node in collector.methods if has_direct_helper_call(node)
    ]
    test_coverage_ok = len(test_functions_with_direct_call) >= 2
    helper_test_names = [
        f"{node.name}@{node.lineno}" for node in test_functions_with_direct_call
    ]
    add(
        "direct-helper-tests",
        test_coverage_ok,
        "at least two distinct test methods directly call prepare_registration",
        ", ".join(helper_test_names) or "no direct helper tests",
        "AST inspection of test method bodies, excluding nested scopes"
    )

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
