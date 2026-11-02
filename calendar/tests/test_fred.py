"""Occurrence building, using FRED's real dates for each awkward case."""
from datetime import date

import fred
import transforms

TODAY = date(2026, 11, 2)
WINDOW = (date(2025, 1, 1), date(2027, 3, 31))
M = date


def definition(series="X", **fred_fields):
    return {
        "fred": {"release_id": 1, **fred_fields},
        "actual_series": [{"key": "value", "series": series}],
    }


def build(release_dates, first_published, values, **fred_fields):
    return fred.build_occurrences(
        "e", definition(**fred_fields), release_dates, first_published, {"X": values}, TODAY, WINDOW
    )


def test_same_month_survey_gets_its_own_month():
    # Empire State publishes October data on Oct 15.
    out, _ = build([M(2026, 10, 15)], [(M(2026, 10, 1), M(2026, 10, 15))], {M(2026, 10, 1): 25.5})
    assert out[0]["period"] == "2026-10"
    assert out[0]["actuals"] == {"value": 25.5}


def test_shutdown_catch_up_keeps_both_periods_and_the_gap():
    # CPI: October 2025 was never collected and arrived blank with November.
    first = [(M(2025, 10, 1), M(2025, 12, 18)), (M(2025, 11, 1), M(2025, 12, 18))]
    out, _ = build([M(2025, 12, 18)], first, {M(2025, 11, 1): 325.0})
    newest, catch_up = sorted(out, key=lambda o: "role" in o)
    assert catch_up["role"] == "catch_up"
    assert catch_up["period"] == "2025-10"
    assert catch_up["actuals"] == {"value": None}
    assert newest["period"] == "2025-11"
    assert "role" not in newest
    assert catch_up["id"] != newest["id"]


def test_gdp_later_estimates_are_revisions():
    first = [(M(2026, 4, 1), M(2026, 7, 30))]
    dates = [M(2026, 7, 30), M(2026, 8, 26), M(2026, 9, 30), M(2026, 11, 25)]
    out, warnings = build(dates, first, {M(2026, 4, 1): 2.2}, frequency="Q", revisions=True)
    assert [(o["date"], o.get("role"), o.get("period"), o["status"]) for o in out] == [
        ("2026-07-30", None, "2026-Q2", "released"),
        ("2026-08-26", "revision", "2026-Q2", "released"),
        ("2026-09-30", "revision", "2026-Q2", "released"),
        ("2026-11-25", None, None, "scheduled"),
    ]
    assert warnings == []


def test_durable_goods_drops_the_full_m3_report():
    dates = [M(2026, 10, 2), M(2026, 10, 27), M(2026, 11, 3), M(2026, 11, 25)]
    first = [(M(2026, 9, 1), M(2026, 10, 27))]
    out, warnings = build(dates, first, {M(2026, 9, 1): 345.0}, pick_in_month="last")
    assert [o["date"] for o in out] == ["2026-10-27", "2026-11-25"]
    assert warnings == []


def test_release_with_no_new_data_stays_on_the_calendar_and_warns():
    # UMich, Oct 23, 2026.
    out, warnings = build([M(2026, 10, 23)], [], {})
    assert out[0]["date"] == "2026-10-23"
    assert "actuals" not in out[0]
    assert warnings == ["e: no new data on the 2026-10-23 release"]


def test_old_gap_stays_on_the_calendar_without_a_warning():
    out, warnings = build([M(2026, 3, 10)], [], {})
    assert out[0]["date"] == "2026-03-10"
    assert warnings == []


def test_annual_revision_date_is_dropped():
    # Philly Fed, January 2026: a second date in a month with new data.
    first = [(M(2026, 1, 1), M(2026, 1, 15))]
    out, warnings = build([M(2026, 1, 8), M(2026, 1, 15)], first, {M(2026, 1, 1): 1.0})
    assert [o["date"] for o in out] == ["2026-01-15"]
    assert warnings == []


def test_release_today_is_scheduled_until_data_arrives():
    out, warnings = build([TODAY], [], {})
    assert out[0]["status"] == "scheduled"
    assert warnings == []


def test_manual_dates_use_the_entered_period():
    entries = [
        {"date": M(2026, 10, 13), "period": "2026-09"},
        {"date": M(2026, 11, 12), "period": "2026-10"},
    ]
    values = {"X": {M(2026, 9, 1): 4.1}}
    out = fred.build_manual_dated("e", definition(), entries, values, TODAY)
    assert out[0]["actuals"] == {"value": 4.1}
    assert out[1]["status"] == "scheduled"


def test_transforms_match_bls_cpi():
    # CPIAUCNS, September 2026: BLS published 3.7%.
    spec = {"transform": "yoy_pct"}
    values = {M(2026, 9, 1): 336.94, M(2025, 9, 1): 324.8}
    assert transforms.compute(spec, values, M(2026, 9, 1)) == 3.7


def test_transforms_do_not_cross_a_gap():
    values = {M(2025, 9, 1): 324.0, M(2025, 11, 1): 325.0}
    assert transforms.compute({"transform": "mom_pct"}, values, M(2025, 11, 1)) is None


def test_scale_and_decimals():
    spec = {"scale": 1000, "decimals": 0}
    assert transforms.compute(spec, {M(2026, 10, 24): 194000.0}, M(2026, 10, 24)) == 194


def test_period_labels():
    assert transforms.period_label(M(2026, 7, 1), "Q") == "2026-Q3"
    assert transforms.period_label(M(2026, 7, 1), "M") == "2026-07"
    assert transforms.period_label(M(2026, 10, 24), "W") == "2026-10-24"
