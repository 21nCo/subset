import AppKit
@testable import Hop
import HopCore
import XCTest

/// The tap's side of a switch: what the callback does before the switcher has opened.
@MainActor
final class SwitchShortcutTests: XCTestCase {
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

    /// A shortcut on the default ⌥Tab whose window list takes 0.3 s to read, the most `WindowListController` waits.
    private func shortcut(_ recorder: RecordingWindowOperator) -> (SwitchShortcutController, SwitcherController) {
        let switcher = SwitcherController(readWindows: { [unowned self] in
            reads += 1
            Thread.sleep(forTimeInterval: 0.3)
            return windows
        }, windowOperator: recorder)
        let defaults = UserDefaults(suiteName: "SwitchShortcutTests.\(UUID().uuidString)")!
        return (SwitchShortcutController(switcher: switcher, store: ShortcutStore(defaults: defaults), isTrusted: { true }), switcher)
    }

    private func key(_ kind: KeyEvent.Kind, _ keyCode: UInt16, _ modifiers: ModifierMask) -> TapInput {
        .key(KeyEvent(kind, keyCode: keyCode, modifiers: modifiers))
    }

    private func wait(until condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testKeysBeforeTheSwitcherOpensAreHeldAndAppliedInOrderWithoutReadingWindowsInTheTap() async throws {
        let recorder = RecordingWindowOperator()
        let (tap, switcher) = shortcut(recorder)
        let started = ContinuousClock.now
        XCTAssertEqual(tap.handle(key(.keyDown, KeyCode.tab, .option)), .swallow)
        XCTAssertEqual(tap.handle(key(.keyUp, KeyCode.tab, .option)), .swallow)
        XCTAssertEqual(tap.handle(key(.keyDown, KeyCode.tab, .option)), .swallow)
        XCTAssertEqual(tap.handle(key(.flagsChanged, 0x3A, [])), .pass)
        XCTAssertLessThan(ContinuousClock.now - started, .milliseconds(100), "the callback never waits for the list")
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(recorder.calls.isEmpty)
        try await wait(until: { !recorder.calls.isEmpty })
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(recorder.calls.map(\.operation), [.focus])
        XCTAssertEqual(recorder.calls.map(\.window), [windows[2].ref], "opened on 1, stepped to 2, committed")
        XCTAssertFalse(switcher.isOpen)
    }

    func testEscBeforeTheSwitcherOpensReadsNothingAndFocusesNothing() async throws {
        let recorder = RecordingWindowOperator()
        let (tap, switcher) = shortcut(recorder)
        XCTAssertEqual(tap.handle(key(.keyDown, KeyCode.tab, .option)), .swallow)
        XCTAssertEqual(tap.handle(key(.keyDown, KeyCode.escape, .option)), .swallow)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(reads, 0)
        XCTAssertTrue(recorder.calls.isEmpty)
        XCTAssertFalse(switcher.isOpen)
    }
}
