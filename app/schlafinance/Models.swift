import Foundation

// The shape of calendar/data/events.json. The app never does math on raw data.

struct EventsFile: Decodable {
    let schemaVersion: Int
    let generatedAt: Date
    let warnings: [String]
    let definitions: [String: Definition]
    let occurrences: [Occurrence]

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case generatedAt = "generated_at"
        case warnings, definitions, occurrences
    }

    static func decode(_ data: Data) throws -> EventsFile {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(EventsFile.self, from: data)
    }
}

struct Definition: Decodable {
    let name: String
    let short: String
    let category: String
    let star: Bool
    let sourceType: String
    let timeEt: String?
    let description: String?
    let actualSeries: [ActualSeries]?

    enum CodingKeys: String, CodingKey {
        case name, short, category, star, description
        case sourceType = "source_type"
        case timeEt = "time_et"
        case actualSeries = "actual_series"
    }
}

struct ActualSeries: Decodable, Identifiable {
    let key: String
    let label: String
    let unit: String

    var id: String { key }

    func format(_ value: Double) -> String {
        let number: String
        if unit == "%" {
            number = String(format: "%.1f", value)
        } else if value == value.rounded() {
            number = String(format: "%.0f", value)
        } else {
            number = String(value)
        }
        switch unit {
        case "%", "k": return number + unit
        case "$bn": return "$" + number + "bn"
        case "millions": return number + "M"
        default: return number
        }
    }
}

struct Occurrence: Decodable, Identifiable {
    let id: String
    let definition: String
    let date: String
    let status: String
    let time: String?
    let period: String?
    let actuals: [String: Double?]?
    let role: String?
    let title: String?
    let symbol: String?
    let note: String?
    let star: Bool?
    let approximate: Bool?
    let earlyClose: String?

    enum CodingKeys: String, CodingKey {
        case id, definition, date, status, time, period, actuals, role, title, symbol, note, star, approximate
        case earlyClose = "early_close"
    }
}

/// A calendar day with no time zone attached.
struct DayKey: Hashable, Comparable {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    init?(iso: String) {
        let parts = iso.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        self.init(year: parts[0], month: parts[1], day: parts[2])
    }

    init(_ date: Date, in calendar: Calendar) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: c.year!, month: c.month!, day: c.day!)
    }

    static func < (a: DayKey, b: DayKey) -> Bool {
        (a.year, a.month, a.day) < (b.year, b.month, b.day)
    }

    /// Noon, so day arithmetic can't slip across a daylight-saving change.
    func date(in calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    func adding(_ component: Calendar.Component, _ value: Int, in calendar: Calendar) -> DayKey {
        DayKey(calendar.date(byAdding: component, value: value, to: date(in: calendar))!, in: calendar)
    }
}

enum EventTime {
    static let eastern = TimeZone(identifier: "America/New_York")!

    static func calendar(in zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// The instant of a date and time given in US Eastern, daylight saving included.
    static func instant(date: String, time: String) -> Date? {
        guard let day = DayKey(iso: date) else { return nil }
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { return nil }
        return calendar(in: eastern).date(
            from: DateComponents(year: day.year, month: day.month, day: day.day, hour: parts[0], minute: parts[1])
        )
    }
}

/// One event as the calendar shows it, resolved to a display time zone.
struct DisplayEvent: Identifiable {
    let occurrence: Occurrence
    let definition: Definition
    let day: DayKey
    let time: String?
    let instant: Date?

    var id: String { occurrence.id }
    var starred: Bool { occurrence.star ?? definition.star }
    var category: String { definition.category }
    var isApproximate: Bool { occurrence.approximate ?? false }
    var name: String { occurrence.title ?? definition.name }
    var isReleased: Bool { occurrence.status == "released" }

    /// An earnings date with no time is unknown, not an all-day event.
    var timeLabel: String {
        time ?? (occurrence.symbol == nil ? "All day" : "Time TBA")
    }

    var shortName: String {
        if let symbol = occurrence.symbol { return symbol }
        return definition.short
    }

    /// The main actual, as on a chip: "CPI YoY 3.7%".
    var headline: String? {
        guard let series = definition.actualSeries?.first,
              let value = occurrence.actuals?[series.key] ?? nil
        else { return nil }
        return "\(series.label) \(series.format(value))"
    }

