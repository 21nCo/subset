import AppKit
import CryptoKit
import Darwin
import Foundation
@testable import SubsetCore
import XCTest

/// The installer with injected download, image, verifier and running-app fakes, in temporary folders standing in for
/// /Applications, ~/Applications (/Users/alex/Applications), the receipts, the locks and the Trash. Every refusal and
/// interruption must leave the folders as they were (no staged copy, no receipt, the old copy in place), and an update
/// must have the old app or the new verified one in place at every moment.
final class AppInstallerTests: XCTestCase {
    static let liveImage = Data("Breaks 0.1.0 image".utf8)
    static let betaImage = Data("Breaks 0.1.1 beta 4 image".utf8)
    static let prefix = "https://github.com/21nCo/subset/releases/download/macos/breaks/"

    static func hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    static let breaks = CatalogApp(
        id: "breaks", name: "Breaks", summary: "Screen breaks.", appName: "Breaks", bundleID: "dev.subset.breaks",
        live: LiveRelease(version: "0.1.0", url: prefix + "v0.1.0/Breaks-0.1.0.dmg", sha256: hex(liveImage), releaseURL: ""),
        beta: BetaRelease(version: "0.1.1", build: 4, url: prefix + "v0.1.1-beta.4/Breaks-0.1.1-beta.4.dmg", sha256: hex(betaImage), releaseURL: "")
    )
    static let live = ChosenRelease(breaks, channel: .live)!
    static let beta = ChosenRelease(breaks, channel: .beta)!
    static let installedAt = Date(timeIntervalSince1970: 1_763_035_205) // 2025-11-13T12:00:05Z

    private var root: URL!
    private var system: URL { root.appendingPathComponent("Applications") }
    private var user: URL { root.appendingPathComponent("home/Applications") }
    private var receipts: URL { root.appendingPathComponent("receipts") }
    private var locks: URL { root.appendingPathComponent("locks") }
    private var temporary: URL { root.appendingPathComponent("tmp") }
    private var trashFolder: URL { root.appendingPathComponent("Trash") }
    private var target: URL { system.appendingPathComponent("Breaks.app") }
    private var receiptFile: URL { receipts.appendingPathComponent("dev.subset.breaks.json") }

