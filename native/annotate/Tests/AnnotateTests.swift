import PDFKit
import UIKit
import XCTest
@testable import Annotate

@MainActor
final class AnnotateTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makePDF(pages: Int = 2) throws -> URL {
        let url = directory.appendingPathComponent("fixture.pdf")
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792))
        try renderer.writePDF(to: url) { context in
            for index in 0 ..< pages {
                context.beginPage()
                NSString(string: "Subset Annotate page \(index + 1)").draw(
                    at: CGPoint(x: 72, y: 72),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24)]
                )
            }
        }
        return url
    }

    func testCoverToolIsNotPresentedAsRedaction() {
        XCTAssertEqual(AnnotationTool.redaction.title, "Cover")
        XCTAssertTrue(AnnotationTool.redaction.instruction.contains("not secure redaction"))
    }

    func testInkStrokeMarksChangesWithoutTouchingTheSourceFile() throws {
        let url = try makePDF()
        let originalBytes = try Data(contentsOf: url)
        let store = PDFDocumentStore()
        store.importDocument(from: .success(url))
        let page = try XCTUnwrap(store.document?.page(at: 0))

        XCTAssertFalse(store.hasUnexportedChanges)
        XCTAssertEqual(store.totalAnnotationCount, 0)

        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 240)])

        XCTAssertTrue(store.hasUnexportedChanges)
        XCTAssertEqual(store.totalAnnotationCount, 1)
        XCTAssertEqual(try Data(contentsOf: url), originalBytes, "Annotating must not modify the opened file")

        store.undoLastChange()
        XCTAssertEqual(store.totalAnnotationCount, 0)
    }

    func testClosingWithUnexportedChangesAsksFirst() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))
        let page = try XCTUnwrap(store.document?.page(at: 0))
        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)])

        store.requestClose()
        XCTAssertNotNil(store.document, "Close waits for confirmation")
        XCTAssertEqual(store.pendingDiscard, .close)

        store.confirmDiscard()
        XCTAssertNil(store.document)
        XCTAssertFalse(store.hasUnexportedChanges)
    }

    func testExportDataContainsTheAnnotation() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))
        let page = try XCTUnwrap(store.document?.page(at: 1))
        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 10, y: 10), CGPoint(x: 80, y: 90)])

        store.prepareExport()
        let data = try XCTUnwrap(store.exportFile?.data)
        let exported = try XCTUnwrap(PDFDocument(data: data))

        XCTAssertEqual(exported.pageCount, 2)
        XCTAssertEqual(exported.page(at: 1)?.annotations.count, 1)
        XCTAssertEqual(exported.page(at: 0)?.annotations.count, 0)
    }

    func testClosingWithoutChangesClosesImmediately() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))

        store.requestClose()
        XCTAssertNil(store.pendingDiscard)
        XCTAssertNil(store.document)
    }

    func testOpenAnotherKeepsChangesGuardedUntilANewDocumentLoads() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))
        let page = try XCTUnwrap(store.document?.page(at: 0))
        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 10, y: 10), CGPoint(x: 50, y: 50)])

        store.requestOpenAnother()
        XCTAssertEqual(store.pendingDiscard, .openAnother)
        XCTAssertFalse(store.isImporterPresented)

        store.confirmDiscard()
        XCTAssertTrue(store.isImporterPresented)
        // The picker is cancelled: the current edits are still loaded and still unexported.
        store.isImporterPresented = false
        XCTAssertNotNil(store.document)
        XCTAssertTrue(store.hasUnexportedChanges)
        store.requestClose()
        XCTAssertEqual(store.pendingDiscard, .close)
    }

    func testInkPathIsRelativeToAnOffsetMediaBox() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))
        let page = try XCTUnwrap(store.document?.page(at: 0))
        page.setBounds(CGRect(x: 50, y: 40, width: 500, height: 700), for: .mediaBox)

        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 240)])

        let annotation = try XCTUnwrap(page.annotations.first)
        let pathBounds = try XCTUnwrap(annotation.paths?.first?.bounds)
        // Path points are relative to the annotation's bounds, which start just outside the stroke.
        XCTAssertEqual(annotation.bounds.origin.x + pathBounds.origin.x, 100, accuracy: 0.5)
        XCTAssertEqual(annotation.bounds.origin.y + pathBounds.origin.y, 100, accuracy: 0.5)
        XCTAssertEqual(pathBounds.width, 100, accuracy: 0.5)
        XCTAssertEqual(pathBounds.height, 140, accuracy: 0.5)
    }

    func testInkBoundsCoverOnlyTheStroke() throws {
        let store = PDFDocumentStore()
        store.importDocument(from: .success(try makePDF()))
        let page = try XCTUnwrap(store.document?.page(at: 0))

        store.commitInkStroke(on: page, pagePoints: [CGPoint(x: 100, y: 100), CGPoint(x: 200, y: 240)])

        let annotation = try XCTUnwrap(page.annotations.first)
        XCTAssertTrue(annotation.bounds.contains(CGPoint(x: 100, y: 100)))
        XCTAssertTrue(annotation.bounds.contains(CGPoint(x: 200, y: 240)))
        XCTAssertLessThan(annotation.bounds.width, 120)
        XCTAssertNil(page.annotation(at: CGPoint(x: 400, y: 600)))
        XCTAssertNotNil(page.annotation(at: CGPoint(x: 150, y: 170)))
    }

    func testWordRangesAdvancePastNonBMPCharacters() {
        let text = "a \u{1D44E}\u{1F600}b  c" as NSString
        let ranges = PDFDocumentStore.wordRanges(in: text, limitedTo: NSRange(location: 0, length: text.length))
        XCTAssertEqual(ranges.map { text.substring(with: $0) }, ["a", "\u{1D44E}\u{1F600}b", "c"])
    }

    func testLinkURLsMustBeAbsoluteWebOrMailAddresses() {
        XCTAssertNotNil(PDFDocumentStore.validatedLinkURL("https://example.com/path"))
        XCTAssertNotNil(PDFDocumentStore.validatedLinkURL(" http://example.com "))
        XCTAssertNotNil(PDFDocumentStore.validatedLinkURL("mailto:someone@example.com"))
        XCTAssertNil(PDFDocumentStore.validatedLinkURL("https://"))
        XCTAssertNil(PDFDocumentStore.validatedLinkURL("example.com"))
        XCTAssertNil(PDFDocumentStore.validatedLinkURL("file:///etc/hosts"))
        XCTAssertNil(PDFDocumentStore.validatedLinkURL("tel:5551234"))
        XCTAssertNil(PDFDocumentStore.validatedLinkURL("mailto:"))
    }
}
