import Charts
import PointInTimeCore
import SwiftUI

// Every chart is followed by a text summary that VoiceOver reads too, and no label is carried by color alone: the
// timeline places each category in its own named lane, the weekly calendar puts each category in its own lane in the
// legend's order and marks stretches of half an hour or more with its initial, bars carry the category's initial, and
// the rhythm's series have their own symbols. Captured text (titles, sites, reasons) is shown verbatim, never as markup.

extension TimeCategory {
    var color: Color {
        switch self {
        case .focus: .green
        case .neutral: .blue
        case .drift: .orange
        case .unclassified: .gray
        case .excluded: .purple
        }
    }

    var initial: String { String(title.prefix(1)) }
}

private let categoryScale = (domain: TimeCategory.allCases.map(\.title), range: TimeCategory.allCases.map(\.color))

struct ReportsView: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DayPicker(model: model).padding([.horizontal, .top])
            StatusBanners(model: model).padding(.horizontal)
            TabView {
                ScrollView { DayTab(model: model).padding() }
                    .tabItem { Text("Day") }
                ScrollView { WeekTab(model: model).padding() }
                    .tabItem { Text("Week") }
            }
            .padding()
        }
        .frame(minWidth: 720, minHeight: 520)
    }
}

/// Earlier days, today, and the next day up to today.
private struct DayPicker: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        HStack {
            Button { model.moveDay(by: -1) } label: { Label("Previous Day", systemImage: "chevron.left") }
                .keyboardShortcut("[", modifiers: .command)
            DatePicker("Day", selection: Binding { model.selectedDay } set: { model.choose(day: $0) }, in: ...Date(), displayedComponents: .date)
                .fixedSize()
            Button { model.moveDay(by: 1) } label: { Label("Next Day", systemImage: "chevron.right") }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(model.isToday)
            Button("Today") { model.choose(day: Date()) }.disabled(model.isToday)
            Spacer()
            Button { model.reload() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .keyboardShortcut("r", modifiers: .command)
        }
        .labelStyle(.titleAndIcon)
    }
}

/// Read errors, tracking off or paused, no provider or a failing one, and failed blocks with their retry.
private struct StatusBanners: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.readError {
                HStack {
                    Label { Text(verbatim: "Could not read the activity store: \(error)") } icon: { Image(systemName: "exclamationmark.triangle") }
                    Button("Try Again") { model.reload() }
                }
                .foregroundStyle(.red)
            }
            if let notice = model.trackingNotice {
                Label(notice, systemImage: "pause.circle")
            }
            if model.providerOff {
                HStack {
                    Label("Classification is off, so blocks are shown unclassified.", systemImage: "tag.slash")
                    Button("Choose a Provider…", action: model.showClassification)
                }
            }
            if let error = model.classificationError {
                HStack {
                    Label { Text(verbatim: error) } icon: { Image(systemName: "exclamationmark.triangle") }
                    if !model.providerOff { Button("Classification Settings…", action: model.showClassification) }
                }
            }
            let failed = model.classificationStatus.failed
            if failed > 0 {
                HStack {
                    Label("\(failed) block\(failed == 1 ? "" : "s") could not be classified.", systemImage: "exclamationmark.circle")
                    Button("Retry Failed Blocks") { model.retryFailed() }
                }
            }
        }
        .padding(.top, 6)
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: Day

private struct DayTab: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        if let day = model.day {
            VStack(alignment: .leading, spacing: 16) {
                if day.blocks.isEmpty {
                    Text(model.hasAnyActivity ? "No activity was recorded on this day." : "No activity recorded yet. Turn tracking on from the menu bar item, and blocks appear here as you work.")
                        .foregroundStyle(.secondary)
                }
                TimelineSection(model: model, day: day)
                HStack(alignment: .top, spacing: 16) {
                    BlockList(model: model).frame(minWidth: 260, maxWidth: 340, minHeight: 280, maxHeight: 360)
                    BlockInspector(model: model)
                }
                DayRings(title: model.isToday ? "Today’s Balance" : "Balance on \(day.interval.start.formatted(date: .abbreviated, time: .omitted))",
                         totals: day.totals)
                HStack(alignment: .top, spacing: 16) {
                    UsageList(title: "Top Apps", totals: day.apps, empty: "No app time recorded.")
                    UsageList(title: "Top Sites", totals: day.hosts, empty: "No sites recorded.")
                }
                Text(model.freshness(for: day.interval, latest: day.latestBlockEnd)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing to show until the activity store can be read.").foregroundStyle(.secondary)
        }
    }
}