    private var downloader = FakeDownloader(images: [:])
    private var images = FakeImages()
    private var verifier = FakeVerifier()
    private var running = FakeRunning()
    private var trash: any Trashing = FolderTrash(folder: URL(fileURLWithPath: "/nonexistent"))
    /// The executable of the running Subset app the installer is told it is (by default one outside both folders).
    private var ownExecutable: String? = "/nonexistent/Subset.app/Contents/MacOS/Subset"

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subset-installer-\(UUID().uuidString)")
        for folder in [system, user, receipts, temporary, trashFolder] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        downloader = FakeDownloader(images: [Self.live.url: Self.liveImage, Self.beta.url: Self.betaImage])
        images = FakeImages()
        images.volumes = [
            Self.liveImage: ["Breaks 0.1.0": { try Self.imageVolume($0, version: "0.1.0", build: "12") }],
            Self.betaImage: ["Breaks 0.1.1": { try Self.imageVolume($0, version: "0.1.1", build: "4") }]
        ]
        verifier = FakeVerifier()
        running = FakeRunning()
        trash = FolderTrash(folder: trashFolder)
        ownExecutable = "/nonexistent/Subset.app/Contents/MacOS/Subset"
    }

    override func tearDownWithError() throws {
        _ = try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path)
        try? FileManager.default.removeItem(at: root)
    }

    /// The volume of a release image: Breaks.app and the usual link to /Applications.
    static func imageVolume(_ volume: URL, version: String, build: String, name: String = "Breaks.app", bundleID: String = "dev.subset.breaks", minimumMacOS: String? = "14.0") throws {
        try makeBundle(volume.appendingPathComponent(name), bundleID: bundleID, version: version, build: build, minimumMacOS: minimumMacOS)
        try FileManager.default.createSymbolicLink(atPath: volume.appendingPathComponent("Applications").path, withDestinationPath: "/Applications")
    }

    private func installer() -> AppInstaller {
        AppInstaller(
            setup: InstallSetup(
                folders: [
                    ApplicationsFolder(label: "/Applications", path: "/Applications", directory: system),
                    ApplicationsFolder(label: "~/Applications", path: "/Users/alex/Applications", directory: user)
                ],
                receipts: receipts, locks: locks, temporary: temporary
            ),
            downloader: downloader, images: images, verifier: verifier, trash: trash, running: running,
            clock: { Self.installedAt }, quitTimeout: 1, ownExecutable: ownExecutable
        )
    }

    /// Runs `operation` in a task of its own (a fake that cancels cancels only it) and returns how it failed, or nil.
    private func failure(_ operation: @escaping @Sendable (AppInstaller) async throws -> InstallOutcome) async -> InstallFailure? {
        let installer = installer()
        do {
            _ = try await Task { try await operation(installer) }.value
            return nil
        } catch {
            return error as? InstallFailure
        }
    }

    private func version(_ bundle: URL) -> String? {
        InstalledAppFinder.infoPlist(bundle.path)?["CFBundleShortVersionString"] as? String
    }

    private func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
    }

    /// Nothing an install leaves behind: no staged copy, no private folder, no image attached, no lock.
    private func assertNoLeftovers(file: StaticString = #filePath, line: UInt = #line) {
        for folder in [system, user] {
            XCTAssertEqual(names(folder).filter { $0.contains(".subset-") }, [], "hidden copies in \(folder.path)", file: file, line: line)
        }
        XCTAssertEqual(names(temporary), [], "private folders", file: file, line: line)
        XCTAssertEqual(images.attached.get(), [], "attached volumes", file: file, line: line)
        XCTAssertEqual(names(locks), [], "lock files", file: file, line: line)
    }

    /// Installs Breaks 0.0.9 (build 3) at /Applications/Breaks.app with a live receipt, as an earlier install would.
    @discardableResult
    private func installOld() throws -> FileIdentity {
        try makeBundle(target, bundleID: "dev.subset.breaks", version: "0.0.9", build: "3")
        let old = ReceiptDocument(Self.breaks, ChosenRelease(Self.breaks, channel: .live)!, folder: installer().setup.folders[0], receipts: receipts)!
        var document = old
        document.version = "0.0.9"
        try document.text(installedAt: Self.installedAt).write(to: receiptFile)
        return AppInstaller.identity(target)!
    }

    // MARK: - Install

    func testInstallPutsTheVerifiedAppInPlaceWithTheCommandsReceipt() async throws {
        let steps = Recorder<[InstallProgress]>([])
        let outcome = try await installer().install(Self.breaks, Self.live) { step in steps.update { $0.append(step) } }
        XCTAssertEqual(outcome.path, target.path)
        XCTAssertEqual(names(system), ["Breaks.app"])
        XCTAssertEqual(version(target), "0.1.0")
        XCTAssertEqual(verifier.verified.get().count, 1)
        XCTAssertTrue(verifier.verified.get()[0].lastPathComponent.hasPrefix(".Breaks.app.subset-install-"), "the staged copy is verified")
        XCTAssertEqual(try String(contentsOf: receiptFile, encoding: .utf8), """
        {
          "schema": "subset.receipt@1",
          "channel": "live",
          "version": "0.1.0",
          "sha256": "\(Self.live.sha256)",
          "installedAt": "2025-11-13T12:00:05Z",
          "path": "/Applications/Breaks.app"
        }

        """)
        XCTAssertEqual(steps.get().first, .downloading(received: 0, total: nil))
        XCTAssertEqual(Array(steps.get().suffix(2)), [.verifying, .installing])
        XCTAssertEqual(images.detached.get(), 1)
        assertNoLeftovers()
    }

    func testAnUnwritableApplicationsFolderInstallsInUserApplications() async throws {
        try FileManager.default.removeItem(at: user)
        chmod(system.path, 0o555)
        let outcome = try await installer().install(Self.breaks, Self.beta)
        XCTAssertEqual(outcome.path, user.appendingPathComponent("Breaks.app").path)
        XCTAssertEqual(names(system), [])
        let receipt = try Receipt.parse(Data(contentsOf: receiptFile)).get()
        XCTAssertEqual(receipt.path, "/Users/alex/Applications/Breaks.app")
        XCTAssertEqual(receipt.channel, .beta)
        XCTAssertEqual(receipt.build, 4)
    }

    func testEveryRefusalLeavesNothingInstalledAndNoReceipt() async throws {
        let wrongVolume = { (make: @escaping (URL) throws -> Void) in [Self.liveImage: ["Breaks": make]] }
        let cases: [(String, InstallFailure.Step, (inout RefusalCase) -> Void)] = [
            ("bad checksum", .checksum, { $0.downloads[Self.live.url] = Data("tampered".utf8) }),
            ("HTTP error", .download, { $0.downloads[Self.live.url] = nil }),
            ("URL outside the releases", .download, { $0.release.url = "https://example.com/Breaks.dmg" }),
            ("not a disk image", .image, { $0.volumes = [:] }),
            ("no app in the image", .image, { $0.volumes = wrongVolume { _ in } }),
            ("two apps in the image", .image, { $0.volumes = wrongVolume {
                try Self.imageVolume($0, version: "0.1.0", build: "1")
                try makeBundle($0.appendingPathComponent("Other.app"), bundleID: "dev.subset.breaks", version: "0.1.0")
            } }),
            ("app under another name", .image, { $0.volumes = wrongVolume { try Self.imageVolume($0, version: "0.1.0", build: "1", name: "Pauses.app") } }),
            ("two volumes", .image, { $0.volumes = [Self.liveImage: [
                "A": { try Self.imageVolume($0, version: "0.1.0", build: "1") }, "B": { _ in }
            ]] }),
            ("unsigned", .signature, { $0.refusal = InstallFailure(.signature, "code object is not signed at all") }),
            ("wrong team", .team, { $0.refusal = InstallFailure(.team, "it is not signed by the Subset team SAZVPX4CAA (TeamIdentifier: not reported)") }),
            ("not notarized", .notarization, { $0.refusal = InstallFailure(.notarization, "spctl: source=Unnotarized Developer ID") }),
            ("wrong bundle ID", .bundleID, { $0.volumes = wrongVolume { try Self.imageVolume($0, version: "0.1.0", build: "1", bundleID: "dev.example.breaks") } }),
            ("wrong version", .version, { $0.volumes = wrongVolume { try Self.imageVolume($0, version: "0.1.1", build: "1") } }),
            ("newer minimum macOS", .macOSVersion, { $0.volumes = wrongVolume { try Self.imageVolume($0, version: "0.1.0", build: "1", minimumMacOS: "15.1") } })
        ]
        for (name, step, change) in cases {
            try tearDownWithError()
            try setUpWithError()
            var setup = RefusalCase(downloads: downloader.images, volumes: images.volumes, release: Self.live, refusal: nil)
            change(&setup)
            downloader = FakeDownloader(images: setup.downloads)
            images.volumes = setup.volumes
            verifier.refusal = setup.refusal
            let release = setup.release
            let refused = await failure { try await $0.install(Self.breaks, release) }
            XCTAssertEqual(refused?.step, step, "\(name): \(String(describing: refused))")
            XCTAssertEqual(names(system), [], name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path), name)
            assertNoLeftovers()
        }
    }

    func testABetaWithAnotherBuildIsRefusedAtTheVersionCheck() async throws {
        images.volumes[Self.betaImage] = ["Breaks": { try Self.imageVolume($0, version: "0.1.1", build: "3") }]
        let refused = await failure { try await $0.install(Self.breaks, Self.beta) }
        XCTAssertEqual(refused, InstallFailure(.version, "its build is \"3\", not 4"))
        XCTAssertEqual(names(system), [])
    }

    func testCancellingAtEachStepLeavesNothingInstalled() async throws {
        for step in ["download", "attach", "verify"] {
            try tearDownWithError()
            try setUpWithError()
            downloader.cancelDuring = step == "download"
            images.cancelDuring = step == "attach"
            verifier.cancelDuring = step == "verify"
            let refused = await failure { try await $0.install(Self.breaks, Self.live) }
            XCTAssertEqual(refused?.step, .interrupted, step)
            XCTAssertEqual(names(system), [], step)
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path), step)
            XCTAssertEqual(images.detached.get(), step == "download" ? 0 : 1, step)
            assertNoLeftovers()
        }
    }

    func testInstallNeverReplacesAnAppOrDowngrades() async throws {
        try makeBundle(target, bundleID: "dev.subset.breaks", version: "0.0.9")
        let existing = await failure { try await $0.install(Self.breaks, Self.live) }
        XCTAssertEqual(existing?.step, .install)
        XCTAssertEqual(version(target), "0.0.9")

        try FileManager.default.removeItem(at: target)
        try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.2.0")
        let downgrade = await failure { try await $0.install(Self.breaks, Self.live) }
        XCTAssertEqual(downgrade, InstallFailure(.downgrade, "0.2.0 is installed in ~/Applications, and Subset does not downgrade"))
        XCTAssertEqual(downloader.calls.get(), 0)
        assertNoLeftovers()
    }

    func testAnAppPutInPlaceWhileTheCopyIsVerifiedIsNotReplaced() async throws {
        let other = target
        verifier.during = { _ in try makeBundle(other, bundleID: "dev.subset.breaks", version: "9.9.9") }
        let refused = await failure { try await $0.install(Self.breaks, Self.live) }
        XCTAssertEqual(refused?.step, .install)
        XCTAssertEqual(version(target), "9.9.9", "the copy the subset command put there first stays")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path))
        assertNoLeftovers()
    }

    // MARK: - Concurrency

    func testAnotherSubsetHoldingTheLockRefusesBeforeAnythingChanges() async throws {
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let key = AppInstallerTests.hex(Data("dev.subset.breaks".utf8))
        // pid 1 (launchd) always runs; the subset command names its lock files this way.
        let held = locks.appendingPathComponent("\(key).1.0123456789ab.lock")
        try Data("1\n".utf8).write(to: held)
        let refused = await failure { try await $0.install(Self.breaks, Self.live) }
        XCTAssertEqual(refused?.step, .lock)
        XCTAssertEqual(downloader.calls.get(), 0)
        XCTAssertEqual(names(locks), [held.lastPathComponent])

        // A lock whose process no longer runs is removed, and the install goes ahead.
        try FileManager.default.removeItem(at: held)
        var dead: pid_t = 99_999
        while kill(dead, 0) == 0 || errno == EPERM { dead -= 1 }
        try Data("\(dead)\n".utf8).write(to: locks.appendingPathComponent("\(key).\(dead).0123456789ab.lock"))
        _ = try await installer().install(Self.breaks, Self.live)
        assertNoLeftovers()
    }

    func testASecondOperationOnTheSameAppInThisAppIsRefused() async throws {
        let first = try AppLock(Self.breaks, in: locks)
        defer { first.release() }
        let refused = await failure { try await $0.install(Self.breaks, Self.live) }
        XCTAssertEqual(refused?.step, .lock)
        XCTAssertTrue(refused?.message.contains("already installing") == true, String(describing: refused))
        XCTAssertEqual(names(system), [])
    }

    // MARK: - Update

    func testUpdateMovesTheOldCopyToTheTrashOnlyAfterTheNewOneIsInPlace() async throws {
        let old = try installOld()
        let checked = CheckingTrash(inner: trash, target: target)
        trash = checked
        let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: false)
        XCTAssertEqual(checked.versionsInPlace.get(), ["0.1.0"], "the new copy was in place when the old one went to the Trash")
        XCTAssertEqual(version(target), "0.1.0")
        XCTAssertNotEqual(AppInstaller.identity(target), old)
        let trashed = names(trashFolder)
        XCTAssertEqual(trashed.count, 1)
        XCTAssertNotNil(trashed[0].range(of: #"^Breaks \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\.app$"#, options: .regularExpression), trashed[0])
        XCTAssertEqual(version(trashFolder.appendingPathComponent(trashed[0])), "0.0.9")
        XCTAssertEqual(try Receipt.parse(Data(contentsOf: receiptFile)).get().version, "0.1.0")
        XCTAssertEqual(outcome.notes.count, 1, "\(outcome.notes)")
        assertNoLeftovers()
    }

    func testAFailedOrCancelledUpdateLeavesTheOldCopyInPlace() async throws {
        let cases: [(String, (AppInstallerTests) -> Void)] = [
            ("bad checksum", { $0.downloader = FakeDownloader(images: [Self.live.url: Data("tampered".utf8)]) }),
            ("wrong team", { $0.verifier.refusal = InstallFailure(.team, "TeamIdentifier: ABCDE12345") }),
            ("not notarized", { $0.verifier.refusal = InstallFailure(.notarization, "rejected") }),
            ("wrong version", { $0.images.volumes[Self.liveImage] = ["Breaks": { try Self.imageVolume($0, version: "0.0.8", build: "1") }] }),
            ("cancelled while downloading", { $0.downloader.cancelDuring = true }),
            ("cancelled while verifying", { $0.verifier.cancelDuring = true })
        ]
        for (name, change) in cases {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            change(self)
            let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
            XCTAssertNotNil(refused, name)
            XCTAssertEqual(AppInstaller.identity(target), old, "\(name): the old copy is untouched")
            XCTAssertEqual(version(target), "0.0.9", name)
            XCTAssertEqual(names(trashFolder), [], name)
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, name)
            assertNoLeftovers()
        }
    }

    func testARunningAppIsNotQuitWithoutTheUsersConsent() async throws {
        try installOld()
        running.running.update { $0.insert(target.path) }
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .running)
        XCTAssertEqual(downloader.calls.get(), 0, "refused before the download")
        XCTAssertEqual(running.quits.get(), [])
        XCTAssertEqual(version(target), "0.0.9")
    }

    func testARunningAppIsQuitOnlyAfterTheNewCopyIsVerifiedAndIsNotOpenedAgain() async throws {
        try installOld()
        let path = target.path
        running.running.update { $0.insert(path) }
        let verified = verifier.verified
        // The closure captures a plain path and reads before asserting: a local `target` shadowing the property, captured
        // here, hung Swift 6.3's ClosureLifetimeFixup (Xcode 26.6 on the macos-26 CI runner) while compiling this file.
        running.onQuit = {
            let count = verified.get().count
            let installed = InstalledAppFinder.infoPlist(path)?["CFBundleShortVersionString"] as? String
            XCTAssertEqual(count, 1, "quit only once the new copy is verified")
            XCTAssertEqual(installed, "0.0.9")
        }
        let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: true)
        XCTAssertEqual(running.quits.get(), [path])
        // Subset never opens it again (RunningAppControlling has no way to): the result ends by saying to.
        XCTAssertEqual(outcome.notes.last, "Breaks was asked to quit for the update. Open Breaks again.")
        XCTAssertEqual(version(target), "0.1.0")
    }

    func testAnAppThatDoesNotQuitIsNotReplaced() async throws {
        let old = try installOld()
        running.running.update { $0.insert(target.path) }
        running.stubborn = true
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(refused?.step, .running)
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(refused?.notes, ["Breaks was asked to quit for the update. Open Breaks again."], "an app asked to quit is said to be, and not opened again")
        assertNoLeftovers()
    }

    // An app asked to quit for an update is never opened again by Subset, whatever then happens: the update fails
    // (a copy put at its path meanwhile stays), the app does not quit, or the update succeeds. The result says it was
    // asked to quit, ends with "Open Breaks again.", and is not "only partly" done when no copy changed.
    func testAQuitForAnUpdateIsSaidAndNothingIsOpenedAgain() async throws {
        try installOld()
        let quitPath = target.path
        running.running.update { $0.insert(quitPath) }
        running.onQuit = {
            try? FileManager.default.removeItem(atPath: quitPath)
            try? makeBundle(URL(fileURLWithPath: quitPath), bundleID: "dev.subset.breaks", version: "0.3.0")
        }
        let failed = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(failed?.step, .install)
        XCTAssertEqual(failed?.partial, false, "asking the app to quit changed no copy")
        XCTAssertEqual(failed?.notes, ["Breaks was asked to quit for the update. Open Breaks again."])
        XCTAssertEqual(version(target), "0.3.0", "what was put there stays")
        assertNoLeftovers()

        try tearDownWithError()
        try setUpWithError()
        try installOld()
        let stubbornPath = target.path
        running.running.update { $0.insert(stubbornPath) }
        running.stubborn = true
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(refused?.step, .running)
        XCTAssertEqual(refused?.partial, false)
        XCTAssertEqual(refused?.notes, ["Breaks was asked to quit for the update. Open Breaks again."])
    }

    // A copy replaced after it was checked and before its app is asked to quit is not quit, updated or moved: the
    // request is never sent to the replacement's app.
    func testACopyReplacedJustBeforeTheQuitIsNotQuit() async throws {
        for operation in ["update", "moveToTrash"] {
            try tearDownWithError()
            try setUpWithError()
            try installOld()
            let replacedPath = target.path
            running.running.update { $0.insert(replacedPath) }
            running.beforeQuit = {
                try? FileManager.default.removeItem(atPath: replacedPath)
                try? makeBundle(URL(fileURLWithPath: replacedPath), bundleID: "dev.subset.breaks", version: "0.3.0")
            }
            let refused = await failure { installer in
                operation == "update" ? try await installer.update(Self.breaks, Self.live, quitAllowed: true)
                    : try await installer.moveToTrash(Self.breaks, quitAllowed: true)
            }
            XCTAssertEqual(refused?.step, .running, operation)
            XCTAssertEqual(running.quits.get(), [], operation)
            XCTAssertEqual(version(target), "0.3.0", operation)
            XCTAssertEqual(names(trashFolder), [], operation)
        }
        // The system's quit refuses the same way before asking any app.
        let bundle = root.appendingPathComponent("Idle.app")
        try makeBundle(bundle, bundleID: "dev.subset.idle", version: "1.0")
        do {
            _ = try await WorkspaceRunningApps().quit(bundle, timeout: 1) { false }
            XCTFail("a replaced copy is not quit")
        } catch let failure as InstallFailure {
            XCTAssertEqual(failure.step, .running)
        }
        let quit = try await WorkspaceRunningApps().quit(bundle, timeout: 1) { true }
        XCTAssertEqual(quit.left, [])
        XCTAssertFalse(quit.asked)
    }

    // Putting back what an interrupted update left is a change: an update or a move to the Trash that then fails or is
    // refused says so, and the copy put back stays with its receipt.
    func testACopyPutBackBeforeAFailureIsReportedAsAChange() async throws {
        var dead: pid_t = 99_999
        while kill(dead, 0) == 0 || errno == EPERM { dead -= 1 }
        for operation in ["update", "moveToTrash"] {
            try tearDownWithError()
            try setUpWithError()
            let copy = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            let aside = system.appendingPathComponent(".Breaks.app.subset-update-\(dead)-0123456789ab")
            try FileManager.default.moveItem(at: target, to: aside)
            running.running.update { $0.insert(self.target.path) }
            let refused = await failure { installer in
                operation == "update" ? try await installer.update(Self.breaks, Self.live, quitAllowed: false)
                    : try await installer.moveToTrash(Self.breaks, quitAllowed: false)
            }
            XCTAssertEqual(refused?.step, .running, operation)
            XCTAssertEqual(refused?.partial, true, operation)
            XCTAssertEqual(refused?.onlyRecovered, true, "the \(operation) itself did not run")
            XCTAssertEqual(refused?.notes, ["Breaks was put back at \(target.path): an interrupted update had left it at \(aside.path)."], operation)
            XCTAssertEqual(AppInstaller.identity(target), copy, operation)
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, operation)
        }
    }

    func testACopyReplacedDuringTheUpdateIsNotSwapped() async throws {
        try installOld()
        let target = target
        verifier.during = { _ in
            try FileManager.default.removeItem(at: target)
            try makeBundle(target, bundleID: "dev.subset.breaks", version: "0.3.0")
        }
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .install)
        XCTAssertEqual(version(target), "0.3.0", "what the other manager put there stays")
        XCTAssertEqual(names(trashFolder), [])
        assertNoLeftovers()
    }

    func testAnUpdateInterruptedBetweenItsRenamesIsPutBackFirst() async throws {
        try installOld()
        var dead: pid_t = 99_999
        while kill(dead, 0) == 0 || errno == EPERM { dead -= 1 }
        // What a crash between the two renames leaves, named as the subset command and this app name it.
        let aside = system.appendingPathComponent(".Breaks.app.subset-update-\(dead)-0123456789ab")
        try FileManager.default.moveItem(at: target, to: aside)
        let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: false)
        XCTAssertTrue(outcome.notes[0].contains("was put back"), "\(outcome.notes)")
        XCTAssertEqual(version(target), "0.1.0")
        XCTAssertEqual(version(trashFolder.appendingPathComponent(names(trashFolder)[0])), "0.0.9")
        assertNoLeftovers()
    }

    /// A copying tool that copies with ditto, protects part of the copy (an immutable file and a deny-delete ACL, as an
    /// image can carry) and then holds until it is stopped; `marker` appears once the copy is made.
    private func holdingCopyTool(marker: URL) throws -> String {
        let script = root.appendingPathComponent("holding-ditto.sh")
        try """
        #!/bin/sh
        /usr/bin/ditto "$1" "$2" || exit 1
        /usr/bin/chflags uchg "$2/Contents/Info.plist" || exit 1
        /bin/chmod +a "everyone deny delete" "$2/Contents" || exit 1
        : > '\(marker.path)'
        exec /bin/sleep 600
        """.write(to: script, atomically: true, encoding: .utf8)
        chmod(script.path, 0o755)
        return script.path
    }

    func testCancellingDuringTheCopyLeavesNothingInstalledOrTheOldCopyInPlace() async throws {
        for mode in ["install", "update"] {
            try tearDownWithError()
            try setUpWithError()
            let old = mode == "update" ? try installOld() : nil
            let receiptBefore = try? Data(contentsOf: receiptFile)
            let marker = root.appendingPathComponent("copied")
            var copying = installer()
            copying.ditto = try holdingCopyTool(marker: marker)
            let task = Self.start(copying, update: mode == "update")
            let deadline = Date().addingTimeInterval(30)
            while !FileManager.default.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path), "\(mode): the copy was made")
            XCTAssertEqual(names(system).filter { $0.hasPrefix(".Breaks.app.subset-install-") }.count, 1, "\(mode): staged while the tool runs")
            XCTAssertTrue(verifier.verified.get().isEmpty, mode)
            let cancelled = Date()
            task.cancel()
            var refused: InstallFailure?
            do { _ = try await task.value } catch { refused = error as? InstallFailure }
            XCTAssertLessThan(Date().timeIntervalSince(cancelled), 8, "\(mode): the copying tool is stopped promptly")
            XCTAssertEqual(refused, InstallFailure(.interrupted, "it was cancelled before it was installed"), mode)
            XCTAssertEqual(refused?.partial, false, mode)
            XCTAssertEqual(images.detached.get(), 1, mode)
            if let old {
                XCTAssertEqual(AppInstaller.identity(target), old, "\(mode): the old copy is untouched")
                XCTAssertEqual(version(target), "0.0.9", mode)
            } else {
                XCTAssertEqual(names(system), [], mode)
            }
            XCTAssertEqual(try? Data(contentsOf: receiptFile), receiptBefore, "\(mode): no new receipt")
            XCTAssertEqual(names(trashFolder), [], mode)
            assertNoLeftovers()
        }
    }

    // Outside the test (a Task closure there that captures the loop's values trips Swift 6.3's region-based isolation
    // checker, Xcode 26.6 on the macos-26 CI runner).
    private static func start(_ installer: AppInstaller, update: Bool) -> Task<InstallOutcome, Error> {
        Task { update ? try await installer.update(breaks, live, quitAllowed: false) : try await installer.install(breaks, live) }
    }

    func testCancellingWhileARunningAppQuitsChangesNothingElse() async throws {
        // Update: the app is said to have been asked to quit, and the old copy stays.
        let old = try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        running.running.update { $0.insert(target.path) }
        running.cancelDuringQuit = true
        let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(update?.step, .interrupted)
        XCTAssertEqual(update?.message, "it was cancelled before it was installed")
        XCTAssertEqual(update?.partial, false, "the app was quit, and no copy was changed")
        XCTAssertEqual(update?.notes, ["Breaks was asked to quit for the update. Open Breaks again."])
        XCTAssertEqual(running.quits.get(), [target.path])
        XCTAssertEqual(AppInstaller.identity(target), old, "nothing was swapped")
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        XCTAssertEqual(names(trashFolder), [])
        XCTAssertEqual(images.detached.get(), 1)
        assertNoLeftovers()

        // Move to Trash: nothing is moved and the receipt stays.
        try tearDownWithError()
        try setUpWithError()
        let copy = try installOld()
        let receipt = try Data(contentsOf: receiptFile)
        running.running.update { $0.insert(target.path) }
        running.cancelDuringQuit = true
        let move = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: true) }
        XCTAssertEqual(move?.step, .interrupted)
        XCTAssertEqual(move?.message, "it was cancelled after the app was asked to quit, before any copy was changed")
        XCTAssertEqual(move?.partial, false, "the app was quit, and no copy was moved")
        XCTAssertEqual(move?.notes, ["Breaks at \(target.path) was asked to quit."])
        XCTAssertEqual(names(system), ["Breaks.app"])
        XCTAssertEqual(AppInstaller.identity(target), copy, "nothing was moved")
        XCTAssertEqual(try Data(contentsOf: receiptFile), receipt)
        XCTAssertEqual(names(trashFolder), [])
        assertNoLeftovers()
    }

    // MARK: - Move to Trash

    func testMoveToTrashMovesEveryCopyAndRemovesTheReceipt() async throws {
        try installOld()
        try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
        let outcome = try await installer().moveToTrash(Self.breaks, quitAllowed: false)
        XCTAssertNil(outcome.path)
        XCTAssertEqual(names(system), [])
        XCTAssertEqual(names(user), [])
        XCTAssertEqual(Set(names(trashFolder).map { version(trashFolder.appendingPathComponent($0)) }), ["0.0.9", "0.0.8"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path))
        assertNoLeftovers()
    }

    func testMoveToTrashOfARunningAppNeedsConsent() async throws {
        try installOld()
        running.running.update { $0.insert(target.path) }
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .running)
        XCTAssertEqual(names(system), ["Breaks.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptFile.path))

        _ = try await installer().moveToTrash(Self.breaks, quitAllowed: true)
        XCTAssertEqual(running.quits.get(), [target.path])
        XCTAssertEqual(names(system), [])
    }

    func testMoveToTrashOfAnAppThatIsNotInstalledChangesNothing() async throws {
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .notInstalled)
        assertNoLeftovers()
    }

    func testMoveToTrashKeepsTheReceiptWhileACopyThatMayBeTheAppStays() async throws {
        // The copy the receipt describes cannot be read or looked into: it may be Breaks, so the readable copy in
        // ~/Applications is moved and the receipt stays, as `subset uninstall` decides.
        let cases: [(String, String, (AppInstallerTests) throws -> Void)] = [
            ("unreadable Info.plist", "its Info.plist could not be read", {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.target.appendingPathComponent("Contents/Info.plist").path)
            }),
            ("unsearchable Contents", "TARGET/Contents/Info.plist could not be looked into: Permission denied", {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.target.appendingPathComponent("Contents").path)
            }),
            ("unsearchable folder", "it could not be looked into: Permission denied", {
                try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: $0.system.path)
            })
        ]
        for (name, why, change) in cases {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
            try change(self)
            let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: system.path)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.appendingPathComponent("Contents").path)
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: target.appendingPathComponent("Contents/Info.plist").path)
            XCTAssertEqual(refused?.step, .trash, name)
            XCTAssertEqual(refused?.message, "\(target.path) was not moved to the Trash: it may be Breaks (\(why.replacingOccurrences(of: "TARGET", with: target.path))), so the receipt \(receiptFile.path) stays; remove the receipt by hand if that is not Breaks", name)
            XCTAssertEqual(refused?.partial, true, "\(name): the copy in ~/Applications was moved")
            XCTAssertEqual(refused?.notes.count, 1, "\(name): \(refused?.notes ?? [])")
            XCTAssertTrue(refused?.notes.first?.hasPrefix("Moved Breaks 0.0.8 (~/Applications) to the Trash: ") == true, name)
            XCTAssertEqual(AppInstaller.identity(target), old, "\(name): the copy that may be Breaks stays")
            XCTAssertEqual(names(user), [], name)
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, "\(name): the receipt stays")
            assertNoLeftovers()
        }
    }

    func testMoveToTrashTreatsWhatIsNotABundleAsAnotherApp() async throws {
        // A link (even to Breaks), a dangling link, a file, an empty folder or one without Contents/Info.plist at
        // Breaks.app is not Breaks (uninstall.mjs mayBeApp): it stays, and the receipt goes with the moved copy.
        let elsewhere = FileManager.default.temporaryDirectory.appendingPathComponent("subset-elsewhere-\(UUID().uuidString)/Breaks.app")
        defer { try? FileManager.default.removeItem(at: elsewhere.deletingLastPathComponent()) }
        try makeBundle(elsewhere, bundleID: "dev.subset.breaks", version: "0.0.9")
        let cases: [(String, (AppInstallerTests) throws -> Void)] = [
            ("link to Breaks", { try FileManager.default.createSymbolicLink(atPath: $0.target.path, withDestinationPath: elsewhere.path) }),
            ("dangling link", { try FileManager.default.createSymbolicLink(atPath: $0.target.path, withDestinationPath: $0.root.appendingPathComponent("gone").path) }),
            ("file", { try Data("not an app".utf8).write(to: $0.target) }),
            ("empty folder", { try FileManager.default.createDirectory(at: $0.target, withIntermediateDirectories: false) }),
            ("folder without Info.plist", {
                try FileManager.default.createDirectory(at: $0.target.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            }),
            ("Info.plist that is a folder", {
                try FileManager.default.createDirectory(at: $0.target.appendingPathComponent("Contents/Info.plist"), withIntermediateDirectories: true)
            })
        ]
        for (name, make) in cases {
            try tearDownWithError()
            try setUpWithError()
            try make(self)
            let before = AppInstaller.identity(target)
            try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
            try Data("{}".utf8).write(to: receiptFile)
            let outcome = try await installer().moveToTrash(Self.breaks, quitAllowed: false)
            XCTAssertEqual(outcome.notes.filter { !$0.hasPrefix("Moved Breaks 0.0.8 (~/Applications) to the Trash: ") }, [], name)
            XCTAssertEqual(names(user), [], name)
            XCTAssertNotNil(before, name)
            XCTAssertEqual(AppInstaller.identity(target), before, "\(name) stays where it is")
            XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path), "\(name): the receipt goes")
            assertNoLeftovers()
        }
    }

    func testThisRunningSubsetIsNeverUpdatedOrMovedToTheTrash() async throws {
        // The copy holding this app cannot be quit for the swap without ending the operation: Update and Move to Trash
        // refuse before anything changes (even with leave to quit), and no consent prompt is offered for it.
        let old = try installOld()
        try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
        let receiptBefore = try Data(contentsOf: receiptFile)
        ownExecutable = target.appendingPathComponent("Contents/MacOS/Breaks").path
        try Data().write(to: URL(fileURLWithPath: ownExecutable!))
        running.running.update { $0.insert(target.path) }
        let message = { (doing: String) in
            "\(self.target.path) is this running Breaks app, which cannot quit itself to be \(doing); quit it and use the subset command in Terminal"
        }
        for quitAllowed in [false, true] {
            let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: quitAllowed) }
            XCTAssertEqual(update?.step, .running)
            XCTAssertEqual(update?.message, message("updated"))
            XCTAssertEqual(update?.partial, false)
            let trashed = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: quitAllowed) }
            XCTAssertEqual(trashed?.step, .running)
            XCTAssertEqual(trashed?.message, message("moved to the Trash"))
            XCTAssertEqual(trashed?.partial, false)
        }
        XCTAssertThrowsError(try installer().isRunning(Self.breaks)) { error in
            XCTAssertEqual((error as? InstallFailure)?.message, message("changed"))
        }
        XCTAssertEqual(downloader.calls.get(), 0)
        XCTAssertEqual(running.quits.get(), [])
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(version(user.appendingPathComponent("Breaks.app")), "0.0.8", "the other copy is not moved either")
        XCTAssertEqual(names(trashFolder), [])
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        assertNoLeftovers()

        // Through a link to the folder, the copy is still this app's.
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: system.path)
        ownExecutable = link.appendingPathComponent("Breaks.app/Contents/MacOS/Breaks").path
        let viaLink = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: true) }
        XCTAssertEqual(viaLink?.step, .running)
        XCTAssertEqual(AppInstaller.identity(target), old)
    }

    func testMoveToTrashOfAnotherAppWithTheSameNameRemovesTheReceipt() async throws {
        // An app with another bundle ID at Breaks.app is not Breaks: it neither keeps the receipt nor is moved.
        try makeBundle(target, bundleID: "com.example.other", version: "1.0")
        try makeBundle(user.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.0.8")
        try Data("{}".utf8).write(to: receiptFile)
        _ = try await installer().moveToTrash(Self.breaks, quitAllowed: false)
        XCTAssertEqual(names(system), ["Breaks.app"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path))
    }

    func testAnUnreadableProcessListRefusesBeforeAnythingChanges() async throws {
        // A running app must never be taken for one that is not: when the processes cannot be read, nothing is changed.
        let old = try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        running.unreadable = true
        for quitAllowed in [false, true] {
            let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: quitAllowed) }
            XCTAssertEqual(update?.step, .running)
            XCTAssertEqual(update?.partial, false)
            // Without leave to quit it is refused before the download; with it, just before the swap.
            XCTAssertEqual(downloader.calls.get(), quitAllowed ? 1 : 0)
            let trashed = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: quitAllowed) }
            XCTAssertEqual(trashed?.step, .running)
        }
        XCTAssertThrowsError(try installer().isRunning(Self.breaks))
        XCTAssertEqual(running.quits.get(), [])
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(names(trashFolder), [])
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        assertNoLeftovers()
    }

    func testTheProcessListIsReadWholeOrNotAtAll() throws {
        XCTAssertThrowsError(try WorkspaceRunningApps.allPids { _, _ in -1 }, "libproc failing is an error, not no process")
        XCTAssertThrowsError(try WorkspaceRunningApps.allPids { buffer, size in
            buffer == nil ? 3 : Int32(Int(size) / MemoryLayout<pid_t>.size)
        }, "a list that always fills its buffer may be cut short")
        // The list grew past the size libproc first gave and filled the first buffer: it is read again in a larger one.
        var calls = 0
        let pids = try WorkspaceRunningApps.allPids { buffer, size in
            guard let buffer else { return 3 }
            calls += 1
            let count = calls == 1 ? Int(size) / MemoryLayout<pid_t>.size : 5
            let list = buffer.assumingMemoryBound(to: pid_t.self)
            for index in 0..<count { list[index] = pid_t(index + 1) }
            return Int32(count)
        }
        XCTAssertEqual(pids, [1, 2, 3, 4, 5])
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(try WorkspaceRunningApps.allPids().contains(getpid()), "the real list holds this process")
        // This process counts as running from the bundle that holds it, so its copy is never taken for a stopped one.
        let own = URL(fileURLWithPath: try XCTUnwrap(WorkspaceRunningApps.ownExecutable())).deletingLastPathComponent()
        XCTAssertEqual(try WorkspaceRunningApps.processes(inside: own, among: [getpid()], look: WorkspaceRunningApps.look), [getpid()])
    }

    // Every process on this Mac, other users' included (PROC_PIDTBSDINFO refuses those with EPERM), is classified, so
    // one that is not the bundle's never refuses an update or a move to the Trash of an app nothing runs from.
    func testEveryRealProcessIsClassifiedAndNoneBlocksAnAppThatIsNotRunning() throws {
        let unknown = { (pid: pid_t) -> Int32? in
            if case .unknown(let code) = WorkspaceRunningApps.look(pid) { return code }
            return nil
        }
        // One that exits while it is looked at is not one that cannot be read.
        for pid in try WorkspaceRunningApps.allPids() where pid > 0 && unknown(pid) != nil {
            usleep(200_000)
            guard let code = unknown(pid) else { continue }
            let record = WorkspaceRunningApps.record(of: pid).record
            XCTFail("pid \(pid) (uid \(record.map { String($0.kp_eproc.e_ucred.cr_uid) } ?? "?"), parent \(record.map { String($0.kp_eproc.e_ppid) } ?? "?")): \(String(cString: strerror(code)))")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-idle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try makeBundle(folder.appendingPathComponent("Breaks.app"), bundleID: "dev.subset.breaks", version: "0.1.0")
        XCTAssertEqual(try WorkspaceRunningApps().processes(inside: folder.appendingPathComponent("Breaks.app")), [])
    }

    func testAnUpdateThatFailsAfterUpdatingOneCopySaysWhatItChanged() async throws {
        try installOld()
        let second = user.appendingPathComponent("Breaks.app")
        try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
        let secondBefore = AppInstaller.identity(second)
        let userPath = user.path
        verifier.during = { staged in
            if staged.path.hasPrefix(userPath) { throw InstallFailure(.team, "TeamIdentifier: ABCDE12345") }
        }
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .team)
        XCTAssertEqual(refused?.partial, true)
        XCTAssertEqual(refused?.notes.first, "Updated the copy in /Applications from 0.0.9 to 0.1.0.")
        XCTAssertTrue(refused?.notes.last?.hasPrefix("Moved Breaks 0.0.9 (/Applications) to the Trash: ") == true, "\(refused?.notes ?? [])")
        XCTAssertEqual(version(target), "0.1.0", "the first copy stays updated")
        XCTAssertEqual(AppInstaller.identity(second), secondBefore, "the second copy is untouched")
        assertNoLeftovers()
    }

    func testMoveToTrashCancelledAfterTheFirstCopySaysWhatItChanged() async throws {
        try installOld()
        let second = user.appendingPathComponent("Breaks.app")
        try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
        trash = CancellingTrash(inner: trash)
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .interrupted)
        XCTAssertEqual(refused?.message, "it was cancelled after part of it was done")
        XCTAssertEqual(refused?.partial, true)
        XCTAssertEqual(refused?.notes.count, 1)
        XCTAssertTrue(refused?.notes.first?.hasPrefix("Moved Breaks 0.0.9 (/Applications) to the Trash: ") == true, "\(refused?.notes ?? [])")
        XCTAssertEqual(names(system), [])
        XCTAssertEqual(names(user), ["Breaks.app"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: receiptFile.path), "a copy is left, so the receipt stays")
        assertNoLeftovers()
    }

    // hdiutil info may name an image by the path it was attached with or by its real path (/private/var/... for a
    // /var/folders temporary image), so cleanup looks for both, as install.mjs does; Foundation's resolving drops /private.
    func testTheDiskImageIsLookedUpByItsAttachPathAndItsRealPath() throws {
        let real = FileManager.default.temporaryDirectory.appendingPathComponent("subset-image-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: false)
        let link = FileManager.default.temporaryDirectory.appendingPathComponent("subset-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer {
            try? FileManager.default.removeItem(at: link)
            try? FileManager.default.removeItem(at: real)
        }
        let realFolder = try XCTUnwrap(AppInstaller.realPath(real.path))

        let viaTemporary = HdiutilDiskImages.imagePaths(of: real.appendingPathComponent("image.dmg"))
        XCTAssertTrue(viaTemporary.contains(real.path + "/image.dmg"), "\(viaTemporary)")
        XCTAssertTrue(viaTemporary.contains(realFolder + "/image.dmg"), "\(viaTemporary)")
        if real.path.hasPrefix("/var/") {
            XCTAssertTrue(viaTemporary.contains("/private" + real.path + "/image.dmg"), "\(viaTemporary)")
        }

        let viaLink = HdiutilDiskImages.imagePaths(of: link.appendingPathComponent("image.dmg"))
        XCTAssertTrue(viaLink.contains(link.path + "/image.dmg"), "\(viaLink)")
        XCTAssertTrue(viaLink.contains(realFolder + "/image.dmg"), "\(viaLink)")
        XCTAssertTrue(realFolder.hasPrefix("/private/") || !real.path.hasPrefix("/var/"), realFolder)
    }

    func testTheDiskImageIsFoundByItsImagePathOrItsAlias() {
        let image = URL(fileURLWithPath: "/tmp/subset-alias-test/image.dmg")
        let ours: [String: Any] = ["image-path": "/elsewhere/other.dmg", "image-alias": image.path,
                                   "system-entities": [["dev-entry": "/dev/disk42"], ["dev-entry": "/dev/disk42s1"]]]
        let byPath: [String: Any] = ["image-path": image.path, "system-entities": [["dev-entry": "/dev/disk44"]]]
        let other: [String: Any] = ["image-path": "/elsewhere/unrelated.dmg", "system-entities": [["dev-entry": "/dev/disk43"]]]
        XCTAssertEqual(HdiutilDiskImages.devices(of: image, in: ["images": [ours, byPath, other]]), ["/dev/disk42", "/dev/disk44"])
    }

    // MARK: - Running detection, interruption and reporting

    func testTheDetectorMatchesTheRealPathAndRefusesAPidItCannotRead() throws {
        // A bundle in /var/folders whose executable libproc reports under /private/var.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-alias-\(UUID().uuidString)")
        let bundle = folder.appendingPathComponent("Breaks.app")
        try makeBundle(bundle, bundleID: "dev.subset.breaks", version: "0.1.0")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let real = try XCTUnwrap(AppInstaller.realPath(bundle.path))
        let look: (pid_t) -> WorkspaceRunningApps.ProcessLook = { pid in
            switch pid {
            case 10: return .path(real + "/Contents/MacOS/Breaks")
            case 11: return .exited
            case 12: return .path("/Applications/Other.app/Contents/MacOS/Other")
            case 13: return .otherUser
            // Started from the bundle, whose file there is now a link to one outside it: the saved path still counts.
            case 14: return .started(bundle.path + "/Contents/MacOS/Helper")
            case 15: return .started(bundle.path + "/Contents/MacOS/../../../Other.app/Contents/MacOS/Other")
            // Started through a link to another folder and `..`: it runs from that folder's Breaks.app, not this one.
            case 17: return .started(folder.path + "/Route/../Breaks.app/Contents/MacOS/Helper")
            // Started in the bundle's Contents/Helpers, which has since been moved out and replaced by a link to where it
            // went: libproc names where the file is now, the saved path still places it in the bundle.
            case 18: return .started(bundle.path + "/Contents/Helpers/Helper")
            case 19: return .path(folder.path + "/Moved/Helper", started: bundle.path + "/Contents/Helpers/Helper")
            case 20: return .path(folder.path + "/Moved/Helper", started: nil)
            // The same with `..` inside the bundle in the saved path: Helpers was a folder when it started.
            case 21: return .started(bundle.path + "/Contents/Helpers/Child/../Helper")
            case 22: return .path(folder.path + "/Moved/Helper", started: bundle.path + "/Contents/Helpers/Child/../Helper")
            // Leaving the bundle and entering it again through folders that are not links.
            case 23: return .started(bundle.path + "/Contents/Helpers/../../../Breaks.app/Contents/Helpers/Helper")
            // Started through a link outside the bundle that now leads into it: libproc names the file outside, so the
            // link resolved now does not make it the copy's; with nothing naming the file now, it does.
            case 24: return .path("/usr/bin/true", started: folder.path + "/Alias/Tool")
            case 25: return .started(folder.path + "/Alias/Tool")
            default: return .unknown(EPERM)
            }
        }
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Contents/MacOS/Helper").path, withDestinationPath: "/usr/bin/true")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Tools/Child"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Tools/Breaks.app/Contents/MacOS"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Route").path, withDestinationPath: folder.appendingPathComponent("Tools/Child").path)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Moved"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: bundle.appendingPathComponent("Contents/Helpers").path, withDestinationPath: folder.appendingPathComponent("Moved").path)
        try FileManager.default.createSymbolicLink(atPath: folder.appendingPathComponent("Alias").path, withDestinationPath: bundle.appendingPathComponent("Contents/MacOS").path)
        XCTAssertEqual(try WorkspaceRunningApps.processes(inside: bundle, among: [10, 11, 12, 13, 14, 15, 17, 18, 19, 20, 21, 22, 23, 24, 25], look: look), [10, 14, 18, 19, 21, 22, 23, 25])
        XCTAssertThrowsError(try WorkspaceRunningApps.processes(inside: bundle, among: [11, 16], look: look), "a live process of this user that cannot be named")
        for (path, inside) in [(real + "/Contents/MacOS/Breaks", true), (bundle.path + "/Contents/MacOS/Breaks", true), (real + "x/MacOS/Breaks", false)] {
            XCTAssertEqual(BundleMatcher(bundle).contains(path), inside, path)
        }
        XCTAssertEqual(BundleMatcher.canonical(bundle.path + "/Contents/./MacOS//../MacOS/Gone"), real + "/Contents/MacOS/Gone")
    }

    // Only an app that is a process found in the copy (the same pid, started at the same time) and whose own executable
    // or bundle is the copy's is asked to quit: a pid given to another app since is skipped, and this app is never asked.
    func testOnlyAnAppStillRunningFromTheCopyIsAskedToQuit() throws {
        let bundle = URL(fileURLWithPath: "/Applications/Breaks.app")
        let apps: [(pid: pid_t, executable: URL?, bundle: URL?)] = [
            (10, bundle.appendingPathComponent("Contents/MacOS/Breaks"), bundle),
            (11, URL(fileURLWithPath: "/Applications/Other.app/Contents/MacOS/Other"), URL(fileURLWithPath: "/Applications/Other.app")),
            (12, nil, bundle),
            (13, bundle.appendingPathComponent("Contents/MacOS/Breaks"), bundle),
            (14, bundle.appendingPathComponent("Contents/MacOS/Breaks"), bundle),
            (getpid(), bundle.appendingPathComponent("Contents/MacOS/Breaks"), bundle),
        ]
        // 14 was found, then exited, and its pid went to another copy of the app, started later.
        let found: [pid_t: UInt64?] = [10: 100, 11: 100, 12: 100, 14: 100, getpid(): 100]
        let now: [pid_t: UInt64] = [10: 100, 11: 100, 12: 100, 13: 100, 14: 900, getpid(): 100]
        let targets = WorkspaceRunningApps.targets(apps, found: found, matcher: BundleMatcher(bundle), own: getpid(), startTime: { now[$0] }) {
            ($0.pid, [$0.executable, $0.bundle])
        }
        XCTAssertEqual(targets.map { $0.pid }, [10, 12])
    }

    // A real process in a /var/folders bundle is found by the bundle's real path. Once its executable is deleted libproc
    // cannot name it (ESRCH, as for one that exited); the path it was started with still does, so it is still found
    // inside its bundle and blocks nothing else.
    func testAProcessWhoseExecutableWasDeletedIsStillFoundByTheBundle() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-deleted-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let bundle = folder.appendingPathComponent("Breaks.app")
        try makeBundle(bundle, bundleID: "dev.subset.breaks", version: "0.1.0")
        let executable = bundle.appendingPathComponent("Contents/MacOS/Breaks")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let signed = try await ToolRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", executable.path], timeout: 60)
        XCTAssertEqual(signed.status, 0, signed.stderr)
        // Started by a path that is not canonical, with the bundle's name in another case where the volume ignores case.
        let name = BundleMatcher(bundle).foldsCase ? "BREAKS.app" : "Breaks.app"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: folder.path + "/\(name)/Contents/./MacOS/../MacOS/Breaks")
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        let pid = process.processIdentifier
        let found = { (bundle: URL) in try WorkspaceRunningApps.processes(inside: bundle, among: [pid], look: WorkspaceRunningApps.look) }
        // Running: libproc names it under /private/var, the bundle's real path, for this /var/folders bundle.
        XCTAssertEqual(try found(bundle), [pid])
        XCTAssertEqual(try WorkspaceRunningApps().processes(inside: bundle), [pid], "and among every process")
        // Deleted while it still loads, its executable's pages could not be checked and the system would kill it.
        try await Task.sleep(for: .milliseconds(500))
        try FileManager.default.removeItem(at: executable)
        XCTAssertNil(WorkspaceRunningApps.executable(of: pid), "libproc no longer names it")
        XCTAssertEqual(try found(bundle), [pid])
        XCTAssertEqual(try found(folder.appendingPathComponent("Other.app")), [])
        XCTAssertTrue(process.isRunning)
    }

    func testHashingStopsWhenCancelled() async throws {
        let file = temporary.appendingPathComponent("big.dmg")
        try Data(count: 3 * 1024 * 1024).write(to: file)
        let task = Task { () throws -> String in
            cancelCurrentTask()
            return try AppInstaller.sha256(of: file)
        }
        let result = try? await task.value
        XCTAssertNil(result, "a cancelled hash throws")
    }

    func testCancellingOnceTheCopyIsVerifiedQuitsNothing() async throws {
        let old = try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        running.running.update { $0.insert(target.path) }
        verifier.cancelDuring = true
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(refused?.step, .interrupted)
        XCTAssertEqual(refused?.partial, false)
        XCTAssertEqual(running.quits.get(), [])
        XCTAssertEqual(refused?.notes.contains("Breaks was asked to quit for the update. Open Breaks again."), false, "nothing was asked to quit")
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        assertNoLeftovers()
    }

    func testCancellingDuringTheFirstOfTwoQuitsStartsNoOther() async throws {
        let old = try installOld()
        let second = user.appendingPathComponent("Breaks.app")
        try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
        let secondBefore = AppInstaller.identity(second)
        let receiptBefore = try Data(contentsOf: receiptFile)
        let paths = [target.path, second.path]
        running.running.update { $0.formUnion(paths) }
        running.cancelDuringQuit = true
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: true) }
        XCTAssertEqual(refused?.step, .interrupted)
        XCTAssertEqual(running.quits.get(), [target.path], "the second copy is not asked to quit")
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(AppInstaller.identity(second), secondBefore)
        XCTAssertEqual(names(trashFolder), [])
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        assertNoLeftovers()
    }

    func testAHelperIsNamedAndOnlyAnAppAskedToQuitIsSaidToBe() async throws {
        let old = try installOld()
        let path = target.path
        running.helpers.update { $0.insert(path) }
        let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(update?.step, .running)
        XCTAssertEqual(update?.message, "a helper process of Breaks runs from \(path) (pid 4343) and Subset asks only apps to quit; quit it and try again")
        let trashed = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: true) }
        XCTAssertEqual(trashed?.step, .running)
        XCTAssertEqual(trashed?.partial, false)
        XCTAssertEqual(update?.notes, [], "no app was asked to quit")
        // The app quits but its helper stays: refused, and the app is said to have been asked to quit.
        running.running.update { $0.insert(path) }
        let both = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(both?.message, "Breaks is still running 1 seconds after it was asked to quit (pid 4343)")
        XCTAssertEqual(running.quits.get(), [path])
        XCTAssertEqual(both?.notes, ["Breaks was asked to quit for the update. Open Breaks again."])
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(names(trashFolder), [])
        assertNoLeftovers()
    }

    func testACancelAsksNoFurtherAppToQuit() async throws {
        let asked = await Task { () -> [Int] in
            WorkspaceRunningApps.ask([1, 2, 3]) { app in
                if app == 1 { cancelCurrentTask() }
                return true
            }
        }.value
        XCTAssertEqual(asked, [1], "the request made is kept; no further one is made")
        // terminate() is false for an app that exited before it was asked: it does not count as asked.
        XCTAssertEqual(WorkspaceRunningApps.ask([1, 2, 3]) { $0 != 2 }, [1, 3])
    }

    func testAHelperThatExitedBeforeTheQuitIsNotAReasonToRefuse() async throws {
        try installOld()
        running.helpers.update { $0.insert(self.target.path) }
        running.helperExitsOnQuit = true
        let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: true)
        XCTAssertEqual(version(target), "0.1.0")
        XCTAssertFalse(outcome.notes.contains("Breaks was asked to quit for the update. Open Breaks again."), "nothing was asked to quit")
    }

    func testACopyLeftUnderItsHiddenNameInTheTrashIsReportedWithWhy() async throws {
        try installOld()
        trash = HiddenTrash(folder: trashFolder)
        let outcome = try await installer().moveToTrash(Self.breaks, quitAllowed: false)
        let hidden = try XCTUnwrap(names(trashFolder).first)
        XCTAssertEqual(outcome.notes.last, "It is in the Trash under the hidden name \(trashFolder.path)/\(hidden) because it could not be renamed there (name taken); in Finder, press Command-Shift-Period to see it.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptFile.path))
        // SystemTrash's naming step in a Trash folder where the copy cannot be renamed keeps the hidden name and says why.
        let folder = root.appendingPathComponent("ReadOnlyTrash")
        let moved = folder.appendingPathComponent(".Breaks.app.subset-trash-1-aaaaaaaaaaaa")
        try makeBundle(moved, bundleID: "dev.subset.breaks", version: "0.0.9")
        chmod(folder.path, 0o555)
        defer { chmod(folder.path, 0o755) }
        let named = SystemTrash.name(moved, appName: "Breaks", at: Self.installedAt)
        XCTAssertEqual(named.url, moved)
        XCTAssertNotNil(named.renameFailure)
    }

    func testCopiesBesideAnAppPathThatIsNotAFolderAreNamedNotMoved() throws {
        for kind in ["file", "link"] {
            try tearDownWithError()
            try setUpWithError()
            let saved = system.appendingPathComponent(".Breaks.app.subset-update-99999-aaaaaaaaaaaa")
            try makeBundle(saved, bundleID: "dev.subset.breaks", version: "0.0.9")
            if kind == "file" { try Data("x".utf8).write(to: target) } else { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: user) }
            let notes = installer().recover(Self.breaks)
            XCTAssertEqual(notes.map(\.line), ["\(target.path) is not an app folder, and an interrupted update or move to the Trash left copies of Breaks beside it at \(saved.path)."], kind)
            XCTAssertEqual(notes.map(\.changed), [false], "only named, nothing renamed")
            XCTAssertEqual(names(system), [saved.lastPathComponent, "Breaks.app"], kind)
            XCTAssertEqual(version(saved), "0.0.9", kind)
        }
    }

    func testLockFilesOutsideTheSharedGrammarAreLeftAlone() async throws {
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let key = Self.hex(Data("dev.subset.breaks".utf8))
        let live = getppid()
        // A combining mark makes a 12-character nonce that is not 12 hex bytes, for a live and a stale pid.
        let malformed = [
            "\(key).\(live).ABCDEF012345.lock", "\(key).+\(live).abcdef012345.lock", "\(key).99999.abcdef01234z.lock",
            "\(key).\(live).abcdef01234a\u{20DD}.lock", "\(key).99999.abcdef01234a\u{20DD}.lock",
        ].sorted()
        for name in malformed { FileManager.default.createFile(atPath: locks.appendingPathComponent(name).path, contents: Data()) }
        _ = try await installer().install(Self.breaks, Self.live)
        XCTAssertEqual(names(locks), malformed, "neither refused by nor removed")
    }
}

