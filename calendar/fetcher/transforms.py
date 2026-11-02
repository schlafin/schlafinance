"""Turns raw FRED observations into the values shown as actuals.

A transform that needs a prior period returns None when that period is
missing, so nothing is ever computed across a data gap.
"""
from datetime import date

LOOKBACK_MONTHS = {"diff": 1, "mom_pct": 1, "qoq_pct": 3, "yoy_pct": 12}


def months_before(d, n):
    total = d.year * 12 + d.month - 1 - n
    return date(total // 12, total % 12 + 1, d.day)


def compute(spec, values, d):
    """The actual for observation date d. values maps date to float."""
    current = values.get(d)
    if current is None:
        return None

    transform = spec.get("transform", "level")
    if transform == "level":
        result = current
    else:
        prior = values.get(months_before(d, LOOKBACK_MONTHS[transform]))
        if prior is None:
            return None
        result = current - prior if transform == "diff" else (current / prior - 1) * 100

    # Adding 0.0 turns a rounded -0.0 into 0.0.
    return round(result / spec.get("scale", 1), spec.get("decimals", 1)) + 0.0


def period_label(d, frequency):
    if frequency == "W":
        return d.isoformat()
    if frequency == "Q":
        return f"{d.year}-Q{(d.month - 1) // 3 + 1}"
    return f"{d.year}-{d.month:02d}"
