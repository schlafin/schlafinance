"""Alpha Vantage earnings calendar, filtered to the watchlist."""
import csv
import io
import urllib.parse
import urllib.request

URL = "https://www.alphavantage.co/query"
TIME_NOTES = {"pre-market": "Before market open", "post-market": "After market close"}


def download(api_key):
    params = {"function": "EARNINGS_CALENDAR", "horizon": "3month", "apikey": api_key}
    with urllib.request.urlopen(URL + "?" + urllib.parse.urlencode(params), timeout=60) as response:
        text = response.read().decode("utf-8", "replace")
    # Errors and rate-limit notices arrive as JSON with a 200 status.
    if text.lstrip().startswith("{"):
        raise ValueError("Alpha Vantage returned a message instead of CSV")
    return text


def occurrences_from_csv(text, watchlist, today):
    occurrences = []
    for row in csv.DictReader(io.StringIO(text)):
        symbol = row["symbol"]
        if symbol not in watchlist:
            continue
        reported = row["reportDate"]
        out = {
            "id": f"earn-{symbol}-{reported}",
            "definition": "earnings",
            "date": reported,
            "title": f"{row['name'].title()} earnings",
            "symbol": symbol,
            "status": "released" if reported <= today.isoformat() else "scheduled",
        }
        note = TIME_NOTES.get(row.get("timeOfTheDay", ""))
        if note:
            out["note"] = note
        if watchlist[symbol].get("star"):
            out["star"] = True
        occurrences.append(out)
    return occurrences


def merge_history(new, previous, today):
    """The calendar has only future dates, so past ones come from the last file."""
    past = [o for o in previous if o["date"] < today.isoformat()]
    return sorted(past + new, key=lambda o: o["id"])
