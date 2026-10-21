import AppKit
import PointInTimeCore
import SwiftUI

/// The pointInTime window: the Day tab's timeline and the Week tab's reports, read from the store.
@MainActor
final class ReportsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    let model: ReportsModel

    init(model: ReportsModel) {
        self.model = model
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ReportsView(model: model)))
            window.title = "pointInTime"
            window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
            window.setContentSize(NSSize(width: 980, height: 760))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // Opening shows today and the current hour; bringing an open window forward keeps what it shows.
        if window?.isVisible == true { model.reload() } else { model.open() }
        // While shown, new blocks and labels appear within a minute.
        if timer == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.model.reload() } }
            timer.tolerance = 10
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// After a classification run or a settings change; nothing is read while the window is closed.
    func refreshIfVisible() {
        if window?.isVisible == true { model.reload() }
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }
}

/// What the window shows and the actions it offers. Every number comes from one read of the selected week's blocks.
@MainActor
final class ReportsModel: ObservableObject {
    enum Zoom: String, CaseIterable, Identifiable {
        case day = "Full Day", hour = "Hourly"
        var id: String { rawValue }
    }

    /// The selected day and the hour the hourly zoom shows.
    @Published private(set) var selection: ReportSelection
    @Published var zoom = Zoom.day
    @Published var selectedBlock: Date?
    @Published private(set) var day: DayReport?
    @Published private(set) var week: WeekReport?
    @Published private(set) var loadedAt: Date?
    @Published private(set) var readError: String?
    /// Whether the store holds any activity at all, to tell "nothing yet" from "nothing on this day".
    @Published private(set) var hasAnyActivity = false
    @Published var correctionLabel = BlockLabel.focus
    @Published var correctionNote = ""
    @Published var correctionMessage: String?

    let calendar = Calendar.autoupdatingCurrent
    private let store: ActivityStore?
    private let storeError: String?
    private let classification: ClassificationController
    private let captureState: () -> CaptureState
    let showClassification: () -> Void

    init(store: ActivityStore?, storeError: String?, classification: ClassificationController,
         captureState: @escaping () -> CaptureState, showClassification: @escaping () -> Void) {
        self.store = store
        self.storeError = storeError
        self.classification = classification
        self.captureState = captureState
        self.showClassification = showClassification
        selection = ReportSelection(now: Date(), calendar: calendar)
    }

    var selectedDay: Date { selection.day }
    var hour: Date { selection.hour }

    /// As the window opens: today and the current hour.
    func open() {
        selection = ReportSelection(now: Date(), calendar: calendar)
        selectedBlock = nil
        reload()
    }

    /// Reads the selected day's week from the store, after moving a selection on today past midnight. A failed read
    /// keeps nothing stale on screen.
    func reload() {
        let now = Date()
        let previousDay = selection.interval
        selection.followClock(now: now)
        if selection.interval != previousDay { selectedBlock = nil }
        defer { selection.settle(now: now, firstBlock: day?.blocks.first?.start) }
        guard let store else {
            readError = storeError ?? "The activity store is unavailable."
            day = nil
            week = nil
            return
        }
        let interval = ReportPeriod.week(containing: selectedDay, calendar: calendar)
        do {
            // The block before the week tells whether a focus run continues into its first day.
            let blocks = try store.blocks(from: interval.start.addingTimeInterval(-Block.length), to: interval.end)
            hasAnyActivity = try !blocks.isEmpty || store.latestSegmentEnd() != nil
            week = WeekReport(containing: selectedDay, blocks: blocks, calendar: calendar)
            day = DayReport(day: selectedDay, blocks: blocks, calendar: calendar)
            readError = nil
            loadedAt = now
        } catch {
            readError = String(describing: error)
            day = nil
            week = nil
        }
        if let selectedBlock, day?.blocks.contains(where: { $0.start == selectedBlock }) != true { self.selectedBlock = nil }
    }

    // MARK: Day navigation

    var isToday: Bool { selection.isToday(at: Date()) }

    /// Selects the day holding `date` (today for a later one) and reads it.
    func choose(day date: Date) {
        let previous = selection.interval
        selection.choose(day: date, now: Date())
        changedDay(from: previous)
    }

    func moveDay(by days: Int) {
        let previous = selection.interval
        selection.moveDay(by: days, now: Date())
        changedDay(from: previous)
    }

    private func changedDay(from previous: DateInterval) {
        guard selection.interval != previous else { return }
        selectedBlock = nil
        reload()
    }

    /// The day's hours by elapsed time, so a day the clocks change has 23 or 25 of them.
    var hours: [Date] { selection.hours }

