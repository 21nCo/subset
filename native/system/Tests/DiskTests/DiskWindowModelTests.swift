import Foundation
import os
@testable import SystemCore
@testable import SystemDisk
import SystemProcesses
import XCTest

/// The Disk section's view model without the UI, on a fixture home folder scanned with the real scanner: breadcrumb
/// navigation, sort order, paging long lists, folders whose contents were not read, each tab's contents, the
/// unreadable-folder banner, cancelling, and spoken labels.
@MainActor
final class DiskWindowModelTests: XCTestCase {
    private var fixture: DiskFixture!

    override func setUp() async throws {
        fixture = try DiskFixture()
        try fixture.populate()
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    // MARK: Folders

    func testBreadcrumbsFollowOpenedFoldersAndGoingBackSelectsTheFolderLeft() async throws {
        let model = try await fixture.scanned()
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~"])
        let documents = try XCTUnwrap(model.row(named: "Documents"))
        XCTAssertTrue(documents.isNavigable)

        model.open(documents.id)
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~", "Documents"])
        XCTAssertEqual(model.rows.map(\.name), ["big.bin", "Sub", "small.bin"])
        // A file is not a folder to open.
        let file = try XCTUnwrap(model.row(named: "big.bin"))
        XCTAssertFalse(file.isNavigable)
        model.open(file.id)
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~", "Documents"])
        XCTAssertEqual(model.path(for: file.id), fixture.path("Documents/big.bin"))

        model.selection = try XCTUnwrap(model.row(named: "Sub")).id
        model.openSelection()
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~", "Documents", "Sub"])
        XCTAssertEqual(model.rows.map(\.name), ["notes.bin"])

        // The root crumb goes back two levels and selects the folder that was open there.
        model.navigate(to: model.breadcrumbs[0].id)
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~"])
        XCTAssertEqual(model.selection, documents.id)

        model.open(documents.id)
        model.closeSelection()
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~"])
        XCTAssertEqual(model.selection, documents.id)
        // Going up from the root does nothing.
        model.goUp()
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~"])
    }

    func testFoldersSortBySizeOrNameWithUnknownSizesLastAndLongListsPaged() async throws {
        try fixture.lock("Locked")
        try fixture.write("Library/Caches/zz-small", bytes: 4_000)
        let model = try await fixture.scanned()
        let tree = try XCTUnwrap(model.result?.tree)

        let bySize = model.rows.map(\.name)
        XCTAssertEqual(bySize.first, "Documents")
        XCTAssertEqual(bySize.last, "Locked", "an unreadable folder's size is unknown, so it sorts last")
        let sizes = model.rows.dropLast().map { tree[Self.index($0.id)].sizes!.allocated }
        XCTAssertEqual(sizes, sizes.sorted(by: >))
        let locked = try XCTUnwrap(model.row(named: "Locked"))
        XCTAssertEqual(locked.size, "–")
        XCTAssertEqual(locked.badges, [.unknown])
        XCTAssertFalse(locked.isNavigable)

        model.sortKey = .name
        XCTAssertEqual(model.rows.map(\.name), [".Trash", "Documents", "Library", "Locked"])

        model.sortKey = .private
        let privates = model.rows.dropLast().map { tree[Self.index($0.id)].sizes!.private }
        XCTAssertEqual(privates, privates.sorted(by: >))
        XCTAssertEqual(model.rows.last?.name, "Locked")

        let capped = try await fixture.scanned(rowLimit: 2)
        XCTAssertEqual(capped.rows.map(\.name), ["Documents", "Library", "Show 2 more"])
        XCTAssertNil(capped.rows.last?.path)
        XCTAssertEqual(capped.rows.last?.detail, "2 more items not listed yet; the totals include them.")
    }

    /// Every item of a long list can be reached, selected, revealed, and copied: the row ending it shows the next page
    /// from Return, a double-click, or its button, in the Folders tab and in an open group or match alike.
    func testShowMorePagesThroughEveryItemOfALongList() async throws {
        try fixture.write("Library/Developer/Xcode/DerivedData/Other-def/Build/app", bytes: 400_000)
        try fixture.write("Library/Application Support/com.example.editor/data.db", bytes: 50_000)
        let model = try await fixture.scanned(rowLimit: 1)
        XCTAssertEqual(model.rows.map(\.name), ["Library", "Show 1 more"])
        let first = try XCTUnwrap(model.rows.last)
        XCTAssertTrue(first.isMore)
        XCTAssertEqual(first.accessibilityLabel, "Show 1 more item")
        XCTAssertEqual(first.accessibilityValue, "2 more items not listed yet; the totals include them.")

        // Return on the row shows the next item and selects it.
        model.selection = first.id
        model.openSelection()
        XCTAssertEqual(model.rows.map(\.name), ["Library", "Documents", "Show 1 more"])
        XCTAssertEqual(model.selection, model.row(named: "Documents")?.id)
        // A double-click or the button shows the last one, which can be revealed and copied.
        model.activate(try XCTUnwrap(model.rows.last).id)
        XCTAssertEqual(model.rows.map(\.name), ["Library", "Documents", ".Trash"])
        let trash = try XCTUnwrap(model.row(named: ".Trash"))
        XCTAssertEqual(model.selection, trash.id)
        XCTAssertEqual(model.path(for: trash.id), fixture.path(".Trash"))
        // The page stays when the sort changes; another folder starts at one page.
        model.sortKey = .name
        XCTAssertEqual(model.rows.map(\.name), [".Trash", "Documents", "Library"])
        model.open(try XCTUnwrap(model.row(named: "Documents")).id)
        XCTAssertEqual(model.rows.map(\.name), ["big.bin", "Show 1 more"])

        model.tab = .suggestions
        let derived = try XCTUnwrap(model.row(named: "Xcode DerivedData"))
        model.setExpanded(derived.id, true)
        let page = model.rows.drop { $0.id != derived.id }.dropFirst().prefix(2).map(\.name)
        XCTAssertEqual(page, ["App-abc", "Show 1 more"])
        model.selection = try XCTUnwrap(model.rows.first { $0.isMore }).id
        model.openSelection()
        let other = try XCTUnwrap(model.row(named: "Other-def"))
        XCTAssertEqual(other.depth, 1)
        XCTAssertEqual(model.selection, other.id)
        XCTAssertEqual(model.path(for: other.id), fixture.path("Library/Developer/Xcode/DerivedData/Other-def"))
        XCTAssertNil(model.rows.first { $0.isMore })
        XCTAssertTrue(model.isExpanded(derived.id), "showing more does not collapse the match")

        model.tab = .origins
        let editor = try XCTUnwrap(model.row(named: "Editor"))
        model.activate(editor.id)
        XCTAssertTrue(model.isExpanded(editor.id))
        let more = try XCTUnwrap(model.rows.first { $0.isMore })
        XCTAssertEqual(more.depth, 1)
        model.activate(more.id)
        XCTAssertNil(model.rows.first { $0.isMore })
        let items = model.rows.filter { $0.depth == 1 }
        XCTAssertEqual(Set(items.compactMap { model.path(for: $0.id) }),
                       [fixture.path("Library/Caches/com.example.editor"),
                        fixture.path("Library/Application Support/com.example.editor")])
    }

    /// The selection is always a listed row, so it can be revealed and copied: going up, a breadcrumb, or a new sort
    /// shows as many pages as reach the selected folder.
    func testTheSelectedFolderIsListedAfterGoingUpOrChangingTheSort() async throws {
        let sorted = try await fixture.scanned(rowLimit: 1)
        XCTAssertEqual(sorted.rows.map(\.name), ["Documents", "Show 1 more"])
        let documents = try XCTUnwrap(sorted.row(named: "Documents")).id
        sorted.selection = documents
        sorted.sortKey = .name
        XCTAssertEqual(sorted.rows.map(\.name), [".Trash", "Documents", "Show 1 more"])
        XCTAssertEqual(sorted.selection, documents)
        XCTAssertEqual(sorted.path(for: documents), fixture.path("Documents"))

        let model = try await fixture.scanned(rowLimit: 1)
        model.open(documents)
        XCTAssertEqual(model.rows.map(\.name), ["big.bin", "Show 1 more"])
        model.open(try XCTUnwrap(model.rows.last).id)
        let sub = try XCTUnwrap(model.row(named: "Sub")).id
        XCTAssertEqual(model.selection, sub)
        model.open(sub)
        // By name Sub is third in Documents and Documents second in the home folder, past the pages shown so far.
        model.sortKey = .name
        model.navigate(to: try XCTUnwrap(model.breadcrumbs.dropLast().last).id)
        XCTAssertEqual(model.rows.map(\.name), ["big.bin", "small.bin", "Sub"])
        XCTAssertEqual(model.selection, sub)
        XCTAssertEqual(model.path(for: sub), fixture.path("Documents/Sub"))
        model.goUp()
        XCTAssertEqual(model.rows.map(\.name), [".Trash", "Documents", "Show 1 more"])
        XCTAssertEqual(model.selection, documents)
        XCTAssertEqual(model.path(for: documents), fixture.path("Documents"))
    }

    /// A folder opens to an empty list when the scan did not read its contents; only one read in full is called empty.
    func testAFolderWhoseContentsWereNotReadIsNeverCalledEmpty() async throws {
        for name in ["Cloud", "Elsewhere", "Replaced"] {
            try fixture.write("\(name)/inside.bin", bytes: 4_000)
        }
        try FileManager.default.createDirectory(atPath: fixture.path("Empty"), withIntermediateDirectories: false)
        let home = fixture.home
        // The scanner's states for a placeholder folder, one reached another way, and one replaced after it was listed,
        // as the Core tests place them: no children and nothing counted.
        let placed: [(name: String, flags: DiskItemFlags)] = [
            ("Cloud", .dataless), ("Elsewhere", .countedElsewhere), ("Replaced", .incomplete)
        ]
        let model = fixture.model(service: fixture.service(scan: { root, onProgress in
            let scanned = await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
            guard case var .success(result) = scanned else { return scanned }
            var tree = result.tree
            for (name, flags) in placed {
                guard let index = tree.index(atPath: home + "/" + name) else { continue }
                tree.nodes[index].flags = flags
                tree.nodes[index].childCount = 0
                tree.nodes[index].sizes = .zero
            }
            result = DiskScanResult(tree: tree, outcome: result.outcome, unreadablePaths: result.unreadablePaths,
                                    entriesRead: result.entriesRead)
            return .success(result)
        }))
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        XCTAssertEqual(model.phase, .completed)

        let notes = [
            "Cloud": "This folder is stored in iCloud and not downloaded to this Mac, so its contents were not read. "
                + "System never downloads it.",
            "Elsewhere": "This folder was reached another way during the scan, so its contents are listed and counted "
                + "there, not here.",
            "Replaced": "This folder's contents were not read (it may have been replaced while the scan ran), so they "
                + "are unknown.",
            "Empty": "This folder is empty."
        ]
        for (name, note) in notes {
            let row = try XCTUnwrap(model.row(named: name), name)
            XCTAssertTrue(row.isNavigable, name)
            model.open(row.id)
            XCTAssertEqual(model.breadcrumbs.last?.name, name)
            XCTAssertEqual(model.rows, [], name)
            XCTAssertEqual(model.sections.first?.note, note, name)
            model.goUp()
        }
        XCTAssertEqual(try XCTUnwrap(model.row(named: "Cloud")).badges, [.dataless])
        XCTAssertEqual(try XCTUnwrap(model.row(named: "Elsewhere")).badges, [.countedElsewhere])
        XCTAssertNil(model.sections.first?.note, "a folder that lists items needs no note")
    }

    // MARK: Tabs

    func testTabsShowTheVolumeOriginsAndSuggestionsOfAFixtureScan() async throws {
        let model = try await fixture.scanned()
        let header = try XCTUnwrap(model.volumeHeader)
        XCTAssertEqual(header.title, "Macintosh HD")
        XCTAssertEqual(header.capacity, "500 GB")
        XCTAssertEqual(header.availableForImportantUse, "120 GB")
        XCTAssertEqual(header.purgeable, "20 GB")
        XCTAssertEqual(header.snapshots, "2 local snapshots, sizes unavailable")

        model.tab = .origins
        XCTAssertEqual(model.sections.map(\.title), DiskOriginSection.allCases.map(\.title))
        XCTAssertEqual(model.section("apps")?.rows.map(\.name), ["Editor"])
        XCTAssertEqual(model.section("vendors")?.rows.map(\.name), ["Example Ltd"])
        XCTAssertEqual(Set(model.section("developerTools")?.rows.map(\.name) ?? []), ["Xcode", "Homebrew"])
        XCTAssertEqual(model.section("leftovers")?.rows.map(\.name), ["Leftovers"])
        let editor = try XCTUnwrap(model.row(named: "Editor"))
        XCTAssertEqual(editor.path, "/Applications/Editor.app")
        model.toggle(editor.id)
        let cache = try XCTUnwrap(model.row(named: "com.example.editor"))
        XCTAssertEqual(cache.depth, 1)
        XCTAssertEqual(cache.path, fixture.path("Library/Caches/com.example.editor"))
        XCTAssertEqual(cache.detail, "~/Library/Caches/com.example.editor")

        model.tab = .suggestions
        XCTAssertEqual(model.sections.map(\.id), ["safe", "review", "info"])
        XCTAssertEqual(Set(model.section("safe")?.rows.map(\.name) ?? []),
                       ["Xcode DerivedData", "Homebrew cache", "App caches: Editor"])
        XCTAssertEqual(model.section("review")?.rows.map(\.name), ["App leftovers: com.gone.app"])
        XCTAssertEqual(model.section("info")?.rows.map(\.name), ["Trash"])
        for row in model.rows {
            XCTAssertFalse(row.explanation?.isEmpty ?? true, row.name)
            XCTAssertFalse(row.rebuild?.isEmpty ?? true, row.name)
            XCTAssertNotEqual(row.size, "–", row.name)
        }
        // Largest first within a risk.
        let safe = try XCTUnwrap(model.section("safe")).rows.map(\.name)
        XCTAssertEqual(safe.first, "Xcode DerivedData")

        let derived = try XCTUnwrap(model.row(named: "Xcode DerivedData"))
        XCTAssertTrue(derived.isExpandable)
        model.selection = derived.id
        model.openSelection()
        let project = try XCTUnwrap(model.row(named: "App-abc"))
        XCTAssertEqual(model.path(for: project.id), fixture.path("Library/Developer/Xcode/DerivedData/App-abc"))
        model.selection = project.id
        model.closeSelection()
        XCTAssertEqual(model.selection, derived.id)
        model.closeSelection()
        XCTAssertNil(model.row(named: "App-abc"))

        // Each tab keeps its own selection.
        model.tab = .folders
        XCTAssertNil(model.selection)
        model.tab = .suggestions
        XCTAssertEqual(model.selection, derived.id)
    }

    func testAnItemsPrivateSizeIsShownOnlyWhenItDiffersAndPlaceholdersAreFlagged() throws {
        let format = fixture.format
        let same = DiskSizes(logical: 4_096, allocated: 4_096, private: 4_096)
        let shared = DiskSizes(logical: 8_192, allocated: 8_192, private: 4_096)
        XCTAssertNil(DiskFigures(same, flags: [], format: format).privateSize)
        XCTAssertEqual(DiskFigures(shared, flags: [], format: format).privateSize, "4 kB private")
        let dataless = DiskFigures(.zero, flags: .dataless, format: format)
        XCTAssertEqual(dataless.badges, [.dataless])
        XCTAssertEqual(DiskFigures(nil, flags: .unreadable, format: format).badges, [.unknown])
        let partial = DiskFigures(same, flags: .partial, format: format)
        XCTAssertEqual(partial.size, "≥4 kB")
        XCTAssertEqual(partial.badges, [.partial, .lowerBound])
    }

    // MARK: Banner

    func testTheUnreadableBannerAppearsOnlyWhenAFolderCouldNotBeRead() async throws {
        let clean = try await fixture.scanned()
        XCTAssertNil(clean.unreadableBanner)

        try fixture.lock("Locked")
        let model = try await fixture.scanned()
        let banner = try XCTUnwrap(model.unreadableBanner)
        XCTAssertEqual(banner.examples, ["~/Locked"])
        XCTAssertTrue(banner.message.hasPrefix("1 folder or item could not be read"), banner.message)
        XCTAssertTrue(banner.message.contains("works without it"), banner.message)
        XCTAssertEqual(DiskUnreadableBanner.fullDiskAccessSettings.absoluteString,
                       "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")

        // A new scan clears the banner until it meets an unreadable folder again.
        model.scan()
        XCTAssertNil(model.unreadableBanner)
    }

    // MARK: Cancel

    func testCancellingAScanKeepsWhatItReadOnScreen() async throws {
        let gate = Gate()
        // One worker, reporting every batch: the scan stops at the gate after reading the home folder's own listing.
        let model = fixture.model(service: fixture.service(scan: { root, onProgress in
            await DiskScanService.scan(DiskScanner(workers: 1, progressInterval: .zero), root: root) { progress in
                onProgress(progress)
                gate.pass()
            }
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        try await DiskFixture.wait { model.progress != nil }
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertTrue(model.statusText.contains("so far"), model.statusText)
        XCTAssertNil(model.result)

        model.cancel()
        XCTAssertTrue(model.isCancelling)
        gate.open()
        try await DiskFixture.wait { !model.isScanning }

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(model.result?.outcome, .cancelled)
        XCTAssertTrue(model.statusText.hasPrefix("Scan cancelled"), model.statusText)
        XCTAssertTrue(model.statusText.contains("before it stopped"), model.statusText)
        XCTAssertEqual(Set(model.rows.map(\.name)), [".Trash", "Documents", "Library"])
        XCTAssertTrue(try XCTUnwrap(model.row(named: "Documents")).badges.contains(.partial))
        XCTAssertNotNil(model.sections.first?.note)
        XCTAssertNil(model.analysis)
        model.tab = .suggestions
        XCTAssertEqual(model.sections.first?.note, "The scan was cancelled before it finished, so origins and "
                       + "suggestions were not worked out. Scan again to see them.")
    }

    func testCancellingWhileSuggestionsAreWorkedOutKeepsTheWholeTreeAndDropsTheLateAnalysis() async throws {
        let gate = AsyncGate()
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            await gate.pass()
            return DiskFixture.analysis(result, home: home)
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        XCTAssertEqual(model.phase, .analyzing)
        model.cancel()
        XCTAssertEqual(model.phase, .cancelled)
        gate.open()
        // Let the analysis come back; it must not be shown.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.analysis)
        XCTAssertEqual(model.result?.outcome, .completed)
        XCTAssertEqual(Set(model.rows.map(\.name)), [".Trash", "Documents", "Library"])
        Self.assertWholeTreeCancelled(model)
    }

    /// Cancel pressed after the scanner finished reading, before the model takes the result: the whole tree is shown
    /// as cancelled, and nothing is analyzed in the cancelled task.
    func testCancellingAfterTheScanFinishedReadingDoesNotAnalyze() async throws {
        let gate = AsyncGate()
        let analyzed = OSAllocatedUnfairLock(initialState: 0)
        let home = fixture.home
        let model = fixture.model(service: fixture.service(scan: { root, onProgress in
            let scanned = await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
            await gate.pass()
            return scanned
        }, analyze: { result, _ in
            analyzed.withLock { $0 += 1 }
            return DiskFixture.analysis(result, home: home)
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        XCTAssertEqual(model.phase, .scanning)
        model.cancel()
        gate.open()
        try await DiskFixture.wait { !model.isScanning }

        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertEqual(model.result?.outcome, .completed)
        XCTAssertNil(model.analysis)
        XCTAssertEqual(analyzed.withLock { $0 }, 0)
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(Set(model.rows.map(\.name)), [".Trash", "Documents", "Library"])
        Self.assertWholeTreeCancelled(model)
    }

    /// A scan cancelled before it reported anything, perhaps stuck looking up a stalled root, is abandoned at once:
    /// the section is usable again, the late result is dropped, and a new scan runs normally.
    func testCancellingAScanThatHasReportedNothingAbandonsItAtOnce() async throws {
        let gate = AsyncGate()
        let model = fixture.model(service: fixture.service(scan: { root, onProgress in
            await gate.pass()
            return await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        XCTAssertEqual(model.phase, .scanning)
        XCTAssertNil(model.progress)

        model.cancel()
        XCTAssertFalse(model.isScanning)
        XCTAssertFalse(model.isCancelling)
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.result)
        XCTAssertEqual(model.statusText, "Scan of ~ cancelled before anything was read.")
        XCTAssertEqual(model.sections.first?.note, "The scan was cancelled before anything was read.")

        gate.open()
        // Let the abandoned scan come back; it must not be shown.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.phase, .cancelled)
        XCTAssertNil(model.result)
        XCTAssertNil(model.progress)

        model.scan()
        try await DiskFixture.wait { model.phase == .completed }
        XCTAssertEqual(model.result?.outcome, .completed)
        XCTAssertEqual(Set(model.rows.map(\.name)), [".Trash", "Documents", "Library"])
    }

    /// A tree read in full and cancelled before its analysis says so, without the partial scan's wording.
    private static func assertWholeTreeCancelled(_ model: DiskWindowModel, file: StaticString = #filePath, line: UInt = #line) {
        let status = model.statusText
        XCTAssertTrue(status.contains("Cancelled before origins and suggestions were worked out; the whole folder tree is shown."),
                      status, file: file, line: line)
        XCTAssertFalse(status.contains("before it stopped"), status, file: file, line: line)
        XCTAssertFalse(status.contains(DiskBadge.partial.title), status, file: file, line: line)
        XCTAssertNil(model.sections.first?.note, file: file, line: line)
        XCTAssertFalse(model.rows.contains { $0.badges.contains(.partial) }, file: file, line: line)
        model.tab = .suggestions
        XCTAssertEqual(model.sections.first?.note, "The scan finished reading, but was cancelled before origins and "
                       + "suggestions were worked out. Scan again to see them.", file: file, line: line)
        model.tab = .folders
    }

    /// A scan that cannot start says why, with no volume header, whether the header was read before or after.
    func testAScanThatCannotStartSaysWhy() async throws {
        let (scanGate, openScan) = AsyncStream<Void>.makeStream()
        let (volumeGate, openVolume) = AsyncStream<Void>.makeStream()
        let headerFirst = OSAllocatedUnfairLock(initialState: true)
        let model = fixture.model(service: fixture.service(
            scan: { root, onProgress in
                if headerFirst.withLock({ $0 }) { for await _ in scanGate {} }
                return await DiskScanService.scan(DiskScanner(workers: 2), root: root, onProgress: onProgress)
            },
            volume: { _ in
                if !headerFirst.withLock({ $0 }) { for await _ in volumeGate {} }
                return DiskFixture.volume
            }))
        model.chooseFolder(fixture.path("missing"))
        XCTAssertEqual(model.scopes.map(\.title), ["Home", "missing"])
        model.scan()
        try await DiskFixture.wait { model.volumeHeader != nil }
        openScan.finish()
        try await DiskFixture.wait { !model.isScanning }
        guard case let .failed(message) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(message, "~/missing could not be opened: No such file or directory.")
        XCTAssertEqual(model.sections.first?.note, "The scan did not run.")
        XCTAssertNil(model.volumeHeader)

        headerFirst.withLock { $0 = false }
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        XCTAssertEqual(model.statusText, "The scan did not run. ~/missing could not be opened: No such file or directory.")
        openVolume.finish()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(model.volumeHeader, "a header read after the scan failed is not shown")
    }

    /// A volume that goes away leaves the picker, and a scope set to it falls back to Home.
    func testAnUnmountedVolumeLeavesThePicker() {
        let model = fixture.model()
        let external = DiskScope.volume(name: "External", path: "/Volumes/External")
        model.setVolumes([.volume(name: "Macintosh HD", path: "/"), external])
        model.scope = external
        XCTAssertEqual(model.scopes.map(\.title), ["Home", "Macintosh HD", "External"])
        model.setVolumes([.volume(name: "Macintosh HD", path: "/")])
        XCTAssertEqual(model.scopes.map(\.title), ["Home", "Macintosh HD"])
        XCTAssertEqual(model.scope, .home)
    }

    /// A renamed volume stays the scope under its new name, whether its mount path stayed (the startup disk) or moved
    /// with the name; only unmounting falls back to Home.
    func testARenamedVolumeStaysTheScope() {
        let model = fixture.model()
        model.setVolumes([.volume(name: "Macintosh HD", path: "/")])
        model.scope = .volume(name: "Macintosh HD", path: "/")
        model.setVolumes([.volume(name: "Main", path: "/")])
        XCTAssertEqual(model.scope, .volume(name: "Main", path: "/"))

        model.setVolumes([.volume(name: "Main", path: "/"), .volume(name: "External", path: "/Volumes/External")])
        model.scope = .volume(name: "External", path: "/Volumes/External")
        let renamed = DiskScope.volume(name: "Backup", path: "/Volumes/Backup")
        model.setVolumes([.volume(name: "Main", path: "/"), renamed],
                         renamed: (from: "/Volumes/External", to: "/Volumes/Backup"))
        XCTAssertEqual(model.scope, renamed)
        XCTAssertEqual(model.scopes.map(\.title), ["Home", "Main", "Backup"])

        model.setVolumes([.volume(name: "Main", path: "/")])
        XCTAssertEqual(model.scope, .home)
    }

    /// A volume renamed while no rename was seen (the Disk section was not shown) is found by its UUID under its new
    /// name and mount path; another volume mounted at the old path is not taken for it.
    func testAVolumeRenamedUnseenStaysTheScopeByItsUUID() {
        let model = fixture.model()
        let main = DiskScope.volume(name: "Macintosh HD", path: "/", id: "MAIN")
        let external = DiskScope.volume(name: "External", path: "/Volumes/External", id: "EXT")
        model.setVolumes([main, external])
        model.scope = external
        let renamed = DiskScope.volume(name: "Backup", path: "/Volumes/Backup", id: "EXT")
        model.setVolumes([main, renamed])
        XCTAssertEqual(model.scope, renamed)
        XCTAssertEqual(model.scope.title, "Backup")

        model.setVolumes([main, .volume(name: "Backup", path: "/Volumes/Backup", id: "OTHER")])
        XCTAssertEqual(model.scope, .home, "a different volume at the same mount path is not the one selected")
    }

    /// Volumes are read through the injected reader; a slower, older refresh does not overwrite a newer one.
    func testTheLatestVolumeRefreshWins() async {
        let model = fixture.model()
        let (gate, open) = AsyncStream<Void>.makeStream()
        let stale = DiskScope.volume(name: "Stale", path: "/Volumes/Stale", id: "STALE")
        let current = DiskScope.volume(name: "Current", path: "/Volumes/Current", id: "CURRENT")
        let reading = expectation(description: "the older refresh is reading")
        let older = Task {
            await model.refreshVolumes {
                reading.fulfill()
                for await _ in gate {}
                return [stale]
            }
        }
        await fulfillment(of: [reading], timeout: 10)
        await model.refreshVolumes { [current] }
        XCTAssertEqual(model.volumes, [current])
        open.finish()
        await older.value
        XCTAssertEqual(model.volumes, [current])
    }

    /// Docker's image space is asked for whenever the home folder is scanned, picked as Home or chosen as a folder, and
    /// not for another folder.
    func testDockerIsAskedForAScanOfTheHomeFolderHoweverItWasPicked() async throws {
        let asked = OSAllocatedUnfairLock(initialState: [Bool]())
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, includeDocker in
            asked.withLock { $0.append(includeDocker) }
            return DiskFixture.analysis(result, home: home)
        }))
        for scope in [DiskScope.home, .folder(path: home), .folder(path: fixture.path("Documents"))] {
            model.scope = scope
            model.scan()
            try await DiskFixture.wait { !model.isScanning }
            XCTAssertEqual(model.phase, .completed, "\(scope)")
        }
        XCTAssertEqual(asked.withLock { $0 }, [true, true, false])
    }

    /// A scan replaced by a new one before its analysis came back never shows that analysis.
    func testAReplacedScansLateAnalysisIsDropped() async throws {
        let gate = AsyncGate()
        let home = fixture.home
        let documents = fixture.path("Documents")
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            if result.tree.rootPath == home { await gate.pass() }
            return DiskFixture.analysis(result, home: home)
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        model.scope = .folder(path: documents)
        model.scan()
        try await DiskFixture.wait { model.phase == .completed }
        gate.open()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(model.scannedScope, .folder(path: documents))
        XCTAssertEqual(model.result?.tree.rootPath, documents)
        XCTAssertEqual(model.breadcrumbs.map(\.name), ["~/Documents"])
    }

    /// The live analysis runs detached, off the main actor; cancelling the scan's task must reach it.
    func testCancellingTheCallerCancelsDetachedWork() async {
        let started = expectation(description: "work started")
        let caller = Task {
            await DiskScanService.detached { () -> Bool in
                started.fulfill()
                let deadline = Date().addingTimeInterval(10)
                while !Task.isCancelled, Date() < deadline { usleep(1_000) }
                return Task.isCancelled
            }
        }
        await fulfillment(of: [started], timeout: 10)
        caller.cancel()
        let sawCancel = await caller.value
        XCTAssertTrue(sawCancel, "the detached work ran to its deadline without seeing Cancel")
    }

    // MARK: Accessibility

    func testEveryRowBreadcrumbAndHeaderHasASpokenLabel() async throws {
        try fixture.lock("Locked")
        let model = try await fixture.scanned()
        var checked = 0
        for tab in DiskTab.allCases {
            model.tab = tab
            while let closed = model.rows.first(where: { $0.isExpandable && !$0.isExpanded }) {
                model.setExpanded(closed.id, true)
            }
            for row in model.rows {
                XCTAssertFalse(row.accessibilityLabel.trimmingCharacters(in: .whitespaces).isEmpty, "\(tab) \(row.id)")
                XCTAssertFalse(row.accessibilityValue.trimmingCharacters(in: .whitespaces).isEmpty, "\(tab) \(row.id)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 20)
        model.tab = .folders
        model.open(try XCTUnwrap(model.row(named: "Documents")).id)
        XCTAssertEqual(model.breadcrumbs.map(\.accessibilityLabel), ["Go to ~", "Go to ~/Documents"])
        XCTAssertFalse(try XCTUnwrap(model.volumeHeader).accessibilityLabel.isEmpty)
        XCTAssertFalse(try XCTUnwrap(model.unreadableBanner).accessibilityLabel.isEmpty)
        XCTAssertEqual(try XCTUnwrap(model.row(named: "big.bin")).accessibilityLabel, "big.bin, File")
    }

    private static func index(_ id: DiskRowID) -> Int {
        guard case let .item(index) = id else { fatalError("\(id)") }
        return index
    }
}
