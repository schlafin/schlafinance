import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @State private var showingWarnings = false
    @State private var showingCategories = false

    var body: some View {
        Group {
            if model.file == nil {
                ContentUnavailableView("No calendar data yet", systemImage: "calendar", description: Text("Waiting for the first download."))
            } else if model.layout == .list {
                ScheduleView()
            } else {
                switch model.mode {
                case .month: MonthView()
                case .week: WeekView()
                case .day: DayView()
                }
            }
        }
        .navigationTitle(model.title)
        .toolbar { toolbar }
        .inspector(isPresented: inspectorShown) {
            if let event = model.selected {
                DrillDownView(event: event)
                    .inspectorColumnWidth(min: 300, ideal: 360, max: 520)
            }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(
            get: { model.selected != nil },
            set: { if !$0 { model.selected = nil } }
        )
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.step(-1) } label: { Image(systemName: "chevron.left") }
                .help("Previous")
            Button { model.step(1) } label: { Image(systemName: "chevron.right") }
                .help("Next")
            Button("Today") { model.goToToday() }
        }

        ToolbarItem(placement: .principal) {
            HStack {
                Picker("Layout", selection: $model.layout) {
                    ForEach(CalendarLayout.allCases) { layout in
                        Image(systemName: layout.icon).tag(layout).help(layout.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Picker("View", selection: $model.mode) {
                    ForEach(CalendarMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            categoryMenu

            Toggle(isOn: $model.starredOnly) {
                Image(systemName: model.starredOnly ? "star.fill" : "star")
            }
            .help("Show only high-impact events")

            statusButton
        }
    }

    /// A popover, not a Menu: a Menu closes on every click, and this one has to
    /// stay open for multi-select until the user clicks outside it.
    private var categoryMenu: some View {
        Button { showingCategories.toggle() } label: {
            Label(categoryLabel, systemImage: "line.3.horizontal.decrease.circle")
                .labelStyle(.titleAndIcon)
        }
        .popover(isPresented: $showingCategories, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Button("Select All") { model.categories = Set(Categories.all) }
                    Button("Clear All") { model.categories = [] }
                }
                Divider()
                ForEach(Categories.all, id: \.self) { category in
                    Toggle(isOn: Binding(
                        get: { model.categories.contains(category) },
                        set: { _ in model.toggle(category) }
                    )) {
                        HStack(spacing: 6) {
                            Circle().fill(Categories.color(category)).frame(width: 8, height: 8)
                            Text(category)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
            }
            .padding(12)
        }
    }

    private var categoryLabel: String {
        let count = model.categories.count
        return count == Categories.all.count ? "Filter" : "Filter (\(count))"
    }

    @ViewBuilder
    private var statusButton: some View {
        if let file = model.file {
            // Redraws on its own, so an app left open still turns red past 36 hours.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                let status = DataStatus(generatedAt: file.generatedAt, warnings: file.warnings, now: context.date)
                Button { showingWarnings = true } label: {
                    Text(status.text).foregroundStyle(status.isAlert ? Color.red : Color.secondary)
                }
            }
            .popover(isPresented: $showingWarnings) { warningsPopover }
        }
    }

    private var warningsPopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let file = model.file {
                Text("Data from \(file.generatedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.headline)
                if file.warnings.isEmpty {
                    Text("No warnings").foregroundStyle(.secondary)
                }
                ForEach(file.warnings, id: \.self) { Text($0) }
            }
        }
        .padding()
        .frame(width: 340, alignment: .leading)
    }
}
