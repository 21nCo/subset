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

        XCTAssertTrue(value.hasPrefix("Capture 1970-01-01 "))
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

        store.clearCloud(id: record.id)
        XCTAssertNil(store.records.first?.cloudShareURL)
        XCTAssertNil(store.records.first?.cloudID)

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
}