/// The fields one refusal case changes.
struct RefusalCase {
    var downloads: [String: Data]
    var volumes: [Data: [String: (URL) throws -> Void]]
    var release: ChosenRelease
    var refusal: InstallFailure?
}

/// Records the version at `target` each time a copy is moved to the Trash.
struct CheckingTrash: Trashing {
    var inner: any Trashing
    var target: URL
    let versionsInPlace = Recorder<[String?]>([])

    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        versionsInPlace.update { $0.append(InstalledAppFinder.infoPlist(target.path)?["CFBundleShortVersionString"] as? String) }
        return try inner.trash(bundle, appName: appName, at: date)
    }
}

/// A Trash whose call number `call` (from 1) throws `error` before moving anything, or moves the copy and then runs
/// `after` (as another manager changing the install path just then).
struct ScriptedTrash: Trashing {
    var inner: any Trashing
    var call = 1
    var error: (any Error & Sendable)?
    var after: (@Sendable () -> Void)?
    let calls = Recorder(0)

    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        calls.update { $0 += 1 }
        guard calls.get() == call else { return try inner.trash(bundle, appName: appName, at: date) }
        if let error { throw error }
        let trashed = try inner.trash(bundle, appName: appName, at: date)
        after?()
        return trashed
    }
}

/// Moves a copy to the Trash, then cancels the task, as Cancel pressed just after the first copy went would.
struct CancellingTrash: Trashing {
    var inner: any Trashing

    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        defer { cancelCurrentTask() }
        return try inner.trash(bundle, appName: appName, at: date)
    }
}

