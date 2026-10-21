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

    /// `windows` with bundle IDs, so their apps can be excluded: App n is com.example.app<n>.
    private var bundled: [WindowEntry] {
        windows.map { entry in
            var entry = entry
            entry.bundleIdentifier = "com.example.app\(entry.pid - 10)"
            return entry
        }
    }

    func testAWindowMinimizedWithMinimizedWindowsOffIsNotFocusedByAWaitingReleaseWhenItsAppDoesNotAnswer() async throws {
        let gate = GatedWindowOperator(holding: [.minimize])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        skipping = [2: [windows[1].pid]]
        var settings = Settings.default
        settings.shownWindows.minimized = false
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate, settings: { settings })
        switcher.open()
        switcher.apply(.operation(.minimize))
        switcher.commit()
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the read, then the commit")
        XCTAssertEqual(gate.calls.map(\.operation), [.minimize, .focus])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref], "the minimized window stays minimized")
    }

    func testWithTheCurrentAppExcludedAQuickSwitchFocusesThePreviousEligibleWindow() async throws {
        let recorder = RecordingWindowOperator()
        let windows = bundled
        lists = [windows]
        var settings = Settings.default
        settings.exclude("com.example.app0")
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: recorder, settings: { settings })
        switcher.open()
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [1, 2, 3].map { windows[$0].ref })
        switcher.commit()
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.window), [windows[1].ref], "not the one after it")
    }

    func testASwitcherThatOpenedEmptyOpensOnThePreviousEligibleWindowWhenASettingsChangeListsWindows() async throws {
        let recorder = RecordingWindowOperator()
        let windows = bundled
        lists = [windows]
        var settings = Settings.default
        (0..<4).forEach { settings.exclude("com.example.app\($0)") }
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: recorder, settings: { settings })
        switcher.open()
        XCTAssertEqual(switcher.model?.items, [])
        (1..<4).forEach { settings.include("com.example.app\($0)") }
        switcher.settingsChanged()
        try await wait(until: { switcher.model?.items.count == 3 }, "the read after the change")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)
        switcher.cancel()
    }

    func testASettingsChangeAppliesToTheOpenSwitcherAtOnce() async throws {
        let recorder = RecordingWindowOperator()
        var windows = bundled
        windows[2].isMinimized = true
        lists = [windows]
        var settings = Settings.default
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: recorder, settings: { settings })
        let tap = SwitchShortcutController(switcher: switcher, shortcut: .default, isTrusted: { true })
        switcher.open()
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)

        settings.exclude("com.example.app1")
        tap.settingsChanged(settings)
        XCTAssertTrue(switcher.isOpen, "the same shortcut keeps the switch going")
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [0, 2, 3].map { windows[$0].ref }, "with no read in between")
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[2].ref)

        settings.shownWindows.minimized = false
        tap.settingsChanged(settings)
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [0, 3].map { windows[$0].ref })
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[3].ref)
        try await wait(until: { reads >= 3 }, "each change reads the list again")
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [0, 3].map { windows[$0].ref }, "the reads keep the filter")
        switcher.commit()
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.window), [windows[3].ref])
    }

    func testAReleaseWaitingOnACloseDoesNotFocusAWindowASettingsChangeRemoved() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        let windows = bundled
        lists = [windows, [windows[0], windows[2], windows[3]]]
        // App 2 answers no read after the switcher opened.
        skipping = [2: [windows[2].pid], 3: [windows[2].pid], 4: [windows[2].pid]]
        var settings = Settings.default
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate, settings: { settings })
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.commit()
        try await wait(until: { gate.held == 1 })
        settings.exclude("com.example.app2")
        switcher.settingsChanged()
        XCTAssertFalse(switcher.model?.windows.contains { $0.ref == windows[2].ref } ?? true, "it leaves at once")
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the read, then the commit")
        XCTAssertEqual(gate.calls.map(\.operation), [.close, .focus])
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[3].ref], "window 2 is never focused")
    }

    func testAClickWaitingOnACloseCommitsNothingWhenASettingsChangeRemovedItsWindow() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        let windows = bundled
        lists = [windows, [windows[0], windows[2], windows[3]]]
        // App 3 answers no read after the switcher opened.
        skipping = [2: [windows[3].pid], 3: [windows[3].pid], 4: [windows[3].pid]]
        var settings = Settings.default
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate, settings: { settings })
        var ended = 0
        switcher.onSessionEnded = { ended += 1 }
        switcher.open()
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        let view = switcher.panel.switcherView
        view.mouseDown(with: try mouse(.leftMouseDown, onCellAt: 3, of: switcher))
        view.mouseUp(with: try mouse(.leftMouseUp, onCellAt: 3, of: switcher))
        settings.exclude("com.example.app3")
        switcher.settingsChanged()
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(ended, 1, "the click ended the switch")
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "the clicked window is no longer listed")
    }

    // MARK: - Search and the same-app shortcut

    func testACommitWithNoMatchingWindowCancels() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        for character in "zz" { switcher.apply(.type(character)) }
        XCTAssertEqual(switcher.model?.items.count, 0)
        XCTAssertEqual(switcher.model?.emptyText, "No matching windows")
        switcher.commit()
        XCTAssertFalse(switcher.isOpen)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(recorder.calls.isEmpty, "nothing is focused")
    }

    func testTypingCommitsTheFirstMatchAndTheQueryClearsWhenTheSwitcherHides() async throws {
        let recorder = RecordingWindowOperator()
        lists = [windows]
        let switcher = controller(recorder)
        switcher.open()
        for character in "Window 3" { switcher.apply(.type(character)) }
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "Search: Window 3")
        switcher.commit()
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "", "the hidden panel keeps no query")
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.window), [windows[3].ref])
        switcher.open()
        XCTAssertEqual(switcher.model?.query, "", "a new switch starts with no query")
        XCTAssertEqual(switcher.model?.items.count, 4)
        for character in "Win" { switcher.apply(.type(character)) }
        switcher.cancel()
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
    }

    func testReleasingOnNoMatchWhileACloseIsPendingCancelsEvenIfTheReadListsAMatch() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        let notes = WindowEntry(
            app: SourceApp(pid: 20, bundleIdentifier: nil, name: "Notes"),
            window: SourceWindow(ref: HopCore.WindowRef(rawValue: 20), title: "zz notes",
                                 subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: nil
        )
        lists = [windows, [windows[0], notes, windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        for character in "zz" { switcher.apply(.type(character)) }
        XCTAssertEqual(switcher.model?.emptyText, "No matching windows")
        switcher.commit()
        XCTAssertFalse(switcher.panel.isVisible)
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "the release cancelled: nothing is focused")
        XCTAssertFalse(switcher.isOpen)
    }

    func testAReleaseWaitingOnACloseDropsTheQueryAndFocusesAmongTheMatches() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        for character in "Window" { switcher.apply(.type(character)) }
        switcher.apply(.step(.forward))
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, windows[1].ref)
        switcher.apply(.operation(.close))
        switcher.commit()
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "", "the query goes at the release")
        XCTAssertEqual(switcher.model?.query, "")
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "", "the close's result draws nothing")
        try await wait(until: { gate.calls.count == 2 }, "the list is read again, then the release commits")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref])
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "", "nothing drew the query again")
        XCTAssertFalse(switcher.panel.isVisible)
    }

    func testAReleaseBehindAWaitingCloseDrawsNoQueryAndCommitsAmongTheMatches() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]], [windows[0], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        for character in "Window" { switcher.apply(.type(character)) }
        switcher.apply(.step(.forward))
        switcher.apply(.operation(.close))
        switcher.apply(.operation(.close))
        switcher.commit()
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "", "the first close's result draws nothing")
        try await wait(until: { gate.held == 1 && gate.calls.count == 2 }, "the second ⌘W runs after the read")
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
        gate.release(.done)
        try await wait(until: { gate.calls.count == 3 }, "the release commits after the second read")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref, windows[3].ref])
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
        XCTAssertFalse(switcher.panel.isVisible)
    }

    /// A window of an app with this pid and name, titled `title`, with ref `ref`.
    private func entry(_ ref: UInt64, _ title: String, app: String, pid: pid_t) -> WindowEntry {
        WindowEntry(
            app: SourceApp(pid: pid, bundleIdentifier: nil, name: app),
            window: SourceWindow(ref: HopCore.WindowRef(rawValue: ref), title: title,
                                 subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: nil
        )
    }

    func testAWaitingCloseKeyPressedOnNoMatchActsOnNothingTheReadAddsAndTheReleaseCancels() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], entry(20, "zz notes", app: "Notes", pid: 20), windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        for character in "zz" { switcher.apply(.type(character)) }
        XCTAssertEqual(switcher.model?.emptyText, "No matching windows")
        switcher.apply(.operation(.close))
        switcher.commit()
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "neither the waiting ⌘W nor the release acted on zz notes")
        XCTAssertFalse(switcher.isOpen, "the release cancelled")
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "")
    }

    func testAWaitingCloseKeyPressedOnNoMatchWhileHeldActsOnNothingTheReadAdds() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        let notes = entry(20, "zz notes", app: "Notes", pid: 20)
        lists = [windows, [windows[0], notes, windows[2], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        for character in "zz" { switcher.apply(.type(character)) }
        switcher.apply(.operation(.close))
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { reads == 2 }, "the close's read")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(gate.calls.map(\.operation), [.close], "the waiting ⌘W did nothing to zz notes")
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [notes.ref], "once nothing waits, the new match is listed")
        XCTAssertEqual(switcher.panel.switcherView.accessibilityQueryText, "Search: zz")
        switcher.cancel()
    }

    func testNoSearchTextOutlivesAReleaseWaitingOnOneOrTwoCloses() async throws {
        for closes in 1...2 {
            let gate = GatedWindowOperator(holding: [.close])
            lists = [windows]
            let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
            switcher.open()
            for character in "Window" { switcher.apply(.type(character)) }
            for _ in 0..<closes { switcher.apply(.operation(.close)) }
            switcher.commit()
            XCTAssertFalse(switcher.panel.isVisible)
            XCTAssertEqual(searchText(in: switcher), [], "\(closes) waiting: the controller and its model keep no query")
            try await wait(until: { gate.held == 1 })
            switcher.cancel()
            gate.release(.done)
        }
    }

    func testKeysTypedBehindAWaitingCloseAreWorkedOutAtTheReleaseAndAppliedInTurn() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        lists = [windows, [windows[0], windows[2], windows[3]], [windows[0], windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        for character in "Window" { switcher.apply(.type(character)) }
        switcher.apply(.step(.forward))
        switcher.apply(.operation(.close))
        switcher.apply(.operation(.close))
        for character in " 3" { switcher.apply(.type(character)) }
        switcher.apply(.deleteBackward)
        switcher.apply(.type("3"))
        switcher.commit()
        XCTAssertEqual(searchText(in: switcher), [], "nothing typed waits as text once the panel hides")
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { gate.held == 1 && gate.calls.count == 2 }, "the waiting ⌘W runs after the read")
        gate.release(.done)
        try await wait(until: { gate.calls.count == 3 }, "the release commits after the second read")
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref, windows[3].ref],
                       "the ⌘W before the typing closed Window 1's follower; the typing then chose Window 3")
        XCTAssertFalse(switcher.isOpen)
    }

    func testKeysTypedBehindAWaitingCloseToNoMatchCancelEvenIfAReadAddsAMatch() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        let notes = entry(20, "zz notes", app: "Notes", pid: 20)
        lists = [windows, [windows[0], windows[2], windows[3]], [windows[0], notes, windows[3]]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        switcher.apply(.operation(.close))
        switcher.apply(.operation(.close))
        for character in "zz" { switcher.apply(.type(character)) }
        switcher.commit()
        XCTAssertEqual(searchText(in: switcher), [])
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { gate.held == 1 && gate.calls.count == 2 }, "the waiting ⌘W runs after the read")
        gate.release(.done)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertEqual(gate.calls.map(\.window), [windows[1].ref, windows[2].ref], "zz notes is not focused")
        XCTAssertFalse(switcher.isOpen, "the release cancelled")
    }

    func testAReleaseWaitingOnACloseFocusesTheFollowerInTheOrderTheSearchListed() async throws {
        let gate = GatedWindowOperator(holding: [.close])
        // Recency C, A, B; "saf" lists the Safari windows first: A, B, C.
        let guide = entry(30, "Safe guide", app: "TextEdit", pid: 30)
        let docs = entry(31, "Docs", app: "Safari", pid: 31)
        let news = entry(32, "News", app: "Safari", pid: 31)
        lists = [[guide, docs, news], [guide, docs]]
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: gate)
        switcher.open()
        for character in "saf" { switcher.apply(.type(character)) }
        XCTAssertEqual(switcher.model?.windows.map(\.ref), [docs.ref, news.ref, guide.ref])
        switcher.apply(.step(.forward))
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, news.ref)
        switcher.apply(.operation(.close))
        switcher.commit()
        try await wait(until: { gate.held == 1 })
        gate.release(.done)
        try await wait(until: { gate.calls.count == 2 }, "the list is read again, then the release commits")
        XCTAssertEqual(gate.calls.map(\.window), [news.ref, guide.ref], "News was followed by Safe guide, as listed")
    }

    func testDeletingAfterARefreshShowsTheIconOfEachAppListedAgain() async throws {
        let recorder = RecordingWindowOperator()
        let own = WindowEntry(
            app: SourceApp(pid: ProcessInfo.processInfo.processIdentifier, bundleIdentifier: nil, name: "Tests"),
            window: SourceWindow(ref: HopCore.WindowRef(rawValue: 30), title: "Own",
                                 subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: nil
        )
        lists = [[windows[0], own, windows[1]]]
        let switcher = controller(recorder)
        switcher.open()
        XCTAssertNotNil(switcher.icons[own.pid])
        for character in "Window 1" { switcher.apply(.type(character)) }
        switcher.apply(.operation(.minimize))
        try await wait(until: { reads == 2 }, "the list is read again while only Window 1 is listed")
        for _ in "Window 1" { switcher.apply(.deleteBackward) }
        XCTAssertEqual(switcher.model?.items.count, 3)
        XCTAssertNotNil(switcher.icons[own.pid], "the app listed again keeps its icon")
        switcher.cancel()
    }

    func testTheSameAppShortcutListsOnlyTheFrontmostAppsWindows() async throws {
        let recorder = RecordingWindowOperator()
        let app = SourceApp(pid: 77, bundleIdentifier: "com.example.pages", name: "Pages")
        let pages = (0..<3).map { index in
            WindowEntry(
                app: app,
                window: SourceWindow(ref: HopCore.WindowRef(rawValue: UInt64(70 + index)), title: "Doc \(index)",
                                     subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
                frame: CGRect(x: 0, y: 0, width: 400, height: 300),
                display: nil
            )
        }
        lists = [[pages[0], windows[0], pages[1], windows[1], pages[2]]]
        var frontmost: pid_t? = 77
        let switcher = SwitcherController(readWindows: readWindows, windowOperator: recorder, frontmostApp: { frontmost })
        switcher.open(.frontmostApp)
        XCTAssertEqual(switcher.model?.windows.map(\.ref), pages.map(\.ref))
        XCTAssertEqual(switcher.model?.selectedWindow?.ref, pages[1].ref, "the app's second most recent window")
        switcher.commit()
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(recorder.calls.map(\.window), [pages[1].ref])
        frontmost = nil
        switcher.open(.frontmostApp)
        XCTAssertEqual(switcher.model?.items.count, 0)
        switcher.cancel()
        switcher.open()
        XCTAssertEqual(switcher.model?.items.count, 5, "the switch shortcut still lists every window")
    }

    /// The search text kept anywhere in `value`'s stored state: a non-empty `query`, or a typed character or Delete
    /// that waits. Goes `depth` levels down.
    private func searchText(in value: Any, depth: Int = 8) -> [String] {
        guard depth > 0 else { return [] }
        return Mirror(reflecting: value).children.flatMap { child -> [String] in
            switch child.value {
            case let query as String where child.label == "query": query.isEmpty ? [] : [query]
            case let event as SwitchSession.Event:
                switch event {
                case .type, .deleteBackward: [String(describing: event)]
                default: []
                }
            default: searchText(in: child.value, depth: depth - 1)
            }
        }
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
