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

    # Semantic helper check: recognize separate subtotal, discount, tax helpers
    # Accept sensible naming variants (e.g., _calculate_line_item_subtotal)
    # Reject combined tax+total helper and intermediate taxable_amount helper
    subtotal_helpers = [name for name in functions if name.startswith("_") and ("subtotal" in name or "line_item" in name)]
    discount_helpers = [name for name in functions if name.startswith("_") and "discount" in name]
    taxable_amount_helpers = [name for name in functions if name.startswith("_") and "taxable" in name]
    tax_and_total_helpers = [name for name in functions if name.startswith("_") and "tax" in name and "total" in name]
    # Tax helpers must have "tax" in name but NOT "total" and NOT "taxable"
    tax_helpers = [name for name in functions if name.startswith("_") and "tax" in name and "total" not in name and "taxable" not in name]

    all_private_helpers = [name for name in functions if name.startswith("_")]
    helper_count = len(all_private_helpers)

    has_subtotal = len(subtotal_helpers) >= 1
    has_discount = len(discount_helpers) >= 1
    has_tax = len(tax_helpers) >= 1
    has_taxable_amount = len(taxable_amount_helpers) >= 1
    has_tax_and_total = len(tax_and_total_helpers) >= 1

    helpers_ok = has_subtotal and has_discount and has_tax and not has_taxable_amount and not has_tax_and_total and helper_count <= 4
    actual_helpers = ", ".join(sorted(all_private_helpers)) or "no private helpers"
    expected_msg = "separate subtotal, discount, tax helpers; no taxable_amount or tax_and_total helper; <=4 total"
    add("meaningful-calculation-helpers", helpers_ok, expected_msg, actual_helpers, "top-level function definitions (semantic match)")

    # Orchestration: public entry point calls all three recognized operations and contains no calculation loop
    orchestration_ok = False
    if public is not None:
        called = {node.func.id for node in ast.walk(public) if isinstance(node, ast.Call) and isinstance(node.func, ast.Name)}
        has_loop = any(isinstance(node, (ast.For, ast.AsyncFor, ast.While)) for node in ast.walk(public))
        # Check that it calls at least one helper for each domain operation
        calls_subtotal = any(h in called for h in subtotal_helpers)
        calls_discount = any(h in called for h in discount_helpers)
        calls_tax = any(h in called for h in tax_helpers)
        orchestration_ok = calls_subtotal and calls_discount and calls_tax and not has_loop
    add("entry-point-orchestrates-steps", orchestration_ok, "create_invoice calls subtotal, discount, tax helpers and contains no calculation loop", "orchestration extracted" if orchestration_ok else "calculation details remain in entry point or missing helper calls", "AST calls and control-flow inspection")

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