/// Moves a copy into `folder` under its own (hidden) name, as the Trash does when the rename there fails.
struct HiddenTrash: Trashing {
    var folder: URL

    func trash(_ bundle: URL, appName _: String, at _: Date) throws -> Trashed {
        let moved = folder.appendingPathComponent(bundle.lastPathComponent)
        try FileManager.default.moveItem(at: bundle, to: moved)
        return Trashed(url: moved, renameFailure: "name taken")
    }
}

// MARK: - The shared detector and the update's commit, end to end

extension AppInstallerTests {
    /// The installer as the app makes it, with the system's process list in place of the fake.
    private func installerWithSystemProcesses() -> AppInstaller {
        var installer = installer()
        installer.running = WorkspaceRunningApps()
        return installer
    }

    // A live helper started from the installed copy, whose folder was then moved out of the bundle and replaced by a
    // link to where it went: libproc names it outside the bundle, but it was started inside, so the user is asked, and
    // Update and Move to Trash refuse, leaving the copy and its receipt as they were.
    func testALiveHelperUnderAReplacedFolderIsFoundAndBlocksUpdateAndMoveToTrash() async throws {
        let old = try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        let helpers = target.appendingPathComponent("Contents/Helpers")
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        let helper = helpers.appendingPathComponent("Helper")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: helper.path)
        let signed = try await ToolRunner.run("/usr/bin/codesign", ["--force", "--sign", "-", helper.path], timeout: 60)
        XCTAssertEqual(signed.status, 0, signed.stderr)
        let process = Process()
        process.executableURL = helper
        process.arguments = ["30"]
        try process.run()
        defer { process.terminate() }
        // Let it load before its folder moves (pages of a moved file still load; this only keeps the test steady).
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(try installerWithSystemProcesses().isRunning(Self.breaks))
        let moved = root.appendingPathComponent("Moved")
        try FileManager.default.moveItem(at: helpers, to: moved)
        try FileManager.default.createSymbolicLink(at: helpers, withDestinationURL: moved)
        let named = try XCTUnwrap(WorkspaceRunningApps.executable(of: process.processIdentifier))
        XCTAssertFalse(BundleMatcher(target).contains(named), "libproc names it outside the bundle: \(named)")

