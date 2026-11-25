# schlafinance

A personal macOS app: a calendar of market events (US macro releases with actual values, central banks, Treasury, commodities, market structure, and company earnings). The full design and its decisions are in `docs/design-v0.md`.

## How it fits together

- **Fetcher** (`calendar/fetcher/`, Python): a GitHub Action (`.github/workflows/calendar-refresh.yml`) runs it daily. It pulls FRED (release dates and actuals) and the Alpha Vantage earnings calendar, computes the rule-based dates, merges `calendar/config/manual_events.yaml`, and commits `calendar/data/events.json`. The API keys live only in GitHub secrets (and `.env` locally).
- **App** (`app/`, SwiftUI): reads only `events.json` from the repo's raw GitHub URL, on launch and every 4 hours. It keeps the last good copy in `~/Library/Application Support/schlafinance/events.json` and loads that first, so a bad cached file breaks launch until it is replaced.
- Earnings past dates come from the previous `events.json`, since the feed lists only upcoming reports. See "Earnings scope" in the design doc.

## Build and run

- Fetcher tests: `.venv/bin/python -m pytest calendar/tests -q`
- App tests: `xcodebuild test -project app/schlafinance.xcodeproj -scheme schlafinance -destination 'platform=macOS'`
- The installed copy is `/Applications/schlafinance.app` (ad hoc signed). To update it, build the Release configuration and copy the `.app` there.
- Refresh data on demand: `gh workflow run calendar-refresh.yml`, then `git pull` to get the bot's commit.

## How the author works

- The author is not a developer and checks things by hand. Explain in plain language.
- Discuss a change before making it.
- Commit only after the author says "Works, commit".
- Record decisions and test results in `docs/design-v0.md`.