/// The day or one hour as lanes of blocks, one lane per category.
private struct TimelineSection: View {
    @ObservedObject var model: ReportsModel
    let day: DayReport

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Timeline").font(.headline)
                Picker("Zoom", selection: $model.zoom) {
                    ForEach(ReportsModel.Zoom.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .fixedSize()
                if model.zoom == .hour {
                    Button { model.moveHour(by: -1) } label: { Label("Previous Hour", systemImage: "chevron.left") }
                        .labelStyle(.iconOnly)
                        .disabled(model.hours.first == model.hour)
                    if let shown = model.visibleInterval {
                        Text(verbatim: "\(model.time(shown.start)) to \(model.time(shown.end, asEnd: true))")
                    }
                    Button { model.moveHour(by: 1) } label: { Label("Next Hour", systemImage: "chevron.right") }
                        .labelStyle(.iconOnly)
                        .disabled(model.hours.last == model.hour)
                }
            }
            if let interval = model.visibleInterval {
                timeline(interval)
                    .frame(height: 180)
                    .focusable()
                    .onKeyPress(.leftArrow) { model.moveSelection(by: -1); return .handled }
                    .onKeyPress(.rightArrow) { model.moveSelection(by: 1); return .handled }
                    .accessibilityLabel(model.zoom == .day ? "Timeline of the day" : "Timeline of one hour")
                    .accessibilityHint("Left and right arrows move between blocks.")
            }
            let visible = model.visibleBlocks.reduce(CategorySeconds()) { $0 + $1.categorySeconds }
            Text(verbatim: "\(model.visibleBlocks.count) blocks. \(ReportText.totals(visible))")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func timeline(_ interval: DateInterval) -> some View {
        Chart {
            ForEach(model.visibleBlocks, id: \.start) { block in
                RectangleMark(xStart: .value("Start", block.start), xEnd: .value("End", block.end),
                              y: .value("Category", block.category.title))
                    .foregroundStyle(by: .value("Category", block.category.title))
                    .accessibilityLabel(Text(verbatim: "\(model.time(block.start)), \(block.category.title)"))
                    .accessibilityValue(Text(verbatim: block.dominantAppName ?? "Excluded time"))
            }
            if let selected = model.block {
                RuleMark(x: .value("Selected", selected.start.addingTimeInterval(Block.length / 2)))
                    .foregroundStyle(.primary)
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .accessibilityHidden(true)
            }
        }
        .chartXScale(domain: interval.start...interval.end)
        .chartYScale(domain: TimeCategory.allCases.map(\.title))
        .chartForegroundStyleScale(domain: categoryScale.domain, range: categoryScale.range)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onTapGesture { location in
                        guard let frame = proxy.plotFrame else { return }
                        let x = location.x - geometry[frame].origin.x
                        if let date: Date = proxy.value(atX: x) { model.select(at: date) }
                    }
            }
        }
    }
}

/// Every visible block as a keyboard-navigable list; selecting one opens it in the inspector.
private struct BlockList: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        List(selection: Binding(get: { model.selectedBlock }, set: { model.select($0) })) {
            ForEach(model.visibleBlocks, id: \.start) { block in
                HStack {
                    Text(verbatim: model.time(block.start)).monospacedDigit()
                    Text(verbatim: block.category.title).bold()
                    Text(verbatim: block.dominantAppName ?? "Excluded time").foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(block.start)
                .accessibilityElement(children: .combine)
            }
        }
        .accessibilityLabel("Blocks")
        .overlay { if model.visibleBlocks.isEmpty { Text("No blocks").foregroundStyle(.secondary) } }
    }
}