        XCTAssertTrue(try installerWithSystemProcesses().isRunning(Self.breaks), "the user is asked before it is quit")
        for (operation, quitAllowed) in [("update", false), ("moveToTrash", false), ("moveToTrash", true)] {
            let refused = await failure { installer in
                var installer = installer
                installer.running = WorkspaceRunningApps()
                return operation == "update" ? try await installer.update(Self.breaks, Self.live, quitAllowed: quitAllowed)
                    : try await installer.moveToTrash(Self.breaks, quitAllowed: quitAllowed)
            }
            XCTAssertEqual(refused?.step, .running, "\(operation) quitAllowed \(quitAllowed): \(refused?.message ?? "")")
            XCTAssertEqual(refused?.partial, false, operation)
            XCTAssertEqual(AppInstaller.identity(target), old, operation)
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, operation)
            XCTAssertEqual(names(trashFolder), [], operation)
        }
        XCTAssertEqual(downloader.calls.get(), 0, "refused before the download")
        XCTAssertTrue(process.isRunning, "a helper is never stopped")
        assertNoLeftovers()
    }

    // Right after the verified copy is renamed into place, something else replaces it, or it disappears: the update
    // stops without touching the receipt or the Trash, leaves a replacement as it is and keeps the previous copy (put
    // back when nothing is there, otherwise kept under its hidden name, which the failure names).
    func testAnUpdateWhoseNewCopyIsReplacedOrRemovedRightAfterItsRenameStops() async throws {
        for (disappears, whileWritingReceipt) in [(false, false), (true, false), (false, true), (true, true)] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            let path = target.path
            running.running.update { $0.insert(path) }
            var installer = installer()
            let change: @Sendable () -> Void = {
                try? FileManager.default.removeItem(atPath: path)
                if !disappears { try? makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.other", version: "9.0") }
            }
            if whileWritingReceipt {
                // The receipt's time is read as the receipt is written, after the new copy is in place.
                let armed = Recorder(false)
                installer.afterPlacing = { _ in armed.update { $0 = true } }
                installer.clock = {
                    if armed.get() { armed.update { $0 = false }; change() }
                    return Self.installedAt
                }
            } else {
                installer.afterPlacing = { _ in change() }
            }
            var failure: InstallFailure?
            do { _ = try await installer.update(Self.breaks, Self.live, quitAllowed: true) } catch { failure = error as? InstallFailure }
            let label = (disappears ? "disappears" : "replaced") + (whileWritingReceipt ? " while the receipt is written" : "")
            XCTAssertEqual(failure?.step, .install, label)
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, "\(label): the receipt is unchanged")
            XCTAssertEqual(names(trashFolder), [], "\(label): the previous copy is not moved to the Trash")
            XCTAssertEqual(failure?.notes.last, "Breaks was asked to quit for the update. Open Breaks again.", "\(label): the quit is said; nothing is opened again")
            let hidden = names(system).filter { $0.hasPrefix(".Breaks.app.subset-update-") }
            if disappears {
                XCTAssertEqual(failure?.message, "\(path) was changed or removed right after the new copy was put there (by the subset command?), so the previous copy was put back")
                XCTAssertEqual(failure?.partial, false)
                XCTAssertEqual(AppInstaller.identity(target), old, "the previous copy is back in place")
                XCTAssertEqual(hidden, [])
            } else {
                XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "the replacement stays")
                XCTAssertEqual(hidden.count, 1)
                let kept = system.appendingPathComponent(hidden.first ?? "")
                XCTAssertEqual(AppInstaller.identity(kept), old, "the previous copy is kept")
                XCTAssertEqual(failure?.partial, true)
                XCTAssertEqual(failure?.message, "\(path) was changed or removed right after the new copy was put there (by the subset command?), so it was left as it is and the receipt was not changed")
                XCTAssertTrue(failure?.notes.contains("The previous copy of Breaks is kept at \(kept.path); rename it to \(path) to use it again.") == true, "\(failure?.notes ?? [])")
            }
            XCTAssertEqual(names(temporary), [], label)
            XCTAssertEqual(names(receipts), ["dev.subset.breaks.json"], "\(label): no temporary receipt is left")
            XCTAssertEqual(images.attached.get(), [], label)
        }
    }

    // The image is detached after the swap, and progress is reported, before the previous copy goes to the Trash; if the
    // verified copy is changed or removed meanwhile, the previous copy does not go and the update is not reported as
    // done: the receipt is put back as it was, the previous copy is put back when nothing is there (then nothing has
    // changed), otherwise kept and named.
    func testAnUpdateWhoseNewCopyChangesDuringCleanupKeepsThePreviousCopy() async throws {
        for (disappears, atProgress) in [(true, false), (false, false), (true, true), (false, true)] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            let path = target.path
            running.running.update { $0.insert(path) }
            let armed = Recorder(false)
            let change: @Sendable () -> Void = {
                guard armed.get() else { return }
                armed.update { $0 = false }
                try? FileManager.default.removeItem(atPath: path)
                if !disappears { try? makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.other", version: "9.0") }
            }
            if !atProgress { images.onDetach = change }
            var installer = installer()
            installer.afterPlacing = { _ in armed.update { $0 = true } }
            let progress: @Sendable (InstallProgress) -> Void = { step in if atProgress, step == .movingToTrash { change() } }
            var failure: InstallFailure?
            do { _ = try await installer.update(Self.breaks, Self.live, quitAllowed: true, progress: progress) } catch { failure = error as? InstallFailure }
            let label = (disappears ? "disappears" : "replaced") + (atProgress ? " as the move to the Trash starts" : " during cleanup")
            XCTAssertEqual(failure?.step, .install, label)
            XCTAssertEqual(failure?.partial, !disappears, "\(label): a change only while the previous copy stays aside")
            XCTAssertEqual(try? Data(contentsOf: receiptFile), receiptBefore, "\(label): the receipt is as it was")
            XCTAssertEqual(names(trashFolder), [], "\(label): the previous copy is not moved to the Trash")
            let hidden = names(system).filter { $0.hasPrefix(".Breaks.app.subset-") }
            if disappears {
                XCTAssertEqual(failure?.message, "\(path) was changed or removed after the new copy was put there (by the subset command?), so the previous copy and its receipt were put back")
                XCTAssertEqual(AppInstaller.identity(target), old)
                XCTAssertEqual(hidden, [])
            } else {
                XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "the replacement stays")
                XCTAssertEqual(hidden.count, 1)
                XCTAssertEqual(AppInstaller.identity(system.appendingPathComponent(hidden.first ?? "")), old, "the previous copy is kept")
            }
            XCTAssertEqual(names(receipts), ["dev.subset.breaks.json"], label)
        }
    }

    // A copy moved aside that cannot be put back is a change, also after the app was asked to quit: the update (the new
    // copy cannot take its place, which something else took) and Move to Trash (the Trash refuses it, and something else
    // took its place) say they were only partly done and where the copy is.
    func testACopyLeftAsideAfterAFailedRollbackIsReportedAsAChange() async throws {
        for operation in ["update", "moveToTrash"] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let path = target.path
            running.running.update { $0.insert(path) }
            let occupy: @Sendable () -> Void = { try? makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.other", version: "9.0") }
            var installer = installer()
            installer.beforePlacing = { _ in occupy() }
            installer.trash = OccupyingTrash(occupy: occupy)
            var failure: InstallFailure?
            do {
                _ = operation == "update" ? try await installer.update(Self.breaks, Self.live, quitAllowed: true)
                    : try await installer.moveToTrash(Self.breaks, quitAllowed: true)
            } catch { failure = error as? InstallFailure }
            let hidden = names(system).filter { $0.hasPrefix(".Breaks.app.subset-") }
            XCTAssertEqual(hidden.count, 1, operation)
            let aside = system.appendingPathComponent(hidden.first ?? "")
            XCTAssertEqual(AppInstaller.identity(aside), old, "\(operation): the previous copy is aside")
            XCTAssertEqual(failure?.partial, true, operation)
            XCTAssertEqual(failure?.onlyRecovered, false, operation)
            XCTAssertTrue(failure?.message.hasSuffix("it is at \(aside.path); rename it to \(path)") == true, "\(operation): \(failure?.message ?? "")")
            XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleIdentifier"] as? String, "dev.subset.other", operation)
        }
    }
}

