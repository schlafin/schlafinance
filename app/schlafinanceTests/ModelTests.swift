import XCTest
@testable import schlafinance

final class ModelTests: XCTestCase {
    private let hanoi = TimeZone(identifier: "Asia/Ho_Chi_Minh")!

    private func file(occurrences: String, generatedAt: String = "2026-11-02T08:02:01Z", warnings: String = "[]") throws -> EventsFile {
        let json = """
        {
          "schema_version": 1,
          "generated_at": "\(generatedAt)",
          "warnings": \(warnings),
          "definitions": {
            "cpi": {
              "name": "Consumer Price Index", "short": "CPI", "category": "Inflation", "star": true,
              "source_type": "fred", "time_et": "08:30",
              "actual_series": [
                { "key": "headline_yoy", "label": "CPI YoY", "unit": "%" },
                { "key": "core_yoy", "label": "Core CPI YoY", "unit": "%" }
              ]
            },
            "h41": { "name": "H.4.1", "short": "H.4.1", "category": "Monetary", "star": false,
                     "source_type": "fred", "time_et": "16:30" },
            "opex": { "name": "Options", "short": "OPEX", "category": "Market Structure", "star": false,
                      "source_type": "rule" }
          },
          "occurrences": \(occurrences)
        }
        """
        return try EventsFile.decode(Data(json.utf8))
    }

    private func occurrence(_ id: String, _ definition: String, _ date: String, extra: String = "") -> String {
        #"{ "id": "\#(id)", "definition": "\#(definition)", "date": "\#(date)", "status": "released"\#(extra) }"#
    }

    // MARK: - Time zones

    func testDaylightSavingOnBothSides() throws {
        let events = try DisplayEvent.build(
            from: file(occurrences: "[\(occurrence("a", "cpi", "2026-03-06")), \(occurrence("b", "cpi", "2026-03-10"))]"),
            zone: hanoi
        ).sorted { $0.id < $1.id }
        XCTAssertEqual(events[0].time, "20:30")  // EST
        XCTAssertEqual(events[1].time, "19:30")  // EDT
    }

    func testAfternoonEasternEventFallsOnTheNextLocalDay() throws {
        let events = try DisplayEvent.build(from: file(occurrences: "[\(occurrence("a", "h41", "2026-11-05"))]"), zone: hanoi)
        XCTAssertEqual(events[0].day, DayKey(year: 2026, month: 11, day: 6))
        XCTAssertEqual(events[0].time, "04:30")
    }

    func testEasternSettingKeepsTheListedTime() throws {
        let events = try DisplayEvent.build(from: file(occurrences: "[\(occurrence("a", "h41", "2026-11-05"))]"), zone: EventTime.eastern)
        XCTAssertEqual(events[0].day, DayKey(year: 2026, month: 11, day: 5))
        XCTAssertEqual(events[0].time, "16:30")
    }

    func testEventWithoutATimeStaysOnItsDate() throws {
        let events = try DisplayEvent.build(from: file(occurrences: "[\(occurrence("a", "opex", "2026-11-20"))]"), zone: hanoi)
        XCTAssertEqual(events[0].day, DayKey(year: 2026, month: 11, day: 20))
        XCTAssertNil(events[0].time)
    }

    // MARK: - Roles and drill-down

    func testCatchUpIsHiddenFromTheCalendarButListedInTheDrillDown() throws {
        let f = try file(occurrences: """
        [\(occurrence("a", "cpi", "2025-12-18", extra: #", "period": "2025-11", "actuals": {"headline_yoy": 2.7, "core_yoy": 2.6}"#)),
         \(occurrence("b", "cpi", "2025-12-18", extra: #", "period": "2025-10", "role": "catch_up", "actuals": {"headline_yoy": null, "core_yoy": null}"#))]
        """)
        XCTAssertEqual(DisplayEvent.build(from: f, zone: hanoi).map(\.id), ["a"])

        let rows = TrailingRow.build(key: "cpi", file: f)
        XCTAssertEqual(rows.map(\.period), ["2025-11", "2025-10"])
        XCTAssertEqual(rows[0].values, ["2.7%", "2.6%"])
        XCTAssertEqual(rows[1].values, ["—", "—"])
    }

    func testRevisionIsOnTheCalendarButNotTheDrillDown() throws {
        let f = try file(occurrences: """
        [\(occurrence("a", "cpi", "2026-07-30", extra: #", "period": "2026-Q2""#)),
         \(occurrence("b", "cpi", "2026-08-26", extra: #", "period": "2026-Q2", "role": "revision""#))]
        """)
        XCTAssertEqual(DisplayEvent.build(from: f, zone: hanoi).count, 2)
        XCTAssertEqual(TrailingRow.build(key: "cpi", file: f).count, 1)
    }

