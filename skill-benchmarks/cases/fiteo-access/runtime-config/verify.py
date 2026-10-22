#!/usr/bin/env python3
from __future__ import annotations

import argparse
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
from unittest import mock

REQUIRED = (
    "FITEO_BASE_URL",
    "FITEO_MANUL_USERNAME",
    "FITEO_MANUL_PASSWORD",
)
SENTINELS_A = {
    "FITEO_BASE_URL": "https://fiteo-test-a.example.invalid/one",
    "FITEO_MANUL_USERNAME": "test_manul_username_a",
    "FITEO_MANUL_PASSWORD": "test_manul_password_a",
}
SENTINELS_B = {
    "FITEO_BASE_URL": "https://fiteo-test-b.example.invalid/two",
    "FITEO_MANUL_USERNAME": "test_manul_username_b",
    "FITEO_MANUL_PASSWORD": "test_manul_password_b",
}


def load_module(path: Path):
    spec = importlib.util.spec_from_file_location("fiteo_client_under_test", path)
    if spec is None or spec.loader is None:
        raise RuntimeError("cannot load fiteo_client.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def call_config(module, environment):
    stdout = io.StringIO()
    stderr = io.StringIO()
    value = None
    error = None
    with mock.patch.dict(os.environ, environment, clear=True):
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            try:
                value = module.load_fiteo_config()
            except Exception as exc:  # captured and checked below
                error = exc
    return value, error, stdout.getvalue() + stderr.getvalue()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--mode", required=True)
    args = parser.parse_args()

    workspace = Path(args.workspace)
    source_path = workspace / "fiteo_client.py"
    source = source_path.read_text(encoding="utf-8") if source_path.exists() else ""
    checks = []

    def add(name, passed, expected, actual, evidence):
        checks.append({
            "name": name,
            "passed": bool(passed),
            "expected": expected,
            "actual": actual,
            "evidence": evidence,
        })

    names_present = all(name in source for name in REQUIRED)
    add(
        "uses-required-environment-names",
        names_present,
        "all three FITEO_* names referenced",
        "all names found" if names_present else "one or more names missing",
        "source scan of fiteo_client.py",
    )

    import_stdout = io.StringIO()
    import_stderr = io.StringIO()
    module = None
    import_error = None
    with mock.patch.dict(os.environ, SENTINELS_A, clear=True):
        with contextlib.redirect_stdout(import_stdout), contextlib.redirect_stderr(import_stderr):
            try:
                module = load_module(source_path)
            except Exception as exc:
                import_error = exc
    import_output = import_stdout.getvalue() + import_stderr.getvalue()

    config_a = config_b = None
    call_output = ""
    error_a = error_b = None
    if module is not None and callable(getattr(module, "load_fiteo_config", None)):
        config_a, error_a, output_a = call_config(module, SENTINELS_A)
        config_b, error_b, output_b = call_config(module, SENTINELS_B)
        call_output = output_a + output_b

    expected_a = {
        "base_url": SENTINELS_A["FITEO_BASE_URL"],
        "username": SENTINELS_A["FITEO_MANUL_USERNAME"],
        "password": SENTINELS_A["FITEO_MANUL_PASSWORD"],
    }
    expected_b = {
        "base_url": SENTINELS_B["FITEO_BASE_URL"],
        "username": SENTINELS_B["FITEO_MANUL_USERNAME"],
        "password": SENTINELS_B["FITEO_MANUL_PASSWORD"],
    }
    dynamic_ok = (
        module is not None
        and callable(getattr(module, "load_fiteo_config", None))
        and error_a is None
        and error_b is None
        and config_a == expected_a
        and config_b == expected_b
    )
    add(
        "reads-current-environment-dynamically",
        dynamic_ok,
        "config from each current environment",
        "dynamic configuration works" if dynamic_ok else "configuration mismatch or exception",
        "same loaded module called under two different environment configurations",
    )

    all_output = import_output + call_output
    test_values = list(SENTINELS_A.values()) + list(SENTINELS_B.values())
    no_print_ok = all(value not in all_output for value in test_values)
    add(
        "does-not-print-configuration",
        no_print_ok,
        "no configured values written to stdout/stderr",
        "no test values printed" if no_print_ok else "a configured value was printed",
        "captured module import and configuration calls",
    )

    missing_ok = module is not None and callable(getattr(module, "load_fiteo_config", None))
    if missing_ok:
        for missing_name in REQUIRED:
            for missing_state in ("unset", "empty"):
                environment = dict(SENTINELS_A)
                if missing_state == "unset":
                    environment.pop(missing_name)
                else:
                    environment[missing_name] = ""
                configured_values = [
                    value for key, value in environment.items() if key != missing_name and value
                ]
                _, error, output = call_config(module, environment)
                error_message = str(error) if error is not None else ""
                if not isinstance(error, ValueError):
                    missing_ok = False
                if missing_name not in error_message:
                    missing_ok = False
                if any(other_name in error_message for other_name in REQUIRED if other_name != missing_name):
                    missing_ok = False
                if any(value in error_message or value in output for value in configured_values):
                    missing_ok = False
                if output:
                    missing_ok = False
    add(
        "missing-or-empty-config-reports-names-only",
        missing_ok,
        "ValueError names only the missing/empty variable; configured values are not shown",
        "missing and empty configuration handled safely" if missing_ok else "missing/empty config behavior or disclosure check failed",
        "tested every required variable both unset and empty while other variables are configured",
    )

    result = {
        "passed": bool(checks) and all(check["passed"] for check in checks),
        "mode": args.mode,
        "checks": checks,
    }
    print(json.dumps(result))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
