"""FRED client, and the logic that turns its data into calendar occurrences."""
import json
import time
import urllib.parse
import urllib.request
from collections import defaultdict
from datetime import date, timedelta

from transforms import compute, months_before, period_label

BASE_URL = "https://api.stlouisfed.org/fred/"
REQUEST_GAP_SECONDS = 0.6  # FRED allows 120 calls a minute
RETRIES = 3
FAR_FUTURE = "9999-12-31"
HISTORY_MONTHS = 18
WARN_WINDOW = timedelta(days=14)  # warnings turn the app's status line red


class Client:
    def __init__(self, api_key):
        self.api_key = api_key

    def get(self, path, **params):
        params.update(api_key=self.api_key, file_type="json")
        url = BASE_URL + path + "?" + urllib.parse.urlencode(params)
        for attempt in range(RETRIES):
            time.sleep(REQUEST_GAP_SECONDS)
            try:
                with urllib.request.urlopen(url, timeout=30) as response:
                    return json.load(response)
            except OSError:
                if attempt == RETRIES - 1:
                    raise
                time.sleep(5)

    def release_dates(self, release_id, start, end):
        data = self.get(
            "release/dates",
            release_id=release_id,
            include_release_dates_with_no_data="true",
            realtime_start=start.isoformat(),
            realtime_end=end.isoformat(),
            sort_order="asc",
            limit=1000,
        )
        return sorted(date.fromisoformat(r["date"]) for r in data["release_dates"])

    def observations(self, series, start):
        """Latest revised values, as {observation date: value}. Gaps are left out."""
        data = self.get(
            "series/observations",
            series_id=series,
            observation_start=start.isoformat(),
        )
        return {
            date.fromisoformat(o["date"]): float(o["value"])
            for o in data["observations"]
            if o["value"] != "."
        }

    def first_published(self, series, start):
        """(observation date, date FRED first published it), gaps included."""
        data = self.get(
            "series/observations",
            series_id=series,
            output_type=4,  # initial release only
            observation_start=start.isoformat(),
            realtime_start=start.isoformat(),
            realtime_end=FAR_FUTURE,
            sort_order="asc",
        )
        return [
            (date.fromisoformat(o["date"]), date.fromisoformat(o["realtime_start"]))
            for o in data["observations"]
        ]


def history_start(window_start):
    """Far enough back for the first YoY in the window, even on a lagged series."""
    return months_before(window_start.replace(day=1), HISTORY_MONTHS)


def pick_in_month(dates, which):
    months = defaultdict(list)
    for d in dates:
        months[(d.year, d.month)].append(d)
    index = 0 if which == "first" else -1
    return sorted(sorted(ds)[index] for ds in months.values())


def occurrence(key, d, period=None, status="released", actuals=None, role=None):
    out = {"id": f"{key}-{d.isoformat()}", "definition": key, "date": d.isoformat()}
    if role == "catch_up":
        out["id"] += f"-{period}"
    if period:
        out["period"] = period
    out["status"] = status
    if actuals:
        out["actuals"] = actuals
    if role:
        out["role"] = role
    return out


def actuals_for(definition, values, d):
    return {
        spec["key"]: compute(spec, values[spec["series"]], d)
        for spec in definition["actual_series"]
    }


def build_occurrences(key, definition, release_dates, first_published, values, today, window):
    """Occurrences for one event, plus warnings.

    A released occurrence is the date FRED first published a period, so it needs
    no rule for which period a release covers. Two extra cases get a `role`:
    - catch_up: an older period first published with a newer one, as after a
      shutdown. Listed in the drill-down, hidden on the calendar.
    - revision: a later estimate of a period, as with GDP. Shown on the
      calendar, left out of the drill-down.
    """
    fred = definition["fred"]
    frequency = fred.get("frequency", "M")
    start, end = window
    occurrences = []
    warnings = []

    by_publication = defaultdict(list)
    for observed, published in first_published:
        by_publication[published].append(observed)

    for published, periods in sorted(by_publication.items()):
        if not start <= published <= min(today, end):
            continue
        *older, newest = sorted(periods)
        for observed in older:
            label = period_label(observed, frequency)
            occurrences.append(
                occurrence(key, published, label, actuals=actuals_for(definition, values, observed), role="catch_up")
            )
        occurrences.append(
            occurrence(
                key,
                published,
                period_label(newest, frequency),
                actuals=actuals_for(definition, values, newest),
            )
        )

    published_months = {(p.year, p.month) for p in by_publication}
    dates = release_dates
    if "pick_in_month" in fred:
        dates = pick_in_month(dates, fred["pick_in_month"])

    for d in dates:
        if d in by_publication or not start <= d <= end:
            continue
        if d >= today:
            occurrences.append(occurrence(key, d, status="scheduled"))
        elif fred.get("revisions"):
            published_before = [o for o, p in first_published if p < d]
            if published_before:
                latest = max(published_before)
                occurrences.append(
                    occurrence(
                        key,
                        d,
                        period_label(latest, frequency),
                        actuals=actuals_for(definition, values, latest),
                        role="revision",
                    )
                )
        elif "pick_in_month" not in fred and (d.year, d.month) not in published_months:
            # Dates in a month that already had new data are annual revisions.
            occurrences.append(occurrence(key, d))
            if today - d <= WARN_WINDOW:
                warnings.append(f"{key}: no new data on the {d.isoformat()} release")

    occurrences.sort(key=lambda o: o["id"])
    return occurrences, warnings


def build_manual_dated(key, definition, entries, values, today):
    """Occurrences for a FRED-valued event whose dates are hand-entered."""
    occurrences = []
    for entry in entries:
        d = entry["date"]
        if d > today:
            occurrences.append(occurrence(key, d, entry["period"], status="scheduled"))
            continue
        observed = date.fromisoformat(entry["period"] + "-01")
        actuals = actuals_for(definition, values, observed)
        occurrences.append(occurrence(key, d, entry["period"], actuals=actuals))
    return occurrences


def fetch_event(client, key, definition, manual_entries, today, window):
    fred = definition["fred"]
    history = history_start(window[0])
    series = {spec["series"] for spec in definition["actual_series"]}
    values = {s: client.observations(s, history) for s in sorted(series)}

    if fred.get("dates") == "manual":
        return build_manual_dated(key, definition, manual_entries, values, today), []

    primary = definition["actual_series"][0]["series"]
    release_dates = client.release_dates(fred["release_id"], window[0], date(window[1].year + 1, 12, 31))
    first_published = client.first_published(primary, months_before(window[0].replace(day=1), 6))
    return build_occurrences(key, definition, release_dates, first_published, values, today, window)
