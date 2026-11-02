# schlafinance V0 — Market Events Calendar Design Doc

Nov 2, 2026 · @Michael Schlafly

## Overview

schlafinance V0 is a personal macOS app with one feature: a calendar of recurring market events, with actual values for past US macro releases. It is the first feature of a larger app, so the repo and code are structured to take more features later.

**V0 scope**

- Three calendar views: monthly, weekly, daily.
- A multi-select category filter (13 categories) and a star toggle that shows only high-impact events.
- The calendar is backward-looking: past US macro releases show their actual value.
- An event drill-down view: for a US macro release, a trailing list of prior actuals. For all other events, the event's details only.
- Dark mode only, using the macOS system palette.
- Data refreshed once a day by a GitHub Action. The Mac does not need to be on.

**Explicitly not in V0**

- Actuals for corporate earnings. Earnings appear as dates only. Reported results will come later from EDGAR filings.
- Actuals for global, commodity, market-structure, or central-bank events. These appear as dates only.
- Consensus forecasts ("expected vs. actual"). No free source exists.
- News feeds, notifications, live prices.
- Any credential that expires: no OAuth, no browser sessions, no web scraping.

**V1 preview**: the event drill-down adds the next scheduled release date and a news feed filtered to that event.

**Hard rule for every data source**: a static API key or no key at all. Any source that needs a token refresh, a login, or a bot check is rejected. The project this replaces broke for exactly that reason.

## Architecture

A daily GitHub Action fetches and computes every event, writes one JSON file, and commits it to the repo. The macOS app only reads that file. It holds no API keys and makes no calls to data providers.

&#91;embedded content: schlafinance V0 data flow · 3 sources, 1 Action, 1 file, 1 app\]

Keys live only in the Action; the app holds no credentials and calls no provider.

**Fetcher (GitHub Action, Python)**

1. Runs once a day on a cron schedule, around 23:00 UTC, after US releases for the day are out. GitHub can delay scheduled runs, so nothing depends on exact timing.
2. Pulls FRED release dates and actuals, and the Alpha Vantage earnings calendar.
3. Generates rule-based events (options expiration, ISM dates, weekly reports) locally.
4. Merges in the hand-maintained events from `calendar/config/manual_events.yaml`.
5. Writes `calendar/data/events.json` with a `generated_at` timestamp and commits it.
6. Also runnable on demand (`workflow_dispatch`) for testing.

**Viewer (macOS app, SwiftUI)**

- On launch and every few hours, downloads `events.json` from the repo's raw URL.
- Caches the last good copy locally, so the app works offline and survives a failed fetch.
- Shows a staleness warning if `generated_at` is more than 36 hours old.

**Secrets**: `FRED_API_KEY` and `ALPHAVANTAGE_API_KEY`, stored as GitHub Actions secrets. Both are static keys that do not expire.

**Repo**: `schlafinance`, public. A public repo lets the app read the data file without any GitHub token. The data is public economic data, and secrets are not exposed by a public repo.

**Known risk, the 60-day rule**: GitHub disables scheduled workflows in a public repo after 60 days with no repository activity. The daily data commit should count as activity and keep the schedule alive. Verify this, for example against an existing repo whose scheduled Action has run untouched for over 60 days. If it does not hold, add a monthly keep-alive step.

**Repo layout** (each future feature gets a sibling folder and its own workflow):

```
schlafinance/
  .github/workflows/
    calendar-refresh.yml
  calendar/
    fetcher/          # Python: FRED, Alpha Vantage, rule engine, merge
    config/
      releases.yaml       # event catalog: FRED release IDs, series, transforms, stars
      manual_events.yaml  # FOMC, ECB, BoJ, BoE, refunding, holidays
      watchlist.yaml      # symbols kept from the earnings calendar
    data/
      events.json         # written by the Action, read by the app
    tests/
  app/                # Xcode project (SwiftUI)
  docs/
    design-v0.md
```

