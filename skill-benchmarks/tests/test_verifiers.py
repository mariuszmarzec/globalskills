#!/usr/bin/env python3
from __future__ import annotations

import ast
import json
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent


class TestableDesignVerifierTests(unittest.TestCase):
    """Regression tests for the testable-design registration-boundary verifier."""

    VERIFIER_PATH = HERE.parent / "cases" / "testable-design" / "registration-boundary" / "verify.py"

    def run_verifier(self, source: str, tests: str) -> dict:
        """Run the verifier on a temporary workspace with given source and tests."""
        with tempfile.TemporaryDirectory() as tmpdir:
            workspace = Path(tmpdir)
            (workspace / "registration.py").write_text(source, encoding="utf-8")
            tests_dir = workspace / "tests"
            tests_dir.mkdir()
            (tests_dir / "test_registration.py").write_text(tests, encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(self.VERIFIER_PATH), "--workspace", str(workspace), "--mode", "with-skill"],
                capture_output=True,
                text=True,
                check=False,
            )
            return json.loads(result.stdout.strip())

    def test_two_distinct_test_methods_directly_call_helper_passes(self):
        """Two distinct test_* methods directly call prepare_registration -> PASS."""
        source = """
def prepare_registration(data):
    name = data.get("name", "").strip()
    email = data.get("email", "").strip().lower()
    if not name:
        raise ValueError("name is required")
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError("email is invalid")
    return {"name": name, "email": email}

def register_user(data, database, mailer):
    prepared = prepare_registration(data)
    user = {"name": prepared["name"], "email": prepared["email"]}
    database.insert(user)
    mailer.send_welcome(prepared["email"])
    return user
"""
        tests = """
import unittest
from registration import prepare_registration, register_user

class FakeDatabase:
    def __init__(self):
        self.users = []
    def insert(self, user):
        self.users.append(user)

class FakeMailer:
    def __init__(self):
        self.sent_to = []
    def send_welcome(self, email):
        self.sent_to.append(email)

class TestPrepareRegistration(unittest.TestCase):
    def test_normalizes_name_and_email(self):
        result = prepare_registration({"name": "  Ada ", "email": " ADA@EXAMPLE.COM "})
        self.assertEqual("Ada", result["name"])
        self.assertEqual("ada@example.com", result["email"])

    def test_email_ends_with_at_raises(self):
        with self.assertRaises(ValueError):
            prepare_registration({"name": "Ada", "email": "bad@"})

class RegisterUserTests(unittest.TestCase):
    def test_normalizes_user_and_sends_welcome(self):
        db = FakeDatabase()
        mailer = FakeMailer()
        user = register_user({"name": "Ada", "email": "ada@example.com"}, db, mailer)
        self.assertEqual("Ada", user["name"])

    def test_invalid_input_does_not_write_or_send(self):
        db = FakeDatabase()
        mailer = FakeMailer()
        with self.assertRaises(ValueError):
            register_user({"name": " ", "email": "bad"}, db, mailer)
        self.assertEqual([], db.users)
"""
        result = self.run_verifier(source, tests)
        check = next(c for c in result["checks"] if c["name"] == "direct-helper-tests")
        self.assertTrue(check["passed"], f"Expected pass, got: {check}")
        self.assertIn("test_normalizes_name_and_email", check["actual"])
        self.assertIn("test_email_ends_with_at_raises", check["actual"])

    def test_test_names_contain_helper_but_no_direct_call_fails(self):
        """Test method names contain 'prepare_registration' but bodies don't call it -> FAIL."""
        source = """
def prepare_registration(data):
    name = data.get("name", "").strip()
    email = data.get("email", "").strip().lower()
    if not name:
        raise ValueError("name is required")
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError("email is invalid")
    return {"name": name, "email": email}

def register_user(data, database, mailer):
    prepared = prepare_registration(data)
    user = {"name": prepared["name"], "email": prepared["email"]}
    database.insert(user)
    mailer.send_welcome(prepared["email"])
    return user
"""
        tests = """
import unittest
from registration import register_user

class FakeDatabase:
    def __init__(self):
        self.users = []
    def insert(self, user):
        self.users.append(user)

class FakeMailer:
    def __init__(self):
        self.sent_to = []
    def send_welcome(self, email):
        self.sent_to.append(email)

class TestPrepareRegistration(unittest.TestCase):
    def test_prepare_registration_normalizes(self):
        # Name contains helper but body does NOT call prepare_registration
        user = register_user({"name": "Ada", "email": "ada@example.com"}, FakeDatabase(), FakeMailer())
        self.assertEqual("Ada", user["name"])

    def test_prepare_registration_invalid_email(self):
        # Name contains helper but body does NOT call prepare_registration
        with self.assertRaises(ValueError):
            register_user({"name": "Ada", "email": "bad@"}, FakeDatabase(), FakeMailer())
"""
        result = self.run_verifier(source, tests)
        check = next(c for c in result["checks"] if c["name"] == "direct-helper-tests")
        self.assertFalse(check["passed"], f"Expected fail, got: {check}")
        self.assertEqual(check["actual"], "no direct helper tests")

    def test_calls_inside_nested_local_functions_do_not_count(self):
        """Calls inside nested local functions are not direct calls from the test methods."""
        source = """
def prepare_registration(data):
    return {"name": data["name"], "email": data["email"]}

def register_user(data, database, mailer):
    prepared = prepare_registration(data)
    database.insert(prepared)
    mailer.send_welcome(prepared["email"])
    return prepared
"""
        tests = """
from registration import register_user

class TestRegistration:
    def test_first_case(self):
        def nested_check():
            from registration import prepare_registration
            return prepare_registration({"name": "Ada", "email": "ada@example.com"})
        nested_check()

    def test_second_case(self):
        def another_nested_check():
            from registration import prepare_registration
            return prepare_registration({"name": "Grace", "email": "grace@example.com"})
        another_nested_check()
"""
        result = self.run_verifier(source, tests)
        check = next(c for c in result["checks"] if c["name"] == "direct-helper-tests")
        self.assertFalse(check["passed"], f"Expected nested calls not to count, got: {check}")
        self.assertEqual(check["actual"], "no direct helper tests")

    def test_only_one_test_method_directly_calls_helper_fails(self):
        """Only one test_* method directly calls prepare_registration -> FAIL."""
        source = """
def prepare_registration(data):
    name = data.get("name", "").strip()
    email = data.get("email", "").strip().lower()
    if not name:
        raise ValueError("name is required")
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError("email is invalid")
    return {"name": name, "email": email}

def register_user(data, database, mailer):
    prepared = prepare_registration(data)
    user = {"name": prepared["name"], "email": prepared["email"]}
    database.insert(user)
    mailer.send_welcome(prepared["email"])
    return user
"""
        tests = """
import unittest
from registration import prepare_registration, register_user

class FakeDatabase:
    def __init__(self):
        self.users = []
    def insert(self, user):
        self.users.append(user)

class FakeMailer:
    def __init__(self):
        self.sent_to = []
    def send_welcome(self, email):
        self.sent_to.append(email)

class TestPrepareRegistration(unittest.TestCase):
    def test_normalizes_name_and_email(self):
        result = prepare_registration({"name": "  Ada ", "email": " ADA@EXAMPLE.COM "})
        self.assertEqual("Ada", result["name"])
        self.assertEqual("ada@example.com", result["email"])

    def test_another_test_no_direct_call(self):
        user = register_user({"name": "Ada", "email": "ada@example.com"}, FakeDatabase(), FakeMailer())
        self.assertEqual("Ada", user["name"])
"""
        result = self.run_verifier(source, tests)
        check = next(c for c in result["checks"] if c["name"] == "direct-helper-tests")
        self.assertFalse(check["passed"], f"Expected fail, got: {check}")
        self.assertIn("test_normalizes_name_and_email", check["actual"])
        self.assertNotIn("test_another_test_no_direct_call", check["actual"])

    def test_direct_calls_outside_test_methods_do_not_count(self):
        """Direct calls in production code / setup / non-test functions do not count -> FAIL."""
        source = """
def prepare_registration(data):
    name = data.get("name", "").strip()
    email = data.get("email", "").strip().lower()
    if not name:
        raise ValueError("name is required")
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise ValueError("email is invalid")
    return {"name": name, "email": email}

def register_user(data, database, mailer):
    # Direct call in production code
    prepared = prepare_registration(data)
    user = {"name": prepared["name"], "email": prepared["email"]}
    database.insert(user)
    mailer.send_welcome(prepared["email"])
    return user

def helper_setup():
    # Direct call in non-test function
    prepare_registration({"name": "Setup", "email": "setup@test.com"})
"""
        tests = """
import unittest
from registration import register_user

class FakeDatabase:
    def __init__(self):
        self.users = []
    def insert(self, user):
        self.users.append(user)

class FakeMailer:
    def __init__(self):
        self.sent_to = []
    def send_welcome(self, email):
        self.sent_to.append(email)

class RegisterUserTests(unittest.TestCase):
    def test_normalizes_user_and_sends_welcome(self):
        db = FakeDatabase()
        mailer = FakeMailer()
        user = register_user({"name": "Ada", "email": "ada@example.com"}, db, mailer)
        self.assertEqual("Ada", user["name"])

    def test_invalid_input_does_not_write_or_send(self):
        db = FakeDatabase()
        mailer = FakeMailer()
        with self.assertRaises(ValueError):
            register_user({"name": " ", "email": "bad"}, db, mailer)
        self.assertEqual([], db.users)
"""
        result = self.run_verifier(source, tests)
        check = next(c for c in result["checks"] if c["name"] == "direct-helper-tests")
        self.assertFalse(check["passed"], f"Expected fail, got: {check}")
        self.assertEqual(check["actual"], "no direct helper tests")


