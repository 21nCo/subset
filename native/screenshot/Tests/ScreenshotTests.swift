import AppKit
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
}
