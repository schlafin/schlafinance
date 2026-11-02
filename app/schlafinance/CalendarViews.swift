import SwiftUI

/// A colored event label.
struct EventChip: View {
    @EnvironmentObject private var model: AppModel
    let event: DisplayEvent

    var body: some View {
        Button { model.selected = event } label: {
            HStack(spacing: 4) {
                if event.starred {
                    Image(systemName: "star.fill").font(.system(size: 8))
                }
                if let time = event.time {
                    Text(time).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                }
                Text((event.isApproximate ? "~" : "") + event.shortName).lineLimit(1)
                Spacer(minLength: 0)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(color.opacity(isSelected ? 0.55 : 0.25), in: RoundedRectangle(cornerRadius: 4))
            .overlay(alignment: .leading) {
                Rectangle().fill(color).frame(width: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(event.name)
    }

    private var color: Color { Categories.color(event.category) }
    private var isSelected: Bool { model.selected?.id == event.id }
}

struct MonthView: View {
    @EnvironmentObject private var model: AppModel
    private let headerHeight = 26.0
    private let dayNumberHeight = 22.0
    private let lineHeight = 20.0

    var body: some View {
        GeometryReader { geometry in
            let weeks = model.monthWeeks
            let rowHeight = (geometry.size.height - headerHeight) / Double(weeks.count)
            let lines = max(2, Int((rowHeight - dayNumberHeight) / lineHeight))

            VStack(spacing: 0) {
                weekdayHeader.frame(height: headerHeight)
                ForEach(weeks, id: \.first) { week in
                    HStack(spacing: 0) {
                        ForEach(week, id: \.self) { day in
                            cell(day, lines: lines)
                        }
                    }
                    .frame(height: rowHeight)
                }
            }
        }
    }

    private var weekdayHeader: some View {
        let symbols = model.calendar.shortWeekdaySymbols
        let first = model.calendar.firstWeekday - 1
        return HStack(spacing: 0) {
            ForEach(0..<7, id: \.self) { i in
                Text(symbols[(first + i) % 7])
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
    }

    /// Shows what fits in `lines`, keeping one line for "+N more" when events overflow.
    private func cell(_ day: DayKey, lines: Int) -> some View {
        let events = model.events(on: day).sorted(by: EventOrder.starredFirst)
        let shown = events.count > lines ? lines - 1 : events.count
        return VStack(alignment: .leading, spacing: 2) {
            DayNumber(day: day, faded: day.month != model.anchor.month)
            ForEach(events.prefix(shown)) { EventChip(event: $0) }
            if events.count > shown {
                Button("+\(events.count - shown) more") { model.open(day) }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(3)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .border(Color(nsColor: .separatorColor), width: 0.5)
        .todayBorder(day == model.today)
    }
}

extension View {
    /// Outlines today's cell in the same blue as its date number.
    func todayBorder(_ isToday: Bool) -> some View {
        overlay {
            if isToday {
                Rectangle().strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
    }
}

struct DayNumber: View {
    @EnvironmentObject private var model: AppModel
    let day: DayKey
    var faded = false

    var body: some View {
        Button { model.open(day) } label: {
            Text("\(day.day)")
                .font(.system(size: 11, weight: isToday ? .bold : .regular))
                .monospacedDigit()
                .foregroundStyle(isToday ? Color.white : faded ? Color.secondary.opacity(0.6) : Color.primary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(isToday ? Color.accentColor : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var isToday: Bool { day == model.today }
}

struct WeekView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(model.weekDays, id: \.self) { day in
                column(day)
            }
        }
    }

    private func column(_ day: DayKey) -> some View {
        let weekday = day.date(in: model.calendar)
            .formatted(Date.FormatStyle(timeZone: model.zone).weekday(.abbreviated))
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Text(weekday).font(.caption).foregroundStyle(.secondary)
                DayNumber(day: day)
            }
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(model.events(on: day)) { event in
                        VStack(alignment: .leading, spacing: 1) {
                            EventChip(event: event)
                            if let headline = event.headline {
                                Text(headline)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                                    .padding(.leading, 6)
                            }
                        }
                    }
                }
            }
        }
        .padding(4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .border(Color(nsColor: .separatorColor), width: 0.5)
        .todayBorder(day == model.today)
    }
}

struct DayView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let events = model.events(on: model.anchor)
        if events.isEmpty {
            ContentUnavailableView("No events", systemImage: "calendar")
        } else {
            List(events) { event in
                row(event).listRowSeparator(.visible)
            }
        }
    }

    private func row(_ event: DisplayEvent) -> some View {
        Button { model.selected = event } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(event.timeLabel)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 56, alignment: .trailing)
                RoundedRectangle(cornerRadius: 2)
                    .fill(Categories.color(event.category))
                    .frame(width: 4, height: 14)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        if event.starred {
                            Image(systemName: "star.fill").font(.caption2)
                        }
                        Text((event.isApproximate ? "~" : "") + event.name)
                    }
                    Text(event.category).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    ForEach(event.allActuals, id: \.label) { actual in
                        Text("\(actual.label) \(actual.value)").monospacedDigit()
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The list layout, modeled on Google Calendar's Schedule view: one continuous
/// scroll, dated on the left, with events at the same time grouped together.
struct ScheduleView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(model.scheduleRows) { row in
                    rowView(row)
                }
            }
            .scrollTargetLayout()
        }
        .scrollPosition(id: $model.listPosition, anchor: .top)
        .overlay(alignment: .top) { pinnedHeader }
    }

    /// A busy hour runs to hundreds of rows, so this keeps its date and time in sight.
    @ViewBuilder
    private var pinnedHeader: some View {
        if let row = model.topScheduleRow, !row.showsTime {
            let date = row.day.date(in: model.calendar)
                .formatted(Date.FormatStyle(timeZone: model.zone).weekday(.abbreviated).month(.abbreviated).day())
            Text("\(date) · \(row.event.timeLabel)")
                .font(.caption.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.bar)
        }
    }

    private func rowView(_ row: ScheduleRow) -> some View {
        let event = row.event
        return VStack(spacing: 0) {
            if row.showsDay {
                Divider()
            } else if row.showsTime {
                Divider().padding(.leading, 76)
            }
            Button { model.selected = event } label: {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    dayLabel(row)
                    Text(row.showsTime ? event.timeLabel : "")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 64, alignment: .trailing)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Categories.color(event.category))
                        .frame(width: 4, height: 12)
                    if event.starred {
                        Image(systemName: "star.fill").font(.caption2)
                    }
                    Text((event.isApproximate ? "~" : "") + event.name).lineLimit(1)
                    Spacer()
                    if let headline = event.headline {
                        Text(headline).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(model.selected?.id == event.id ? Color.accentColor.opacity(0.25) : Color.clear)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func dayLabel(_ row: ScheduleRow) -> some View {
        let date = row.day.date(in: model.calendar)
        let style = Date.FormatStyle(timeZone: model.zone)
        return HStack(alignment: .firstTextBaseline, spacing: 4) {
            if row.showsDay {
                Text("\(row.day.day)")
                    .font(.title3.weight(row.day == model.today ? .bold : .regular))
                    .foregroundStyle(row.day == model.today ? Color.accentColor : Color.primary)
                    .monospacedDigit()
                Text(date.formatted(style.month(.abbreviated).weekday(.abbreviated)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 110, alignment: .leading)
    }
}

struct DrillDownView: View {
    @EnvironmentObject private var model: AppModel
    let event: DisplayEvent

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                if event.definition.sourceType == "fred", let file = model.file {
                    trailingTable(file)
                } else {
                    details
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                if event.starred {
                    Image(systemName: "star.fill").foregroundStyle(.yellow)
                }
                Text(event.name).font(.title3.bold())
                Spacer()
                Button { model.selected = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .keyboardShortcut(.cancelAction)
                    .help("Close")
            }
            Text(event.category)
                .font(.caption)
                .foregroundStyle(Categories.color(event.category))
            if let description = event.definition.description {
                Text(description).foregroundStyle(.secondary)
            }
            Text(when).font(.callout)
        }
    }

    private var when: String {
        let date = event.day.date(in: model.calendar)
            .formatted(Date.FormatStyle(timeZone: model.zone).weekday(.abbreviated).month(.abbreviated).day().year())
        let zoneName = model.showEastern ? "ET" : (model.zone.abbreviation() ?? "local")
        return event.time.map { "\(date), \($0) \(zoneName)" } ?? date
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let note = event.occurrence.note {
                Text(note)
            }
            if event.isApproximate {
                Text("Date is approximate: moved by a holiday.").foregroundStyle(.secondary)
            }
        }
    }

    private func trailingTable(_ file: EventsFile) -> some View {
        let series = event.definition.actualSeries ?? []
        let eventPeriod = event.occurrence.period
        let rows = TrailingRow.build(key: event.occurrence.definition, file: file, including: eventPeriod)
        return VStack(alignment: .leading, spacing: 6) {
            Text(eventPeriod == nil ? "Latest revised values" : "Latest revised values. Highlighted: this release's data.")
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                Grid(alignment: .trailing, horizontalSpacing: 0, verticalSpacing: 1) {
                    GridRow {
                        tableCell("Period", alignment: .leading).gridColumnAlignment(.leading)
                        ForEach(series) { tableCell($0.label) }
                    }
                    .font(.caption.bold())
                    Divider()
                    ForEach(rows) { row in
                        let highlighted = row.period == eventPeriod
                        GridRow {
                            tableCell(row.period, alignment: .leading, highlighted: highlighted)
                            ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                                tableCell(value, highlighted: highlighted)
                            }
                        }
                        .font(.callout.monospacedDigit())
                    }
                }
            }
        }
    }

    /// Cells fill their column, with no grid spacing, so a row's highlight is one solid band.
    private func tableCell(_ text: String, alignment: Alignment = .trailing, highlighted: Bool = false) -> some View {
        Text(text)
            .fontWeight(highlighted ? .semibold : nil)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .frame(maxWidth: .infinity, alignment: alignment)
            .background(highlighted ? Color.accentColor.opacity(0.35) : Color.clear)
    }
}