class HumanReadableCodeVerifierTests(unittest.TestCase):
    """Regression tests for the human-readable-code invoice-refactor verifier."""

    VERIFIER_PATH = HERE.parent / "cases" / "human-readable-code" / "invoice-refactor" / "verify.py"

    def run_verifier(self, source: str) -> dict:
        """Run the verifier on a temporary workspace with given source."""
        with tempfile.TemporaryDirectory() as tmpdir:
            workspace = Path(tmpdir)
            (workspace / "invoice.py").write_text(source, encoding="utf-8")
            tests_dir = workspace / "tests"
            tests_dir.mkdir()
            # Copy the existing fixture tests
            fixture_tests = (HERE.parent / "cases" / "human-readable-code" / "invoice-refactor" / "fixture" / "tests" / "test_invoice.py").read_text(encoding="utf-8")
            (tests_dir / "test_invoice.py").write_text(fixture_tests, encoding="utf-8")

            result = subprocess.run(
                [sys.executable, str(self.VERIFIER_PATH), "--workspace", str(workspace), "--mode", "with-skill"],
                capture_output=True,
                text=True,
                check=False,
            )
            return json.loads(result.stdout.strip())

    def test_intended_three_helper_orchestration_passes(self):
        """Three distinct helpers (subtotal, discount, tax) with orchestration -> PASS."""
        source = """
def _calculate_subtotal(items):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price
    return subtotal

def _calculate_discount(subtotal, discount_code):
    discount = 0.0
    if discount_code is not None:
        if discount_code == "SAVE10":
            discount = subtotal * 0.10
        elif discount_code == "SAVE20" and subtotal >= 100.0:
            discount = subtotal * 0.20
    return discount

def _calculate_tax(taxable_amount, tax_rate):
    return round(taxable_amount * tax_rate, 2)

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = subtotal - discount
    if taxable_amount < 0:
        taxable_amount = 0.0
    tax = _calculate_tax(taxable_amount, tax_rate)
    total = round(taxable_amount + tax, 2)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
"""
        result = self.run_verifier(source)
        for check in result["checks"]:
            if check["name"] == "meaningful-calculation-helpers":
                self.assertTrue(check["passed"], f"meaningful-calculation-helpers failed: {check}")
            if check["name"] == "entry-point-orchestrates-steps":
                self.assertTrue(check["passed"], f"entry-point-orchestrates-steps failed: {check}")
            if check["name"] == "existing-behavior-tests":
                self.assertTrue(check["passed"], f"existing-behavior-tests failed: {check}")

    def test_previous_with_skill_implementation_fails_correct_reason(self):
        """Previous with-skill output (intermediate taxable_amount + combined tax_and_total) -> FAIL for correct reasons."""
        source = """
def _calculate_subtotal(items):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price
    return subtotal

def _calculate_discount(subtotal, discount_code):
    discount = 0.0
    if discount_code is not None:
        if discount_code == "SAVE10":
            discount = subtotal * 0.10
        elif discount_code == "SAVE20" and subtotal >= 100.0:
            discount = subtotal * 0.20
    return discount

def _calculate_taxable_amount(subtotal, discount):
    taxable_amount = subtotal - discount
    if taxable_amount < 0:
        taxable_amount = 0.0
    return taxable_amount

def _calculate_tax_and_total(taxable_amount, tax_rate):
    tax = round(taxable_amount * tax_rate, 2)
    total = round(taxable_amount + tax, 2)
    return tax, total

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = _calculate_taxable_amount(subtotal, discount)
    tax, total = _calculate_tax_and_total(taxable_amount, tax_rate)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
"""
        result = self.run_verifier(source)
        for check in result["checks"]:
            if check["name"] == "meaningful-calculation-helpers":
                self.assertFalse(check["passed"], f"meaningful-calculation-helpers should fail: {check}")
                self.assertIn("taxable_amount", check["actual"])
                self.assertIn("tax_and_total", check["actual"])
            if check["name"] == "entry-point-orchestrates-steps":
                self.assertFalse(check["passed"], f"entry-point-orchestrates-steps should fail: {check}")

    def test_combined_tax_and_total_helper_fails(self):
        """Combined tax_and_total helper must not satisfy tax helper requirement -> FAIL."""
        source = """
def _calculate_subtotal(items):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price
    return subtotal

def _calculate_discount(subtotal, discount_code):
    discount = 0.0
    if discount_code is not None:
        if discount_code == "SAVE10":
            discount = subtotal * 0.10
        elif discount_code == "SAVE20" and subtotal >= 100.0:
            discount = subtotal * 0.20
    return discount

def _calculate_tax_and_total(taxable_amount, tax_rate):
    tax = round(taxable_amount * tax_rate, 2)
    total = round(taxable_amount + tax, 2)
    return tax, total

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = subtotal - discount
    if taxable_amount < 0:
        taxable_amount = 0.0
    tax, total = _calculate_tax_and_total(taxable_amount, tax_rate)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
"""
        result = self.run_verifier(source)
        for check in result["checks"]:
            if check["name"] == "meaningful-calculation-helpers":
                self.assertFalse(check["passed"], f"meaningful-calculation-helpers should fail: {check}")
                self.assertIn("tax_and_total", check["actual"])

    def test_intermediate_taxable_amount_helper_fails(self):
        """Intermediate taxable_amount helper counts as unwanted proliferation -> FAIL."""
        source = """
def _calculate_subtotal(items):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price
    return subtotal

def _calculate_discount(subtotal, discount_code):
    discount = 0.0
    if discount_code is not None:
        if discount_code == "SAVE10":
            discount = subtotal * 0.10
        elif discount_code == "SAVE20" and subtotal >= 100.0:
            discount = subtotal * 0.20
    return discount

def _calculate_taxable_amount(subtotal, discount):
    taxable_amount = subtotal - discount
    if taxable_amount < 0:
        taxable_amount = 0.0
    return taxable_amount

def _calculate_tax(taxable_amount, tax_rate):
    return round(taxable_amount * tax_rate, 2)

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = _calculate_taxable_amount(subtotal, discount)
    tax = _calculate_tax(taxable_amount, tax_rate)
    total = round(taxable_amount + tax, 2)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
"""
        result = self.run_verifier(source)
        for check in result["checks"]:
            if check["name"] == "meaningful-calculation-helpers":
                self.assertFalse(check["passed"], f"meaningful-calculation-helpers should fail: {check}")
                self.assertIn("taxable_amount", check["actual"])


    VALID_SOURCE = """
def _calculate_subtotal(items):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price
    return subtotal

def _calculate_discount(subtotal, discount_code):
    if discount_code == "SAVE10":
        return subtotal * 0.10
    if discount_code == "SAVE20" and subtotal >= 100.0:
        return subtotal * 0.20
    return 0.0

def _calculate_tax(taxable_amount, tax_rate):
    return round(taxable_amount * tax_rate, 2)

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = max(subtotal - discount, 0.0)
    tax = _calculate_tax(taxable_amount, tax_rate)
    total = round(taxable_amount + tax, 2)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
"""

    def assert_additional_helper_is_rejected(self, extra_helper: str) -> None:
        baseline = self.run_verifier(self.VALID_SOURCE)
        self.assertTrue(baseline["passed"], f"Baseline fixture should pass every verifier check: {baseline}")

        result = self.run_verifier(self.VALID_SOURCE + "\n\n" + extra_helper)
        checks = {check["name"]: check for check in result["checks"]}
        self.assertFalse(
            checks["meaningful-calculation-helpers"]["passed"],
            f"Expected exact helper cardinality to reject {extra_helper!r}: {checks['meaningful-calculation-helpers']}",
        )
        for name, check in checks.items():
            if name not in {"meaningful-calculation-helpers", "entry-point-orchestrates-steps"}:
                self.assertTrue(check["passed"], f"Unexpected unrelated verifier failure for {name}: {check}")

    def test_duplicate_subtotal_helper_fails(self):
        self.assert_additional_helper_is_rejected(
            "def _calculate_additional_subtotal(items):\n    return 0.0"
        )

    def test_duplicate_discount_helper_fails(self):
        self.assert_additional_helper_is_rejected(
            "def _calculate_additional_discount(subtotal, code):\n    return 0.0"
        )

    def test_duplicate_tax_helper_fails(self):
        self.assert_additional_helper_is_rejected(
            "def _calculate_additional_tax(amount, rate):\n    return 0.0"
        )

    def test_unrelated_private_helper_fails(self):
        self.assert_additional_helper_is_rejected(
            "def _format_invoice_note(value):\n    return str(value)"
        )
    
    def test_duplicate_definition_with_same_name_fails(self):
        self.assert_additional_helper_is_rejected(
            "def _calculate_tax(taxable_amount, tax_rate):\n    return round(taxable_amount * tax_rate, 2)"
        )


if __name__ == "__main__":
    unittest.main()