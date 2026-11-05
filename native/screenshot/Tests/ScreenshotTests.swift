import AppKit
import Carbon.HIToolbox
import XCTest
@testable import Screenshot

@MainActor
final class ScreenshotTests: XCTestCase {
    func testFileNamePatternExpandsDateAndTime() {
        let suite = UserDefaults(suiteName: "ScreenshotTests.filename")!
        suite.removePersistentDomain(forName: "ScreenshotTests.filename")
        let preferences = AppPreferences(defaults: suite)
        preferences.fileNamePattern = "Capture {date} {time}"
        let date = Date(timeIntervalSince1970: 0)

        let value = preferences.formattedFileName(at: date)
        // The pattern uses the local calendar day, which differs by time zone.
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"

        XCTAssertTrue(value.hasPrefix("Capture \(day.string(from: date)) "), value)
        XCTAssertFalse(value.contains("{date}"))
        XCTAssertFalse(value.contains("{time}"))
    }

    func testAnnotationProjectRoundTrips() throws {
        let image = NSImage(size: CGSize(width: 20, height: 20))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        CGRect(x: 0, y: 0, width: 20, height: 20).fill()
        image.unlockFocus()
        let project = EditorProject(
            imageData: try image.encodedData(format: "png"),
            annotations: [
                AnnotationItem(
                    tool: .arrow,
                    points: [CodablePoint(CGPoint(x: 0.1, y: 0.2)), CodablePoint(CGPoint(x: 0.8, y: 0.9))],
                    rect: CodableRect(CGRect(x: 0.1, y: 0.2, width: 0.7, height: 0.7)),
                    color: .accent,
                    lineWidth: 4,
                    text: "",
                    counter: nil
                )
            ],
            background: BackgroundConfiguration(style: .gradient),
            canvasCrop: nil
        )

        let data = try JSONEncoder().encode(project)
        let decoded = try JSONDecoder().decode(EditorProject.self, from: data)

        XCTAssertEqual(decoded.version, 1)
        XCTAssertEqual(decoded.annotations.first?.tool, .arrow)
        XCTAssertEqual(decoded.background.style, .gradient)
        XCTAssertFalse(decoded.imageData.isEmpty)
    }

    func testCloudUploadResponseUsesSnakeCaseConversion() throws {
        let data = #"{"id":"abc123","share_url":"https://share.example.com/s/abc123","download_url":"https://share.example.com/download/abc123"}"#.data(using: .utf8)!
        let response = try JSONDecoder().decode(CloudUploadResponse.self, from: data)

        XCTAssertEqual(response.id, "abc123")
        XCTAssertEqual(response.shareURL.host, "share.example.com")
    }

    func testHostedSharingIsOffUntilConfigured() {
        let suite = UserDefaults(suiteName: "ScreenshotTests.cloud")!
        suite.removePersistentDomain(forName: "ScreenshotTests.cloud")
        let preferences = AppPreferences(defaults: suite)

        XCTAssertEqual(preferences.cloudBaseURL, "")
        XCTAssertNil(CloudShareService.validatedBaseURL(""))
        XCTAssertNil(CloudShareService.validatedBaseURL("http://share.example.com"))
        XCTAssertNil(CloudShareService.validatedBaseURL("ftp://share.example.com"))
        XCTAssertNotNil(CloudShareService.validatedBaseURL(" https://share.example.com "))
        XCTAssertNotNil(CloudShareService.validatedBaseURL("http://localhost:8787"))
    }

