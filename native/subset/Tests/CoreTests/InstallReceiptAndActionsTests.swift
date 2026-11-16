import Foundation
@testable import SubsetCore
import XCTest

/// The receipt shared with `subset list` (SET-227), and the window's Install, Update and Move to Trash actions.
@MainActor
final class InstallReceiptAndActionsTests: XCTestCase {
    private var root: URL!
    private var system: URL { root.appendingPathComponent("Applications") }
    private var receipts: URL { root.appendingPathComponent("receipts") }
    private var systemFolder: ApplicationsFolder { ApplicationsFolder(label: "/Applications", path: "/Applications", directory: system) }
    private var folders: [ApplicationsFolder] {
        [systemFolder, ApplicationsFolder(label: "~/Applications", path: "/Users/alex/Applications", directory: root.appendingPathComponent("user"))]
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subset-actions-\(UUID().uuidString)")
        for folder in [system, receipts, root.appendingPathComponent("user"), root.appendingPathComponent("tmp"), root.appendingPathComponent("Trash")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Receipt

    /// `subset install` writes this fixture for the same install (apps.test.mjs checks it), and `subset list` reads it.
    static let sharedFixture = CatalogFeedTests.feedFolder.appendingPathComponent("fixtures/receipt-valid-written-by-install.json")

    func testTheManagersReceiptIsTheTextSubsetWritesAndReads() throws {
        let release = ChosenRelease(
            CatalogApp(
                id: "breaks", name: "Breaks", summary: "s", appName: "Breaks", bundleID: "dev.subset.breaks", live: nil,
                beta: BetaRelease(version: "0.1.1", build: 4, url: "", sha256: "6d37efbe0af41ce3b1acbdff2b70990988be4318799e40f99dcedf417c612f4d", releaseURL: "")
            ),
            channel: .beta
        )!
        let document = try XCTUnwrap(ReceiptDocument(AppInstallerTests.breaks, release, folder: systemFolder, receipts: receipts))
        let installedAt = ISO8601DateFormatter().date(from: "2026-11-13T12:00:05Z")!
        XCTAssertEqual(document.text(installedAt: installedAt), try Data(contentsOf: Self.sharedFixture))

        // And the other way: the receipt `subset install` wrote describes the installed beta.
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.1.1", build: "4")
        try FileManager.default.copyItem(at: Self.sharedFixture, to: receipts.appendingPathComponent("dev.subset.breaks.json"))
        let finder = InstalledAppFinder(folders: folders, receipts: receipts)
        XCTAssertEqual(finder.copies(of: AppInstallerTests.breaks).first?.channel, .beta)
    }

    func testNoReceiptIsWrittenForAFolderTheSchemaCannotName() {
        let elsewhere = ApplicationsFolder(label: "~/Applications", path: "/var/home/alex/Applications", directory: system)
        XCTAssertNil(ReceiptDocument(AppInstallerTests.breaks, AppInstallerTests.live, folder: elsewhere, receipts: receipts))
        XCTAssertEqual(ReceiptDocument.json("a\"b\\c\u{1}\n"), #""a\"b\\c\u0001\n""#)
    }

    // MARK: - Actions

    private func actions(running: FakeRunning = FakeRunning(), images: FakeImages = FakeImages()) async -> (AppActions, AppListModel) {
        let catalog = Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [AppInstallerTests.breaks], tools: [])
        let loader = RecordedLoader([.success(LoadedCatalog(catalog: catalog, url: URL(string: "https://subset.21n.dev/catalog/v1.json")!, fetchedAt: Date(), cached: false))])
        let finder = InstalledAppFinder(folders: folders, receipts: receipts)
        let model = AppListModel(loader: loader, finder: finder, defaults: UserDefaults(suiteName: "subset-actions-\(UUID().uuidString)")!)
        await model.refresh()
        images.volumes = [AppInstallerTests.liveImage: ["Breaks": { try AppInstallerTests.imageVolume($0, version: "0.1.0", build: "12") }]]
        let installer = AppInstaller(
            setup: InstallSetup(folders: folders, receipts: receipts, locks: root.appendingPathComponent("locks"), temporary: root.appendingPathComponent("tmp")),
            downloader: FakeDownloader(images: [AppInstallerTests.live.url: AppInstallerTests.liveImage]), images: images,
            verifier: FakeVerifier(), trash: FolderTrash(folder: root.appendingPathComponent("Trash")), running: running, quitTimeout: 1
        )
        return (AppActions(installer: installer, model: model), model)
    }

    func testInstallShowsProgressThenWhereItInstalledAndListsTheApp() async throws {
        let (actions, model) = await actions()
        XCTAssertEqual(model.rows.first?.install, "0.1.0")
        actions.install("breaks")
        XCTAssertTrue(actions.isBusy("breaks"))
        XCTAssertNotNil(actions.activities["breaks"])
        await actions.wait("breaks")
        XCTAssertEqual(actions.activities["breaks"], .succeeded("Installed 0.1.0 in \(system.path)."))
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.1.0"])
        XCTAssertFalse(actions.isBusy("breaks"))
    }

    func testAFailureIsAPlainSentenceNamingTheStep() async throws {
        let images = FakeImages()
        let (actions, _) = await actions(images: images)
        images.volumes = [:]
        actions.install("breaks")
        await actions.wait("breaks")
        XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not installed: the image step failed: hdiutil could not attach the image (not a disk image)."))
        actions.dismiss("breaks")
        XCTAssertNil(actions.activities["breaks"])
    }

    func testARunningAppIsQuitOnlyAfterTheUserAgrees() async throws {
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        let running = FakeRunning()
        running.running.update { $0.insert(self.system.appendingPathComponent("Breaks.app").path) }
        let (actions, model) = await actions(running: running)
        XCTAssertEqual(model.rows.first?.update, "0.1.0")

        actions.update("breaks")
        XCTAssertEqual(actions.quitRequest, QuitRequest(appID: "breaks", appName: "Breaks", kind: .update))
        XCTAssertFalse(actions.isBusy("breaks"), "nothing starts before the user answers")
        actions.quitRequest = nil
        XCTAssertEqual(running.quits.get(), [])

        actions.update("breaks")
        actions.confirmQuit()
        XCTAssertNil(actions.quitRequest)
        await actions.wait("breaks")
        guard case .succeeded(let text)? = actions.activities["breaks"] else { return XCTFail("\(String(describing: actions.activities["breaks"]))") }
        XCTAssertTrue(text.hasPrefix("Updated to 0.1.0."), text)
        XCTAssertEqual(running.quits.get().count, 1)
        XCTAssertEqual(running.reopened.get().count, 1)
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.1.0"])
    }

    func testCancelStopsTheOperationBeforeAnythingIsInstalled() async throws {
        let (actions, _) = await actions()
        actions.install("breaks")
        actions.cancel("breaks")
        await actions.wait("breaks")
        XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not installed: it was cancelled before anything was changed."))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: system.path), [])
    }

    func testQuittingCancelsWhatRunsAndWaitsForItsCleanup() async throws {
        let (actions, _) = await actions()
        actions.install("breaks")
        XCTAssertTrue(actions.isWorking)
        await actions.cancelAll()
        XCTAssertFalse(actions.isWorking)
        guard case .failed? = actions.activities["breaks"] else { return XCTFail("\(String(describing: actions.activities["breaks"]))") }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: system.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path), [])
    }
}