    func testTrailingListStopsAtTwelveNewestFirst() throws {
        let rows = (1...14).map {
            occurrence("o\($0)", "cpi", "2026-01-01", extra: #", "period": "2025-\#(String(format: "%02d", $0 % 13))""#)
        }
        let list = try TrailingRow.build(key: "cpi", file: file(occurrences: "[\(rows.joined(separator: ","))]"))
        XCTAssertEqual(list.count, 12)
        XCTAssertEqual(list[0].period, "2025-12")
    }

    func testOlderEventKeepsItsRowInTheDrillDown() throws {
        let rows = (1...14).map {
            occurrence("o\($0)", "cpi", "2026-01-01", extra: #", "period": "2025-\#(String(format: "%02d", $0))""#)
        }
        let f = try file(occurrences: "[\(rows.joined(separator: ","))]")

        let list = TrailingRow.build(key: "cpi", file: f, including: "2025-01")
        XCTAssertEqual(list.count, 13)
        XCTAssertEqual(list.last?.period, "2025-01")
        XCTAssertEqual(TrailingRow.build(key: "cpi", file: f, including: "2025-14").count, 12)
    }

    func testHeadline() throws {
        let f = try file(occurrences: "[\(occurrence("a", "cpi", "2026-10-14", extra: #", "actuals": {"headline_yoy": 3.0, "core_yoy": 2.6}"#))]")
        XCTAssertEqual(DisplayEvent.build(from: f, zone: hanoi)[0].headline, "CPI YoY 3.0%")
    }

    // MARK: - Formatting

    func testUnitFormats() {
        func format(_ unit: String, _ value: Double) -> String {
            ActualSeries(key: "k", label: "l", unit: unit).format(value)
        }
        XCTAssertEqual(format("%", 3), "3.0%")
        XCTAssertEqual(format("k", 194), "194k")
        XCTAssertEqual(format("$bn", -52.4), "$-52.4bn")
        XCTAssertEqual(format("millions", 3.99), "3.99M")
        XCTAssertEqual(format("index", 25.5), "25.5")
    }

    // MARK: - Status line

    func testStatusTurnsRedPast36Hours() {
        let now = Date()
        let fresh = DataStatus(generatedAt: now.addingTimeInterval(-6 * 3600), warnings: [], now: now)
        XCTAssertEqual(fresh.text, "Updated 6h ago")
        XCTAssertFalse(fresh.isAlert)

        let stale = DataStatus(generatedAt: now.addingTimeInterval(-40 * 3600), warnings: [], now: now)
        XCTAssertTrue(stale.isAlert)
    }

    func testStatusTurnsRedOnWarnings() {
        let now = Date()
        XCTAssertTrue(DataStatus(generatedAt: now, warnings: ["x"], now: now).isAlert)
    }

    // MARK: - List view

    func testListGroupsEventsAtTheSameTime() throws {
        let f = try file(occurrences: """
        [\(occurrence("a", "cpi", "2026-11-05")),
         \(occurrence("b", "cpi", "2026-11-05", extra: #", "star": false"#)),
         \(occurrence("c", "h41", "2026-11-05")),
         \(occurrence("d", "cpi", "2026-11-06"))]
        """)
        let events = DisplayEvent.build(from: f, zone: EventTime.eastern)
        let byDay = Dictionary(grouping: events, by: \.day).mapValues { $0.sorted(by: EventOrder.byTime) }
        let rows = ScheduleRow.build(from: byDay)

        XCTAssertEqual(rows.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(rows.map(\.showsDay), [true, false, false, true])
        XCTAssertEqual(rows.map(\.showsTime), [true, false, true, true])
    }

    func testEarningsTimes() throws {
        let f = try file(occurrences: """
        [\(occurrence("a", "opex", "2026-11-05", extra: #", "symbol": "AAPL", "time": "16:05""#)),
         \(occurrence("b", "opex", "2026-11-05", extra: #", "symbol": "XYZ""#)),
         \(occurrence("c", "opex", "2026-11-05"))]
        """)
        let labels = Dictionary(uniqueKeysWithValues: DisplayEvent.build(from: f, zone: hanoi).map { ($0.id, $0) })
        XCTAssertEqual(labels["a"]?.timeLabel, "04:05")
        XCTAssertEqual(labels["a"]?.day, DayKey(year: 2026, month: 11, day: 6))
        XCTAssertEqual(labels["b"]?.timeLabel, "Time TBA")
        XCTAssertEqual(labels["c"]?.timeLabel, "All day")
    }

    // MARK: - Ordering

    func testMacroEventsComeBeforeStarredEarningsInMonthChips() throws {
        let f = try file(occurrences: """
        [\(occurrence("a", "opex", "2026-11-05", extra: #", "symbol": "AAPL", "star": true, "time": "07:00""#)),
         \(occurrence("b", "cpi", "2026-11-05"))]
        """)
        let sorted = DisplayEvent.build(from: f, zone: EventTime.eastern).sorted(by: EventOrder.starredFirst)
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
    }

    func testStarredComeFirstInMonthChips() throws {
        let f = try file(occurrences: "[\(occurrence("a", "opex", "2026-11-05")), \(occurrence("b", "cpi", "2026-11-05"))]")
        let sorted = DisplayEvent.build(from: f, zone: EventTime.eastern).sorted(by: EventOrder.starredFirst)
        XCTAssertEqual(sorted.map(\.id), ["b", "a"])
    }
}