    func testHistoryPersistsAndClearsCloudMetadata() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        let exports = base.appendingPathComponent("Exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(rootDirectory: archive)
        let image = NSImage(size: CGSize(width: 32, height: 24))
        image.lockFocus()
        NSColor.systemIndigo.setFill()
        CGRect(x: 0, y: 0, width: 32, height: 24).fill()
        image.unlockFocus()

        let record = try store.saveImage(image, kind: .area, preferredDirectory: exports)
        let shareURL = URL(string: "https://share.example.com/s/example")!
        store.updateCloud(id: record.id, shareURL: shareURL, cloudID: "example")
        store.updateTags(id: record.id, tags: ["design", "review"])

        XCTAssertTrue(FileManager.default.fileExists(atPath: record.fileURL.path))
        XCTAssertEqual(store.records.first?.cloudShareURL, shareURL)
        XCTAssertEqual(store.records.first?.tags, ["design", "review"])

        // Reload from disk so the assertions cover what persist() wrote.
        let reloaded = HistoryStore(rootDirectory: archive)
        XCTAssertEqual(reloaded.records.first?.cloudShareURL, shareURL)
        XCTAssertEqual(reloaded.records.first?.tags, ["design", "review"])

        store.clearCloud(id: record.id)
        let cleared = HistoryStore(rootDirectory: archive)
        XCTAssertNil(cleared.records.first?.cloudShareURL)
        XCTAssertNil(cleared.records.first?.cloudID)

        store.delete(store.records[0])
        XCTAssertTrue(store.records.isEmpty)
    }

    func testSelectionMovesAnnotationAndUndoRestoresIt() {
        let session = EditorSession(image: NSImage(size: CGSize(width: 100, height: 100)), record: nil)
        session.selectedTool = .select
        session.annotations = [
            AnnotationItem(
                tool: .rectangle,
                points: [CodablePoint(CGPoint(x: 0.2, y: 0.2)), CodablePoint(CGPoint(x: 0.4, y: 0.4))],
                rect: CodableRect(CGRect(x: 0.2, y: 0.2, width: 0.2, height: 0.2)),
                color: .accent,
                lineWidth: 4,
                text: "",
                counter: nil
            )
        ]

        session.beginSelection(at: CGPoint(x: 0.3, y: 0.3))
        session.endSelection(at: CGPoint(x: 0.5, y: 0.6))
        XCTAssertEqual(session.annotations[0].rect.x, 0.4, accuracy: 0.0001)
        XCTAssertEqual(session.annotations[0].rect.y, 0.5, accuracy: 0.0001)

        session.undo()
        XCTAssertEqual(session.annotations[0].rect.x, 0.2, accuracy: 0.0001)
        XCTAssertEqual(session.annotations[0].rect.y, 0.2, accuracy: 0.0001)
    }

    func testOCRRecognizesRenderedText() async throws {
        let image = NSImage(size: CGSize(width: 700, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        CGRect(x: 0, y: 0, width: 700, height: 180).fill()
        NSString(string: "Screenshot").draw(
            at: CGPoint(x: 32, y: 48),
            withAttributes: [
                .font: NSFont.systemFont(ofSize: 72, weight: .bold),
                .foregroundColor: NSColor.black,
            ]
        )
        image.unlockFocus()

        let result = try await OCRService().recognize(image: image, preserveLineBreaks: true)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Screenshot"), result.text)
    }

    func testImageWithoutSaveActionStaysInArchiveOnly() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let archive = base.appendingPathComponent("Archive", isDirectory: true)
        let exports = base.appendingPathComponent("Exports", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let store = HistoryStore(rootDirectory: archive)
        let image = NSImage(size: CGSize(width: 8, height: 8))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        CGRect(x: 0, y: 0, width: 8, height: 8).fill()
        image.unlockFocus()

        let record = try store.saveImage(image, kind: .area, preferredDirectory: exports, savesToExportLocation: false)

        XCTAssertEqual(record.fileURL, record.thumbnailURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: record.fileURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: exports.path))
    }

    func testUniqueURLNeverReusesAnExistingRecordingName() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data().write(to: directory.appendingPathComponent("Demo.mp4"))
        try Data().write(to: directory.appendingPathComponent("Demo 2.gif"))

        XCTAssertEqual(HistoryStore.uniqueURL(in: directory, fileName: "Demo.mp4").lastPathComponent, "Demo 2.mp4")
        // A GIF recording also needs its converted name to be free.
        XCTAssertEqual(
            HistoryStore.uniqueURL(in: directory, fileName: "Demo.mp4", reservingExtensions: ["gif"]).lastPathComponent,
            "Demo 3.mp4"
        )
    }