/// A Trash that refuses the copy after something else took its place.
private struct OccupyingTrash: Trashing {
    let occupy: @Sendable () -> Void
    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        occupy()
        throw InstallFailure(.trash, "the fake Trash refused \(bundle.lastPathComponent)")
    }
}

// MARK: - The Trash handoff of an update, the receipt it puts back, and errors of any type from the Trash

extension AppInstallerTests {
    private var quitNote: String { "Breaks was asked to quit for the update. Open Breaks again." }

    // The verified copy is checked again once the previous copy has gone to the Trash: removed or replaced while the
    // Trash took it, the update is not reported as done, the receipt is put back byte for byte, and the previous copy
    // comes back from the Trash when nothing is at its path, or stays there and is named, leaving a replacement as it
    // is. A running copy asked to quit is said to be, and nothing is opened again.
    func testAnUpdateWhoseNewCopyChangesWhileThePreviousGoesToTheTrashIsUndone() async throws {
        for disappears in [true, false] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            let path = target.path
            running.running.update { $0.insert(path) }
            trash = ScriptedTrash(inner: trash, after: {
                try? FileManager.default.removeItem(atPath: path)
                if !disappears { try? makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.other", version: "9.0") }
            })
            let failed = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
            let label = disappears ? "removed" : "replaced"
            XCTAssertEqual(failed?.step, .install, label)
            XCTAssertEqual(try? Data(contentsOf: receiptFile), receiptBefore, "\(label): the receipt is put back")
            XCTAssertEqual(failed?.notes.last, quitNote, label)
            XCTAssertEqual(names(system).filter { $0.contains(".subset-") }, [], label)
            let why = "\(path) was changed or removed after the new copy was put there (by the subset command?)"
            if disappears {
                XCTAssertEqual(failed?.message, "\(why), so the previous copy and its receipt were put back from the Trash")
                XCTAssertEqual(failed?.partial, false, "nothing is left changed")
                XCTAssertEqual(AppInstaller.identity(target), old, "the previous copy is back")
                XCTAssertEqual(names(trashFolder), [])
            } else {
                XCTAssertEqual(failed?.message, "\(why), so it was left as it is and the previous copy was not put back")
                XCTAssertEqual(failed?.partial, true)
                XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "the replacement stays")
                let trashed = trashFolder.appendingPathComponent(names(trashFolder).first ?? "")
                XCTAssertEqual(AppInstaller.identity(trashed), old, "the previous copy is in the Trash")
                XCTAssertTrue(failed?.notes.contains("The previous copy of Breaks is in the Trash at \(trashed.path); rename it to \(path) to use it again.") == true, "\(failed?.notes ?? [])")
            }
            assertNoLeftovers()
        }
    }

    // Two copies: the second copy's install path is removed while its previous copy goes to the Trash. The first copy
    // stays updated (said, so the result is only partly done), the second's previous copy comes back, and the receipt is
    // the one the first copy's update wrote.
    func testTheSecondCopysTrashHandoffFailingKeepsTheFirstUpdated() async throws {
        try installOld()
        let second = user.appendingPathComponent("Breaks.app")
        try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
        let secondOld = AppInstaller.identity(second)
        let path = second.path
        trash = ScriptedTrash(inner: trash, call: 2, after: { try? FileManager.default.removeItem(atPath: path) })
        let failed = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
        XCTAssertEqual(failed?.step, .install)
        XCTAssertEqual(failed?.partial, true)
        XCTAssertEqual(failed?.notes.first, "Updated the copy in /Applications from 0.0.9 to 0.1.0.")
        XCTAssertEqual(version(target), "0.1.0")
        XCTAssertEqual(AppInstaller.identity(second), secondOld, "the second copy's previous copy is back")
        let receipt = try Receipt.parse(Data(contentsOf: receiptFile)).get()
        XCTAssertEqual([receipt.version, receipt.path], ["0.1.0", "/Applications/Breaks.app"], "the first copy's receipt")
        XCTAssertEqual(names(trashFolder).count, 1, "only the first copy's previous copy is in the Trash")
        assertNoLeftovers()
    }

    // The previous copy is put back only while it is that copy (device and inode): something else put where it was
    // left (in the Trash, or under its hidden name after the Trash refused it) is never renamed into the install path;
    // it stays where it is, and the result says the previous copy is no longer there.
    func testOnlyThePreviousCopyItselfIsPutBack() async throws {
        for trashRefuses in [false, true] {
            try tearDownWithError()
            try setUpWithError()
            try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            let substitute = SubstitutingTrash(inner: trash, target: target.path, refuses: trashRefuses)
            trash = substitute
            let failed = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: false) }
            let label = trashRefuses ? "under its hidden name" : "in the Trash"
            XCTAssertEqual(failed?.step, .install, label)
            XCTAssertEqual(failed?.partial, true, label)
            XCTAssertNil(AppInstaller.identity(target), "\(label): nothing is put at the install path")
            let left = try XCTUnwrap(substitute.left.get(), label)
            XCTAssertEqual(InstalledAppFinder.infoPlist(left.path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "\(label): the substitute stays")
            XCTAssertTrue(failed?.notes.contains { $0.hasPrefix("The previous copy of Breaks is no longer at \(left.path), where it was left") } == true, "\(label): \(failed?.notes ?? [])")
            XCTAssertTrue(failed?.message.hasSuffix("so it was left as it is and the previous copy was not put back") == true, failed?.message ?? "")
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore, "\(label): the receipt is put back")
        }
    }

    // Move to Trash: the Trash takes the copy from its hidden name, puts something else there and fails with an untyped
    // error. That substitute is never renamed into the install path; the result says the copy is no longer where it
    // was set aside, and the receipt stays.
    func testMoveToTrashPutsBackOnlyTheCopyItSetAside() async throws {
        try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        let substitute = SubstitutingTrash(inner: trash, target: target.path, refuses: true)
        trash = substitute
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
        let left = try XCTUnwrap(substitute.left.get())
        XCTAssertEqual(refused?.step, .trash)
        XCTAssertEqual(refused?.partial, true)
        XCTAssertNil(AppInstaller.identity(target), "nothing is put at the install path")
        XCTAssertEqual(InstalledAppFinder.infoPlist(left.path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "the substitute stays")
        XCTAssertTrue(refused?.message.hasSuffix("and the copy is no longer at \(left.path), where it was set aside, so it was not put back; look for it in the Trash") == true, refused?.message ?? "")
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
    }

    // Two copies of a running app are quit for one update, or only the first is and the second then adds its own notes:
    // the quit is said once, and last.
    func testTheQuitIsSaidOnceAndLastForAnUpdateOfSeveralCopies() async throws {
        for bothRun in [true, false] {
            try tearDownWithError()
            try setUpWithError()
            try installOld()
            let second = user.appendingPathComponent("Breaks.app")
            try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
            let paths = [target.path, second.path]
            running.running.update { $0.formUnion(bothRun ? paths : [paths[0]]) }
            if !bothRun { trash = ScriptedTrash(inner: trash, call: 2, error: POSIXError(.EPERM)) }
            let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: true)
            XCTAssertEqual(running.quits.get(), bothRun ? paths : [paths[0]])
            XCTAssertEqual(outcome.notes.filter { $0 == quitNote }.count, 1, "\(outcome.notes)")
            XCTAssertEqual(outcome.notes.last, quitNote)
            if !bothRun { XCTAssertTrue(outcome.notes.dropLast().last?.hasPrefix("The previous copy could not be moved to the Trash") == true, "\(outcome.notes)") }
        }
    }

    // An update undone after its swap puts the receipt back as it was: none when there was none, and when it cannot be
    // put back (its folder became read-only) the result does not claim it was, and says so as a change.
    func testAnUndoneUpdatePutsTheReceiptBackOrSaysItCouldNot() async throws {
        for readOnly in [false, true] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            if !readOnly { try FileManager.default.removeItem(at: receiptFile) }
            let path = target.path
            let receiptsPath = receipts.path
            let armed = Recorder(false)
            images.onDetach = {
                guard armed.get() else { return }
                try? FileManager.default.removeItem(atPath: path)
                if readOnly { chmod(receiptsPath, 0o500) }
            }
            var installer = installer()
            installer.afterPlacing = { _ in armed.update { $0 = true } }
            var failure: InstallFailure?
            do { _ = try await installer.update(Self.breaks, Self.live, quitAllowed: false) } catch { failure = error as? InstallFailure }
            chmod(receiptsPath, 0o755)
            let why = "\(path) was changed or removed after the new copy was put there (by the subset command?)"
            XCTAssertEqual(AppInstaller.identity(target), old, "the previous copy is back")
            if readOnly {
                XCTAssertEqual(failure?.message, "\(why), so the previous copy was put back")
                XCTAssertEqual(failure?.partial, true, "the receipt left for the new copy is a change")
                XCTAssertTrue(failure?.notes.first?.hasPrefix("The receipt \(receiptFile.path), written for the new copy, could not be put back as it was (") == true, "\(failure?.notes ?? [])")
            } else {
                XCTAssertEqual(failure?.message, "\(why), so the previous copy and its receipt were put back")
                XCTAssertEqual(failure?.partial, false)
                XCTAssertEqual(names(receipts), [], "there was no receipt, and there is none")
            }
        }
    }

    // A receipt that cannot be read whole, as a regular file within the receipt bound, could not be put back if the
    // update were undone: the update refuses before any download or quit, leaving the copy and the receipt as they are.
    func testAReceiptThatCannotBeReadWholeRefusesTheUpdateFirst() async throws {
        let kinds = ["unreadable", "folder", "pipe", "link", "too large"]
        for kind in kinds {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let path = target.path
            running.running.update { $0.insert(path) }
            let file = receiptFile.path
            switch kind {
            case "unreadable": chmod(file, 0)
            case "folder":
                try FileManager.default.removeItem(at: receiptFile)
                try FileManager.default.createDirectory(at: receiptFile, withIntermediateDirectories: false)
            case "pipe":
                try FileManager.default.removeItem(at: receiptFile)
                XCTAssertEqual(mkfifo(file, 0o644), 0)
            case "link":
                try FileManager.default.moveItem(at: receiptFile, to: receipts.appendingPathComponent("elsewhere.json"))
                try FileManager.default.createSymbolicLink(atPath: file, withDestinationPath: "elsewhere.json")
            default: try Data(repeating: 0x20, count: Receipt.maxBytes + 1).write(to: receiptFile)
            }
            let entry = AppInstaller.identity(receiptFile)
            let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
            chmod(file, 0o644)
            XCTAssertEqual(refused?.step, .receipt, kind)
            XCTAssertTrue(refused?.message.hasPrefix("the receipt \(file) cannot be read (") == true, "\(kind): \(refused?.message ?? "")")
            XCTAssertEqual(refused?.partial, false, kind)
            XCTAssertEqual(downloader.calls.get(), 0, "\(kind): before any download")
            XCTAssertEqual(running.quits.get(), [], "\(kind): before any quit")
            XCTAssertEqual(AppInstaller.identity(target), old, kind)
            XCTAssertEqual(AppInstaller.identity(receiptFile), entry, "\(kind): the receipt is as it was")
            assertNoLeftovers()
        }
        XCTAssertEqual(try AppInstaller.snapshotReceipt(receipts.appendingPathComponent("absent.json")), .absent)
    }

    // The Trash may throw any error. Move to Trash then puts the copy back from its hidden name (the receipt stays), or,
    // when something took its place, says where it is; an update keeps its success and names the previous copy's
    // hidden path.
    func testAnErrorOfAnyTypeFromTheTrashPutsTheCopyBackOrNamesIt() async throws {
        let errors: [any Error & Sendable] = [CocoaError(.fileWriteNoPermission), POSIXError(.EACCES)]
        for error in errors {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let receiptBefore = try Data(contentsOf: receiptFile)
            trash = ScriptedTrash(inner: trash, error: error)
            let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
            XCTAssertEqual(refused?.step, .trash, "\(error)")
            XCTAssertEqual(refused?.message, "\(target.path) cannot be moved to the Trash (\(error.localizedDescription))")
            XCTAssertEqual(refused?.partial, false, "\(error)")
            XCTAssertEqual(AppInstaller.identity(target), old, "\(error): the copy is put back")
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
            assertNoLeftovers()

            // Something takes its place first: the copy stays under its hidden name, which the failure names.
            let path = target.path
            trash = OccupyingThenFailingTrash(error: error) { try? makeBundle(URL(fileURLWithPath: path), bundleID: "dev.subset.other", version: "9.0") }
            let occupied = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
            let hidden = names(system).filter { $0.hasPrefix(".Breaks.app.subset-trash-") }
            XCTAssertEqual(hidden.count, 1)
            let aside = system.appendingPathComponent(hidden.first ?? "")
            XCTAssertEqual(AppInstaller.identity(aside), old)
            XCTAssertEqual(occupied?.partial, true)
            XCTAssertTrue(occupied?.message.hasSuffix("it is at \(aside.path); rename it to \(path)") == true, occupied?.message ?? "")
            XCTAssertEqual(InstalledAppFinder.infoPlist(path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "the occupant stays")
            XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)

            // Update: the new copy is verified and in place, so the update stands; the previous copy is named.
            try tearDownWithError()
            try setUpWithError()
            try installOld()
            trash = ScriptedTrash(inner: trash, error: error)
            let outcome = try await installer().update(Self.breaks, Self.live, quitAllowed: false)
            XCTAssertEqual(version(target), "0.1.0")
            XCTAssertEqual(try Receipt.parse(Data(contentsOf: receiptFile)).get().version, "0.1.0")
            let kept = names(system).filter { $0.hasPrefix(".Breaks.app.subset-old-") }
            XCTAssertEqual(kept.count, 1)
            XCTAssertEqual(outcome.notes, ["The previous copy could not be moved to the Trash (\(error.localizedDescription)); it is at \(system.appendingPathComponent(kept.first ?? "").path)."])
        }
    }

    // Move to Trash of two copies where the Trash refuses the second (with an untyped error): the first stays in the
    // Trash, the second is put back, the receipt stays, and the result is only partly done.
    func testMoveToTrashOfTwoCopiesWhoseSecondFailsKeepsTheFirstInTheTrash() async throws {
        try installOld()
        let second = user.appendingPathComponent("Breaks.app")
        try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8")
        let secondOld = AppInstaller.identity(second)
        let receiptBefore = try Data(contentsOf: receiptFile)
        trash = ScriptedTrash(inner: trash, call: 2, error: POSIXError(.EPERM))
        let refused = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: false) }
        XCTAssertEqual(refused?.step, .trash)
        XCTAssertEqual(refused?.partial, true)
        XCTAssertNil(AppInstaller.identity(target))
        XCTAssertEqual(names(trashFolder).count, 1)
        XCTAssertEqual(AppInstaller.identity(second), secondOld, "the second copy is put back")
        XCTAssertEqual(try Data(contentsOf: receiptFile), receiptBefore)
        assertNoLeftovers()
    }
}

