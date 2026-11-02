"""Daily refresh: builds calendar/data/events.json from every source."""
import calendar
import json
import os
import sys
from datetime import date, datetime, timezone
from pathlib import Path

import yaml

import earnings
import fred
import rules
from transforms import months_before

ROOT = Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config"
OUTPUT = ROOT / "data" / "events.json"

MONTHS_BACK = 22
MONTHS_FORWARD = 4  # past the current month
CATEGORIES = {
    "Monetary", "Labor", "Inflation", "Growth", "Consumer", "Housing", "Treasury",
    "Fiscal", "Trade", "Commodities", "Earnings", "Market Structure", "Global",
}
PUBLIC_FIELDS = ("name", "short", "category", "star", "source_type", "time_et", "description")


class ConfigError(Exception):
    pass


def load_yaml(name):
    return yaml.safe_load((CONFIG / name).read_text())


def load_definitions():
    definitions = load_yaml("releases.yaml")["definitions"]
    for key, d in definitions.items():
        if d["category"] not in CATEGORIES:
            raise ConfigError(f"{key}: unknown category {d['category']!r}")
    return definitions


def load_manual_events(definitions):
    """Validates every entry; a bad one stops the run."""
    entries = load_yaml("manual_events.yaml")["events"]
    seen = set()
    for entry in entries:
        key = entry.get("definition")
        d = definitions.get(key)
        if d is None:
            raise ConfigError(f"manual event has unknown definition: {entry}")
        if d["source_type"] != "manual" and d.get("fred", {}).get("dates") != "manual":
            raise ConfigError(f"{key} does not take manual dates: {entry}")
        if not isinstance(entry.get("date"), date):
            raise ConfigError(f"manual event has a bad date: {entry}")
        if (key, entry["date"]) in seen:
            raise ConfigError(f"duplicate manual event: {entry}")
        seen.add((key, entry["date"]))
    return entries


def compute_window(today):
    start = months_before(today.replace(day=1), MONTHS_BACK)
    total = today.year * 12 + today.month - 1 + MONTHS_FORWARD
    year, month = total // 12, total % 12 + 1
    return start, date(year, month, calendar.monthrange(year, month)[1])


def holidays_from(entries):
    return [
        e["date"] for e in entries
        if e["definition"] == "market_holidays" and "early_close" not in e
    ]


def manual_occurrences(entries, definitions, window, today):
    occurrences = []
    for entry in entries:
        key, d = entry["definition"], entry["date"]
        if definitions[key]["source_type"] != "manual" or not window[0] <= d <= window[1]:
            continue
        out = {
            "id": f"{key}-{d.isoformat()}",
            "definition": key,
            "date": d.isoformat(),
            "status": "released" if d <= today else "scheduled",
        }
        for field in ("time", "note", "early_close"):
            if field in entry:
                out[field] = entry[field]
        occurrences.append(out)
    return occurrences


def rule_occurrences(events, today):
    occurrences = []
    for e in events:
        out = {
            "id": f"{e['definition']}-{e['date']}",
            "definition": e["definition"],
            "date": e["date"],
            "status": "released" if e["date"] <= today.isoformat() else "scheduled",
        }
        if e["approximate"]:
            out["approximate"] = True
        occurrences.append(out)
    return occurrences


def public_definition(definition):
    out = {field: definition[field] for field in PUBLIC_FIELDS if field in definition}
    if "actual_series" in definition:
        out["actual_series"] = [
            {field: spec[field] for field in ("key", "label", "unit")}
            for spec in definition["actual_series"]
        ]
    return out


def scrub(message, secrets):
    for secret in secrets:
        if secret:
            message = message.replace(secret, "[key]")
    return message


def load_previous():
    if OUTPUT.exists():
        return json.loads(OUTPUT.read_text()).get("occurrences", [])
    return []


def build(today, fred_key, alphavantage_key):
    definitions = load_definitions()
    manual = load_manual_events(definitions)
    watchlist = {s["symbol"]: s for s in load_yaml("watchlist.yaml")["symbols"]}
    window = compute_window(today)
    previous = load_previous()
    secrets = [fred_key, alphavantage_key]
    warnings = []

    def previous_for(key):
        return [o for o in previous if o["definition"] == key]

    client = fred.Client(fred_key)
    occurrences = []
    for key, definition in definitions.items():
        if definition["source_type"] != "fred":
            continue
        entries = [e for e in manual if e["definition"] == key]
        try:
            built, notes = fred.fetch_event(client, key, definition, entries, today, window)
            occurrences += built
            warnings += notes
        except (OSError, ValueError, KeyError) as e:
            occurrences += previous_for(key)
            warnings.append(scrub(f"{key}: kept previous data after FRED failed: {e}", secrets))

    try:
        csv_text = earnings.download(alphavantage_key)
        new = earnings.occurrences_from_csv(csv_text, watchlist, today)
        occurrences += earnings.merge_history(new, previous_for("earnings"), today)
    except (OSError, ValueError, KeyError) as e:
        occurrences += previous_for("earnings")
        warnings.append(scrub(f"earnings: kept previous data after Alpha Vantage failed: {e}", secrets))

    employment = sorted(
        {
            date.fromisoformat(o["date"])
            for o in occurrences
            if o["definition"] == "employment_situation" and o.get("role") != "catch_up"
        }
    )
    fomc = [e["date"] for e in manual if e["definition"] == "fomc_decision"]
    holidays = holidays_from(manual)
    if window[1].year > max(holidays).year:
        warnings.append(f"NYSE holidays end before the window does ({window[1].isoformat()})")
    occurrences += rule_occurrences(rules.generate(window[0], window[1], holidays, fomc, employment), today)
    occurrences += manual_occurrences(manual, definitions, window, today)

    present = {o["definition"] for o in occurrences}
    missing = sorted(set(definitions) - present)
    if missing:
        warnings.append("No occurrences: " + ", ".join(missing))

    occurrences.sort(key=lambda o: (o["date"], o["id"]))
    return {
        "schema_version": 1,
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "window": {"start": window[0].isoformat(), "end": window[1].isoformat()},
        "warnings": warnings,
        "definitions": {key: public_definition(d) for key, d in definitions.items()},
        "occurrences": occurrences,
    }


def main():
    fred_key = os.environ.get("FRED_API_KEY")
    alphavantage_key = os.environ.get("ALPHAVANTAGE_API_KEY")
    if not fred_key or not alphavantage_key:
        sys.exit("FRED_API_KEY and ALPHAVANTAGE_API_KEY must be set")

    data = build(datetime.now(timezone.utc).date(), fred_key, alphavantage_key)
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(data, indent=1) + "\n")
    print(f"Wrote {len(data['occurrences'])} occurrences, {len(data['warnings'])} warnings")
    for warning in data["warnings"]:
        print(f"  warning: {warning}")


if __name__ == "__main__":
    main()
