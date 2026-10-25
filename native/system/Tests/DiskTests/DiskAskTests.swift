import Foundation
@testable import SystemCore
@testable import SystemDisk
import SystemProcesses
import XCTest

/// What Ask's disk tools (SET-51) read from a fixture scan, redacted, and what a citation selects: only the row it
/// cites, never a cleanup.
@MainActor
final class DiskAskTests: XCTestCase {
    private var fixture: DiskFixture!

    override func setUp() async throws {
        fixture = try DiskFixture()
        try fixture.populate()
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    private var redactor: ExplainRedactor {
        ExplainRedactor(homes: [fixture.home], accountNames: [], sendFolderNames: false, key: Array(repeating: 2, count: 32))
    }

    func testWithoutAScanTheToolsSaySo() {
        let model = fixture.model()
        XCTAssertEqual(model.askDiskSummary(redactor: redactor), AskOutput(["scan": .words("No scan yet")]))
        XCTAssertEqual(model.askLargestItems(limit: 5, redactor: redactor).fields["status"],
                       .words("No disk scan has finished yet."))
        XCTAssertNotNil(model.askReclaimSuggestions(redactor: redactor).fields["status"])
    }

    func testTheLargestFilesAreListedLargestFirstWithRedactedPaths() async throws {
        let model = try await fixture.scanned()
        let output = model.askLargestItems(limit: 3, redactor: redactor)
        XCTAssertEqual(output.entries.map(\.target), [
            .diskItem(path: fixture.path("Documents/big.bin")),
            .diskItem(path: fixture.path("Library/Developer/Xcode/DerivedData/App-abc/Build/app")),
            .diskItem(path: fixture.path("Library/Caches/com.example.editor/cache.db"))
        ])
        let big = output.entries[0].fields
        XCTAssertEqual(big["path"], .path(redactor.path(fixture.path("Documents/big.bin"))))
        XCTAssertEqual(big["name"], .name(redactor.placeholder("big.bin")), "named as its path is sent")
        XCTAssertEqual(big["type"], .words("File"))
        XCTAssertEqual(output.fields["scannedFolder"], .path(ExplainPath("~")))

        let summary = model.askDiskSummary(redactor: redactor)
        XCTAssertEqual(summary.fields["scan"], .words("Finished"))
        XCTAssertEqual(summary.fields["scannedFolder"], .path(ExplainPath("~")))
        try await DiskFixture.wait { model.volumeHeader != nil }
        XCTAssertEqual(model.askDiskSummary(redactor: redactor).fields["localSnapshots"], .words("2, sizes unavailable"))
    }

    func testSuggestionsAndCitationsSelectOnlyTheirRows() async throws {
        let model = try await fixture.scanned()
        let output = model.askReclaimSuggestions(redactor: redactor)
        let derived = try XCTUnwrap(output.entries.first { $0.fields["rule"] == .words("Xcode DerivedData") })
        guard case let .suggestion(key)? = derived.target else { return XCTFail("\(String(describing: derived.target))") }
        XCTAssertNil(derived.fields["cleanedUpThisSession"])

        var shown: [String] = []
        let source = AskWindowSource(processes: ProcessesWindowModel(), disk: model, showProcesses: { shown.append("processes") },
                                     showDisk: { shown.append("disk") })
        XCTAssertTrue(source.select(.suggestion(key)))
        XCTAssertEqual(model.tab, .suggestions)
        guard case let .match(position)? = model.selection else { return XCTFail("\(String(describing: model.selection))") }
        XCTAssertEqual(model.analysis?.matches[position].rule.id, .xcodeDerivedData)
        XCTAssertNil(model.cleanupSheet, "a citation never starts a cleanup")

        let notes = fixture.path("Documents/Sub/notes.bin")
        XCTAssertTrue(source.select(.diskItem(path: notes)))
        XCTAssertEqual(model.tab, .folders)
        XCTAssertEqual(model.breadcrumbs.last?.name, "Sub")
        XCTAssertEqual(model.selection.flatMap(model.path(for:)), notes)
        XCTAssertEqual(shown, ["disk", "disk"])

        // What is no longer in the scan selects nothing and changes nothing.
        XCTAssertFalse(source.select(.diskItem(path: fixture.path("Documents/gone.bin"))))
        XCTAssertFalse(source.select(.diskItem(path: "/elsewhere/file")))
        XCTAssertFalse(source.select(.suggestion("disk-suggestion:none")))
        XCTAssertFalse(source.select(.group(OriginGroupID(.app(bundlePath: "/Applications/Gone.app")))))
        XCTAssertEqual(model.selection.flatMap(model.path(for:)), notes)
        XCTAssertEqual(shown, ["disk", "disk"])
    }
}