/// Lets something take the copy's place, then throws `error` (not an InstallFailure).
private struct OccupyingThenFailingTrash: Trashing {
    let error: any Error & Sendable
    let occupy: @Sendable () -> Void
    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        occupy()
        throw error
    }
}

/// After the previous copy goes to the Trash (or as the Trash refuses it, `refuses`), something else takes its place
/// where it was left and the verified copy at `target` disappears; `left` is where the substitute is.
private final class SubstitutingTrash: Trashing, @unchecked Sendable {
    let inner: any Trashing
    let target: String
    let refuses: Bool
    let left = Recorder<URL?>(nil)

    init(inner: any Trashing, target: String, refuses: Bool) {
        self.inner = inner
        self.target = target
        self.refuses = refuses
    }

    func trash(_ bundle: URL, appName: String, at date: Date) throws -> Trashed {
        let place = refuses ? bundle : try inner.trash(bundle, appName: appName, at: date).url
        try FileManager.default.moveItem(at: place, to: place.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString).app"))
        try makeBundle(place, bundleID: "dev.subset.other", version: "9.0")
        try? FileManager.default.removeItem(atPath: target)
        left.update { $0 = place }
        if refuses { throw POSIXError(.EACCES) }
        return Trashed(url: place)
    }
}

// MARK: - Only the recorded previous copy and receipt are moved, renamed back or put back

