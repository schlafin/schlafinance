"""Alpha Vantage earnings calendar: every report, with S&P 500 members starred."""
import csv
import io
import urllib.parse
import urllib.request
from datetime import timedelta

URL = "https://www.alphavantage.co/query"
# Typical release times in ET. The feed says only before or after the bell.
TYPICAL_TIMES = {
    "pre-market": ("07:00", "Before market open (typical time)"),
    "post-market": ("16:05", "After market close (typical time)"),
}
PAST_UNSTARRED = timedelta(days=90)  # keeps events.json small


def download(api_key):
    params = {"function": "EARNINGS_CALENDAR", "horizon": "3month", "apikey": api_key}
    with urllib.request.urlopen(URL + "?" + urllib.parse.urlencode(params), timeout=60) as response:
        text = response.read().decode("utf-8", "replace")
    # Errors and rate-limit notices arrive as JSON with a 200 status.
    if text.lstrip().startswith("{"):
        raise ValueError("Alpha Vantage returned a message instead of CSV")
    return text


def normalize(symbol):
    """Sources write Berkshire as BRK.B or BRK-B."""
    return symbol.replace(".", "-")


def occurrences_from_csv(text, sp500, today):
    members = {normalize(s) for s in sp500}
    occurrences = []
    for row in csv.DictReader(io.StringIO(text)):
        symbol = row["symbol"]
        reported = row["reportDate"]
        out = {
            "id": f"earn-{symbol}-{reported}",
            "definition": "earnings",
            "date": reported,
            "title": f"{row['name'].title()} earnings",
            "symbol": symbol,
            "status": "released" if reported <= today.isoformat() else "scheduled",
        }
        typical = TYPICAL_TIMES.get(row.get("timeOfTheDay", ""))
        if typical:
            out["time"], out["note"] = typical
        if normalize(symbol) in members:
            out["star"] = True
        occurrences.append(out)
    return occurrences


def merge_history(new, previous, today):
    """The calendar has only future dates, so past ones come from the last file."""
    oldest_unstarred = (today - PAST_UNSTARRED).isoformat()
    past = [
        o for o in previous
        if o["date"] < today.isoformat() and (o.get("star") or o["date"] >= oldest_unstarred)
    ]
    return sorted(past + new, key=lambda o: o["id"])
