"""Rule engine: computes the `rule` events in the catalog (see docs/design-v0.md).

"Business day" means an NYSE trading day. A date moved off its usual day by a
holiday is marked approximate.
"""
from datetime import date, timedelta

DAY = timedelta(days=1)
MON, TUE, WED, THU, FRI = range(5)


class Calendar:
    def __init__(self, holidays):
        self.holidays = set(holidays)

    def is_business_day(self, d):
        return d.weekday() < 5 and d not in self.holidays

    def on_or_before(self, d):
        while not self.is_business_day(d):
            d -= DAY
        return d

    def on_or_after(self, d):
        while not self.is_business_day(d):
            d += DAY
        return d

    def nth_business_day(self, first, n):
        """The nth business day counting from `first`, which is day 1."""
        d = self.on_or_after(first)
        for _ in range(n - 1):
            d = self.on_or_after(d + DAY)
        return d


def next_month(year, month):
    return (year + 1, 1) if month == 12 else (year, month + 1)


def months(start, end):
    y, m = start.year, start.month
    while (y, m) <= (end.year, end.month):
        yield y, m
        y, m = next_month(y, m)


def last_day(year, month):
    y, m = next_month(year, month)
    return date(y, m, 1) - DAY


def third_friday(year, month):
    first = date(year, month, 1)
    return first + timedelta(days=(FRI - first.weekday()) % 7 + 14)


def last_weekday(year, month, weekday):
    d = last_day(year, month)
    return d - timedelta(days=(d.weekday() - weekday) % 7)


def options_expiration(cal, year, month):
    return cal.on_or_before(third_friday(year, month))


def vix_expiration(cal, year, month):
    # 30 days before the next month's S&P expiration, which itself moves off a
    # holiday Friday. That is why May 2026 expires on Tuesday the 19th.
    y, m = next_month(year, month)
    return cal.on_or_before(options_expiration(cal, y, m) - timedelta(days=30))


def ism_first_day(cal, year, month):
    # ISM skips January 2: it published Jan 5, 2026, although Jan 2 was a trading day.
    start = date(year, 1, 3) if month == 1 else date(year, month, 1)
    return cal.on_or_after(start)


def ism_manufacturing(cal, year, month):
    return ism_first_day(cal, year, month)


def ism_services(cal, year, month):
    return cal.nth_business_day(ism_first_day(cal, year, month), 3)


def month_end(cal, year, month):
    return cal.on_or_before(last_day(year, month))


def conference_board(cal, year, month):
    return cal.on_or_after(last_weekday(year, month, TUE))


def pboc_lpr(year, month):
    # China's calendar, so only weekends apply here, not NYSE holidays.
    d = date(year, month, 20)
    while d.weekday() >= 5:
        d += DAY
    return d


def weekly(start, end, weekday):
    d = start + timedelta(days=(weekday - start.weekday()) % 7)
    while d <= end:
        yield d
        d += timedelta(days=7)


def adp_date(employment_date):
    """The Wednesday before an Employment Situation release."""
    return employment_date - timedelta(days=(employment_date.weekday() - WED - 1) % 7 + 1)


MONTHLY_RULES = {
    "ism_manufacturing": ism_manufacturing,
    "ism_services": ism_services,
    "chicago_pmi": month_end,
    "conference_board": conference_board,
    "options_expiration": options_expiration,
    "vix_expiration": vix_expiration,
    "month_end": month_end,
}
QUAD_WITCHING_MONTHS = (3, 6, 9, 12)
# definition: (weekday, moves later on a holiday)
WEEKLY_RULES = {
    "eia_crude": (WED, True),
    "eia_natural_gas": (THU, True),
    "baker_hughes": (FRI, False),
    "cftc_cot": (FRI, True),
}


def event(definition, d, approximate=False):
    return {"definition": definition, "date": d.isoformat(), "approximate": approximate}


def generate(start, end, holidays, fomc_dates=(), employment_dates=()):
    """All rule events from start to end, inclusive, sorted by date.

    fomc_dates are FOMC decision dates; employment_dates are Employment
    Situation release dates, which come from FRED.
    """
    cal = Calendar(holidays)
    no_holidays = Calendar(())
    events = []

    for y, m in months(start, end):
        for name, rule in MONTHLY_RULES.items():
            d = rule(cal, y, m)
            events.append(event(name, d, d != rule(no_holidays, y, m)))
        if m in QUAD_WITCHING_MONTHS:
            d = options_expiration(cal, y, m)
            events.append(event("quad_witching", d, d != third_friday(y, m)))
        events.append(event("pboc_lpr", pboc_lpr(y, m)))

    for name, (weekday, later) in WEEKLY_RULES.items():
        for d in weekly(start, end, weekday):
            moved = cal.on_or_after(d) if later else cal.on_or_before(d)
            events.append(event(name, moved, moved != d))

    for d in fomc_dates:
        events.append(event("fomc_minutes", d + timedelta(days=21)))
    for d in employment_dates:
        events.append(event("adp", adp_date(d)))

    in_range = [e for e in events if start.isoformat() <= e["date"] <= end.isoformat()]
    return sorted(in_range, key=lambda e: (e["date"], e["definition"]))
