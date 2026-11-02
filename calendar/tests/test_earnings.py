from datetime import date
from pathlib import Path

import yaml

import earnings

CONFIG = Path(__file__).resolve().parents[1] / "config" / "sp500.yaml"
TODAY = date(2026, 11, 2)
CSV = """symbol,name,reportDate,fiscalDateEnding,estimate,currency,timeOfTheDay
AAPL,APPLE INCORPORATED,2026-11-02,2026-09-30,1.5,USD,post-market
WMT,WALMART INC,2026-11-19,2026-10-31,0.7,USD,pre-market
XYZQ,SMALL COMPANY INC,2026-11-05,2026-09-30,,USD,
BRK-B,BERKSHIRE HATHAWAY,2026-11-07,2026-09-30,,USD,
"""


def build():
    rows = earnings.occurrences_from_csv(CSV, ["AAPL", "WMT", "BRK.B"], TODAY)
    return {o["symbol"]: o for o in rows}


def test_sp500_file_holds_only_symbols():
    symbols = yaml.safe_load(CONFIG.read_text())["symbols"]
    assert all(isinstance(s, str) for s in symbols)
    assert {"ON", "AAPL", "BRK.B"} <= set(symbols)
    assert len(symbols) > 490


def test_every_report_is_kept():
    assert set(build()) == {"AAPL", "WMT", "XYZQ", "BRK-B"}


def test_only_sp500_members_are_starred():
    rows = build()
    assert rows["AAPL"]["star"] is True
    assert "star" not in rows["XYZQ"]


def test_share_class_symbols_match_across_sources():
    assert build()["BRK-B"]["star"] is True


def test_bell_timing_becomes_a_typical_time():
    rows = build()
    assert rows["AAPL"]["time"] == "16:05"
    assert rows["WMT"]["time"] == "07:00"


def test_unknown_timing_stays_without_a_time():
    assert "time" not in build()["XYZQ"]


def test_merge_keeps_starred_history_and_trims_old_unstarred():
    previous = [
        {"id": "a", "date": "2026-01-05", "star": True},
        {"id": "b", "date": "2026-01-05"},
        {"id": "c", "date": "2026-10-20"},
        {"id": "d", "date": "2026-11-20"},
    ]
    merged = earnings.merge_history([{"id": "e", "date": "2026-11-21"}], previous, TODAY)
    assert [o["id"] for o in merged] == ["a", "c", "e"]
