import unittest

from invoice import create_invoice


class CreateInvoiceTests(unittest.TestCase):
    def test_calculates_subtotal_discount_tax_and_total(self):
        result = create_invoice(
            [
                {"quantity": 2, "unit_price": 10.0},
                {"quantity": 1, "unit_price": 5.0},
            ],
            discount_code="SAVE10",
            tax_rate=0.10,
        )
        self.assertEqual(
            {"subtotal": 25.0, "discount": 2.5, "tax": 2.25, "total": 24.75},
            result,
        )

    def test_save_twenty_requires_minimum_subtotal(self):
        result = create_invoice(
            [{"quantity": 1, "unit_price": 50.0}], discount_code="SAVE20"
        )
        self.assertEqual(0.0, result["discount"])

    def test_save_twenty_applies_at_threshold(self):
        result = create_invoice(
            [{"quantity": 2, "unit_price": 50.0}], discount_code="SAVE20"
        )
        self.assertEqual(20.0, result["discount"])

    def test_empty_invoice_is_zero(self):
        self.assertEqual(
            {"subtotal": 0.0, "discount": 0.0, "tax": 0.0, "total": 0.0},
            create_invoice([]),
        )

    def test_rejects_negative_quantity(self):
        with self.assertRaisesRegex(ValueError, "quantity"):
            create_invoice([{"quantity": -1, "unit_price": 2.0}])

    def test_rejects_negative_unit_price(self):
        with self.assertRaisesRegex(ValueError, "unit_price"):
            create_invoice([{"quantity": 1, "unit_price": -2.0}])


if __name__ == "__main__":
    unittest.main()
