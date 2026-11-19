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

    func testARunningAppIsQuitOnlyAfterTheNewCopyIsVerifiedAndThenReopened() async throws {
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
        _ = try await installer().update(Self.breaks, Self.live, quitAllowed: true)
        XCTAssertEqual(running.quits.get(), [path])
        XCTAssertEqual(running.reopened.get(), [path])
        XCTAssertEqual(version(target), "0.1.0")
    }

    func testAnAppThatDoesNotQuitIsNotReplaced() async throws {
        let old = try installOld()
        running.running.update { $0.insert(target.path) }
        running.stubborn = true
        let refused = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(refused?.step, .running)
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(running.reopened.get(), [target.path], "an app asked to quit is reopened")
        assertNoLeftovers()
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
        // Update: the app is reopened and the old copy stays.
        let old = try installOld()
        let receiptBefore = try Data(contentsOf: receiptFile)
        running.running.update { $0.insert(target.path) }
        running.cancelDuringQuit = true
        let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(update?.step, .interrupted)
        XCTAssertEqual(update?.message, "it was cancelled before it was installed")
        XCTAssertEqual(update?.partial, true, "the app was quit")
        XCTAssertEqual(update?.notes, ["Breaks was asked to quit for the update and was reopened."])
        XCTAssertEqual(running.quits.get(), [target.path])
        XCTAssertEqual(running.reopened.get(), [target.path])
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
        XCTAssertEqual(move?.message, "it was cancelled after part of it was done")
        XCTAssertEqual(move?.partial, true)
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
        XCTAssertEqual(running.reopened.get(), [], "an app moved to the Trash is not reopened")
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
        let own = try XCTUnwrap(WorkspaceRunningApps.ownExecutable())
        XCTAssertTrue(try WorkspaceRunningApps().processes(inside: URL(fileURLWithPath: own).deletingLastPathComponent()).contains(getpid()))
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
        let real = try XCTUnwrap(AppInstaller.realPath(bundle.path))
        let lookup: (pid_t) -> (path: String?, errno: Int32) = { pid in
            switch pid {
            case 10: return (real + "/Contents/MacOS/Breaks", 0)
            case 11: return (nil, ESRCH)
            case 12: return ("/Applications/Other.app/Contents/MacOS/Other", 0)
            default: return (nil, EPERM)
            }
        }
        XCTAssertEqual(try WorkspaceRunningApps.processes(inside: bundle, among: [10, 11, 12], executable: lookup), [10])
        XCTAssertThrowsError(try WorkspaceRunningApps.processes(inside: bundle, among: [11, 13], executable: lookup), "a live pid that cannot be read")
    }

    func testTheRealDetectorFindsAnAppRunningFromATemporaryFolder() throws {
        // The temporary folder is under /var/folders, which libproc names /private/var.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("subset-detect-\(UUID().uuidString)")
        try XCTSkipUnless(folder.path.hasPrefix("/var/"), folder.path)
        let bundle = folder.appendingPathComponent("Breaks.app")
        try makeBundle(bundle, bundleID: "dev.subset.breaks", version: "0.1.0")
        defer { try? FileManager.default.removeItem(at: folder) }
        let executable = bundle.appendingPathComponent("Contents/MacOS/Breaks")
        try FileManager.default.copyItem(atPath: "/bin/sleep", toPath: executable.path)
        let process = try Process.run(executable, arguments: ["30"])
        defer { process.terminate(); process.waitUntilExit() }
        XCTAssertTrue(try WorkspaceRunningApps().processes(inside: bundle).contains(process.processIdentifier))
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
        XCTAssertEqual(running.reopened.get(), [])
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

    func testAHelperIsNamedAndOnlyAnAppThatQuitIsReopened() async throws {
        let old = try installOld()
        let path = target.path
        running.helpers.update { $0.insert(path) }
        let update = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(update?.step, .running)
        XCTAssertEqual(update?.message, "a helper process of Breaks runs from \(path) (pid 4343) and Subset asks only apps to quit; quit it and try again")
        let trashed = await failure { try await $0.moveToTrash(Self.breaks, quitAllowed: true) }
        XCTAssertEqual(trashed?.step, .running)
        XCTAssertEqual(trashed?.partial, false)
        XCTAssertEqual(running.reopened.get(), [], "an app that never ran is not opened")
        // The app quits but its helper stays: refused, and the app that quit is reopened.
        running.running.update { $0.insert(path) }
        let both = await failure { try await $0.update(Self.breaks, Self.live, quitAllowed: true) }
        XCTAssertEqual(both?.message, "Breaks is still running 1 seconds after it was asked to quit (pid 4343)")
        XCTAssertEqual(running.quits.get(), [path])
        XCTAssertEqual(running.reopened.get(), [path])
        XCTAssertEqual(AppInstaller.identity(target), old)
        XCTAssertEqual(names(trashFolder), [])
        assertNoLeftovers()
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
            XCTAssertEqual(notes, ["\(target.path) is not an app folder, and an interrupted update or move to the Trash left copies of Breaks beside it at \(saved.path)."], kind)
            XCTAssertEqual(names(system), [saved.lastPathComponent, "Breaks.app"], kind)
            XCTAssertEqual(version(saved), "0.0.9", kind)
        }
    }

    func testLockFilesOutsideTheSharedGrammarAreLeftAlone() async throws {
        try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: true)
        let key = Self.hex(Data("dev.subset.breaks".utf8))
        let live = getppid()
        let malformed = ["\(key).\(live).ABCDEF012345.lock", "\(key).+\(live).abcdef012345.lock", "\(key).99999.abcdef01234z.lock"].sorted()
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
