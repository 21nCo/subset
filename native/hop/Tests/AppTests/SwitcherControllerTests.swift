import AppKit
@testable import Hop
import HopCore
import XCTest

/// The switcher's flow with a recording operator and a scripted window list: what each key asks of the operator, and
/// what the switcher shows after the result.
@MainActor
final class SwitcherControllerTests: XCTestCase {
    private var lists: [[WindowEntry]] = []
    private var reads = 0
    private let windows = (0..<4).map { index in
        WindowEntry(
            app: SourceApp(pid: pid_t(10 + index), bundleIdentifier: nil, name: "App \(index)"),
            window: SourceWindow(ref: HopCore.WindowRef(rawValue: UInt64(index)), title: "Window \(index)",
                                 subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: nil
        )
    }

    /// The apps each read (by its number, from 1) leaves out because they did not answer in time.
    private var skipping: [Int: [pid_t]] = [:]

    private func controller(_ windowOperator: RecordingWindowOperator) -> SwitcherController {
        SwitcherController(readWindows: readWindows, windowOperator: windowOperator)
    }

    private func wait(until condition: () -> Bool, _ message: String = "") async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A left-button event at the middle of the cell at `index`, in the panel's window coordinates.
    private func mouse(_ type: NSEvent.EventType, onCellAt index: Int, of switcher: SwitcherController) throws -> NSEvent {
        let model = try XCTUnwrap(switcher.model)
        let cell = try XCTUnwrap(model.layout.frame(of: index, firstVisibleRow: model.firstVisibleRow))
        let view = switcher.panel.switcherView
        let location = view.convert(NSPoint(x: cell.midX, y: cell.midY), to: nil)
        return try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: location, modifierFlags: [], timestamp: 0,
            windowNumber: switcher.panel.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1
        ))
    }

    func testAClickCommitsTheWindowItWasPressedOn() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows]
        let switcher = controller(recorder)
        var ended = 0
        switcher.onSessionEnded = { ended += 1 }
        switcher.open()
        let view = switcher.panel.switcherView
        view.mouseDown(with: try mouse(.leftMouseDown, onCellAt: 2, of: switcher))
        view.mouseUp(with: try mouse(.leftMouseUp, onCellAt: 2, of: switcher))
        XCTAssertFalse(switcher.isOpen)
        XCTAssertEqual(ended, 1)
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.operation), [.focus])
        XCTAssertEqual(recorder.calls.map(\.window), [windows[2].ref])
    }

    func testAClickWhoseCellChangedWindowsBeforeTheReleaseCommitsNothing() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = controller(recorder)
        var ended = 0
        switcher.onSessionEnded = { ended += 1 }
        switcher.open()
        let view = switcher.panel.switcherView
        view.mouseDown(with: try mouse(.leftMouseDown, onCellAt: 2, of: switcher))
        // ⌘W closes the selected window 1 before the release, so the pressed spot now shows window 3.
        switcher.apply(.operation(.close))
        try await wait(until: { switcher.model?.windows.count == 3 }, "the closed window leaves the list")
        XCTAssertEqual(switcher.model?.windows[2].ref, windows[3].ref)
        view.mouseUp(with: try mouse(.leftMouseUp, onCellAt: 2, of: switcher))
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(switcher.isOpen, "the click is dropped")
        XCTAssertEqual(ended, 0)
        XCTAssertEqual(recorder.calls.map(\.operation), [.close], "window 3 is never focused")
        // A new click on that spot chooses the window it now shows.
        view.mouseDown(with: try mouse(.leftMouseDown, onCellAt: 2, of: switcher))
        view.mouseUp(with: try mouse(.leftMouseUp, onCellAt: 2, of: switcher))
        XCTAssertFalse(switcher.isOpen)
        try await wait(until: { recorder.calls.count == 2 })
        XCTAssertEqual(recorder.calls.map(\.operation), [.close, .focus])
        XCTAssertEqual(recorder.calls.last?.window, windows[3].ref)
    }

    func testCloseKeepsTheSwitcherOpenAndSelectsTheNextWindow() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = controller(recorder)
        switcher.open()
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)
        switcher.apply(.operation(.close))
        try await wait(until: { switcher.model?.windows.count == 3 }, "the closed window leaves the list")
        XCTAssertEqual(recorder.calls.map(\.operation), [.close])
        XCTAssertEqual(recorder.calls.map(\.window), [windows[1].ref])
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[2].ref)
        try await wait(until: { reads == 2 }, "the list is read again")
        XCTAssertTrue(switcher.isOpen)
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[2].ref, "the refresh keeps the next window selected")
        XCTAssertNil(switcher.model?.message)
        switcher.cancel()
    }

    func testAFailedOperationShowsItsMessageInTheOpenSwitcher() async throws {
        let recorder = RecordingWindowOperator(results: [.minimize: .refused("can't be minimized")])
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        switcher.apply(.step(.forward))
        switcher.apply(.operation(.minimize))
        try await wait(until: { switcher.model?.message != nil })
        XCTAssertEqual(recorder.calls.map(\.window), [windows[2].ref])
        XCTAssertEqual(switcher.model?.message, "Couldn't minimize the App 2 window")
        XCTAssertEqual(switcher.model?.windows, windows)
        switcher.cancel()
    }

    func testCommitFocusesTheSelectedWindowAndHides() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        switcher.apply(.row(.down)) // one row: stays on 1
        switcher.apply(.step(.backward))
        switcher.commit()
        XCTAssertFalse(switcher.isOpen)
        XCTAssertFalse(switcher.panel.isVisible)
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.operation), [.focus])
        XCTAssertEqual(recorder.calls.map(\.window), [windows[0].ref])
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(switcher.panel.isVisible, "a focus that succeeded shows nothing")
    }

    func testAFocusThatFailsShowsWhyThenHides() async throws {
        let recorder = RecordingWindowOperator(results: [.focus: .refused("did not come to front")])
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        switcher.commit()
        try await wait(until: { switcher.panel.isVisible }, "the message appears")
        let labels = switcher.panel.switcherView.accessibilityChildren()?
            .compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertEqual(labels, ["Couldn't bring App 1 forward"])
        try await wait(until: { !switcher.panel.isVisible }, "the message hides after 1.5 s")
    }

    func testAnOperationWithoutPermissionAsksForIt() async throws {
        let recorder = RecordingWindowOperator(results: [.hideApp: .notPermitted])
        lists = [windows]
        let switcher = controller(recorder)
        var asked = 0
        switcher.onNotPermitted = { asked += 1 }
        switcher.open()
        switcher.apply(.operation(.hideApp))
        try await wait(until: { asked == 1 })
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(reads, 1, "no refresh without permission")
        switcher.cancel()
    }

    func testAResultAfterTheSwitcherClosedChangesNothing() async throws {
        let recorder = RecordingWindowOperator(results: [.close: .refused("can't be closed")])
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.cancel()
        try await wait(until: { !recorder.calls.isEmpty })
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertNil(switcher.model)
        XCTAssertFalse(switcher.panel.isVisible)
        XCTAssertEqual(reads, 1)
    }

    func testAnEmptyListOpensSayingNoWindowsAndCommitsNothing() async throws {
        let recorder = RecordingWindowOperator()
        lists = [[]]
        let switcher = controller(recorder)
        switcher.open()
        XCTAssertEqual(switcher.model?.windows, [])
        switcher.apply(.operation(.quitApp))
        switcher.commit()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.calls, [])
    }

    // MARK: - Operations still pending

    func testReleasingWhileACloseIsPendingFocusesTheWindowThatFollowsItOnceItIsGone() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.commit()
        XCTAssertFalse(switcher.panel.isVisible, "the switcher hides at once")
        try await wait(until: { gate.held == 1 })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "nothing is focused while the close is pending")
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the list is read again, then the release commits")
        XCTAssertEqual(gate.calls.map(\.operation), [.close, .focus])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref], "the closed window is never focused")
        XCTAssertFalse(switcher.isOpen)
    }

    func testACloseThatLeavesTheWindowOpenKeepsItSelected() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows] // the app asked to save: window 1 is still listed after ⌘W
        let switcher = controller(recorder)
        switcher.open()
        switcher.apply(.operation(.close))
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(switcher.model?.windows, windows, "a delivered close is not taken as the window gone")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)
        try await wait(until: { reads == 2 }, "the list is read again")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref, "the prompting window stays selected")
        switcher.apply(.operation(.close))
        try await wait(until: { reads == 3 })
        switcher.commit()
        try await wait(until: { recorder.calls.count == 3 })
        XCTAssertEqual(recorder.calls.map(\.operation), [.close, .close, .focus])
        XCTAssertEqual(recorder.calls.map(\.window), Array(repeating: windows[1].ref, count: 3),
                       "no other window is closed or focused")
    }

    func testAnOperationKeyWhileACloseIsPendingActsOnTheSelectionOnceTheListIsReadAgain() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref], "the second ⌘W waits for the first")
        gate.release(.done)
        try await wait(until: { gate.held == 1 && gate.calls.count == 2 }, "the second ⌘W runs after the read")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref])
        gate.release(.done)
        switcher.cancel()
    }

    func testAClickOnAWindowWhoseCloseIsPendingCommitsNothingOnceItIsGone() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        var ended = 0
        switcher.onSessionEnded = { ended += 1 }
        switcher.open()
        switcher.apply(.operation(.close))
        let view = switcher.panel.switcherView
        view.mouseDown(with: try mouse(.leftMouseDown, onCellAt: 1, of: switcher))
        view.mouseUp(with: try mouse(.leftMouseUp, onCellAt: 1, of: switcher))
        XCTAssertEqual(ended, 1)
        XCTAssertFalse(switcher.panel.isVisible)
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { reads == 2 }, "the list is read again")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "the clicked window is gone, so nothing is focused")
        XCTAssertFalse(switcher.isOpen)
    }

    func testReopeningWhileACommitWaitsDropsTheOldCommit() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.commit()
        switcher.open()
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "the old switch focuses nothing")
        XCTAssertTrue(switcher.isOpen, "the new switch stays open")
        XCTAssertEqual(reads, 2, "the old close's read is dropped too")
        switcher.cancel()
    }

    // MARK: - Pointer input while keys wait

    func testAHoverAfterAWaitingCloseLeavesTheCloseOnItsWindow() async throws {
        let gate = GatedWindowOperator(holding: [.minimize])
        lists = [windows]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.minimize))
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        switcher.panel.switcherView.onHover(2)
        switcher.panel.switcherView.onHover(1)
        switcher.panel.switcherView.onHover(2)
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the waiting close runs after the read")
        XCTAssertEqual(gate.calls.map(\.operation), [.minimize, .close])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref], "⌘W was pressed on window 1")
        try await wait(until: { reads == 3 }, "the close is read")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[2].ref, "the hover applies after the close")
        switcher.cancel()
    }

    func testAHoverAfterAWaitingQuitLeavesTheQuitOnItsApp() async throws {
        let gate = GatedWindowOperator(holding: [.hideApp])
        lists = [windows]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.hideApp))
        switcher.apply(.operation(.quitApp))
        try await wait(until: { gate.held == 1 })
        switcher.panel.switcherView.onHover(3)
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the waiting quit runs after the read")
        XCTAssertEqual(gate.calls.map(\.operation), [.hideApp, .quitApp])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref], "⌘Q was pressed on App 1")
        switcher.cancel()
    }

    func testAHoverAfterAWaitingCloseThenAReleaseFocusesTheHoveredWindowAfterTheClose() async throws {
        let gate = GatedWindowOperator(holding: [.minimize])
        lists = [windows]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.minimize))
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        switcher.panel.switcherView.onHover(2)
        switcher.commit()
        gate.release(.done)
        try await wait(until: { gate.calls.count == 3 }, "the close, then the commit")
        XCTAssertEqual(gate.calls.map(\.operation), [.minimize, .close, .focus])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref, windows[2].ref])
        XCTAssertFalse(switcher.isOpen)
    }

    func testCancellingAfterAWaitingCloseAndAHoverDoesNothingMore() async throws {
        let gate = GatedWindowOperator(holding: [.minimize])
        lists = [windows]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.minimize))
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        switcher.panel.switcherView.onHover(2)
        switcher.cancel()
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(gate.calls.map(\.operation), [.minimize])
        XCTAssertEqual(reads, 1)
    }

    // MARK: - Reads that skip an app

    func testARefusedCloseThenAReadThatSkipsItsAppLeavesTheNextCloseOnThatWindow() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        // The read after the refused close times out on App 1, so window 1 is unknown, not gone.
        lists = [windows, [windows[0], windows[2], windows[3]]]
        skipping = [2: [windows[1].pid]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        gate.release(.refused("timed out"))
        try await wait(until: { gate.calls.count == 2 }, "the waiting close runs after the read")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref], "window 2 is never closed")
        XCTAssertEqual(switcher.model?.windows, windows, "window 1 stays listed where it was")
        gate.release(.done)
        switcher.cancel()
    }

    func testADeliveredQuitThenAReadThatSkipsItsAppLeavesTheNextQuitOnThatApp() async throws {
        let gate = GatedWindowOperator(holding: [.quitApp])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        skipping = [2: [windows[1].pid]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.quitApp))
        switcher.apply(.operation(.quitApp))
        try await wait(until: { gate.held == 1 })
        gate.release(.done) // App 1 is asking to save and does not answer the read
        try await wait(until: { gate.calls.count == 2 }, "the waiting quit runs after the read")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref], "App 2 is never quit")
        gate.release(.done)
        switcher.cancel()
    }

    func testAReleaseWhileACloseIsPendingFocusesItsWindowWhenTheReadSkipsItsApp() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        skipping = [2: [windows[1].pid]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.commit()
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the read, then the commit")
        XCTAssertEqual(gate.calls.map(\.operation), [.close, .focus])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[1].ref], "the save prompt comes forward, not window 2")
    }

    func testAnAppQuittingKeepsTheWindowsOfAnAppTheReadSkipped() async throws {
        let recorder = RecordingWindowOperator()
        // App 3 quit; App 1 did not answer the read that follows.
        lists = [windows, [windows[0], windows[2]]]
        skipping = [2: [windows[1].pid]]
        let switcher = controller(recorder)
        switcher.open()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        try await wait(until: { reads == 2 }, "an app quitting reads the list again")
        XCTAssertEqual(switcher.model?.windows, [windows[0], windows[1], windows[2]], "only the quit app's window leaves")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)
        switcher.cancel()
    }

    // MARK: - Settings

    func testTheShownWindowsSettingsFilterEachReadAndAChangeAppliesFromTheNextRead() async throws {
        let recorder = RecordingWindowOperator()
        var minimized = windows[1]
        minimized.isMinimized = true
        let notes = AppEntry(SourceApp(pid: 30, bundleIdentifier: "com.example.notes", name: "Notes"))
        var settings = Settings.default
        settings.shownWindows.minimized = false
        let switcher = SwitcherController(
            readWindows: { [windows] in WindowList(windows: [windows[0], minimized, windows[2]], windowlessApps: [notes]) },
            windowOperator: recorder,
            settings: { settings }
        )
        switcher.open()
        XCTAssertEqual(switcher.model?.items.map(\.id), [.window(windows[0].ref), .window(windows[2].ref)])
        settings.shownWindows.minimized = true
        settings.shownWindows.windowlessApps = true
        switcher.apply(.operation(.hideApp))
        try await wait(until: { switcher.model?.items.count == 4 }, "the read after the operation uses the new settings")
        XCTAssertEqual(switcher.model?.items.last, .app(notes))
        switcher.cancel()
    }

    func testCommittingAnAppCellActivatesItsApp() async throws {
        let recorder = RecordingWindowOperator()
        let notes = AppEntry(SourceApp(pid: 30, bundleIdentifier: "com.example.notes", name: "Notes"))
        var settings = Settings.default
        settings.shownWindows.windowlessApps = true
        let switcher = SwitcherController(
            readWindows: { [windows] in WindowList(windows: [windows[0]], windowlessApps: [notes]) },
            windowOperator: recorder,
            settings: { settings }
        )
        switcher.open()
        XCTAssertEqual(switcher.model?.selectedItem, .app(notes))
        switcher.apply(.operation(.close))
        switcher.commit()
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.operation), [.focus], "⌘W does nothing on an app cell")
        XCTAssertEqual(recorder.calls.map(\.window), [nil])
        XCTAssertEqual(recorder.calls.map(\.pid), [30])
    }

    private func readWindows() -> WindowList {
        reads += 1
        let windows = lists.count > 1 ? lists.removeFirst() : lists[0]
        return WindowList(windows: windows, skippedApps: (skipping[reads] ?? []).map { SkippedApp(pid: $0, reason: .timedOut) })
    }
}