## Event model

Every event has one category, a star flag, and one of four source types. The source type decides how its date is produced and whether it can have actuals.

**Categories (13, the filter values)**: Monetary, Labor, Inflation, Growth, Consumer, Housing, Treasury, Fiscal, Trade, Commodities, Earnings, Market Structure, Global.

**Star** marks the high-impact events. The star toggle shows only those. Stars live in `releases.yaml` and `manual_events.yaml`, so they can be changed without code.

**Source types**

| Source type | How dates are produced | Actuals in V0 | Examples |
| --- | --- | --- | --- |
| `fred` | FRED release calendar API | Yes, from FRED series | CPI, jobs report, GDP, retail sales |
| `rule` | Computed by the fetcher from a calendar rule | No | Options expiration, ISM, EIA reports |
| `earnings` | Alpha Vantage earnings calendar | No | Company earnings dates |
| `manual` | Hand-entered in `manual_events.yaml`, updated once a year | No | FOMC, ECB, BoJ, BoE, Treasury refunding, market holidays |

**`events.json` schema** (one file; the app needs nothing else):

```json
{
  "schema_version": 1,
  "generated_at": "2026-11-02T23:05:00Z",
  "window": { "start": "2025-01-01", "end": "2027-03-31" },
  "definitions": {
    "cpi": {
      "name": "Consumer Price Index",
      "category": "Inflation",
      "star": true,
      "source_type": "fred",
      "time_et": "08:30",
      "description": "Headline and core consumer inflation, BLS.",
      "actual_series": [
        { "key": "headline_yoy", "label": "CPI YoY", "unit": "%" },
        { "key": "core_yoy", "label": "Core CPI YoY", "unit": "%" }
      ]
    }
  },
  "occurrences": [
    {
      "id": "cpi-2026-10-15",
      "definition": "cpi",
      "date": "2026-10-15",
      "period": "2026-09",
      "status": "released",
      "actuals": { "headline_yoy": 3.0, "core_yoy": 3.1 }
    },
    {
      "id": "earn-NVDA-2026-11-19",
      "definition": "earnings",
      "date": "2026-11-19",
      "title": "NVIDIA earnings",
      "symbol": "NVDA",
      "status": "scheduled"
    }
  ]
}
```

The values above are placeholders showing the shape, not real data.

- `definitions` holds what never changes per occurrence (name, category, star, time, which actuals exist).
- `occurrences` holds one entry per dated event. `status` is `scheduled` or `released`.
- `period` is the period the data covers (September CPI is released in October). The drill-down list labels rows by period, not release date.
- The trailing actuals list in the drill-down is built from past occurrences of the same definition.
- `window`: about 22 months back for history and 5 months forward. Tune after seeing the file size.

## Event catalog

V0 ships 53 event definitions: 23 with FRED actuals, the rest date-only. This table becomes `releases.yaml` and `manual_events.yaml`. FRED series IDs below are the expected ones; the design session confirms each one and looks up the FRED release ID by name (see Tests). Times are US Eastern.

