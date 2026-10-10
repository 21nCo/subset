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

        let restored = expectation(description: "restored")
        guardian.restore(after: 0) { restored.fulfill() }
        wait(for: [restored], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "rich")
        XCTAssertEqual(pasteboard.data(forType: customType), Data([1, 2, 3]))
    }

    func testPasteboardGuardSnapshotsAtFirstWrite() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DictateTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("old", forType: .string)

        let guardian = PasteboardGuard(pasteboard)
        // The user copies something while earlier insertion attempts run.
        pasteboard.clearContents()
        pasteboard.setString("copied meanwhile", forType: .string)
        guardian.write("transcript")

        let restored = expectation(description: "restored")
        guardian.restore(after: 0) { restored.fulfill() }
        wait(for: [restored], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "copied meanwhile")
    }

    func testPasteboardGuardKeepsNewerClipboardContent() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DictateTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)

        let guardian = PasteboardGuard(pasteboard)
        guardian.write("transcript")
        let checked = expectation(description: "checked")
        guardian.restore(after: 0) { checked.fulfill() }
        // The user copies something before the delayed restore fires.
        pasteboard.clearContents()
        pasteboard.setString("newer", forType: .string)

        wait(for: [checked], timeout: 2)
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
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

    func testSpeechGateSeesShortSpeechInsideALongPause() {
        let sampleRate = 16_000
        // 60 s of silence with 1 s of speech-level signal in the middle.
        var samples = [Float](repeating: 0, count: sampleRate * 60)
        for index in (sampleRate * 30)..<(sampleRate * 31) { samples[index] = index.isMultiple(of: 2) ? 0.02 : -0.02 }
        let overall = sqrt(samples.reduce(Float.zero) { $0 + $1 * $1 } / Float(samples.count))
        XCTAssertLessThan(overall, 0.0035)
        XCTAssertGreaterThan(WhisperCppBackend.peakWindowRMS(samples, windowSize: sampleRate / 2), 0.0035)
        // The production preparation path keeps the speech and trims the silence around it.
        let prepared = WhisperCppBackend.prepareSamplesForDictation(samples, sampleRate: sampleRate)
        XCTAssertNotNil(prepared)
        XCTAssertLessThan(prepared?.count ?? .max, sampleRate * 2)
    }
}
