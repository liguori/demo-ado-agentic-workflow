"""Calcolo degli sconti."""


def apply_discount(total_cents, percent):
    return int(total_cents * (100 - percent) / 100)


def apply_loyalty_discount(total_cents, years_as_customer):
    percent = min(years_as_customer * 2, 20)
    return apply_discount(total_cents, percent)