/// The selected block's apps, site, title, label, reason, and provider, and its correction.
private struct BlockInspector: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        GroupBox("Block") {
            if let block = model.block {
                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: "\(model.time(block.start)) to \(model.time(block.end, asEnd: true))").font(.headline)
                    row("Label", "\(block.category.title) (\(state(block)))")
                    if let reason = block.labeling.reason { row(block.labeling.state == .corrected ? "Note" : "Reason", reason) }
                    if let provider = block.labeling.provider {
                        row("Provider", [provider, block.labeling.model].compactMap { $0 }.joined(separator: ", ")
                            + (block.labeling.confidence.map { ", \(ReportText.percent($0)) confident" } ?? ""))
                    }
                    if let host = block.dominantURL { row("Site", host.host + host.path) }
                    if let title = block.dominantTitle { row("Title", title) }
                    row("Apps", block.apps.isEmpty ? "None (excluded time only)" : block.apps.map { "\($0.appName) \(ReportText.duration($0.seconds))" }.joined(separator: ", "))
                    row("Recorded", "\(ReportText.duration(block.activeSeconds)) in apps, \(ReportText.duration(block.excludedSeconds)) excluded")
                    Divider()
                    correction(block)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a block in the timeline or the list to see its details and correct its label.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func row(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(name).foregroundStyle(.secondary).frame(minWidth: 70, alignment: .leading)
            Text(verbatim: value).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func state(_ block: Block) -> String {
        guard model.canCorrect(block) else { return "in progress" }
        return switch block.labeling.state {
        case .pending: model.isSendable(block) ? "pending" : "not sent: excluded app or time"
        case .classified: "by the model"
        case .corrected: "corrected by you"
        case .failed: "could not be classified"
        }
    }

    @ViewBuilder private func correction(_ block: Block) -> some View {
        if model.canCorrect(block) {
            Picker("Correct to", selection: $model.correctionLabel) {
                ForEach(BlockLabel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            TextField("Note (optional)", text: $model.correctionNote)
            HStack {
                Button("Save Correction") { model.saveCorrection() }
                if let message = model.correctionMessage { Text(verbatim: message).font(.caption) }
            }
        } else {
            Text("This block is still in progress; it can be corrected once it ends.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

/// Focus, neutral, and drift as shares of classified time, each named and given as a number.
private struct DayRings: View {
    let title: String
    let totals: CategorySeconds

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title).font(.headline)
            HStack(spacing: 24) {
                ForEach([TimeCategory.focus, .neutral, .drift], id: \.self) { category in
                    // Nil with nothing classified: an empty ring with a dash, not 0%.
                    let share = totals.classified > 0 ? totals[category] / totals.classified : nil
                    VStack {
                        Gauge(value: share ?? 0) { Text(category.title) } currentValueLabel: { Text(share.map(ReportText.percent) ?? "–") }
                            .gaugeStyle(.accessoryCircularCapacity)
                            .tint(category.color)
                        Text(category.title)
                        Text(ReportText.duration(totals[category])).font(.caption).foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(category.title)
                    .accessibilityValue(share.map { "\(ReportText.percent($0)) of classified time, \(ReportText.duration(totals[category]))" }
                                        ?? "No classified time")
                }
            }
            Text(verbatim: ReportText.totals(totals)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct UsageList: View {
    let title: String
    let totals: [UsageTotal]
    let empty: String

    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 4) {
                if totals.isEmpty { Text(empty).foregroundStyle(.secondary) }
                ForEach(totals.prefix(8)) { total in
                    HStack {
                        Text(verbatim: total.name).lineLimit(1)
                        Spacer()
                        Text(ReportText.duration(total.seconds)).monospacedDigit()
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: Week

private struct WeekTab: View {
    @ObservedObject var model: ReportsModel

    var body: some View {
        if let week = model.week {
            VStack(alignment: .leading, spacing: 20) {
                if week.totals.recorded == 0 { Text("No activity was recorded this week.").foregroundStyle(.secondary) }
                ProfileCards(model: model, profile: week.profile)
                section("Daily Totals", summary: ReportText.bars(week.days) { model.dayName($0.interval.start, wide: true) }) {
                    WeekBars(model: model, week: week)
                }
                section("Half-Hour Rhythm", summary: ReportText.rhythm(week.rhythm, clock: model.clock)) {
                    RhythmChart(model: model, slots: week.rhythm)
                }
                section("Focus by Hour", summary: ReportText.heatmap(week.heatmap, dayName: { model.dayName(week.days[$0].interval.start, wide: true) }, clock: model.clock)) {
                    Heatmap(model: model, week: week)
                }
                section("Week Calendar", summary: calendarSummary(week)) {
                    WeekCalendar(model: model, week: week)
                }
                Text(model.freshness(for: week.interval, latest: week.latestBlockEnd)).font(.caption).foregroundStyle(.secondary)
            }
        } else {
            Text("Nothing to show until the activity store can be read.").foregroundStyle(.secondary)
        }
    }

    private func section<Content: View>(_ title: String, summary: String, @ViewBuilder chart: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            chart()
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
            Text(verbatim: summary).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func calendarSummary(_ week: WeekReport) -> String {
        let counts = TimeCategory.allCases.compactMap { category -> String? in
            let spans = week.days.flatMap(\.spans).filter { $0.category == category }.count
            return spans > 0 ? "\(spans) \(category.rawValue) stretch\(spans == 1 ? "" : "es")" : nil
        }
        return counts.isEmpty ? "No stretches recorded this week." : "Contiguous stretches this week: " + counts.joined(separator: ", ") + "."
    }
}

private struct ProfileCards: View {
    @ObservedObject var model: ReportsModel
    let profile: FocusProfile

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Focus Profile").font(.headline)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .top)], alignment: .leading, spacing: 12) {
                card("Typical focus start",
                     profile.typicalFocusStart.map(model.clock) ?? (profile.focusSeconds > 0 ? "No new start" : "No focus yet"),
                     profile.typicalFocusStart == nil && profile.focusSeconds > 0
                        ? "Focus only continued from before the week"
                        : "\(profile.focusDays) day\(profile.focusDays == 1 ? "" : "s") with a focus start")
                card("Start consistency", profile.startSpread.map { "± \(Int($0.rounded())) min" } ?? "Needs two days",
                     "Spread of the days’ first focus")
                card("Longest focus run", profile.longestFocusRun.map { ReportText.duration($0.duration) } ?? "None",
                     profile.longestFocusRun.map { "From \(model.dayName($0.start)) \(model.time($0.start))" } ?? "Consecutive focus blocks")
                card("Short drifts", "\(profile.shortDrifts)", "Drift stretches under 6 minutes")
                card("Focus and drift", profile.balance.map(ReportText.percent) ?? "None",
                     "Focus \(ReportText.duration(profile.focusSeconds)), drift \(ReportText.duration(profile.driftSeconds))")
            }
            Text(verbatim: ReportText.profile(profile, clock: model.clock)).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private func card(_ title: String, _ value: String, _ detail: String) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(verbatim: value).font(.title2).bold()
                Text(verbatim: detail).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Minutes per category per day, side by side in a fixed order, each bar marked with its category's initial. Excluded
/// time is left out; the text summary names it.
private struct WeekBars: View {
    @ObservedObject var model: ReportsModel
    let week: WeekReport

    var body: some View {
        Chart {
            ForEach(week.days, id: \.interval.start) { day in
                ForEach([TimeCategory.focus, .neutral, .drift, .unclassified], id: \.self) { category in
                    BarMark(x: .value("Day", model.dayName(day.interval.start)), y: .value("Minutes", day.totals[category] / 60))
                        .position(by: .value("Category", category.title))
                        .foregroundStyle(by: .value("Category", category.title))
                        .annotation(position: .top) {
                            if day.totals[category] > 0 { Text(category.initial).font(.caption2) }
                        }
                        .accessibilityLabel(Text(verbatim: "\(model.dayName(day.interval.start, wide: true)), \(category.title)"))
                        .accessibilityValue(Text(ReportText.duration(day.totals[category])))
                }
            }
        }
        .chartForegroundStyleScale(domain: categoryScale.domain, range: categoryScale.range)
        .chartYAxisLabel("Minutes")
        .frame(height: 220)
    }
}

/// Focus and drift per half-hour of the day, summed over the week; each series has its own symbol.
private struct RhythmChart: View {
    @ObservedObject var model: ReportsModel
    let slots: [RhythmSlot]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            chart
            Text("Focus: solid green line with circles. Drift: dashed orange line with squares.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var chart: some View {
        Chart {
            ForEach([TimeCategory.focus, .drift], id: \.self) { category in
                ForEach(slots, id: \.minuteOfDay) { slot in
                    LineMark(x: .value("Time", slot.minuteOfDay), y: .value("Minutes", slot.seconds[category] / 60))
                        .foregroundStyle(by: .value("Category", category.title))
                        .symbol(category == .focus ? AnyChartSymbolShape(.circle) : AnyChartSymbolShape(.square))
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: category == .focus ? [] : [5, 3]))
                        .accessibilityLabel(Text(verbatim: "\(model.clock(slot.minuteOfDay)), \(category.title)"))
                        .accessibilityValue(Text(ReportText.duration(slot.seconds[category])))
                }
            }
        }
        .chartForegroundStyleScale(domain: categoryScale.domain, range: categoryScale.range)
        .chartXScale(domain: 0...1_440)
        .chartXAxis {
            AxisMarks(values: Array(stride(from: 0, through: 1_440, by: 180))) { value in
                AxisGridLine()
                AxisValueLabel { if let minute = value.as(Int.self) { Text(model.clock(minute)) } }
            }
        }
        .chartYAxisLabel("Minutes")
        .chartLegend(.hidden)
        .frame(height: 200)
    }
}

/// Focus share of classified time for each hour of each day; empty hours stay blank.
private struct Heatmap: View {
    @ObservedObject var model: ReportsModel
    let week: WeekReport

    var body: some View {
        VStack(alignment: .leading, spacing: 4) { chart }
    }

    @ViewBuilder private var chart: some View {
        Chart {
            ForEach(week.heatmap.filter { $0.seconds.classified > 0 }, id: \.key) { cell in
                RectangleMark(x: .value("Hour", "\(cell.hour)"), y: .value("Day", model.dayName(week.days[cell.dayIndex].interval.start)),
                              width: .ratio(0.9), height: .ratio(0.9))
                    .foregroundStyle(TimeCategory.focus.color.opacity(0.15 + 0.85 * (cell.seconds.focusShare ?? 0)))
                    .accessibilityLabel(Text(verbatim: "\(model.dayName(week.days[cell.dayIndex].interval.start, wide: true)) \(model.clock(cell.hour * 60))"))
                    .accessibilityValue(Text("Focus \(ReportText.duration(cell.seconds.focus)), \(ReportText.percent(cell.seconds.focusShare ?? 0)) of classified time"))
            }
        }
        .chartXScale(domain: (0..<24).map { "\($0)" })
        .chartYScale(domain: week.days.map { model.dayName($0.interval.start) })
        .frame(height: 220)
        Text("A darker cell has a larger share of focus in its classified time; hours with nothing classified are blank.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

/// Each day's contiguous stretches by clock time, in one named lane per category.
private struct WeekCalendar: View {
    @ObservedObject var model: ReportsModel
    let week: WeekReport

    var body: some View {
        Chart {
            ForEach(week.days, id: \.interval.start) { day in
                ForEach(day.spans, id: \.start) { span in
                    // Plotted as minutes before midnight, so the morning is at the top, from the start's clock time to the end's.
                    let minutes = ReportPeriod.clockMinutes(of: span, day: day.interval, calendar: model.calendar)
                    BarMark(x: .value("Day", model.dayName(day.interval.start)),
                            yStart: .value("Start", 1_440 - minutes.lowerBound), yEnd: .value("End", 1_440 - minutes.upperBound))
                        .position(by: .value("Category", span.category.title))
                        .foregroundStyle(by: .value("Category", span.category.title))
                        .annotation(position: .overlay) {
                            if span.duration >= 1_800 { Text(span.category.initial).font(.caption2) }
                        }
                        .accessibilityLabel(Text(verbatim: "\(model.dayName(day.interval.start, wide: true)) \(model.time(span.start)) to \(model.time(span.end, asEnd: true))"))
                        .accessibilityValue(Text(span.category.title))
                }
            }
        }
        .chartForegroundStyleScale(domain: categoryScale.domain, range: categoryScale.range)
        .chartYScale(domain: 0.0...1_440.0)
        .chartYAxis {
            AxisMarks(values: Array(stride(from: 0.0, through: 1_440.0, by: 180.0))) { value in
                AxisGridLine()
                AxisValueLabel { if let minutes = value.as(Double.self) { Text(model.clock(1_440 - Int(minutes))) } }
            }
        }
        .frame(height: 420)
    }
}

private extension HeatmapCell {
    var key: Int { dayIndex * 24 + hour }
}