| Event | Category | Star | Source | Date rule or FRED release | Actuals shown (FRED series) |
| --- | --- | --- | --- | --- | --- |
| FOMC rate decision | Monetary | ★ | manual | Fed's published schedule, 14:00 | none in V0 |
| Summary of Economic Projections | Monetary | ★ | manual | Mar, Jun, Sep, Dec FOMC days | none |
| FOMC minutes | Monetary |  | rule | FOMC decision date + 21 days, 14:00 | none |
| Beige Book | Monetary |  | manual | Fed's published schedule, 14:00 | none |
| Fed balance sheet (H.4.1) | Monetary |  | fred | weekly, Thursday 16:30 | total assets, $bn (WALCL) |
| Fed Chair testimony | Monetary |  | manual | entered when announced | none |
| Jackson Hole symposium | Monetary |  | manual | late August | none |
| Bank stress test results | Monetary |  | manual | entered when announced | none |
| Employment Situation | Labor | ★ | fred | Employment Situation, 08:30 | payrolls change, k (PAYEMS diff); unemployment rate, % (UNRATE); avg hourly earnings YoY, % (CES0500000003) |
| Initial jobless claims | Labor | ★ | fred | Unemployment Insurance Weekly Claims, Thursday 08:30 | initial claims, k (ICSA) |
| JOLTS | Labor |  | fred | Job Openings and Labor Turnover Survey, 10:00 | job openings, k (JTSJOL) |
| ADP employment | Labor |  | rule | Wednesday before Employment Situation, 08:15 | none |
| Employment Cost Index | Labor |  | fred | Employment Cost Index, quarterly, 08:30 | QoQ, % (ECIALLCIV) |
| CPI | Inflation | ★ | fred | Consumer Price Index, 08:30 | headline YoY, % (CPIAUCNS) and MoM, % (CPIAUCSL); core YoY, % (CPILFENS) and MoM, % (CPILFESL) |
| PCE price index | Inflation | ★ | fred | Personal Income and Outlays, 08:30 | PCE YoY, % (PCEPI); core PCE YoY, % (PCEPILFE) |
| PPI | Inflation |  | fred | Producer Price Index, 08:30 | final demand YoY and MoM, % (PPIFIS) |
| Import prices | Inflation |  | fred | U.S. Import and Export Price Indexes, 08:30 | YoY, % (IR) |
| GDP | Growth | ★ | fred | Gross Domestic Product, 08:30 | real GDP, annualized QoQ, % (A191RL1Q225SBEA) |
| ISM Manufacturing PMI | Growth | ★ | rule | 1st business day of month, 10:00 | none (not in FRED) |
| ISM Services PMI | Growth | ★ | rule | 3rd business day of month, 10:00 | none (not in FRED) |
| Retail sales | Growth | ★ | fred | Advance Monthly Retail Trade, 08:30 | MoM, % (RSAFS) |
| Industrial production | Growth |  | fred | Industrial Production and Capacity Utilization, 09:15 | MoM, % (INDPRO); capacity utilization, % (TCU) |
| Durable goods orders | Growth |  | fred | Advance Durable Goods, 08:30 | MoM, % (DGORDER) |
| Empire State survey | Growth |  | fred | Empire State Manufacturing Survey, 08:30 | general business conditions, index (GACDISA066MSFRBNY) |
| Philadelphia Fed survey | Growth |  | fred | Manufacturing Business Outlook Survey, 08:30 | current activity, index (GACDFSA066MSFRBPHI) |
| Chicago PMI | Growth |  | rule | last business day of month, 09:45 | none |
| UMich consumer sentiment | Consumer |  | fred | University of Michigan Surveys of Consumers, 10:00 | sentiment index (UMCSENT) |
| Conference Board confidence | Consumer |  | rule | last Tuesday of month, 10:00 | none |
| Consumer credit | Consumer |  | fred | Consumer Credit G.19, 15:00 | total, $bn (TOTALSL) |
| Housing starts and permits | Housing |  | fred | New Residential Construction, 08:30 | starts, k annualized (HOUST); permits (PERMIT) |
| New home sales | Housing |  | fred | New Residential Sales, 10:00 | k annualized (HSN1F) |
| Existing home sales | Housing |  | fred | NAR's published schedule, hand-entered in `manual_events.yaml`, 10:00 | millions annualized (EXHOSLUSM495S) |
| Case-Shiller home prices | Housing |  | fred | S&P CoreLogic Case-Shiller, 09:00 | national index YoY, % (CSUSHPINSA) |
| Treasury quarterly refunding | Treasury | ★ | manual | early Feb, May, Aug, Nov | none |
| Monthly Treasury Statement | Fiscal |  | fred | Monthly Treasury Statement, 14:00 | monthly deficit or surplus, $bn (MTSDS133FMS) |
| Debt ceiling and funding deadlines | Fiscal |  | manual | entered when set | none |
| Trade balance | Trade |  | fred | U.S. International Trade in Goods and Services, 08:30 | balance, $bn (BOPGSTB) |
| EIA crude inventories | Commodities |  | rule | Wednesday 10:30 | none |
| EIA natural gas storage | Commodities |  | rule | Thursday 10:30 | none |
| Baker Hughes rig count | Commodities |  | rule | Friday 13:00 | none |
| CFTC Commitments of Traders | Commodities |  | rule | Friday 15:30 | none |
| USDA WASDE | Commodities |  | manual | USDA's published schedule, 12:00 | none |
| OPEC+ meetings | Commodities |  | manual | entered when announced | none |
| Company earnings | Earnings |  | earnings | Alpha Vantage earnings calendar | none (later from EDGAR) |
| Monthly options expiration | Market Structure |  | rule | 3rd Friday of month | none |
| Quad witching and S&P rebalance | Market Structure | ★ | rule | 3rd Friday of Mar, Jun, Sep, Dec | none |
| VIX expiration | Market Structure |  | rule | Wednesday 30 days before next month's 3rd Friday | none |
| Month-end | Market Structure |  | rule | last business day of month | none |
| US market holidays and early closes | Market Structure |  | manual | NYSE schedule | none |
| ECB rate decision | Global | ★ | manual | ECB's published schedule | none |
| BoJ rate decision | Global | ★ | manual | BoJ's published schedule | none |
| BoE rate decision | Global | ★ | manual | BoE's published schedule | none |
| PBoC loan prime rate | Global |  | rule | 20th of month, next business day if not | none |

