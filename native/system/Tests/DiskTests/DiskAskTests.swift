import Foundation
import os
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

    func testANewScanReplacesTheLargestItems() async throws {
        let model = try await fixture.scanned()
        let first = model.askLargestItems(limit: 1, redactor: redactor).entries.map(\.target)
        XCTAssertEqual(first, [.diskItem(path: fixture.path("Documents/big.bin"))])
        try fixture.write("Movies/huge.mov", bytes: 2_000_000)
        model.scan()
        try await DiskFixture.wait { model.phase == .completed }
        XCTAssertEqual(model.askLargestItems(limit: 2, redactor: redactor).entries.map(\.target),
                       [.diskItem(path: fixture.path("Movies/huge.mov")), .diskItem(path: fixture.path("Documents/big.bin"))])
    }

    func testDiskToolsSayWhenTheScanEndedAndTheVolumeWasRead() async throws {
        let clock = TestClock()
        let start = clock.now
        // Each scan stops at its own gate once it has read everything.
        let gates = [AsyncGate(), AsyncGate()]
        let scans = OSAllocatedUnfairLock(initialState: 0)
        let model = fixture.model(service: fixture.service(scan: { root, onProgress in
            let scanned = await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
            let scan = scans.withLock { count in
                defer { count += 1 }
                return count
            }
            await gates[scan].pass()
            return scanned
        }), clock: { clock.now })

        model.scan()
        await fulfillment(of: [gates[0].reached], timeout: 30)
        try await DiskFixture.wait { model.volumeHeader != nil }
        XCTAssertNil(model.askDiskSummary(redactor: redactor).fields["scanEnded"], "a scan still reading has not ended")
        clock.now = start.addingTimeInterval(60)
        gates[0].open()
        try await DiskFixture.wait { !model.isScanning }
        let finished: [String: AskValue] = ["scan": .words("Finished"), "scanEnded": at(clock.now, "5 minutes"),
                                            "volumeRead": at(start, "6 minutes")]
        XCTAssertEqual(times(model, at: start.addingTimeInterval(360)), [finished, finished, finished])
        // A reading kept for hours says so; nothing reads it again.
        let later = times(model, at: start.addingTimeInterval(3 * 3_600))
        XCTAssertEqual(later[0]["scanEnded"], at(start.addingTimeInterval(60), "2 hours"))
        XCTAssertEqual(later[2]["volumeRead"], at(start, "3 hours"))

        // A new scan drops both until it reads them again; a cancelled one ends when it stops.
        clock.now = start.addingTimeInterval(7_200)
        model.scan()
        XCTAssertEqual(model.askDiskSummary(redactor: redactor).fields, ["scan": .words("Scanning")])
        await fulfillment(of: [gates[1].reached], timeout: 30)
        try await DiskFixture.wait { model.volumeHeader != nil }
        clock.now = start.addingTimeInterval(7_260)
        model.cancel()
        gates[1].open()
        try await DiskFixture.wait { !model.isScanning }
        let summary = model.askDiskSummary(redactor: redactor, now: start.addingTimeInterval(7_380)).fields
        XCTAssertEqual(summary["scan"], .words("Cancelled; folders not read in full count only what was read"))
        XCTAssertEqual(summary["scanEnded"], at(clock.now, "2 minutes"))
        XCTAssertEqual(summary["volumeRead"], at(start.addingTimeInterval(7_200), "3 minutes"))
        XCTAssertEqual(model.askLargestItems(limit: 1, redactor: redactor, now: clock.now).fields["scanEnded"],
                       at(clock.now, "0 minutes"))
    }

    /// What each disk tool says of the scan's state and when it and the volume were read.
    private func times(_ model: DiskWindowModel, at now: Date) -> [[String: AskValue]] {
        [model.askDiskSummary(redactor: redactor, now: now).fields,
         model.askLargestItems(limit: 1, redactor: redactor, now: now).fields,
         model.askReclaimSuggestions(redactor: redactor, now: now).fields].map {
            $0.filter { ["scan", "scanEnded", "volumeRead"].contains($0.key) }
        }
    }

    private func at(_ date: Date, _ ago: String) -> AskValue {
        .words("At \(fixture.format.time(date)), \(ago) ago")
    }

    func testAHardLinkedFileIsOneLargestItem() async throws {
        try fixture.write("Movies/take.mov", bytes: 3_000_000)
        XCTAssertEqual(link(fixture.path("Movies/take.mov"), fixture.path("Documents/take-link.mov")), 0)
        let model = try await fixture.scanned()
        let paths = model.askLargestItems(limit: 3, redactor: redactor).entries.compactMap { entry -> String? in
            guard case let .diskItem(path)? = entry.target else { return nil }
            return path
        }
        XCTAssertEqual(paths.filter { $0.hasSuffix("take.mov") || $0.hasSuffix("take-link.mov") }.count, 1, "\(paths)")
        XCTAssertEqual(paths.count, 3)
        let counted = try XCTUnwrap(paths.first)
        let tree = try XCTUnwrap(model.result?.tree)
        XCTAssertFalse(try XCTUnwrap(tree.item(at: String(counted.dropFirst(fixture.home.count + 1)))).flags
            .contains(.countedElsewhere), "the link listed is the one that counts the file")
    }

    func testAPackageChosenAsTheScansRootIsItsLargestItem() async throws {
        let bundle = fixture.path("Tool.app")
        try fixture.write("Tool.app/Contents/MacOS/Tool", bytes: 100_000)
        let model = fixture.model(service: fixture.service(scan: { _, onProgress in
            await DiskScanService.scan(DiskScanner(workers: 2), root: bundle, onProgress: onProgress)
        }))
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        let output = model.askLargestItems(limit: 5, redactor: redactor)
        XCTAssertEqual(output.entries.map(\.target), [.diskItem(path: bundle)])
        XCTAssertEqual(output.entries.first?.fields["type"], .words("Package"))
    }

    func testAVolumeWithoutANameSendsItsMountPointOnlyAsARedactedPath() async throws {
        let mountPoint = fixture.path("Private/Work")
        let unnamed = VolumeSummary(values: VolumeCapacityValues(mountPoint: mountPoint, capacity: 500_000_000_000),
                                    snapshots: .count(0))
        let model = fixture.model(service: fixture.service(volume: { _ in unnamed }))
        model.scan()
        try await DiskFixture.wait { !model.isScanning && model.volumeHeader != nil }
        XCTAssertEqual(model.volumeHeader?.title, mountPoint, "the header on screen still shows the mount point")

        let toolbox = AskToolbox(source: AskWindowSource(processes: ProcessesWindowModel(), disk: model,
                                                         showProcesses: { /* Not cited here. */ },
                                                         showDisk: { /* Not cited here. */ }), redactor: redactor)
        toolbox.begin(1, redactor: redactor)
        let sent = toolbox.call("diskSummary", arguments: Data("{}".utf8), question: 1)
        XCTAssertFalse(sent.contains(fixture.home), sent)
        XCTAssertFalse(sent.contains("/Work"), sent)
        XCTAssertFalse(sent.contains(#""volume""#), "a volume without a name sends no name: \(sent)")
        XCTAssertTrue(sent.contains(#""mountedAt":"\#(redactor.path(mountPoint).value)""#), sent)
        XCTAssertTrue(redactor.path(mountPoint).value.hasPrefix("~/Private/folder-"))

        let named = try await fixture.scanned()
        try await DiskFixture.wait { named.volumeHeader != nil }
        XCTAssertEqual(named.askDiskSummary(redactor: redactor).fields["volume"], .name("Macintosh HD"))
        XCTAssertEqual(named.askDiskSummary(redactor: redactor).fields["mountedAt"], .path(ExplainPath("/")))
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

/// A clock tests set by hand.
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}
