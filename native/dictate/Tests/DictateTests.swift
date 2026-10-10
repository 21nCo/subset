import AppKit
import XCTest
@testable import Dictate

@MainActor
final class DictateTests: XCTestCase {
    func testQuickFunctionKeyTapStillDeliversRelease() {
        let monitor = GlobalHotkeyMonitor()
        var events: [String] = []
        monitor.start(onPress: { events.append("press") }, onRelease: { events.append("release") }, onCancel: { events.append("cancel") })
        defer { monitor.stop() }
        let start = Date()

        monitor.handleFunctionKey(isPressed: true, at: start)
        // Released well inside the 0.2 s debounce window.
        monitor.handleFunctionKey(isPressed: false, at: start.addingTimeInterval(0.05))

        XCTAssertEqual(events, ["press", "release"])
    }

    func testPressesInsideDebounceWindowAreIgnored() {
        let monitor = GlobalHotkeyMonitor()
        var presses = 0
        monitor.start(onPress: { presses += 1 }, onRelease: {}, onCancel: {})
        defer { monitor.stop() }
        let start = Date()

        monitor.handleFunctionKey(isPressed: true, at: start)
        monitor.handleFunctionKey(isPressed: false, at: start.addingTimeInterval(0.05))
        monitor.handleFunctionKey(isPressed: true, at: start.addingTimeInterval(0.1))

        XCTAssertEqual(presses, 1)
    }

    func testSettingsWithoutBackendKindDecodeToLocalWhisper() throws {
        let settings = try JSONDecoder().decode(DictationSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.backendKind, DictationSettings.default.backendKind)
        XCTAssertEqual(settings.deployedModelName, DictationSettings.default.deployedModelName)
    }

    func testReleasingDuringPendingStartAbandonsTheSession() {
        let manager = DictationManager(store: SharedTranscriptStore(suiteName: "DictateTests.\(UUID().uuidString)"))
        manager.startDictation()
        XCTAssertTrue(manager.isBusy)

        // Release before the permission prompt or model preparation finished.
        manager.stopDictationAndInsert()

        XCTAssertFalse(manager.isBusy)
        XCTAssertFalse(manager.transcriptState.isRecording)
    }

    func testPasteboardGuardRestoresEveryType() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DictateTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        let customType = NSPasteboard.PasteboardType("dev.subset.dictate.test")
        let item = NSPasteboardItem()
        item.setString("rich", forType: .string)
        item.setData(Data([1, 2, 3]), forType: customType)
        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        let guardian = PasteboardGuard(pasteboard)
        guardian.write("transcript")
        XCTAssertEqual(pasteboard.string(forType: .string), "transcript")
        guardian.restore(after: 0)

        let restored = expectation(description: "restored")
        DispatchQueue.main.async {
            XCTAssertEqual(pasteboard.string(forType: .string), "rich")
            XCTAssertEqual(pasteboard.data(forType: customType), Data([1, 2, 3]))
            restored.fulfill()
        }
        wait(for: [restored], timeout: 2)
    }

    func testPasteboardGuardKeepsNewerClipboardContent() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DictateTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        let guardian = PasteboardGuard(pasteboard)
        guardian.write("transcript")
        guardian.restore(after: 0)
        // The user copies something before the delayed restore fires.
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)

        let checked = expectation(description: "checked")
        DispatchQueue.main.async {
            XCTAssertEqual(pasteboard.string(forType: .string), "newer")
            checked.fulfill()
        }
        wait(for: [checked], timeout: 2)
    }

    func testSystemEventsScriptCompilesWithEveryHandler() throws {
        XCTAssertNoThrow(try ActiveAppTextInjector.systemEventsScript())
        for handler in ActiveAppTextInjector.SystemEventsHandler.allCases {
            XCTAssertTrue(
                ActiveAppTextInjector.systemEventsScriptSource.contains("on \(handler.rawValue)(bundleID, appName, theText)"),
                "missing handler \(handler.rawValue)"
            )
        }
    }
}
