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
        finder: (any InstalledAppDetecting)? = nil, catalogs: [Catalog] = [InstallReceiptAndActionsTests.catalog([AppInstallerTests.breaks])]
    ) async -> (AppActions, AppListModel) {
        let url = URL(string: "https://subset.21n.dev/catalog/v1.json")!
        let loader = RecordedLoader(catalogs.map { .success(LoadedCatalog(catalog: $0, url: url, fetchedAt: Date(), cached: false)) })
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
        await actions.wait("breaks")
        XCTAssertEqual(actions.quitRequest?.asks("breaks", AppInstallerTests.breaks, kind: .update), true)
        XCTAssertEqual(actions.quitRequest?.message, "Breaks is running. Subset asks it to quit before the new version is put in place; open it again once the update ends.")
        XCTAssertFalse(actions.isBusy("breaks"), "nothing starts before the user answers")
        actions.dismissQuit(try XCTUnwrap(actions.quitRequest))
        XCTAssertNil(actions.quitRequest)
        XCTAssertEqual(running.quits.get(), [])

        actions.update("breaks")
        await actions.wait("breaks")
        // The alert's binding clears the request as it is dismissed, before its Quit button's action runs: the
        // operation it presented starts anyway.
        let presented = try XCTUnwrap(actions.quitRequest)
        actions.dismissQuit(presented)
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
        await actions.wait("breaks")
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

    // A row's buttons depend on what the model knows of its app, so a change of the model is a change of the actions,
    // which the rows observe: an app that becomes known with no copy installed re-renders its row enabled.
    func testTheActionsChangeWhenTheModelDoes() async throws {
        let (actions, model) = await actions()
        let changes = Recorder(0)
        let watching = actions.objectWillChange.sink { _ in changes.update { $0 += 1 } }
        try makeBundle(system.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.9")
        await model.reloadInstalled()
        watching.cancel()
        XCTAssertGreaterThan(changes.get(), 0)
        XCTAssertFalse(actions.isBusy("breaks"))
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
            actions.confirmQuit(QuitRequest(appID: "breaks", AppInstallerTests.breaks, kind: kind))
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

    // The answer to the quit question holds only for the app the alert named: a refresh that gives its row to another
    // app (another bundle ID and name under the same ID), or to the same app installed under another bundle name, while
    // the alert is open makes the answer quit, update and move nothing, and says so plainly. The same answer for the app
    // still listed works (see testARunningAppIsQuitOnlyAfterTheUserAgrees).
    func testAnAnswerToQuitHoldsOnlyForTheAppTheAlertNamed() async throws {
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            for sameBundleID in [false, true] {
                try tearDownWithError()
                try setUpWithError()
                let label = "\(kind) sameBundleID=\(sameBundleID)"
                let otherName = sameBundleID ? "BreaksCopy" : "Other"
                let otherID = sameBundleID ? "dev.subset.breaks" : "dev.subset.other"
                let breaksPath = system.appendingPathComponent("Breaks.app").path
                let otherPath = system.appendingPathComponent("\(otherName).app").path
                try makeBundle(URL(fileURLWithPath: breaksPath), bundleID: "dev.subset.breaks", version: "0.0.9")
                try makeBundle(URL(fileURLWithPath: otherPath), bundleID: otherID, version: "0.0.9")
                let running = FakeRunning()
                running.running.update { $0.formUnion([breaksPath, otherPath]) }
                let other = CatalogApp(
                    id: "breaks", name: sameBundleID ? "Breaks" : "Other", summary: "s", appName: otherName, bundleID: otherID,
                    live: AppInstallerTests.breaks.live, beta: nil
                )
                let images = FakeImages()
                let (actions, model) = await actions(running: running, images: images, catalogs: [Self.catalog([AppInstallerTests.breaks]), Self.catalog([other])])
                images.volumes = [AppInstallerTests.liveImage: [otherName: { try AppInstallerTests.imageVolume($0, version: "0.1.0", build: "12", name: "\(otherName).app", bundleID: otherID) }]]
                if kind == .update { actions.update("breaks") } else { actions.moveToTrash("breaks") }
                await actions.wait("breaks")
                let request = try XCTUnwrap(actions.quitRequest, label)
                XCTAssertEqual([request.bundleID, request.bundleName], ["dev.subset.breaks", "Breaks"], label)
                await model.refresh()
                actions.dismissQuit(request)
                actions.confirmQuit(request)
                await actions.wait("breaks")
                XCTAssertEqual(running.quits.get(), [], "\(label): nothing is quit")
                XCTAssertEqual(actions.activities["breaks"], .failed("Nothing was quit or changed: the list changed while Subset asked to quit Breaks, so that answer no longer applies. Try again."), label)
                for (path, bundleID) in [(breaksPath, "dev.subset.breaks"), (otherPath, otherID)] {
                    let info = InstalledAppFinder.infoPlist(path)
                    XCTAssertEqual(info?["CFBundleIdentifier"] as? String, bundleID, "\(label): \(path) stays")
                    XCTAssertEqual(info?["CFBundleShortVersionString"] as? String, "0.0.9", "\(label): \(path) is not updated")
                }
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path), [], label)
            }
        }
    }

    // Two rows whose running apps are found running one after the other each get their question, one at a time and in
    // the order they came. The alert reports one answer to the first twice (its binding and its Cancel or Quit button,
    // in either order): the second question is not dismissed by it, and comes next, once the first is gone.
    func testQuitQuestionsOfTwoRowsAreAskedInTurn() async throws {
        for answer in ["cancel, then binding", "binding, then cancel", "quit, then binding", "binding, then quit"] {
            try tearDownWithError()
            try setUpWithError()
            let breaksPath = system.appendingPathComponent("Breaks.app").path
            let otherPath = system.appendingPathComponent("Other.app").path
            try makeBundle(URL(fileURLWithPath: breaksPath), bundleID: "dev.subset.breaks", version: "0.0.9")
            try makeBundle(URL(fileURLWithPath: otherPath), bundleID: "dev.subset.other", version: "0.0.9")
            let running = FakeRunning()
            running.running.update { $0.formUnion([breaksPath, otherPath]) }
            let other = CatalogApp(id: "other", name: "Other", summary: "s", appName: "Other", bundleID: "dev.subset.other", live: AppInstallerTests.breaks.live, beta: nil)
            let (actions, _) = await actions(running: running, catalogs: [Self.catalog([AppInstallerTests.breaks, other])])
            actions.moveToTrash("breaks")
            await actions.wait("breaks")
            actions.moveToTrash("other")
            await actions.wait("other")
            let first = try XCTUnwrap(actions.quitRequest, answer)
            XCTAssertTrue(first.asks("breaks", AppInstallerTests.breaks, kind: .moveToTrash), answer)
            let quits = answer.hasPrefix("quit") || answer.hasSuffix("quit")
            for step in answer.components(separatedBy: ", then ") {
                if step == "quit" { actions.confirmQuit(first) } else { actions.dismissQuit(first) }
            }
            XCTAssertNil(actions.quitRequest, "\(answer): the next question waits until the first alert has gone")
            try await waitFor { actions.quitRequest != nil }
            let second = try XCTUnwrap(actions.quitRequest, answer)
            XCTAssertTrue(second.asks("other", other, kind: .moveToTrash), "\(answer): the second question comes next")
            actions.dismissQuit(first)
            XCTAssertEqual(actions.quitRequest, second, "\(answer): a late answer to the first leaves it")
            actions.dismissQuit(second)
            actions.dismissQuit(second)
            XCTAssertNil(actions.quitRequest, answer)
            await actions.wait("breaks")
            XCTAssertEqual(running.quits.get(), quits ? [breaksPath] : [], answer)
        }
    }

    // Cancel pressed after the read found the app running, but before its question is asked, ends the attempt: no
    // question, and the row says it was cancelled.
    func testCancelAfterTheAppIsFoundRunningAsksNothing() async throws {
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            try tearDownWithError()
            try setUpWithError()
            let path = system.appendingPathComponent("Breaks.app").path
            try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.breaks", version: "0.0.9")
            let running = FakeRunning()
            running.running.update { $0.insert(path) }
            let (actions, _) = await actions(running: running)
            let gate = DispatchSemaphore(value: 0)
            let held = Recorder(0)
            running.hold = {
                held.update { $0 += 1 }
                gate.wait()
            }
            if kind == .update { actions.update("breaks") } else { actions.moveToTrash("breaks") }
            try await waitFor { held.get() > 0 }
            // The read answers while the main actor is held, so the answer is in before Cancel is pressed.
            gate.signal()
            usleep(300_000)
            actions.cancel("breaks")
            await actions.wait("breaks")
            let what = kind == .update ? "updated to 0.1.0" : "moved to the Trash"
            XCTAssertNil(actions.quitRequest, "\(kind)")
            XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not \(what): it was cancelled before anything was changed."), "\(kind)")
            XCTAssertFalse(actions.isBusy("breaks"), "\(kind)")
            XCTAssertEqual(running.quits.get(), [], "\(kind)")
        }
    }

    // Whether the app runs is read off the main actor: Update and Move to Trash return at once while that read is held
    // up, the row is busy and says what it is doing, and Cancel ends the wait with nothing quit or changed. A held read
    // that then finds the app running asks the user, and grants no leave to quit by itself.
    func testWhetherTheAppRunsIsReadOffTheMainActorAndCanBeCancelled() async throws {
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            for cancelled in [true, false] {
                try tearDownWithError()
                try setUpWithError()
                let path = system.appendingPathComponent("Breaks.app").path
                try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.breaks", version: "0.0.9")
                let running = FakeRunning()
                running.running.update { $0.insert(path) }
                let (actions, _) = await actions(running: running)
                let gate = DispatchSemaphore(value: 0)
                let held = Recorder(0)
                running.hold = {
                    held.update { $0 += 1 }
                    gate.wait()
                    gate.signal()
                }
                let label = "\(kind) cancelled=\(cancelled)"
                let started = Date()
                if kind == .update { actions.update("breaks") } else { actions.moveToTrash("breaks") }
                XCTAssertLessThan(Date().timeIntervalSince(started), 0.5, label)
                try await waitFor { held.get() > 0 }
                XCTAssertTrue(actions.isBusy("breaks"), label)
                XCTAssertTrue(actions.canCancel("breaks"), label)
                XCTAssertEqual(actions.activities["breaks"], .working("Checking whether Breaks is running…", fraction: nil), label)
                if cancelled {
                    actions.cancel("breaks")
                    await actions.wait("breaks")
                    let what = kind == .update ? "updated to 0.1.0" : "moved to the Trash"
                    XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not \(what): it was cancelled before anything was changed."), label)
                    XCTAssertNil(actions.quitRequest, label)
                    gate.signal()
                } else {
                    gate.signal()
                    await actions.wait("breaks")
                    XCTAssertEqual(actions.quitRequest?.asks("breaks", AppInstallerTests.breaks, kind: kind), true, label)
                    XCTAssertNil(actions.activities["breaks"], label)
                    XCTAssertFalse(actions.isBusy("breaks"), label)
                }
                XCTAssertEqual(running.quits.get(), [], label)
                XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleShortVersionString"] as? String, "0.0.9", label)
                XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path), [], label)
            }
        }
    }

    // A question is asked, and answered, only while the list still shows its row with the app it names and offers its
    // action there. The row is removed, or given to another app, while whether the app runs is read or while the question
    // is presented: no question stays, confirming the presented one quits and changes nothing, and the row says why.
    func testAQuestionIsNotAskedOrAnsweredOnceTheListNoLongerShowsItsApp() async throws {
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            for change in ["removed", "replaced"] {
                for stage in ["during the check", "while presented"] {
                    try tearDownWithError()
                    try setUpWithError()
                    let label = "\(kind) \(change) \(stage)"
                    let path = system.appendingPathComponent("Breaks.app").path
                    try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.breaks", version: "0.0.9")
                    let running = FakeRunning()
                    running.running.update { $0.insert(path) }
                    let other = CatalogApp(
                        id: change == "removed" ? "other" : "breaks", name: "Other", summary: "s", appName: "Other",
                        bundleID: "dev.subset.other", live: AppInstallerTests.breaks.live, beta: nil
                    )
                    let (actions, model) = await actions(running: running, catalogs: [Self.catalog([AppInstallerTests.breaks]), Self.catalog([other])])
                    let gate = DispatchSemaphore(value: 0)
                    let held = Recorder(0)
                    if stage == "during the check" {
                        running.hold = {
                            held.update { $0 += 1 }
                            gate.wait()
                            gate.signal()
                        }
                    }
                    if kind == .update { actions.update("breaks") } else { actions.moveToTrash("breaks") }
                    var presented: QuitRequest?
                    if stage == "during the check" {
                        try await waitFor { held.get() > 0 }
                        await model.refresh()
                        gate.signal()
                        await actions.wait("breaks")
                    } else {
                        await actions.wait("breaks")
                        presented = try XCTUnwrap(actions.quitRequest, label)
                        await model.refresh()
                        try await waitFor { actions.quitRequest == nil }
                    }
                    XCTAssertNil(actions.quitRequest, "\(label): no question stays")
                    XCTAssertEqual(actions.activities["breaks"], .failed("Nothing was quit or changed: the list changed before Subset could quit Breaks, so it no longer asks. Try again."), label)
                    if let presented {
                        actions.dismissQuit(presented)
                        actions.confirmQuit(presented)
                        await actions.wait("breaks")
                        XCTAssertEqual(actions.activities["breaks"], .failed("Nothing was quit or changed: the list changed while Subset asked to quit Breaks, so that answer no longer applies. Try again."), label)
                    }
                    XCTAssertFalse(actions.isWorking, label)
                    XCTAssertEqual(running.quits.get(), [], "\(label): nothing is quit")
                    XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleShortVersionString"] as? String, "0.0.9", label)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: system.path), ["Breaks.app"], label)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: receipts.path), [], label)
                    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("Trash").path), [], label)
                }
            }
        }
    }

    // A question waiting behind another row's is withdrawn once the list no longer shows its app, and the next one the
    // list still offers is asked instead.
    func testAWaitingQuestionTheListNoLongerOffersIsSkipped() async throws {
        let names = ["Breaks", "Other", "Third"]
        let paths = names.map { system.appendingPathComponent("\($0).app").path }
        for (name, path) in zip(names, paths) {
            try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.\(name.lowercased())", version: "0.0.9")
        }
        let running = FakeRunning()
        running.running.update { $0.formUnion(paths) }
        let apps = names.map {
            $0 == "Breaks" ? AppInstallerTests.breaks
                : CatalogApp(id: $0.lowercased(), name: $0, summary: "s", appName: $0, bundleID: "dev.subset.\($0.lowercased())", live: AppInstallerTests.breaks.live, beta: nil)
        }
        let (actions, model) = await actions(running: running, catalogs: [Self.catalog(apps), Self.catalog([apps[0], apps[2]])])
        for app in apps {
            actions.moveToTrash(app.id)
            await actions.wait(app.id)
        }
        let first = try XCTUnwrap(actions.quitRequest)
        XCTAssertTrue(first.asks("breaks", apps[0], kind: .moveToTrash))
        await model.refresh()
        try await waitFor { actions.activities["other"] != nil }
        XCTAssertEqual(actions.quitRequest, first, "the presented question still applies")
        actions.dismissQuit(first)
        try await waitFor { actions.quitRequest != nil }
        XCTAssertEqual(actions.quitRequest?.asks("third", apps[2], kind: .moveToTrash), true, "the next question the list offers is asked")
        XCTAssertEqual(actions.activities["other"], .failed("Nothing was quit or changed: the list changed before Subset could quit Other, so it no longer asks. Try again."))
        actions.dismissQuit(try XCTUnwrap(actions.quitRequest))
        XCTAssertEqual(running.quits.get(), [])
    }

    // A row asked again gets another question: a late dismissal of the earlier one, for the same app and action, leaves
    // the new one presented.
    func testALateAnswerToAnEarlierIdenticalQuestionLeavesTheNewOne() async throws {
        let path = system.appendingPathComponent("Breaks.app").path
        try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.breaks", version: "0.0.9")
        let running = FakeRunning()
        running.running.update { $0.insert(path) }
        let (actions, _) = await actions(running: running)
        actions.update("breaks")
        await actions.wait("breaks")
        let earlier = try XCTUnwrap(actions.quitRequest)
        actions.dismissQuit(earlier)
        actions.update("breaks")
        await actions.wait("breaks")
        let later = try XCTUnwrap(actions.quitRequest)
        XCTAssertTrue(later.asks("breaks", AppInstallerTests.breaks, kind: .update))
        XCTAssertNotEqual(later, earlier)
        actions.dismissQuit(earlier)
        XCTAssertEqual(actions.quitRequest, later, "the late dismissal of the earlier question leaves the new one")
        actions.dismissQuit(later)
        XCTAssertNil(actions.quitRequest)
        XCTAssertEqual(running.quits.get(), [])
    }

    // The read of whether the app runs is held up for good: Update or Move to Trash, cancelled and tried again ten times,
    // never has more than that one read under way; each Cancel ends at once, and once the read answers, after its attempts
    // were cancelled, nothing is asked. The next attempt reads again.
    func testRetriesWhileTheRunningReadIsHeldUpWaitForThatOneRead() async throws {
        for kind in [QuitRequest.Kind.update, .moveToTrash] {
            try tearDownWithError()
            try setUpWithError()
            let path = system.appendingPathComponent("Breaks.app").path
            try makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.breaks", version: "0.0.9")
            let running = FakeRunning()
            running.running.update { $0.insert(path) }
            let (actions, _) = await actions(running: running)
            let gate = DispatchSemaphore(value: 0)
            let blocking = Recorder(true)
            let reads = Recorder(0)
            let inFlight = Recorder(0)
            let mostInFlight = Recorder(0)
            running.hold = {
                reads.update { $0 += 1 }
                inFlight.update { $0 += 1 }
                mostInFlight.update { $0 = max($0, inFlight.get()) }
                if blocking.get() { gate.wait() }
                inFlight.update { $0 -= 1 }
            }
            let start = { kind == .update ? actions.update("breaks") : actions.moveToTrash("breaks") }
            for attempt in 1...10 {
                start()
                try await waitFor { reads.get() > 0 && actions.canCancel("breaks") }
                // Long enough for an attempt that reads on its own to have begun its read.
                try await Task.sleep(for: .milliseconds(100))
                let cancelled = Date()
                actions.cancel("breaks")
                await actions.wait("breaks")
                XCTAssertLessThan(Date().timeIntervalSince(cancelled), 2, "\(kind) attempt \(attempt): Cancel ends at once")
                XCTAssertNil(actions.quitRequest, "\(kind) attempt \(attempt)")
            }
            XCTAssertEqual(reads.get(), 1, "\(kind): every attempt waited for the one read")
            XCTAssertEqual(mostInFlight.get(), 1, "\(kind)")
            blocking.update { $0 = false }
            gate.signal()
            try await waitFor { inFlight.get() == 0 }
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertNil(actions.quitRequest, "\(kind): the late answer asks nothing")
            let what = kind == .update ? "updated to 0.1.0" : "moved to the Trash"
            XCTAssertEqual(actions.activities["breaks"], .failed("Breaks was not \(what): it was cancelled before anything was changed."), "\(kind)")
            start()
            await actions.wait("breaks")
            XCTAssertEqual(reads.get(), 2, "\(kind): an attempt after the answer reads again")
            XCTAssertEqual(actions.quitRequest?.asks("breaks", AppInstallerTests.breaks, kind: kind), true, "\(kind)")
            XCTAssertEqual(running.quits.get(), [], "\(kind)")
            XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleShortVersionString"] as? String, "0.0.9", "\(kind)")
        }
    }

    private static func catalog(_ apps: [CatalogApp]) -> Catalog {
        Catalog(generatedAt: "2026-11-12T00:00:00Z", apps: apps, tools: [])
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { return XCTFail("timed out") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
