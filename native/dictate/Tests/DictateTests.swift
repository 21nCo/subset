import AppKit
import CryptoKit
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

    func testSegmentTextIsDecodedAsUTF8() {
        let text = "café € \u{201C}quoted\u{201D}"
        let decoded = text.withCString { WhisperCppWrapper.string(fromSegmentText: $0) }
        XCTAssertEqual(decoded, text)
        // Valid text that starts with U+FEFF keeps it, as Swift's own decoding does.
        let withBOM = "\u{FEFF}text"
        XCTAssertEqual(withBOM.withCString { WhisperCppWrapper.string(fromSegmentText: $0) }, withBOM)
        XCTAssertEqual(WhisperCppWrapper.string(fromSegmentText: nil), "")
        XCTAssertEqual("".withCString { WhisperCppWrapper.string(fromSegmentText: $0) }, "")
    }

    func testSegmentTextWithASplitCharacterKeepsTheRest() {
        func decode(_ bytes: [UInt8]) -> String {
            let cString = bytes.map { CChar(bitPattern: $0) } + [0]
            return cString.withUnsafeBufferPointer { WhisperCppWrapper.string(fromSegmentText: $0.baseAddress) }
        }
        // Each case matches Swift's own replacement decoding: one U+FFFD per maximal ill-formed part, valid text kept.
        let cases: [[UInt8]] = [
            Array("ok ".utf8) + [0xE2, 0x82] + Array(" text".utf8),  // "€" cut after two bytes, then more text
            Array("ok ".utf8) + [0xE2, 0x82],                        // cut at the end
            [0xFF] + Array("caf\u{00E9}".utf8),                      // a byte that never starts a sequence
            [0xED, 0xA0, 0x80] + Array("x".utf8),                    // an encoded surrogate
            [0xF0, 0x9F, 0x98] + Array(" \u{1F600}".utf8),           // a cut emoji before a whole one
            [0xFF, 0xEF, 0xBB, 0xBF, 0x5A],                          // a U+FEFF after a bad byte is kept
            [0xEF, 0xBB, 0xBF] + Array("caf\u{00E9}".utf8),          // and so is a leading one
        ]
        for bytes in cases {
            XCTAssertEqual(decode(bytes), String(decoding: bytes, as: UTF8.self), "\(bytes)")
        }
        XCTAssertEqual(decode(Array("ok ".utf8) + [0xE2, 0x82] + Array(" text".utf8)), "ok \u{FFFD} text")
    }

    func testModelDownloadsArePinnedToACommitAndAHash() {
        XCTAssertEqual(WhisperModelCatalog.revision.count, 40)
        for preset in WhisperModelPreset.allCases {
            let descriptor = WhisperModelCatalog.descriptor(for: preset)
            for file in [descriptor.ggml, descriptor.coreMLArchive] {
                XCTAssertTrue(
                    file.downloadURL.absoluteString.hasPrefix("https://huggingface.co/ggerganov/whisper.cpp/resolve/\(WhisperModelCatalog.revision)/"),
                    file.downloadURL.absoluteString
                )
                XCTAssertFalse(file.downloadURL.path.contains("/resolve/main/"))
                XCTAssertEqual(file.downloadURL.lastPathComponent, file.filename)
                XCTAssertNotNil(file.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression), file.filename)
                XCTAssertGreaterThan(file.size, 0)
            }
        }
    }

    func testDownloadVerificationRejectsChangedOrTruncatedFiles() throws {
        let content = Data("test-model-bytes".utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test-\(UUID().uuidString).bin")
        try content.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let digest = SHA256.hash(data: content).map { String(format: "%02x", $0) }.joined()
        let placeholderURL = URL(string: "https://example.invalid/test-model.bin")!
        let pinned = WhisperModelFile(filename: "test-model.bin", downloadURL: placeholderURL, sha256: digest, size: Int64(content.count))

        XCTAssertNoThrow(try WhisperModelDownloadService.verify(fileAt: url, matches: pinned))

        let otherHash = WhisperModelFile(filename: "test-model.bin", downloadURL: placeholderURL, sha256: String(repeating: "0", count: 64), size: Int64(content.count))
        XCTAssertThrowsError(try WhisperModelDownloadService.verify(fileAt: url, matches: otherHash)) { error in
            guard case WhisperModelDownloadServiceError.checksumMismatch = error else { return XCTFail("\(error)") }
        }

        let longer = WhisperModelFile(filename: "test-model.bin", downloadURL: placeholderURL, sha256: digest, size: Int64(content.count) + 1)
        XCTAssertThrowsError(try WhisperModelDownloadService.verify(fileAt: url, matches: longer)) { error in
            guard case WhisperModelDownloadServiceError.sizeMismatch = error else { return XCTFail("\(error)") }
        }
        // A file of the wrong size on disk is not treated as a ready model.
        XCTAssertNil(WhisperModelManager.completeModel(url, pinned: longer))
        XCTAssertEqual(WhisperModelManager.completeModel(url, pinned: pinned), url)
        // A link to a complete model elsewhere counts as complete; the link's own size does not matter.
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test-link-\(UUID().uuidString).bin")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
        defer { try? FileManager.default.removeItem(at: link) }
        XCTAssertEqual(WhisperModelManager.completeModel(link, pinned: pinned), link)
        XCTAssertNil(WhisperModelManager.completeModel(link, pinned: longer))
    }

    func testInstallingAModelReplacesAStaleFileButNeverAFolder() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("dictate-test-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func download(_ text: String) throws -> URL {
            let url = root.appendingPathComponent("download-\(UUID().uuidString)")
            try Data(text.utf8).write(to: url)
            return url
        }

        // A stale (truncated) model file is replaced.
        let model = root.appendingPathComponent("ggml-test.bin")
        try Data("stale".utf8).write(to: model)
        try WhisperModelDownloadService.install(try download("test-model-bytes"), at: model)
        XCTAssertEqual(try String(contentsOf: model, encoding: .utf8), "test-model-bytes")

        // A folder where the model belongs is refused, and it and its contents survive.
        let folder = root.appendingPathComponent("ggml-folder.bin", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let keep = folder.appendingPathComponent("keep.txt")
        try Data("test-keep".utf8).write(to: keep)
        XCTAssertThrowsError(try WhisperModelDownloadService.checkReplaceable(folder)) { error in
            guard case WhisperModelDownloadServiceError.destinationIsDirectory = error else { return XCTFail("\(error)") }
        }
        XCTAssertThrowsError(try WhisperModelDownloadService.install(try download("test-model-bytes"), at: folder))
        XCTAssertEqual(try String(contentsOf: keep, encoding: .utf8), "test-keep")
    }
}
