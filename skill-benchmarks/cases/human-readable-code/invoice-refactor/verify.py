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

    # Identify helpers by responsibility, allowing naming variants with or without a leading underscore.
    helper_names = [
        node.name for node in tree.body
        if isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef)) and node.name != "create_invoice"
    ]
    subtotal_helpers = [name for name in helper_names if "subtotal" in name]
    discount_helpers = [name for name in helper_names if "discount" in name]
    taxable_amount_helpers = [name for name in helper_names if "taxable" in name]
    tax_and_total_helpers = [name for name in helper_names if "tax" in name and "total" in name]
    tax_helpers = [
        name for name in helper_names
        if "tax" in name and "total" not in name and "taxable" not in name
    ]

    category_helpers = subtotal_helpers + discount_helpers + tax_helpers
    categories_are_distinct = len(category_helpers) == 3 and len(set(category_helpers)) == 3
    exactly_one_per_operation = (
        len(subtotal_helpers) == 1
        and len(discount_helpers) == 1
        and len(tax_helpers) == 1
        and categories_are_distinct
    )
    no_additional_helpers = len(helper_names) == 3 and set(helper_names) == set(category_helpers)
    no_forbidden_helpers = not taxable_amount_helpers and not tax_and_total_helpers
    helpers_ok = exactly_one_per_operation and no_additional_helpers and no_forbidden_helpers

    actual_helpers = ", ".join(sorted(helper_names)) or "no calculation helpers"
    expected_msg = "exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper"
    add(
        "meaningful-calculation-helpers",
        helpers_ok,
        expected_msg,
        actual_helpers,
        "top-level function definitions classified by domain responsibility"
    )

    # The public entry point must call those unique helpers and contain no calculation loop.
    orchestration_ok = False
    if public is not None and exactly_one_per_operation:
        called = {
            node.func.id for node in ast.walk(public)
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
        }
        has_loop = any(
            isinstance(node, (ast.For, ast.AsyncFor, ast.While))
            for node in ast.walk(public)
        )
        orchestration_ok = (
            subtotal_helpers[0] in called
            and discount_helpers[0] in called
            and tax_helpers[0] in called
            and not has_loop
        )
    add(
        "entry-point-orchestrates-steps",
        orchestration_ok,
        "create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop",
        "orchestration extracted" if orchestration_ok else "expected helper calls or loop-free orchestration missing",
        "AST calls and control-flow inspection"
    )

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
