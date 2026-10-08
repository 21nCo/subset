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
}
