def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = 0.0
    for item in items:
        quantity = item["quantity"]
        unit_price = item["unit_price"]
        if quantity < 0:
            raise ValueError("quantity cannot be negative")
        if unit_price < 0:
            raise ValueError("unit_price cannot be negative")
        subtotal += quantity * unit_price

    discount = 0.0
    if discount_code is not None:
        if discount_code == "SAVE10":
            discount = subtotal * 0.10
        elif discount_code == "SAVE20" and subtotal >= 100.0:
            discount = subtotal * 0.20

    taxable_amount = subtotal - discount
    if taxable_amount < 0:
        taxable_amount = 0.0

    tax = round(taxable_amount * tax_rate, 2)
    total = round(taxable_amount + tax, 2)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
