import Combine
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

    private func actions(
        running: FakeRunning = FakeRunning(), images: FakeImages = FakeImages(), verifier: FakeVerifier = FakeVerifier(),
        finder: (any InstalledAppDetecting)? = nil
    ) async -> (AppActions, AppListModel) {
        let catalog = Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: [AppInstallerTests.breaks], tools: [])
        let loader = RecordedLoader([.success(LoadedCatalog(catalog: catalog, url: URL(string: "https://subset.21n.dev/catalog/v1.json")!, fetchedAt: Date(), cached: false))])
        let finder = finder ?? InstalledAppFinder(folders: folders, receipts: receipts)
        let model = AppListModel(loader: loader, finder: finder, defaults: UserDefaults(suiteName: "subset-actions-\(UUID().uuidString)")!)
        await model.refresh()
        images.volumes = [AppInstallerTests.liveImage: ["Breaks": { try AppInstallerTests.imageVolume($0, version: "0.1.0", build: "12") }]]
        let installer = AppInstaller(
            setup: InstallSetup(folders: folders, receipts: receipts, locks: root.appendingPathComponent("locks"), temporary: root.appendingPathComponent("tmp")),
            downloader: FakeDownloader(images: [AppInstallerTests.live.url: AppInstallerTests.liveImage]), images: images,
            verifier: verifier, trash: FolderTrash(folder: root.appendingPathComponent("Trash")), running: running, quitTimeout: 1
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
        XCTAssertEqual(actions.quitRequest?.message, "Breaks is running. Subset asks it to quit before the new version is put in place; open it again once the update ends.")
        XCTAssertFalse(actions.isBusy("breaks"), "nothing starts before the user answers")
        actions.quitRequest = nil
        XCTAssertEqual(running.quits.get(), [])

        actions.update("breaks")
        // The alert's binding clears the request as it is dismissed, before its Quit button's action runs: the
        // operation it presented starts anyway.
        let presented = try XCTUnwrap(actions.quitRequest)
        actions.quitRequest = nil
        actions.confirmQuit(presented)
        XCTAssertNil(actions.quitRequest)
        XCTAssertTrue(actions.isBusy("breaks"))
        await actions.wait("breaks")
        guard case .succeeded(let text)? = actions.activities["breaks"] else { return XCTFail("\(String(describing: actions.activities["breaks"]))") }
        XCTAssertTrue(text.hasPrefix("Updated to 0.1.0."), text)
        XCTAssertTrue(text.hasSuffix(" Breaks was asked to quit for the update. Open Breaks again."), text)
        XCTAssertEqual(running.quits.get().count, 1)
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.1.0"])
    }

    func testAnUnreadableProcessListIsAPlainRefusalNotAPrompt() async throws {
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        let running = FakeRunning()
        running.unreadable = true
        let (actions, model) = await actions(running: running)
        actions.update("breaks")
        XCTAssertNil(actions.quitRequest)
        await actions.wait("breaks")
        XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not updated to 0.1.0: whether the app is running cannot be read (fake)."))
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.0.9"])
    }

    func testAPartlyDoneUpdateSaysWhatItChanged() async throws {
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        let user = root.appendingPathComponent("user")
        try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
        var verifier = FakeVerifier()
        let userPath = user.path
        verifier.during = { staged in
            if staged.path.hasPrefix(userPath) { throw InstallFailure(.team, "TeamIdentifier: ABCDE12345") }
        }
        let (actions, model) = await actions(verifier: verifier)
        actions.update("breaks")
        await actions.wait("breaks")
        guard case .failed(let text)? = actions.activities["breaks"] else { return XCTFail("\(String(describing: actions.activities["breaks"]))") }
        XCTAssertTrue(text.hasPrefix("Breaks was only partly updated to 0.1.0: the team check failed: TeamIdentifier: ABCDE12345. Updated the copy in /Applications from 0.0.9 to 0.1.0. Moved Breaks 0.0.9 (/Applications) to the Trash: "), text)
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.1.0", "0.0.8"])
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

    // An install has ended and its row waits for the installed apps to be looked for again, which a stalled folder holds
    // up: quitting Subset does not wait for that look.
    func testQuittingDoesNotWaitForTheInstalledAppsToBeLookedForAgain() async throws {
        let gated = GatedFinder(InstalledAppFinder(folders: folders, receipts: receipts), gatedCalls: [2])
        let (actions, _) = await actions(finder: gated)
        actions.install("breaks")
        for _ in 0..<500 where !gated.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gated.isWaiting)
        XCTAssertTrue(actions.isBusy("breaks"), "the row stays disabled until its app is looked for again")
        XCTAssertFalse(actions.isWorking, "the install itself has ended")
        // Should quitting wait for the look, the look is let go after 3 seconds and the elapsed time says so.
        let fallback = Task.detached {
            try? await Task.sleep(for: .seconds(3))
            gated.release()
        }
        let started = Date()
        await actions.cancelAll()
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "quitting did not wait for the look")
        gated.release()
        fallback.cancel()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("tmp").path), [], "the install cleaned up")
    }

    // The result shows once the install has cleaned up, even while an earlier look for installed apps holds up the next
    // one; the row's buttons (Cancel included, with nothing left to stop) wait until the app is listed.
    func testAResultShowsAtOnceAndTheRowWaitsForItsNewState() async throws {
        let gated = GatedFinder(InstalledAppFinder(folders: folders, receipts: receipts), gatedCalls: [2], readsAfterGate: true)
        let (actions, model) = await actions(finder: gated)
        actions.install("breaks")
        for _ in 0..<500 where !gated.isWaiting { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(gated.isWaiting)
        for _ in 0..<500 where actions.canCancel("breaks") { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(actions.activities["breaks"], .succeeded("Installed 0.1.0 in \(system.path)."))
        XCTAssertTrue(actions.isBusy("breaks"))
        XCTAssertFalse(actions.canCancel("breaks"))
        XCTAssertEqual(model.installed["breaks"] ?? [], [], "not listed yet")
        gated.release()
        await actions.wait("breaks")
        XCTAssertFalse(actions.isBusy("breaks"))
        XCTAssertEqual(model.installed["breaks"]?.first?.versionLabel, "0.1.0", "the row is enabled with the app listed")
    }

    func testOnceQuittingStartsNoOperationOrPendingQuitStarts() async throws {
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        let running = FakeRunning()
        running.running.update { $0.insert(self.system.appendingPathComponent("Breaks.app").path) }
        let (actions, _) = await actions(running: running)
        actions.update("breaks")
        let pending = try XCTUnwrap(actions.quitRequest)
        await actions.cancelAll()
        XCTAssertNil(actions.quitRequest, "the question is withdrawn")
        actions.confirmQuit(pending)
        actions.moveToTrash("breaks")
        actions.install("breaks")
        XCTAssertFalse(actions.isWorking)
        XCTAssertNil(actions.activities["breaks"])
        XCTAssertEqual(running.quits.get(), [])
    }

    // The row comes back only once a look for installed apps begun after its operation ended is published, however
    // long that look is held up: until then its buttons stay disabled (an Install chosen from the state before the
    // operation would put a second copy in place), it says the list is still being read, and Install or Move to Trash
    // pressed meanwhile starts nothing. Once the look is published, the note goes and the row offers what is installed.
    func testARowComesBackOnlyOnceALookBegunAfterItsOperationIsPublished() async throws {
        let user = root.appendingPathComponent("user")
        let stalled = GatedFinder(InstalledAppFinder(folders: folders, receipts: receipts), gatedCalls: [2], readsAfterGate: true)
        let (row, model) = await actions(finder: stalled)
        row.listNoteDelay = .milliseconds(100)
        row.install("breaks")
        try await waitFor { stalled.isWaiting }
        try await waitFor { !row.canCancel("breaks") }
        let installed = "Installed 0.1.0 in \(system.path)."
        XCTAssertEqual(row.activities["breaks"], .succeeded(installed), "the result shows at once")
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(row.isBusy("breaks"), "the row waits for the look, with no time limit")
        XCTAssertEqual(row.activities["breaks"], .succeeded("\(installed) \(AppActions.listPending)"))
        XCTAssertEqual(model.installed["breaks"] ?? [], [], "only the state before the install is known")
        // With /Applications not writable, a stale Install would put a second copy in ~/Applications.
        chmod(system.path, 0o555)
        defer { chmod(system.path, 0o755) }
        let receiptBefore = try Data(contentsOf: receipts.appendingPathComponent("dev.subset.breaks.json"))
        row.install("breaks")
        row.moveToTrash("breaks")
        XCTAssertFalse(row.canCancel("breaks"), "nothing started")
        XCTAssertNil(row.quitRequest)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: user.path), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: system.path), ["Breaks.app"])
        XCTAssertEqual(try Data(contentsOf: receipts.appendingPathComponent("dev.subset.breaks.json")), receiptBefore)
        stalled.release()
        await row.wait("breaks")
        XCTAssertFalse(row.isBusy("breaks"))
        XCTAssertEqual(row.activities["breaks"], .succeeded(installed), "the note goes once the list shows the install")
        XCTAssertEqual(model.rows.first?.installed.map(\.versionLabel), ["0.1.0"])
        XCTAssertNil(model.rows.first?.update, "the row offers what the install left")
    }

    // The look after an install never ends (a folder that stays stalled): it is given up and the next look shows the
    // install, so the row comes back; when every look stalls, the row stays disabled with its note, and Refresh still
    // ends.
    func testARowComesBackAfterAStalledLookIsGivenUpAndOtherwiseStaysDisabled() async throws {
        let stuck = GatedFinder(InstalledAppFinder(folders: folders, receipts: receipts), gatedCalls: [2])
        let (row, model) = await actions(finder: stuck)
        model.scanStall = .milliseconds(200)
        row.install("breaks")
        try await waitFor { stuck.isWaiting }
        await row.wait("breaks")
        XCTAssertFalse(row.isBusy("breaks"))
        XCTAssertEqual(model.installed["breaks"]?.first?.versionLabel, "0.1.0")
        stuck.release()

        let allStuck = GatedFinder(InstalledAppFinder(folders: folders, receipts: receipts), gatedCalls: Set(2...20))
        let (later, laterModel) = await actions(finder: allStuck)
        laterModel.scanStall = .milliseconds(100)
        laterModel.refreshWait = .milliseconds(200)
        later.listNoteDelay = .milliseconds(100)
        later.moveToTrash("breaks")
        try await waitFor { allStuck.isWaiting }
        try await Task.sleep(for: .milliseconds(600))
        XCTAssertTrue(later.isBusy("breaks"), "no look begun after the operation was published")
        guard case .succeeded(let text)? = later.activities["breaks"] else { return XCTFail("\(String(describing: later.activities["breaks"]))") }
        XCTAssertTrue(text.hasSuffix(AppActions.listPending), text)
        await laterModel.refresh(force: true)
        XCTAssertFalse(laterModel.isRefreshing, "Refresh ends")
        XCTAssertTrue(later.isBusy("breaks"))
        for _ in 0..<20 { allStuck.release() }
    }

    // Cancelled while the app quits, through either row action: no copy changed, so the row says it was not updated or
    // moved (not "only partly"), and that the app was asked to quit.
    func testAQuitOnlyCancelSaysNothingWasChanged() async throws {
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        let path = system.appendingPathComponent("Breaks.app").path
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            let running = FakeRunning()
            running.running.update { $0.insert(path) }
            running.cancelDuringQuit = true
            let (actions, _) = await actions(running: running)
            actions.confirmQuit(QuitRequest(appID: "breaks", appName: "Breaks", kind: kind))
            await actions.wait("breaks")
            switch kind {
            case .update:
                XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not updated to 0.1.0: it was cancelled before it was installed. Breaks was asked to quit for the update. Open Breaks again."))
            case .moveToTrash:
                XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not moved to the Trash: it was cancelled after the app was asked to quit, before any copy was changed. Breaks at \(path) was asked to quit."))
            }
            XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleShortVersionString"] as? String, "0.0.9")
        }
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
