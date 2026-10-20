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

    private func controller(_ windowOperator: RecordingWindowOperator) -> SwitcherController {
        SwitcherController(readWindows: { [unowned self] in
            reads += 1
            return lists.count > 1 ? lists.removeFirst() : lists[0]
        }, windowOperator: windowOperator)
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
        try await wait(until: { switcher.model?.entries.count == 3 }, "the closed window leaves the list")
        XCTAssertEqual(switcher.model?.entries[2].ref, windows[3].ref)
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
        XCTAssertEqual(switcher.model?.selectedEntry?.ref, windows[1].ref)
        switcher.apply(.operation(.close))
        try await wait(until: { switcher.model?.entries.count == 3 }, "the closed window leaves the list")
        XCTAssertEqual(recorder.calls.map(\.operation), [.close])
        XCTAssertEqual(recorder.calls.map(\.window), [windows[1].ref])
        XCTAssertEqual(switcher.model?.selectedEntry?.ref, windows[2].ref)
        try await wait(until: { reads == 2 }, "the list is read again")
        XCTAssertTrue(switcher.isOpen)
        XCTAssertEqual(switcher.model?.selectedEntry?.ref, windows[2].ref, "the refresh keeps the next window selected")
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
        XCTAssertEqual(switcher.model?.entries, windows)
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
        XCTAssertEqual(switcher.model?.entries, [])
        switcher.apply(.operation(.quitApp))
        switcher.commit()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(recorder.calls, [])
    }
}