/// Holds the operations it is told to until the test releases them, first in first out, as the serial operator would
/// run them; answers the others at once with `.done`.
private final class GatedWindowOperator: WindowOperator, @unchecked Sendable {
    private let lock = NSLock()
    private let holding: Set<WindowOperation>
    struct Call: Equatable {
        var operation: WindowOperation
        var window: HopCore.WindowRef?
    }

    private var recorded: [Call] = []
    private var waiting: [CheckedContinuation<OperationResult, Never>] = []

    init(holding: Set<WindowOperation>) {
        self.holding = holding
    }

    var calls: [Call] { lock.withLock { recorded } }
    var held: Int { lock.withLock { waiting.count } }

    func release(_ result: OperationResult) {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
        next?.resume(returning: result)
    }

    func perform(_ operation: WindowOperation, on window: WindowEntry) async -> OperationResult {
        await perform(Call(operation: operation, window: window.ref))
    }

    func perform(_ operation: WindowOperation, onApp _: AppEntry) async -> OperationResult {
        await perform(Call(operation: operation, window: nil))
    }

    private func perform(_ call: Call) async -> OperationResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                recorded.append(call)
                if holding.contains(call.operation) { waiting.append(continuation) } else { continuation.resume(returning: .done) }
            }
        }
    }
}

extension SwitcherViewModel {
    /// The listed windows, for tests whose lists have no app cells.
    var windows: [WindowEntry] { items.compactMap(\.window) }
    var selectedWindow: WindowEntry? { selectedItem?.window }
}