    func testCropKeepsTheSelectedTopRegion() throws {
        // 10×10 bitmap: top half red, bottom half blue (CGContext's origin is bottom-left).
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 10, height: 5))
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 5, width: 10, height: 5))
        let session = EditorSession(image: NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero), record: nil)

        session.crop(to: CGRect(x: 0, y: 0, width: 1, height: 0.5))

        let cropped = try XCTUnwrap(session.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        XCTAssertEqual(cropped.height, 5)
        let bitmap = NSBitmapImageRep(cgImage: cropped)
        for y in [0, 4] {
            let color = try XCTUnwrap(bitmap.colorAt(x: 5, y: y)?.usingColorSpace(.sRGB))
            XCTAssertGreaterThan(color.redComponent, 0.9)
            XCTAssertLessThan(color.blueComponent, 0.1)
        }
    }

    func testTextEditsAreUndoable() {
        let session = EditorSession(image: NSImage(size: CGSize(width: 100, height: 100)), record: nil)
        session.selectedTool = .text
        session.textDraft = "Before"
        session.begin(at: CGPoint(x: 0.5, y: 0.5))
        session.end(at: CGPoint(x: 0.5, y: 0.5))

        session.updateSelectedText("After")
        session.updateSelectedText("After!")
        XCTAssertEqual(session.annotations.first?.text, "After!")

        session.undo()
        XCTAssertEqual(session.annotations.first?.text, "Before")
        session.redo()
        XCTAssertEqual(session.annotations.first?.text, "After!")
    }

    func testCropKeepsRedactionsInTheCroppedArea() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let session = EditorSession(image: NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero), record: nil)
        session.selectedTool = .blur
        session.begin(at: CGPoint(x: 0.6, y: 0.6))
        session.end(at: CGPoint(x: 0.8, y: 0.8))
        session.selectedTool = .rectangle
        session.begin(at: CGPoint(x: 0.05, y: 0.05))
        session.end(at: CGPoint(x: 0.1, y: 0.1))

        session.selectedTool = .crop
        session.begin(at: CGPoint(x: 0.5, y: 0.5))
        session.end(at: CGPoint(x: 1, y: 1))

        XCTAssertEqual(session.annotations.count, 1)
        let blur = try XCTUnwrap(session.annotations.first)
        XCTAssertEqual(blur.tool, .blur)
        XCTAssertEqual(blur.rect.x, 0.2, accuracy: 0.02)
        XCTAssertEqual(blur.rect.y, 0.2, accuracy: 0.02)
        XCTAssertEqual(blur.rect.width, 0.4, accuracy: 0.02)
        XCTAssertEqual(blur.rect.height, 0.4, accuracy: 0.02)
    }

    func testSelectingACroppedAnnotationDoesNotMoveIt() throws {
        let context = try XCTUnwrap(CGContext(
            data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let session = EditorSession(image: NSImage(cgImage: try XCTUnwrap(context.makeImage()), size: .zero), record: nil)
        session.selectedTool = .rectangle
        session.begin(at: CGPoint(x: 0.4, y: 0.4))
        session.end(at: CGPoint(x: 0.6, y: 0.6))
        session.selectedTool = .crop
        session.begin(at: CGPoint(x: 0.5, y: 0))
        session.end(at: CGPoint(x: 1, y: 1))
        let before = try XCTUnwrap(session.annotations.first).rect

        session.selectedTool = .select
        session.beginSelection(at: CGPoint(x: 0.1, y: 0.5))
        session.endSelection(at: CGPoint(x: 0.1, y: 0.5))

        XCTAssertLessThan(before.x, 0)
        XCTAssertEqual(session.annotations.first?.rect, before)
    }

    func testCombineKeepsAnnotationsOnTheOriginalImage() throws {
        let session = EditorSession(image: NSImage(size: CGSize(width: 100, height: 100)), record: nil)
        session.selectedTool = .pixelate
        session.begin(at: CGPoint(x: 0, y: 0))
        session.end(at: CGPoint(x: 1, y: 1))

        session.combine(with: NSImage(size: CGSize(width: 100, height: 80)))

        let item = try XCTUnwrap(session.annotations.first)
        XCTAssertEqual(item.rect.x, 0, accuracy: 0.001)
        XCTAssertEqual(item.rect.y, 0, accuracy: 0.001)
        XCTAssertEqual(item.rect.width, 1, accuracy: 0.001)
        XCTAssertEqual(item.rect.height, 0.5, accuracy: 0.001)
    }

    func testCounterNumbersContinueAfterDeletion() {
        let session = EditorSession(image: NSImage(size: CGSize(width: 100, height: 100)), record: nil)
        session.selectedTool = .counter
        for x in [0.2, 0.4] {
            session.begin(at: CGPoint(x: x, y: 0.5))
            session.end(at: CGPoint(x: x, y: 0.5))
        }
        session.selectedAnnotationID = session.annotations.first?.id
        session.removeSelected()
        session.begin(at: CGPoint(x: 0.6, y: 0.5))
        session.end(at: CGPoint(x: 0.6, y: 0.5))

        XCTAssertEqual(session.annotations.compactMap(\.counter), [2, 3])
    }

    func testShareUpdateOmitsUnchangedRestrictions() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let keep = try encoder.encode(CloudShareService.UpdatePayload(password: .keep, expiresAt: .keep, tags: ["a"]))
        XCTAssertEqual(String(decoding: keep, as: UTF8.self), #"{"tags":["a"]}"#)

        let clear = try encoder.encode(CloudShareService.UpdatePayload(password: .clear, expiresAt: .clear, tags: []))
        XCTAssertEqual(String(decoding: clear, as: UTF8.self), #"{"expiresAt":null,"password":null,"tags":[]}"#)
    }

    func testOCRReadingOrderIsTopToBottomThenLeftToRight() {
        // Vision boxes use a bottom-left origin. Rows ~0.02 apart used to form an ordering cycle.
        let boxes = [
            CGRect(x: 0.5, y: 0.80, width: 0.1, height: 0.01),
            CGRect(x: 0.1, y: 0.80, width: 0.1, height: 0.01),
            CGRect(x: 0.3, y: 0.50, width: 0.1, height: 0.01),
            CGRect(x: 0.2, y: 0.90, width: 0.1, height: 0.01),
        ]
        let ordered = OCRService.readingOrder(boxes, box: { $0 })
        XCTAssertEqual(ordered.map(\.minX), [0.2, 0.1, 0.5, 0.3])
    }

    func testGlobalShortcutBindingsPersistClearAndReset() {
        let suiteName = "ScreenshotTests.shortcuts"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }

        let preferences = AppPreferences(defaults: suite)
        XCTAssertEqual(preferences.globalShortcuts.shortcut(for: .captureArea)?.displayString, "⌃⌥S")
        let custom = KeyShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift, .control], key: "4")
        preferences.globalShortcuts.set(custom, for: .captureArea)
        preferences.globalShortcuts.clear(.captureText)

        let reloaded = AppPreferences(defaults: suite)
        XCTAssertEqual(reloaded.globalShortcuts.shortcut(for: .captureArea), custom)
        XCTAssertNil(reloaded.globalShortcuts.shortcut(for: .captureText))
        XCTAssertTrue(reloaded.globalShortcuts.isDefault(.captureWindow))

        reloaded.globalShortcuts.reset(.captureArea)
        reloaded.globalShortcuts.reset(.captureText)
        XCTAssertEqual(reloaded.globalShortcuts, GlobalShortcutBindings())
        XCTAssertEqual(AppPreferences(defaults: suite).globalShortcuts, GlobalShortcutBindings())
    }

    func testResetRefusesToDuplicateAnotherActionsShortcut() {
        var bindings = GlobalShortcutBindings()
        bindings.clear(.captureWindow)
        bindings.set(GlobalShortcutAction.captureWindow.defaultShortcut, for: .recordScreen)

        XCTAssertEqual(bindings.resetConflict(for: .captureWindow), .recordScreen)
        XCTAssertEqual(bindings.reset(.captureWindow), .recordScreen)
        XCTAssertNil(bindings.shortcut(for: .captureWindow))
        XCTAssertEqual(bindings.shortcut(for: .recordScreen), GlobalShortcutAction.captureWindow.defaultShortcut)

        bindings.reset(.recordScreen)
        XCTAssertNil(bindings.reset(.captureWindow))
        XCTAssertEqual(bindings, GlobalShortcutBindings())
    }

    func testGlobalShortcutBindingsIgnoreUnknownStoredActions() throws {
        let json = #"{"overrides":{"captureArea":{"keyCode":1,"modifierFlags":262144,"key":"S"},"removedAction":{"keyCode":2,"modifierFlags":262144,"key":"D"}},"cleared":["removedAction","captureText"]}"#
        let bindings = try JSONDecoder().decode(GlobalShortcutBindings.self, from: Data(json.utf8))
        XCTAssertEqual(bindings.overrides.keys.map(\.rawValue), ["captureArea"])
        XCTAssertEqual(bindings.cleared, [.captureText])

        // Entries for actions this version doesn't know survive a change and a save.
        var edited = bindings
        edited.clear(.captureHistory)
        let saved = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        XCTAssertNotNil((saved?["overrides"] as? [String: Any])?["removedAction"])
        XCTAssertEqual(saved?["cleared"] as? [String], ["captureHistory", "captureText", "removedAction"])
        edited.resetAll()
        XCTAssertTrue(edited.isAllDefault)
        let afterReset = try JSONSerialization.jsonObject(with: JSONEncoder().encode(edited)) as? [String: Any]
        XCTAssertNotNil((afterReset?["overrides"] as? [String: Any])?["removedAction"])
    }

    func testOneBadStoredShortcutKeepsTheOtherBindings() throws {
        // captureWindow is malformed and captureText uses ⌘ alone, which a global shortcut may not.
        let json = #"{"overrides":{"captureArea":{"keyCode":1,"modifierFlags":262144,"key":"S"},"captureWindow":{"keyCode":"x"},"captureText":{"keyCode":8,"modifierFlags":1048576,"key":"C"}},"cleared":["recordScreen",7]}"#
        let bindings = try JSONDecoder().decode(GlobalShortcutBindings.self, from: Data(json.utf8))
        XCTAssertEqual(bindings.shortcut(for: .captureArea), KeyShortcut(keyCode: 1, modifiers: [.control], key: "S"))
        XCTAssertTrue(bindings.isDefault(.captureWindow))
        XCTAssertTrue(bindings.isDefault(.captureText))
        XCTAssertNil(bindings.shortcut(for: .recordScreen))

        let suiteName = "ScreenshotTests.badShortcut"
        let suite = UserDefaults(suiteName: suiteName)!
        suite.removePersistentDomain(forName: suiteName)
        defer { suite.removePersistentDomain(forName: suiteName) }
        suite.set(Data(json.utf8), forKey: "globalShortcuts")
        XCTAssertEqual(AppPreferences(defaults: suite).globalShortcuts, bindings)
    }

    func testRecordingTheDefaultKeysUnderAnotherLabelKeepsTheDefault() {
        var bindings = GlobalShortcutBindings()
        let areaDefault = GlobalShortcutAction.captureArea.defaultShortcut
        bindings.set(KeyShortcut(keyCode: areaDefault.keyCode, modifiers: areaDefault.modifiers, key: "Ś"), for: .captureArea)
        XCTAssertTrue(bindings.isDefault(.captureArea))
        XCTAssertTrue(bindings.isAllDefault)
        // The label the layout produced is what Settings and the menu show.
        XCTAssertEqual(bindings.shortcut(for: .captureArea)?.displayString, "⌃⌥Ś")
    }

    func testFallbackDefaultDoesNotTakeAnotherActionsStoredKeys() throws {
        // Capture Area's stored override is unusable (⌘ alone) and Capture Window uses ⌃⌥S,
        // Capture Area's default: Capture Window keeps it and Capture Area gets no shortcut.
        let json = #"{"overrides":{"captureArea":{"keyCode":8,"modifierFlags":1048576,"key":"C"},"captureWindow":{"keyCode":1,"modifierFlags":786432,"key":"S"}},"cleared":[]}"#
        let bindings = try JSONDecoder().decode(GlobalShortcutBindings.self, from: Data(json.utf8))
        XCTAssertEqual(bindings.shortcut(for: .captureWindow)?.displayString, "⌃⌥S")
        XCTAssertNil(bindings.shortcut(for: .captureArea))
        XCTAssertNil(bindings.action(using: GlobalShortcutAction.captureArea.defaultShortcut, except: .captureWindow))
    }

    func testShortcutLabelKeepsCharactersThatUppercaseToSeveral() {
        XCTAssertEqual(KeyShortcut.uppercasedLabel("a"), "A")
        XCTAssertEqual(KeyShortcut.uppercasedLabel("ß"), "ß")
        XCTAssertEqual(KeyShortcut(keyCode: 27, modifiers: [.control], key: "ß").menuKeyEquivalent, "ß")
    }

    func testGlobalShortcutConflictsAndValidation() {
        var bindings = GlobalShortcutBindings()
        let windowDefault = GlobalShortcutAction.captureWindow.defaultShortcut
        // Same physical keys conflict even if the layout labelled the key differently.
        let relabelled = KeyShortcut(keyCode: windowDefault.keyCode, modifiers: windowDefault.modifiers, key: "Ś")
        XCTAssertEqual(bindings.action(using: relabelled, except: .captureArea), .captureWindow)
        XCTAssertNil(bindings.action(using: relabelled, except: .captureWindow))
        bindings.clear(.captureWindow)
        XCTAssertNil(bindings.action(using: relabelled))

        XCTAssertTrue(KeyShortcut(keyCode: 1, modifiers: [.control], key: "S").isAllowedAsGlobalShortcut)
        XCTAssertTrue(KeyShortcut(keyCode: 1, modifiers: [.command, .shift], key: "S").isAllowedAsGlobalShortcut)
        XCTAssertTrue(KeyShortcut(keyCode: 1, modifiers: [.command, .option], key: "S").isAllowedAsGlobalShortcut)
        XCTAssertFalse(KeyShortcut(keyCode: 1, modifiers: [.command], key: "S").isAllowedAsGlobalShortcut)
        XCTAssertFalse(KeyShortcut(keyCode: 1, modifiers: [.option, .shift], key: "S").isAllowedAsGlobalShortcut)
        XCTAssertFalse(KeyShortcut(keyCode: 1, modifiers: [], key: "S").isAllowedAsGlobalShortcut)

        XCTAssertTrue(KeyShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .shift], key: "4").overlapsSystemScreenshotShortcut)
        XCTAssertFalse(KeyShortcut(keyCode: UInt32(kVK_ANSI_4), modifiers: [.command, .option], key: "4").overlapsSystemScreenshotShortcut)
    }

    func testKeyShortcutDisplayAndCarbonModifiers() {
        let shortcut = KeyShortcut(keyCode: UInt32(kVK_ANSI_S), modifiers: [.command, .shift, .option, .control, .capsLock], key: "S")
        XCTAssertEqual(shortcut.displayString, "⌃⌥⇧⌘S")
        XCTAssertEqual(shortcut.carbonModifiers, UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(shortcut.menuKeyEquivalent, "s")
        XCTAssertEqual(KeyShortcut(keyCode: UInt32(kVK_F5), modifiers: [.control], key: "F5").menuKeyEquivalent?.unicodeScalars.first?.value, UInt32(NSF5FunctionKey))

        // A function key, so the label doesn't depend on the active keyboard layout.
        let f5 = String(Character(UnicodeScalar(UInt16(NSF5FunctionKey))!))
        let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option, .capsLock], timestamp: 0, windowNumber: 0,
            context: nil, characters: f5, charactersIgnoringModifiers: f5, isARepeat: false, keyCode: UInt16(kVK_F5)
        )!
        let recorded = KeyShortcut(event: event)
        XCTAssertEqual(recorded?.keyCode, UInt32(kVK_F5))
        XCTAssertEqual(recorded?.modifiers, [.control, .option])
        XCTAssertEqual(recorded?.displayString, "⌃⌥F5")
    }

    func testOverlayPanelsCoverTheirOwnScreen() throws {
        // Displays left of, above and right of a 1440×900 main display: each overlay must sit
        // exactly on its display's global frame, with the origin applied once.
        let secondaryFrames = [
            CGRect(x: -1920, y: -180, width: 1920, height: 1080),
            CGRect(x: 0, y: 900, width: 2560, height: 1440),
            CGRect(x: 1440, y: 120, width: 1680, height: 1050),
        ]
        for frame in secondaryFrames {
            XCTAssertEqual(RegionCaptureController.makeOverlayPanel(frame: frame).frame, frame)
        }
        try XCTSkipIf(NSScreen.screens.isEmpty, "The connected-display check needs at least one display.")
        for screen in NSScreen.screens {
            XCTAssertEqual(RegionCaptureController.makeOverlayPanel(for: screen).frame, screen.frame)
        }
    }

    func testAutoCloseCountdownShrinksAndStaysFullWhilePaused() {
        let now: TimeInterval = 5_000
        XCTAssertEqual(AutoCloseCountdownBar.remaining(until: nil, at: now, duration: 10), 10)
        XCTAssertEqual(AutoCloseCountdownBar.remaining(until: now + 4, at: now, duration: 10), 4, accuracy: 0.001)
        XCTAssertEqual(AutoCloseCountdownBar.remaining(until: now - 1, at: now, duration: 10), 0)
        XCTAssertEqual(AutoCloseCountdownBar.remaining(until: now + 30, at: now, duration: 10), 10)
    }

    func testHoveringPausesAndLeavingRestartsTheAutoCloseCountdown() {
        let controller = QuickAccessPanelController(appState: AppState(), autoCloseSeconds: { 5 })
        let record = CaptureRecord(
            id: UUID(), kind: .area, createdAt: Date(), fileURL: URL(fileURLWithPath: "/tmp/quick-access-test.png"),
            projectURL: nil, thumbnailURL: nil, width: 10, height: 10, sourceApplication: nil, sourceWindow: nil,
            cloudShareURL: nil, cloudID: nil, tags: [], isFavorite: false
        )
        defer { controller.hide() }
        let before = ProcessInfo.processInfo.systemUptime
        controller.show(record: record, image: nil)
        XCTAssertEqual(controller.autoCloseDuration, 5)
        let deadline = try? XCTUnwrap(controller.autoCloseDeadline)
        XCTAssertEqual(deadline ?? 0, before + 5, accuracy: 1)

        controller.setHovering(true)
        XCTAssertNil(controller.autoCloseDeadline)

        controller.setHovering(false)
        XCTAssertNotNil(controller.autoCloseDeadline)
        XCTAssertGreaterThanOrEqual(controller.autoCloseDeadline ?? 0, deadline ?? .infinity)

        controller.hide()
        XCTAssertNil(controller.autoCloseDeadline)
    }

    func testQuickAccessOpensOnTheCapturedDisplay() {
        let main = CGRect(x: 0, y: 0, width: 1512, height: 982)
        let external = CGRect(x: -450, y: 982, width: 2560, height: 1440)
        let frames = [main, external]
        let pointerOnMain = CGPoint(x: 100, y: 100)
        // A capture on the external display wins over the pointer position.
        XCTAssertEqual(QuickAccessPanelController.screenIndex(for: CGRect(x: 0, y: 1500, width: 300, height: 200), pointer: pointerOnMain, frames: frames), 1)
        // An area spanning both displays goes to the one holding most of it.
        XCTAssertEqual(QuickAccessPanelController.screenIndex(for: CGRect(x: 0, y: 900, width: 200, height: 300), pointer: pointerOnMain, frames: frames), 1)
        // No area: the display under the pointer.
        XCTAssertEqual(QuickAccessPanelController.screenIndex(for: nil, pointer: CGPoint(x: 0, y: 2000), frames: frames), 1)
        XCTAssertEqual(QuickAccessPanelController.screenIndex(for: nil, pointer: pointerOnMain, frames: frames), 0)
    }
}
