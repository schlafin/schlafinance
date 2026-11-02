"""Rule dates against published calendars (macroption, NYSE, ISM listings, Nov 2026)."""
from datetime import date
from pathlib import Path

import pytest
import yaml

import rules

CONFIG = Path(__file__).resolve().parents[1] / "config" / "manual_events.yaml"


@pytest.fixture(scope="module")
def cal():
    return rules.Calendar(holidays())


def holidays():
    events = yaml.safe_load(CONFIG.read_text())["events"]
    return [
        e["date"]
        for e in events
        if e["definition"] == "market_holidays" and "early_close" not in e
    ]


def by_month(rule, cal, expected):
    return {key: rule(cal, *key) for key in expected}


OPTIONS = {
    (2026, 1): date(2026, 1, 16),
    (2026, 2): date(2026, 2, 20),
    (2026, 3): date(2026, 3, 20),
    (2026, 4): date(2026, 4, 17),
    (2026, 5): date(2026, 5, 15),
    (2026, 6): date(2026, 6, 18),
    (2026, 7): date(2026, 7, 17),
    (2026, 8): date(2026, 8, 21),
    (2026, 9): date(2026, 9, 18),
    (2026, 10): date(2026, 10, 16),
    (2026, 11): date(2026, 11, 20),
    (2026, 12): date(2026, 12, 18),
    (2027, 1): date(2027, 1, 15),
    (2027, 2): date(2027, 2, 19),
    (2027, 3): date(2027, 3, 19),
    (2027, 4): date(2027, 4, 16),
    (2027, 5): date(2027, 5, 21),
    (2027, 6): date(2027, 6, 17),
    (2027, 7): date(2027, 7, 16),
    (2027, 8): date(2027, 8, 20),
    (2027, 9): date(2027, 9, 17),
    (2027, 10): date(2027, 10, 15),
    (2027, 11): date(2027, 11, 19),
    (2027, 12): date(2027, 12, 17),
}

VIX = {
    (2026, 1): date(2026, 1, 21),
    (2026, 2): date(2026, 2, 18),
    (2026, 3): date(2026, 3, 18),
    (2026, 4): date(2026, 4, 15),
    (2026, 5): date(2026, 5, 19),
    (2026, 6): date(2026, 6, 17),
    (2026, 7): date(2026, 7, 22),
    (2026, 8): date(2026, 8, 19),
    (2026, 9): date(2026, 9, 16),
    (2026, 10): date(2026, 10, 21),
    (2026, 11): date(2026, 11, 18),
    (2026, 12): date(2026, 12, 16),
    (2027, 1): date(2027, 1, 20),
    (2027, 2): date(2027, 2, 17),
    (2027, 3): date(2027, 3, 17),
    (2027, 4): date(2027, 4, 21),
    (2027, 5): date(2027, 5, 18),
    (2027, 6): date(2027, 6, 16),
    (2027, 7): date(2027, 7, 21),
    (2027, 8): date(2027, 8, 18),
    (2027, 9): date(2027, 9, 15),
    (2027, 10): date(2027, 10, 20),
    (2027, 11): date(2027, 11, 17),
}

ISM_MANUFACTURING = {
    (2026, 1): date(2026, 1, 5),
    (2026, 11): date(2026, 11, 2),
    (2027, 5): date(2027, 5, 3),
    (2027, 10): date(2027, 10, 1),
    (2027, 11): date(2027, 11, 1),
    (2027, 12): date(2027, 12, 1),
}

ISM_SERVICES = {
    (2026, 1): date(2026, 1, 7),
    (2026, 11): date(2026, 11, 4),
    (2026, 12): date(2026, 12, 3),
    (2027, 1): date(2027, 1, 6),
    (2027, 2): date(2027, 2, 3),
}


@pytest.mark.parametrize(
    "rule, expected",
    [
        (rules.options_expiration, OPTIONS),
        (rules.vix_expiration, VIX),
        (rules.ism_manufacturing, ISM_MANUFACTURING),
        (rules.ism_services, ISM_SERVICES),
    ],
    ids=["options", "vix", "ism_manufacturing", "ism_services"],
)
def test_published_dates(cal, rule, expected):
    assert by_month(rule, cal, expected) == expected


def test_quad_witching_moves_with_the_june_2026_holiday():
    events = rules.generate(date(2026, 6, 1), date(2026, 6, 30), holidays())
    quad = [e for e in events if e["definition"] == "quad_witching"]
    assert quad == [
        {"definition": "quad_witching", "date": "2026-06-18", "approximate": True}
    ]


def test_only_holiday_moves_are_approximate():
    events = rules.generate(date(2026, 11, 1), date(2026, 12, 31), holidays())
    flagged = {e["definition"]: e["approximate"] for e in events if e["date"] == "2026-11-02"}
    assert flagged["ism_manufacturing"] is False  # Nov 1 is a Sunday, not a holiday
    moved = [e for e in events if e["definition"] == "cftc_cot" and e["date"] == "2026-12-28"]
    assert moved[0]["approximate"] is True  # Christmas Friday moves to Monday


def test_month_end_skips_holiday_and_weekend(cal):
    assert rules.month_end(cal, 2026, 5) == date(2026, 5, 29)
    assert rules.month_end(cal, 2026, 11) == date(2026, 11, 30)


def test_weekly_report_moves_a_day_later_on_a_holiday():
    events = rules.generate(date(2026, 12, 21), date(2026, 12, 31), holidays())
    cot = [e["date"] for e in events if e["definition"] == "cftc_cot"]
    # Christmas Friday goes to Monday; Jan 1 is outside the range.
    assert cot == ["2026-12-28"]


def test_pboc_ignores_nyse_holidays():
    assert rules.pboc_lpr(2025, 1) == date(2025, 1, 20)  # MLK Day
    assert rules.pboc_lpr(2026, 9) == date(2026, 9, 21)  # the 20th is a Sunday


def test_dependent_rules():
    events = rules.generate(
        date(2026, 7, 1),
        date(2026, 7, 31),
        holidays(),
        fomc_dates=[date(2026, 6, 17)],
        employment_dates=[date(2026, 7, 2)],
    )
    dates = {e["definition"]: e["date"] for e in events}
    assert dates["fomc_minutes"] == "2026-07-08"
    assert dates["adp"] == "2026-07-01"


def test_every_rule_definition_is_generated():
    events = rules.generate(
        date(2025, 1, 1),
        date(2027, 3, 31),
        holidays(),
        fomc_dates=[date(2026, 6, 17)],
        employment_dates=[date(2026, 7, 2)],
    )
    assert len({e["definition"] for e in events}) == 15
    closed = {d.isoformat() for d in holidays()}
    exempt = {"pboc_lpr", "fomc_minutes", "adp"}
    assert not [e for e in events if e["date"] in closed and e["definition"] not in exempt]