extension AppInstallerTests {
    // While the image is cleaned up after the swap, something else takes the hidden name the previous copy was kept
    // under (for one copy, or for the second of two): nothing goes to the Trash for that copy, what is there is left as
    // it is, the verified copy stays and the result names the path. The first of two copies still goes to the Trash.
    func testAPreviousCopyReplacedBeforeTheTrashIsLeftAndNamed() async throws {
        for secondOfTwo in [false, true] {
            try tearDownWithError()
            try setUpWithError()
            try installOld()
            let second = user.appendingPathComponent("Breaks.app")
            if secondOfTwo { try makeBundle(second, bundleID: "dev.subset.breaks", version: "0.0.8") }
            let folder = secondOfTwo ? user : system
            let armedOn = secondOfTwo ? second.path : target.path
            let armed = Recorder(false)
            let substitute = Recorder<URL?>(nil)
            let moved = root.appendingPathComponent("moved-away.app")
            images.onDetach = {
                guard armed.get(), substitute.get() == nil else { return }
                let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
                guard let hidden = names.first(where: { $0.hasPrefix(".Breaks.app.subset-old-") }) else { return }
                let url = folder.appendingPathComponent(hidden)
                try? FileManager.default.moveItem(at: url, to: moved)
                try? makeBundle(url, bundleID: "dev.subset.other", version: "9.0")
                substitute.update { $0 = url }
            }
            let scripted = ScriptedTrash(inner: trash)
            trash = scripted
            var installer = installer()
            installer.afterPlacing = { placed in if placed.path == armedOn { armed.update { $0 = true } } }
            let outcome = try await installer.update(Self.breaks, Self.live, quitAllowed: false)
            let label = secondOfTwo ? "second of two" : "one copy"
            let left = try XCTUnwrap(substitute.get(), label)
            XCTAssertEqual(scripted.calls.get(), secondOfTwo ? 1 : 0, "\(label): only the first copy's previous copy goes to the Trash")
            XCTAssertEqual(InstalledAppFinder.infoPlist(left.path)?["CFBundleIdentifier"] as? String, "dev.subset.other", "\(label): left as it is")
            XCTAssertEqual(version(secondOfTwo ? second : target), "0.1.0", "\(label): the update stands")
            XCTAssertEqual(version(moved), secondOfTwo ? "0.0.8" : "0.0.9", label)
            XCTAssertTrue(outcome.notes.contains("The previous copy of Breaks (\(secondOfTwo ? "0.0.8" : "0.0.9")) is no longer at \(left.path), where it was kept to be moved to the Trash, so nothing was moved to the Trash and what is there was left as it is."), "\(label): \(outcome.notes)")
        }
    }

    // A previous copy renamed back to the install path is checked there: when something else is there right after the
    // rename (put at the hidden name or the install path meanwhile), it is left as it is, never renamed again.
    func testWhatIsAtTheInstallPathAfterARenameBackIsNotRenamedAgain() throws {
        let previous = system.appendingPathComponent(".Breaks.app.subset-update-1-aaaaaaaaaaaa")
        try makeBundle(previous, bundleID: "dev.subset.breaks", version: "0.0.9")
        let expected = try XCTUnwrap(AppInstaller.identity(previous))
        let path = target
        let moved = root.appendingPathComponent("moved.app")
        let other = Recorder<FileIdentity?>(nil)
        let restore = AppInstaller.restorePrevious(previous, identity: expected, to: target, afterRename: {
            try? FileManager.default.moveItem(at: path, to: moved)
            try? makeBundle(path, bundleID: "dev.subset.other", version: "9.0")
            other.update { $0 = AppInstaller.identity(path) }
        })
        XCTAssertEqual(restore, .otherAtTarget)
        XCTAssertNotNil(other.get())
        XCTAssertEqual(AppInstaller.identity(target), other.get(), "what is there stays")
        XCTAssertNil(AppInstaller.identity(previous), "nothing is renamed to the hidden name")
        XCTAssertEqual(AppInstaller.identity(moved), expected)
        let note = AppInstaller.notRestoredNote(restore, previous, identity: expected, inTrash: false, appName: "Breaks", target: target)
        XCTAssertEqual(note, "What is at \(target.path) after the previous copy of Breaks was renamed back there from \(previous.path) is not that copy, so it was left as it is; look for the previous copy in the Trash.")
        // And the copy itself, with nothing at the install path, is put back.
        try FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: moved, to: previous)
        XCTAssertEqual(AppInstaller.restorePrevious(previous, identity: expected, to: target), .restored)
        XCTAssertEqual(AppInstaller.identity(target), expected)
    }

    // An update undone after its swap puts the receipt back only while it is still the one the update left there:
    // a receipt rewritten in place, replaced or removed meanwhile is left as it is, named, and not claimed put back.
    func testAnUndoneUpdateLeavesAReceiptChangedSinceItWroteIt() async throws {
        for change in ["rewritten", "replaced", "removed"] {
            try tearDownWithError()
            try setUpWithError()
            let old = try installOld()
            let path = target.path
            let file = receiptFile
            let armed = Recorder(false)
            let other = Data("{\"note\":\"written by another manager\"}".utf8)
            images.onDetach = {
                guard armed.get() else { return }
                try? FileManager.default.removeItem(atPath: path)
                switch change {
                case "rewritten": try? other.write(to: file)
                case "replaced": try? other.write(to: file, options: .atomic)
                default: try? FileManager.default.removeItem(at: file)
                }
            }
            var installer = installer()
            installer.afterPlacing = { _ in armed.update { $0 = true } }
            var failure: InstallFailure?
            do { _ = try await installer.update(Self.breaks, Self.live, quitAllowed: false) } catch { failure = error as? InstallFailure }
            XCTAssertEqual(try? Data(contentsOf: receiptFile), change == "removed" ? nil : other, change)
            XCTAssertEqual(AppInstaller.identity(target), old, "\(change): the previous copy is back")
            XCTAssertEqual(failure?.message, "\(path) was changed or removed after the new copy was put there (by the subset command?), so the previous copy was put back", change)
            XCTAssertEqual(failure?.partial, false, change)
            XCTAssertTrue(failure?.notes.contains("The receipt \(receiptFile.path) was changed or removed after this update wrote it, so it was left as it is; it may not describe what is at \(path).") == true, "\(change): \(failure?.notes ?? [])")
        }
    }

    // What an update left at the receipt's path is recognised without reading it (a receipt this process cannot read
    // back, such as one written under a restrictive umask, is still its own), and a rewrite in place is not taken for it.
    func testTheReceiptLeftIsRecognisedWithoutReadingIt() throws {
        try Data("{}".utf8).write(to: receiptFile)
        chmod(receiptFile.path, 0o200)
        defer { chmod(receiptFile.path, 0o644) }
        XCTAssertThrowsError(try AppInstaller.snapshotReceipt(receiptFile), "it cannot be read back")
        let left = try XCTUnwrap(ReceiptState.of(receiptFile))
        XCTAssertTrue(left.isCurrent(receiptFile))
        let handle = try FileHandle(forWritingTo: receiptFile)
        try handle.write(contentsOf: Data("[]".utf8))
        try handle.close()
        XCTAssertFalse(left.isCurrent(receiptFile), "rewritten in place")
        try FileManager.default.removeItem(at: receiptFile)
        XCTAssertFalse(left.isCurrent(receiptFile), "removed")
        XCTAssertTrue(try XCTUnwrap(ReceiptState.of(receiptFile)).isCurrent(receiptFile), "absent, and still absent")
    }
}