    var allActuals: [(label: String, value: String)] {
        (definition.actualSeries ?? []).compactMap { series in
            guard let value = occurrence.actuals?[series.key] ?? nil else { return nil }
            return (series.label, series.format(value))
        }
    }

    static func build(from file: EventsFile, zone: TimeZone) -> [DisplayEvent] {
        let calendar = EventTime.calendar(in: zone)
        let timeFormat = Date.FormatStyle(timeZone: zone).hour(.twoDigits(amPM: .omitted)).minute(.twoDigits)

        return file.occurrences.compactMap { o -> DisplayEvent? in
            // A catch-up is an older period published with a newer one: drill-down only.
            guard o.role != "catch_up",
                  let definition = file.definitions[o.definition],
                  let listedDay = DayKey(iso: o.date)
            else { return nil }

            if let time = o.time ?? definition.timeEt,
               let instant = EventTime.instant(date: o.date, time: time) {
                return DisplayEvent(
                    occurrence: o,
                    definition: definition,
                    day: DayKey(instant, in: calendar),
                    time: instant.formatted(timeFormat),
                    instant: instant
                )
            }
            // No time of day, so the listed date holds in every time zone.
            return DisplayEvent(occurrence: o, definition: definition, day: listedDay, time: nil, instant: nil)
        }
    }
}

enum EventOrder {
    /// Events with no time first, then by time.
    static func byTime(_ a: DisplayEvent, _ b: DisplayEvent) -> Bool {
        switch (a.instant, b.instant) {
        case let (x?, y?) where x != y: return x < y
        case (nil, _?): return true
        case (_?, nil): return false
        default: return a.starred != b.starred ? a.starred : a.id < b.id
        }
    }

    /// For month chips: starred before unstarred, and within each, macro events
    /// before earnings, so a busy earnings day can't push out the jobs report.
    static func starredFirst(_ a: DisplayEvent, _ b: DisplayEvent) -> Bool {
        let (x, y) = (rank(a), rank(b))
        return x != y ? x < y : byTime(a, b)
    }

    private static func rank(_ event: DisplayEvent) -> Int {
        (event.starred ? 0 : 2) + (event.occurrence.symbol == nil ? 0 : 1)
    }
}

/// One row of the list view. The date and time show only where they change,
/// so events at the same time read as one group.
struct ScheduleRow: Identifiable {
    let event: DisplayEvent
    let showsDay: Bool
    let showsTime: Bool

    var id: String { event.id }
    var day: DayKey { event.day }

    static func build(from eventsByDay: [DayKey: [DisplayEvent]]) -> [ScheduleRow] {
        eventsByDay.keys.sorted().flatMap { day -> [ScheduleRow] in
            let events = eventsByDay[day] ?? []
            return events.enumerated().map { index, event in
                ScheduleRow(
                    event: event,
                    showsDay: index == 0,
                    showsTime: index == 0 || events[index - 1].timeLabel != event.timeLabel
                )
            }
        }
    }
}

/// One row of the drill-down table.
struct TrailingRow: Identifiable {
    let period: String
    let values: [String]

    var id: String { period }

    static let count = 12

    /// The newest releases of a definition, one row per period. `including` adds
    /// an older period, so the event being viewed always has its row.
    static func build(key: String, file: EventsFile, including period: String? = nil) -> [TrailingRow] {
        guard let series = file.definitions[key]?.actualSeries else { return [] }
        let rows = file.occurrences
            .filter { $0.definition == key && $0.status == "released" && $0.role != "revision" && $0.period != nil }
            .sorted { $0.period! > $1.period! }
        var shown = Array(rows.prefix(count))
        if let older = rows.dropFirst(count).first(where: { $0.period == period }) {
            shown.append(older)
        }
        return shown.map { o in
            TrailingRow(
                period: o.period!,
                values: series.map { s in
                    (o.actuals?[s.key] ?? nil).map(s.format) ?? "—"
                }
            )
        }
    }
}

struct DataStatus {
    static let staleAfterHours = 36.0

    let text: String
    let isAlert: Bool

    init(generatedAt: Date, warnings: [String], now: Date = Date()) {
        let hours = now.timeIntervalSince(generatedAt) / 3600
        if hours < 1 {
            text = "Updated \(max(0, Int(hours * 60)))m ago"
        } else if hours < 48 {
            text = "Updated \(Int(hours))h ago"
        } else {
            text = "Updated \(Int(hours / 24))d ago"
        }
        isAlert = hours > Self.staleAfterHours || !warnings.isEmpty
    }
}
