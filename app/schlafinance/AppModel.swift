import Foundation
import SwiftUI

enum CalendarMode: String, CaseIterable, Identifiable {
    case month = "Month"
    case week = "Week"
    case day = "Day"

    var id: String { rawValue }
}

enum CalendarLayout: String, CaseIterable, Identifiable {
    case calendar = "Calendar"
    case list = "List"

    var id: String { rawValue }
    var icon: String { self == .calendar ? "calendar" : "list.bullet" }
}

enum Categories {
    static let colors: [(name: String, color: Color)] = [
        ("Monetary", .blue),
        ("Labor", .green),
        ("Inflation", .red),
        ("Growth", .teal),
        ("Consumer", .pink),
        ("Housing", .orange),
        ("Treasury", .indigo),
        ("Fiscal", .purple),
        ("Trade", .cyan),
        ("Commodities", .brown),
        ("Earnings", .mint),
        ("Market Structure", .gray),
        ("Global", .yellow),
    ]

    static let all = colors.map(\.name)

    static func color(_ name: String) -> Color {
        colors.first { $0.name == name }?.color ?? .gray
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let dataURL = URL(string: "https://raw.githubusercontent.com/schlafin/schlafinance/main/calendar/data/events.json")!
    static let refreshInterval: Duration = .seconds(4 * 60 * 60)

    @Published private(set) var file: EventsFile?
    @Published private(set) var eventsByDay: [DayKey: [DisplayEvent]] = [:]
    @Published private(set) var scheduleRows: [ScheduleRow] = []
    @Published var selected: DisplayEvent?
    @Published var anchor: DayKey

    /// The row at the top of the list view. Scrolling moves the anchor, so the
    /// title follows along, and setting it scrolls the list.
    @Published var listPosition: String? {
        didSet {
            if let row = topScheduleRow { anchor = row.day }
        }
    }

    private var scheduleRowsByID: [String: ScheduleRow] = [:]
    var topScheduleRow: ScheduleRow? { listPosition.flatMap { scheduleRowsByID[$0] } }

    @Published var layout: CalendarLayout {
        didSet {
            defaults.set(layout.rawValue, forKey: "layout")
            scrollListToAnchor()
        }
    }
    @Published var mode: CalendarMode {
        didSet { defaults.set(mode.rawValue, forKey: "mode") }
    }
    @Published var categories: Set<String> {
        didSet {
            defaults.set(Array(categories), forKey: "categories")
            rebuild()
        }
    }
    @Published var starredOnly: Bool {
        didSet {
            defaults.set(starredOnly, forKey: "starredOnly")
            rebuild()
        }
    }
    @Published var showEastern: Bool {
        didSet {
            defaults.set(showEastern, forKey: "showEastern")
            rebuild()
        }
    }

    private let defaults = UserDefaults.standard

    init() {
        let defaults = UserDefaults.standard
        layout = CalendarLayout(rawValue: defaults.string(forKey: "layout") ?? "") ?? .calendar
        mode = CalendarMode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .month
        categories = Set(defaults.stringArray(forKey: "categories") ?? Categories.all)
        starredOnly = defaults.bool(forKey: "starredOnly")
        showEastern = defaults.bool(forKey: "showEastern")
        anchor = DayKey(Date(), in: Calendar.current)
        loadCache()
    }

    var zone: TimeZone { showEastern ? EventTime.eastern : .current }
    var calendar: Calendar {
        var calendar = EventTime.calendar(in: zone)
        calendar.firstWeekday = Calendar.current.firstWeekday
        return calendar
    }
    var today: DayKey { DayKey(Date(), in: calendar) }

    var title: String {
        let date = anchor.date(in: calendar)
        switch mode {
        case .month:
            return date.formatted(Date.FormatStyle(timeZone: zone).month(.wide).year())
        case .week:
            let days = weekDays
            let style = Date.FormatStyle(timeZone: zone).month(.abbreviated).day()
            return "\(days[0].date(in: calendar).formatted(style)) – \(days[6].date(in: calendar).formatted(style))"
        case .day:
            return date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated).month(.abbreviated).day().year())
        }
    }

    var weekDays: [DayKey] {
        let date = anchor.date(in: calendar)
        let start = calendar.dateInterval(of: .weekOfYear, for: date)!.start
        let first = DayKey(start, in: calendar)
        return (0..<7).map { first.adding(.day, $0, in: calendar) }
    }

    /// Whole weeks covering the anchor's month.
    var monthWeeks: [[DayKey]] {
        let date = anchor.date(in: calendar)
        let month = calendar.dateInterval(of: .month, for: date)!
        let firstWeek = calendar.dateInterval(of: .weekOfYear, for: month.start)!.start
        var day = DayKey(firstWeek, in: calendar)
        var weeks: [[DayKey]] = []
        while weeks.isEmpty || day.month == anchor.month {
            weeks.append((0..<7).map { day.adding(.day, $0, in: calendar) })
            day = day.adding(.day, 7, in: calendar)
        }
        return weeks
    }

    func events(on day: DayKey) -> [DisplayEvent] {
        eventsByDay[day] ?? []
    }

    func step(_ direction: Int) {
        switch mode {
        case .month: anchor = anchor.adding(.month, direction, in: calendar)
        case .week: anchor = anchor.adding(.day, 7 * direction, in: calendar)
        case .day: anchor = anchor.adding(.day, direction, in: calendar)
        }
        scrollListToAnchor()
    }

    func goToToday() {
        anchor = today
        scrollListToAnchor()
    }

    private func scrollListToAnchor() {
        guard layout == .list else { return }
        listPosition = (scheduleRows.first { $0.day >= anchor } ?? scheduleRows.last)?.id
    }

    func open(_ day: DayKey) {
        anchor = day
        mode = .day
    }

    func toggle(_ category: String) {
        if categories.contains(category) {
            categories.remove(category)
        } else {
            categories.insert(category)
        }
    }

    // MARK: - Data

    private var cacheURL: URL {
        let folder = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("schlafinance", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("events.json")
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cached = try? EventsFile.decode(data)
        else { return }
        file = cached
        rebuild()
    }

    /// Refreshes now and then every 4 hours, for as long as the app runs.
    func refreshLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(for: Self.refreshInterval)
        }
    }

    /// On failure the last good copy stays; its age shows in the status line.
    func refresh() async {
        // eventsURL is a launch argument for trying a local file before it's published.
        let override = defaults.string(forKey: "eventsURL").flatMap(URL.init(string:))
        var request = URLRequest(url: override ?? Self.dataURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse).map({ $0.statusCode == 200 }) ?? true,
              let fresh = try? EventsFile.decode(data)
        else { return }
        file = fresh
        try? data.write(to: cacheURL, options: .atomic)
        rebuild()
    }

    private func rebuild() {
        guard let file else { return }
        let events = DisplayEvent.build(from: file, zone: zone).filter {
            categories.contains($0.category) && (!starredOnly || $0.starred)
        }
        eventsByDay = Dictionary(grouping: events, by: \.day).mapValues { $0.sorted(by: EventOrder.byTime) }
        scheduleRows = ScheduleRow.build(from: eventsByDay)
        scheduleRowsByID = Dictionary(uniqueKeysWithValues: scheduleRows.map { ($0.id, $0) })
        if let selected, scheduleRowsByID[selected.id] == nil {
            self.selected = nil
        }
        if topScheduleRow == nil {
            // Wait a tick: the list has to lay out its new rows before it can scroll to one.
            Task { @MainActor in
                await Task.yield()
                scrollListToAnchor()
            }
        }
    }
}