**Rule engine notes**

- "Business day" means an NYSE trading day. The engine reads the holiday list from `manual_events.yaml`.
- If a rule lands on a holiday: options expiration moves to the prior day; ISM, Chicago PMI, and month-end shift to the next or prior business day as the rule says; EIA and CFTC reports move one day later. Mark shifted dates as approximate in V0.
- ADP's date is derived from the Employment Situation date, so it depends on FRED data being present.

**Earnings scope**: the Alpha Vantage calendar lists thousands of companies. V0 keeps only symbols in `calendar/config/watchlist.yaml`. Every earnings event from the watchlist is shown; none are starred unless the watchlist marks them.

**Deferred from V0** (dates too irregular for a rule, or not worth the upkeep yet): Challenger job cuts, NY Fed consumer expectations, S&P Global flash PMIs, Conference Board LEI, pending home sales, NAHB, Treasury auctions, TIC data, Russell reconstitution, China and Eurozone data releases, other central banks, G7/G20, political events.

## Data sources

Two keyed APIs, one rule engine, and one hand-edited file. A daily run makes roughly 75 FRED calls and 1 Alpha Vantage call.

**FRED (St. Louis Fed)** — free static key

- Release dates: `fred/release/dates` per release ID, with `include_release_dates_with_no_data=true` so future scheduled dates come back too. FRED omits those by default. ([docs](https://fred.stlouisfed.org/docs/api/fred/releases_dates.html))
- Actuals: `fred/series/observations` per series, from 18 months before the window start, so the first YoY values in the window can be computed even on lagged series. The fetcher computes the transforms (MoM %, YoY %, month-over-month difference) itself; the app never does math on raw series.
- Matching an observation to a release: use the date FRED first published the observation, not a calendar rule (see Design-session results). The fetcher stores that as the occurrence's `period`.
- FRED returns the latest revised values. A trailing list will show revised history, not the value as first printed. See Open decisions.
- Release dates come from the agencies, so a release can be rescheduled (for example during a government shutdown). The daily refresh picks that up.

**Alpha Vantage** — free static key, 25 calls per day

- One call per day: `EARNINGS_CALENDAR` with `horizon=3month`. Returns CSV for all US companies; the fetcher filters it to the watchlist.
- No other Alpha Vantage calls in V0, so the daily budget is barely touched.

**Rule engine** — no API

- Generates the `rule` events in the catalog for the whole window.
- Needs the NYSE holiday list, which lives in `manual_events.yaml`.

**Manual events** — `calendar/config/manual_events.yaml`

- FOMC, SEP, Beige Book, ECB, BoJ, BoE, Treasury refunding, WASDE, NYSE holidays and early closes, existing home sales dates, plus one-off events.
- Updated once a year when the institutions publish next year's schedules, plus ad hoc additions (testimony, OPEC+ meetings).
- Each entry: definition key, date, optional time, optional note. The fetcher validates the file and fails loudly on a bad entry.

**Failure handling**

- If any source fails, the fetcher keeps that source's data from the previous `events.json` and records the failure in a `warnings` list in the file. The app shows warnings next to the staleness indicator.
- If the whole run fails, the Action fails, GitHub emails the repo owner, and the app shows the staleness warning after 36 hours.

## macOS app

One window: a toolbar with the view switcher and filters, the calendar below, and a drill-down panel that opens when an event is selected.

**Toolbar**

- View switcher: Month · Week · Day, plus Today and previous/next arrows.
- Category filter: multi-select menu of the 13 categories, all selected by default.
- Star toggle: when on, only starred events show.
- Status line: "Updated 6h ago" from `generated_at`. Turns red past 36 hours, or when `warnings` is not empty; clicking it shows the warnings.
- Filter and view choices persist between launches.

**Month view**: a grid of days. Each day shows its events as compact chips (time + short name), starred events first. A day with more than about 4 events shows "+N more", which opens the day view.

**Week view**: seven columns, events listed by time in each day.

**Day view**: one list, events ordered by time, each with its category, star, and actual values if released.

**Event chips**: color by category, star icon if starred. Released US macro events show their headline actual on the chip in week and day views (for example "CPI 3.0% YoY").

**Time zone**: events are stored in US Eastern. The app displays in the Mac's local time zone by default (Asia/Ho\_Chi\_Minh for Michael), with a setting to show ET instead. Conversion must respect US daylight saving: 08:30 ET is 20:30 local during EST and 19:30 local during EDT.

**Drill-down panel** (opens beside the calendar on click)

- Header: event name, category, star, description, release time.
- For `fred` events: a table of the trailing 12 releases, newest first, one row per period, a column per actual (for example CPI: period, headline YoY, headline MoM, core YoY, core MoM). A small line chart of the main actual over the same 12 periods is optional in V0.
- For all other events: date, time, and notes only.

**Look**: dark mode only. Use SwiftUI system colors and materials so it matches macOS dark mode exactly; force dark appearance at the app level. Category colors use system accent colors (blue, green, orange, and so on), picked for contrast on dark backgrounds.

**Data loading**: fetch `events.json` from the raw GitHub URL on launch and every 4 hours; on failure, keep showing the cached copy. No API keys or tokens in the app.

## Tests and acceptance

Run the design-session tests before any app code. They prove each data source returns what the catalog assumes.

**Design-session tests** (run by hand or as small scripts, results noted in this doc)

- [x] FRED key works: one `fred/series/observations` call for CPIAUCSL returns recent monthly values. (Nov 2, 2026: latest value is Sep 2026.)
- [x] For every `fred` row in the catalog, find its release ID with a FRED release search by name, and record the ID in `releases.yaml`. (All 23 recorded, looked up from each series.)
- [x] For every series ID in the catalog, confirm it exists, has the expected frequency, and has data inside the window. Flag any that are discontinued, lagged, or limited (UMCSENT and EXHOSLUSM495S are the most likely problems). (All exist; both flagged series have problems, see results below.)
- [x] `fred/release/dates` with `include_release_dates_with_no_data=true` returns at least the next 2 months of scheduled dates for CPI and Employment Situation.
- [x] Period matching: for CPI, the computed `period` of the last 6 releases matches the month each release actually covered. (Passes for CPI, but the rule fails elsewhere, see results below.)
- [x] Transforms: computed CPI YoY for the last 3 months matches the BLS headline figure to one decimal. (Passes only on the unadjusted series, see results below.)
- [x] Alpha Vantage `EARNINGS_CALENDAR` returns CSV with symbol, name, and report date for the next 3 months, using 1 call. (Nov 2, 2026: 3,454 rows, 2026-11-02 to 2027-01-28.)
- [x] Rule engine: generated dates for options expiration, quad witching, ISM, and VIX expiration over the next 12 months match the official calendars, including holiday shifts. (Tested against third-party listings, see results below.)
- [x] GitHub: a manually dispatched run commits `events.json`, and the file is readable at its raw URL without a token. (Nov 2, 2026: run 41409922648, commit 3cc704d.)

**Design-session results (Nov 2, 2026)**

- CPI YoY: on CPIAUCSL, July gives 3.3% against the 3.4% BLS published. BLS headline YoY is unadjusted, so YoY now uses CPIAUCNS and CPILFENS, which match for Jul to Sep (headline 3.4, 3.4, 3.7; core 2.5, 2.4, 2.6). MoM stays on the adjusted series. PPI probably has the same issue with PPIFIS; not tested.
- Period rule: "first release date after P ends" holds for CPI's last 6 releases but fails for:
  - Empire State and Philly Fed, which publish the current month (October data on Oct 15).
  - GDP, which has three estimates per quarter, so three release dates share one period.
  - The Oct 2025 shutdown: CPI for September came out Oct 24, and October jobs data first appeared with November's on Dec 16.
  - Replacement, built and run: each observation's first-publication date comes from FRED (`output_type=4`), and that date is the released occurrence. This handles all three cases. Only the first estimate of each GDP quarter is a first publication, so later estimates get `role: revision`.
- Multiple dates per release: release 95 (durable goods) has two dates a month, the full M3 report and the advance report, and only the advance date is this event. Release 27 (housing) has a second date for the revised permits report. `pick_in_month` keeps the right one for future dates.
- Other date mismatches: a date in a month that already had new data is an annual revision and is dropped. A date in a month with none stays on the calendar, with a warning for its first 14 days.
- Added to `events.json`: `warnings`, `short` on definitions, and on occurrences `role`, `approximate`, `early_close`, `note`. `role: catch_up` marks an older period first published with a newer one (shown in the drill-down, hidden on the calendar). `role: revision` is the reverse.
- Shutdown gaps: October 2025 has no value for CPIAUCSL, CPILFESL, UNRATE, or IR. The fetcher must return null for transforms that touch a gap, not compute across it.
- EXHOSLUSM495S: FRED lists no release dates for it, and the series keeps only the latest 13 months (NAR license). Decided: dates are hand-entered from NAR's schedule, and actuals still come from FRED. It is the one `fred` event with manual dates, and its history is limited to what FRED holds. The 2025 dates are as scheduled, not confirmed; NAR's 2027 schedule is not yet found.
- UMCSENT: the Oct 23 release added no October value; the newest observation stayed at September. Earlier months had no such lag. Re-check after the Nov 20 release.
- Schedule horizon: FRED lists scheduled dates only through Dec 31, 2026, and no next date for ECI. Today that means about 2 months ahead for `fred` events, not the 5 in `window`. How far it extends after the new year is unknown.
- Rule engine: `calendar/fetcher/rules.py` generates all 15 `rule` events. Options and VIX dates match macroption's 2026 and 2027 lists, not Cboe's own PDFs, which were unreadable. ISM's official calendar needs a login, so ISM was tested on 11 dates from public listings only.
  - VIX: when next month's third Friday is a holiday, VIX expires 30 days before the Thursday instead, so May 2026 is Tuesday the 19th and May 2027 is Tuesday the 18th. Dec 2027 is computed as Dec 22, but macroption lists Dec 15; this is outside the window.
  - ISM: the first release in January falls after Jan 2 (Jan 5, 2026). The rule uses the first business day from Jan 3, based on the one published date tested here.
  - PBoC: uses weekends only, because NYSE holidays don't apply. Chinese holidays are not handled, so some dates may be off.
  - Not checked against a source: Chicago PMI, Conference Board, EIA, Baker Hughes, CFTC, month-end. Holiday moves for these follow the rules in this doc. FOMC minutes and ADP were tested only on sample dates.
  - NYSE list: the Jan 9, 2025 closure is not on the NYSE page, which shows regular holidays only, and was added by hand.
- Units: the fetcher must convert WALCL, TOTALSL, MTSDS133FMS, and BOPGSTB from millions to $bn, ICSA to k, and EXHOSLUSM495S to millions. ECIALLCIV is an index, so QoQ % is computed.

**V0 acceptance criteria**

- [ ] The Action has run on schedule for 7 consecutive days with no manual intervention.
- [ ] `events.json` contains every catalog definition with occurrences across the full window.
- [ ] Month, week, and day views show the same events for the same dates.
- [ ] Category filter and star toggle combine correctly, and persist after restarting the app.
- [ ] Every released `fred` event shows its actuals, and its drill-down lists the trailing 12 periods.
- [ ] Times display correctly in local time on both sides of a US daylight-saving change.
- [ ] With the network off, the app opens and shows the cached calendar.
- [ ] With `generated_at` set 40 hours back, the status line turns red.

## Open decisions and later versions

**Gaps in `manual_events.yaml`** (Nov 2, 2026; every definition has dates, but these are incomplete):

- Not published yet: Beige Book 2027, Treasury refunding after Nov 4, 2026, and WASDE 2027. Add them as they appear; Treasury names only the next date in each statement.
- Past dates not yet sourced: WASDE before Nov 2025, Jackson Hole 2025, stress tests 2025, and most Fed Chair testimony and OPEC+ meetings.
- Weaker source: ECB dates before Dec 2026 come from third-party listings, not the ECB.
- No debt ceiling date is entered; no current X-date was found.
- Fed testimony, OPEC+, and fiscal deadlines need entering as they are announced, so future coverage will always be short.

**Decide in the design session**

- [ ] **Revised vs. first-print actuals.** FRED's latest values include revisions, so payrolls history will not match what was printed on release day. ALFRED (FRED's vintage archive, same key) can return first prints. Default for V0: revised values, labeled "latest revised."
- [x] **Existing home sales.** FRED has no release dates, and only 13 months of values. Decided: enter NAR's dates by hand in `manual_events.yaml` and keep the values.
- [ ] **FOMC decision actual.** The fed funds target range (DFEDTARU / DFEDTARL) could be attached to FOMC occurrences, making them the one `manual` event with actuals. Small addition; include or defer.
- [ ] **Watchlist contents** for earnings, and whether watchlist earnings are starred.
- [ ] **Window size**: confirm 22 months back and 5 months forward, after checking `events.json` size.
- [ ] **Category colors**: one color per category, 13 total, chosen for contrast on dark backgrounds.
- [ ] **60-day rule**: confirm the daily commit keeps the scheduled workflow alive; if not, add a keep-alive step.

**V1**

- Drill-down shows the next scheduled release date with a countdown.
- Drill-down adds a news feed filtered to the event. Candidate source: Alpha Vantage News & Sentiment, filtered by topic. Check its free-tier fit against the 25-calls-a-day budget before committing.

**Later features of schlafinance**

- EDGAR: 10-Q and 10-K data from the SEC's free official JSON APIs (no key; a User-Agent header with a contact email is required). Reported EPS and revenue from filings attach as actuals to earnings events. Consensus estimates are not in EDGAR, so beat/miss needs another source if ever wanted.
- Each new feature gets its own folder and workflow beside `calendar/`.