    func moveHour(by offset: Int) { selection.moveHour(by: offset) }

    /// The span the timeline shows.
    var visibleInterval: DateInterval? {
        guard let day else { return nil }
        return zoom == .day ? day.interval : DateInterval(start: hour, duration: 3_600)
    }

    var visibleBlocks: [Block] {
        guard let day, let interval = visibleInterval else { return [] }
        return day.blocks.filter { interval.start <= $0.start && $0.start < interval.end }
    }

    var block: Block? { selectedBlock.flatMap { start in day?.blocks.first { $0.start == start } } }

    /// Selects the block holding `date`, if one is stored, and follows it in the hourly zoom.
    func select(at date: Date) {
        let start = Block.bucketStart(containing: date)
        guard day?.blocks.contains(where: { $0.start == start }) == true else { return }
        select(start)
    }

    func select(_ start: Date?) {
        selectedBlock = start
        correctionMessage = nil
        correctionNote = ""
        if let label = block?.reportLabel { correctionLabel = label }
        if let start, zoom == .hour { selection.showHour(containing: start) }
    }

    /// Moves the selection to the previous or next visible block.
    func moveSelection(by offset: Int) {
        let blocks = visibleBlocks
        guard !blocks.isEmpty else { return }
        guard let current = blocks.firstIndex(where: { $0.start == selectedBlock }) else {
            select(offset > 0 ? blocks.first?.start : blocks.last?.start)
            return
        }
        select(blocks[min(max(0, current + offset), blocks.count - 1)].start)
    }

    // MARK: Status

    /// Why nothing new is being recorded, or nil while tracking.
    var trackingNotice: String? {
        switch captureState() {
        case .recording, .idle: nil
        case .paused: "Tracking is paused. Nothing new is recorded until you resume it from the menu."
        case .off: "Tracking is off. Turn it on from the menu bar item to record activity."
        case .asleep, .locked, .inactiveSession: nil
        case .storeUnavailable: "Tracking is unavailable: the activity store could not be opened or read."
        case .writesBacklogged: "Not recording until the activity store accepts the queued writes."
        case .clockBehind: "Not recording until the clock passes the latest recorded activity."
        }
    }

    var providerOff: Bool { classification.settings.provider == .off }
    var classificationStatus: ClassificationStatus { classification.status }

    /// Why blocks are not being labeled while a provider is chosen (no key, an unreadable key, a failing provider), or
    /// why failed blocks could not be retried; nil while classification works.
    var classificationError: String? {
        guard let error = classificationStatus.lastError else { return nil }
        let at = classificationStatus.lastErrorAt.map { " (\(time($0)))" } ?? ""
        return providerOff ? "Last classification error\(at): \(error)"
            : "Blocks stay unclassified while the provider is not set up or is failing. Last error\(at): \(error)"
    }

    func retryFailed() {
        classification.retryFailed()
        reload()
    }

    // MARK: Correction

    /// A block can be corrected once it has ended, as in the Classification window.
    func canCorrect(_ block: Block) -> Bool { block.end <= Date() }

    /// Stores the correction through the store's correction operation; the timeline and totals update at once.
    func saveCorrection() {
        guard let store, let block, canCorrect(block) else { return }
        do {
            try store.correct(blockStart: block.start, to: correctionLabel, note: correctionNote, at: Date())
            correctionMessage = "Saved as \(correctionLabel.title)."
            correctionNote = ""
        } catch {
            correctionMessage = "Could not save the correction: \(error)"
        }
        classification.refreshStatus()
        reload()
    }

    // MARK: Formatting

    func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }

    /// A local clock time, given in minutes after midnight, whether or not today has that time.
    func clock(_ minuteOfDay: Int) -> String { ReportText.clock(minuteOfDay, locale: .autoupdatingCurrent) }

    func dayName(_ date: Date, wide: Bool = false) -> String {
        date.formatted(.dateTime.weekday(wide ? .wide : .abbreviated))
    }

    /// The data range and when it was read, shown under every tab.
    func freshness(for interval: DateInterval, latest: Date?) -> String {
        let first = interval.start.formatted(date: .abbreviated, time: .omitted)
        let last = interval.end.addingTimeInterval(-1).formatted(date: .abbreviated, time: .omitted)
        let range = first == last ? first : "\(first) to \(last)"
        let read = loadedAt.map { "read at \(time($0))" } ?? "not read yet"
        let newest = latest.map { "latest block ends \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "no blocks in this range"
        return "From the local activity store, \(range); \(read); \(newest)."
    }
}
