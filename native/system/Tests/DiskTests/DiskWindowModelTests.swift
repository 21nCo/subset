import Foundation
import SystemCore
@testable import SystemDisk
import SystemProcesses
import XCTest

/// The Disk section's view model without the UI, on a fixture home folder scanned with the real scanner: breadcrumb
/// navigation, sort order, each tab's contents, the unreadable-folder banner, cancelling, and spoken labels.
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

    func testFoldersSortBySizeOrNameWithUnknownSizesLastAndLongListsCapped() async throws {
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
        XCTAssertEqual(capped.rows.map(\.name), ["Documents", "Library", "2 more items"])
        XCTAssertNil(capped.rows.last?.path)
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
        XCTAssertEqual(Set(model.rows.map(\.name)), [".Trash", "Documents", "Library"])
        XCTAssertTrue(try XCTUnwrap(model.row(named: "Documents")).badges.contains(.partial))
        XCTAssertNotNil(model.sections.first?.note)
        XCTAssertNil(model.analysis)
        model.tab = .suggestions
        XCTAssertEqual(model.sections.first?.note,
                       "The scan was cancelled before origins and suggestions were worked out. Scan again to see them.")
    }

    func testCancellingWhileSuggestionsAreWorkedOutKeepsTheWholeTreeAndDropsTheLateAnalysis() async throws {
        let gate = Gate()
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            gate.pass()
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
    }

    func testAScanThatCannotStartSaysWhy() async throws {
        let model = fixture.model()
        model.chooseFolder(fixture.path("missing"))
        XCTAssertEqual(model.scopes.map(\.title), ["Home", "missing"])
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        guard case let .failed(message) = model.phase else { return XCTFail("\(model.phase)") }
        XCTAssertEqual(message, "~/missing could not be opened: No such file or directory.")
        XCTAssertEqual(model.sections.first?.note, "The scan did not run.")
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
