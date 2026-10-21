import Darwin
import Foundation
@testable import SystemCore
@testable import SystemDisk
import SystemProcesses
import XCTest

/// Cleanup against fixture home folders scanned with the real scanner, a Trash stand-in folder, and stub executables:
/// protected paths, revalidation just before a move, selected items only, review rules, the command allowlist, and
/// the confirmation each action needs.
@MainActor
final class CleanupTests: XCTestCase {
    private var fixture: DiskFixture!
    private var recorder: Recorder!

    override func setUp() async throws {
        fixture = try DiskFixture()
        recorder = Recorder()
        try FileManager.default.createDirectory(atPath: fixture.path("Bin"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    // MARK: Protected paths

    func testEveryProtectedPathIsRefused() {
        let protection = CleanupProtection(home: "/Users/me")
        let refused = [
            "/System/Library/Caches/x", "/System", "/usr/lib/x", "/usr/local/bin/brew", "/bin/ls", "/sbin/mount",
            "/private/var/db/x", "/private/var", "/Library/Caches/x", "/Applications/App.app", "/tmp/x",
            "/Users/other/Library/Caches/x", "/Users/me", "/Users/me/Library",
            "/Users/me/Library/Mobile Documents", "/Users/me/Library/Mobile Documents/com~apple~CloudDocs/a.txt",
            "/Users/me/Library/Keychains", "/Users/me/Library/Keychains/login.keychain-db",
            "/Users/me/Library/Mail", "/Users/me/Library/Mail/V10/x.emlx",
            "/Users/me/Pictures/Photos Library.photoslibrary", "/Users/me/Pictures/Old.photoslibrary/database/a",
            "/Users/me/.Trash/old.zip",
            // Another spelling of the same place, and paths that are not plain.
            "/users/ME/library/KEYCHAINS/x", "/Users/me/Library/Caches/../Keychains", "/Users/me/./Library",
            "/Users/me//Library", "Users/me/Library/Caches/x", "/Users/me/Library/Caches/x/",
        ]
        for path in refused {
            XCTAssertNotNil(protection.refusal(path), path)
        }
        let allowed = ["/Users/me/Library/Caches/com.example.app", "/Users/me/Library/Mailbox", "/Users/me/Pictures/a.jpg",
                       "/Users/me/Library/Developer/Xcode/DerivedData/App-abc", "/Users/me/Downloads/old.dmg"]
        for path in allowed {
            XCTAssertNil(protection.refusal(path), path)
        }
        // A home folder that is itself in a protected folder keeps it protected.
        XCTAssertNotNil(CleanupProtection(home: "/private/var/home").refusal("/private/var/home/Library/Caches/x"))
    }

    func testProtectedPathsInjectedAsRuleMatchesAreNeverMoved() async throws {
        let home = "/Users/me"
        let protected = ["/Users/me/Library/Keychains/login.keychain-db", "/Users/me/Library/Mail/V10",
                         "/Users/me/Library/Mobile Documents/x", "/Users/me/Pictures/P.photoslibrary",
                         "/Users/me/Library", "/usr/local/lib/x", "/System/Library/x", "/private/var/db/x"]
        let match = ReclaimMatch(
            rule: ReclaimRules.rule(.xcodeDerivedData), app: nil, identifier: nil,
            items: protected.enumerated().map { index, path in
                ReclaimItem(path: path, index: index, root: (path as NSString).deletingLastPathComponent,
                            sizes: DiskSizes(logical: 1, allocated: 1, private: 1), flags: [], touched: nil,
                            identity: DiskItemIdentity(device: 1, inode: UInt64(index + 1)))
            },
            bytes: .scanned(private: 8, allocated: 8, complete: true, allocatedUpperBound: false))
        let protection = CleanupProtection(home: home)
        let preview = try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)
        XCTAssertEqual(Set(preview.refusals.keys), Set(protected))
        XCTAssertFalse(preview.canConfirm)

        let executor = CleanupExecutor(protection: protection, commands: commands(), trash: mover(),
                                       freeSpace: { nil })
        let result = await executor.perform(preview, confirmation: CleanupConfirmation(preview))
        guard case let .trash(items) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(items.count, protected.count)
        for item in items {
            guard case .skipped(.protected) = item.status else { return XCTFail("\(item)") }
        }
        XCTAssertEqual(recorder.moved, [])
    }

    // MARK: Trash cleanups

    func testOnlyTheSelectedItemsAreMovedToTheTrash() async throws {
        for name in ["A-1", "B-2", "C-3"] {
            try fixture.write("Library/Developer/Xcode/DerivedData/\(name)/Build/app", bytes: 20_000)
        }
        let match = try await match(.xcodeDerivedData)
        XCTAssertEqual(match.items.count, 3)
        let chosen: Set<String> = [derivedData("A-1"), derivedData("C-3")]
        let preview = try CleanupPreview.make(match, selection: .items(chosen), commands: commands(),
                                              protection: protection)
        guard case let .trash(items) = preview.action else { return XCTFail("\(preview.action)") }
        XCTAssertEqual(Set(items.map(\.path)), chosen)
        // The private sizes of the chosen items, read by the scan.
        XCTAssertEqual(preview.estimate.bytes, items.compactMap(\.privateBytes).reduce(0, +))
        XCTAssertGreaterThanOrEqual(preview.estimate.bytes ?? 0, 40_000)

        let free = Counter(values: [1_000, 1_000])
        let executor = CleanupExecutor(protection: protection, commands: commands(), trash: mover(),
                                       freeSpace: { free.next() })
        let result = await executor.perform(preview, confirmation: CleanupConfirmation(preview))
        guard case let .trash(outcomes) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertEqual(outcomes.map(\.path), items.map(\.path))
        for outcome in outcomes {
            guard case .moved = outcome.status else { return XCTFail("\(outcome)") }
        }
        XCTAssertEqual(Set(recorder.moved), chosen)
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedData("A-1")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: derivedData("B-2")))
        XCTAssertFalse(FileManager.default.fileExists(atPath: derivedData("C-3")))
        // The rule's folder itself stays.
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path("Library/Developer/Xcode/DerivedData")))
        XCTAssertEqual(result.freedBytes, 0)
    }

    func testAReviewRuleRefusesOneActionConfirmation() async throws {
        try fixture.write("Library/Developer/Xcode/Archives/2026-01-01/App 1.xcarchive/Info.plist", bytes: 1_000)
        try fixture.write("Library/Developer/Xcode/Archives/2026-01-01/App 2.xcarchive/Info.plist", bytes: 1_000)
        let match = try await match(.xcodeArchives)
        XCTAssertEqual(match.risk, .review)
        XCTAssertThrowsError(try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)) {
            XCTAssertEqual($0 as? CleanupPlanError, .reviewNeedsEachItem)
        }
        // Choosing every item one by one is allowed; choosing none is not.
        let all = Set(match.items.map(\.path))
        XCTAssertNoThrow(try CleanupPreview.make(match, selection: .items(all), commands: commands(), protection: protection))
        XCTAssertThrowsError(try CleanupPreview.make(match, selection: .items([]), commands: commands(), protection: protection)) {
            XCTAssertEqual($0 as? CleanupPlanError, .nothingSelected)
        }
        XCTAssertThrowsError(try CleanupPreview.make(match, selection: .items([fixture.path("Documents")]),
                                                     commands: commands(), protection: protection)) {
            XCTAssertEqual($0 as? CleanupPlanError, .notInMatch(fixture.path("Documents")))
        }

        // The sheet starts with nothing chosen, offers no Check All, and confirms only what was chosen.
        let sheet = CleanupSheet(match: match, index: 0, commands: commands(), protection: protection)
        XCTAssertFalse(sheet.allowsChoosingAll)
        XCTAssertNil(sheet.confirm())
        sheet.chooseAll(true)
        XCTAssertTrue(sheet.chosen.isEmpty)
        let first = match.items[0].path
        sheet.setChosen(first, true)
        let confirmation = try XCTUnwrap(sheet.confirm())
        XCTAssertEqual(confirmation.action, .trash([CleanupItem(match.items[0])]))
    }

    func testMovingToTheFindersTrash() throws {
        try fixture.write("Library/Caches/pip/wheel.bin", bytes: 1_000)
        let url = URL(fileURLWithPath: fixture.path("Library/Caches/pip/wheel.bin"))
        let moved = try XCTUnwrap(CleanupExecutor.moveToTrash(url))
        defer { try? FileManager.default.removeItem(at: moved) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertTrue(moved.path.contains("/.Trash"), moved.path)
    }

    // MARK: Revalidation

    func testRevalidationSkipsAnItemThatChangedSinceTheScan() async throws {
        for name in ["Link-1", "Inode-2", "Moved-3", "Missing-4", "Kept-5"] {
            try fixture.write("Library/Developer/Xcode/DerivedData/\(name)/Build/app", bytes: 4_000)
        }
        let match = try await match(.xcodeDerivedData)
        let items = Dictionary(uniqueKeysWithValues: match.items.map { (($0.path as NSString).lastPathComponent, CleanupItem($0)) })
        let manager = FileManager.default
        // Replaced by a symbolic link to a folder elsewhere.
        try manager.removeItem(atPath: derivedData("Link-1"))
        try manager.createDirectory(atPath: fixture.path("Elsewhere/Link-1"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: derivedData("Link-1"), withDestinationPath: fixture.path("Elsewhere/Link-1"))
        // Replaced by another folder of the same name, with another inode.
        try manager.removeItem(atPath: derivedData("Inode-2"))
        try manager.createDirectory(atPath: derivedData("Inode-2"), withIntermediateDirectories: false)
        try manager.removeItem(atPath: derivedData("Missing-4"))
        XCTAssertEqual(items["Link-1"]?.revalidate(protection), .symlink)
        XCTAssertEqual(items["Inode-2"]?.revalidate(protection), .replaced)
        XCTAssertEqual(items["Missing-4"]?.revalidate(protection), .missing)
        XCTAssertNil(items["Kept-5"]?.revalidate(protection))

        // The rule's folder moved out and a link put in its place: the item is the same file, outside its root.
        let moved = try XCTUnwrap(items["Moved-3"])
        try manager.moveItem(atPath: fixture.path("Library/Developer/Xcode/DerivedData"), toPath: fixture.path("Outside"))
        try manager.createSymbolicLink(atPath: fixture.path("Library/Developer/Xcode/DerivedData"),
                                       withDestinationPath: fixture.path("Outside"))
        XCTAssertTrue(manager.fileExists(atPath: moved.path))
        XCTAssertEqual(moved.revalidate(protection), .outsideRoot)

        // A path not inside its root, the root itself, and an item the scan did not identify.
        let root = fixture.path("Library/Caches")
        XCTAssertEqual(CleanupItem(path: fixture.path("Documents/a"), root: root, identity: moved.identity, privateBytes: 1,
                                   isLowerBound: false).revalidate(protection), .outsideRoot)
        XCTAssertEqual(CleanupItem(path: root, root: root, identity: moved.identity, privateBytes: 1, isLowerBound: false)
            .revalidate(protection), .isRoot)
        try fixture.write("Library/Caches/x/y", bytes: 10)
        XCTAssertEqual(CleanupItem(path: root + "/x", root: root, identity: nil, privateBytes: 1, isLowerBound: false)
            .revalidate(protection), .notIdentified)
    }

    func testSkippedItemsAreReportedAndTheRestMoved() async throws {
        for name in ["Gone-1", "Kept-2"] {
            try fixture.write("Library/Developer/Xcode/DerivedData/\(name)/Build/app", bytes: 4_000)
        }
        let match = try await match(.xcodeDerivedData)
        let preview = try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)
        try FileManager.default.removeItem(atPath: derivedData("Gone-1"))
        let executor = CleanupExecutor(protection: protection, commands: commands(), trash: mover(), freeSpace: { nil })
        let result = await executor.perform(preview, confirmation: CleanupConfirmation(preview))
        XCTAssertEqual(result.outcome, .trash([
            .init(path: derivedData("Gone-1"), status: .skipped(.missing)),
            .init(path: derivedData("Kept-2"), status: .moved(trashPath: fixture.path("Bin/Kept-2"))),
        ]))
        XCTAssertEqual(recorder.moved, [derivedData("Kept-2")])
        XCTAssertTrue(result.summary(fixture.format).hasPrefix("Moved 1 to the Trash, skipped 1, failed 0."))
    }

    // MARK: Confirmation

    func testAConfirmationCoversOnlyItsOwnPreviewAndOnlyOnce() async throws {
        try fixture.write("Library/Developer/Xcode/DerivedData/A-1/Build/app", bytes: 4_000)
        let match = try await match(.xcodeDerivedData)
        let first = try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)
        let second = try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)
        XCTAssertNotEqual(first.id, second.id)
        let executor = CleanupExecutor(protection: protection, commands: commands(), trash: mover(), freeSpace: { nil })
        let confirmation = CleanupConfirmation(first)

        let other = await executor.perform(second, confirmation: confirmation)
        XCTAssertEqual(other.outcome, .notConfirmed)
        XCTAssertEqual(recorder.moved, [])
        let run = await executor.perform(first, confirmation: confirmation)
        guard case .trash = run.outcome else { return XCTFail("\(run.outcome)") }
        XCTAssertEqual(recorder.moved.count, 1)
        let again = await executor.perform(first, confirmation: confirmation)
        XCTAssertEqual(again.outcome, .notConfirmed)
        XCTAssertEqual(recorder.moved.count, 1)
    }

    func testTheSheetIssuesOneConfirmationForThePreviewShown() async throws {
        for name in ["A-1", "B-2"] {
            try fixture.write("Library/Developer/Xcode/DerivedData/\(name)/Build/app", bytes: 4_000)
        }
        let match = try await match(.xcodeDerivedData)
        let sheet = CleanupSheet(match: match, index: 0, commands: commands(), protection: protection)
        // A safe rule starts with every item chosen, as one action.
        XCTAssertTrue(sheet.allowsChoosingAll)
        XCTAssertEqual(sheet.chosen, Set(match.items.map(\.path)))
        let whole = try sheet.preview.get()
        sheet.setChosen(derivedData("B-2"), false)
        let part = try sheet.preview.get()
        XCTAssertNotEqual(whole.id, part.id)
        XCTAssertEqual(sheet.confirmTitle, "Move 1 Item to the Trash")

        let confirmation = try XCTUnwrap(sheet.confirm())
        XCTAssertTrue(confirmation.covers(part))
        XCTAssertFalse(confirmation.covers(whole))
        // Confirmed once: no second confirmation, and the choice is frozen.
        XCTAssertNil(sheet.confirm())
        sheet.setChosen(derivedData("B-2"), true)
        XCTAssertEqual(try sheet.preview.get(), part)
    }

    // MARK: Commands

    func testEachAllowlistedCommandRunsItsExactVectorFromItsFixedPath() async throws {
        XCTAssertEqual(CleanupTool.allCases.map(\.vector), [
            ["xcrun", "simctl", "delete", "unavailable"], ["brew", "cleanup"], ["npm", "cache", "clean", "--force"],
            ["pnpm", "store", "prune"], ["yarn", "cache", "clean"], ["docker", "image", "prune", "-f"],
        ])
        XCTAssertEqual(CleanupTool.xcrun.candidatePaths(home: "/Users/me"), ["/usr/bin/xcrun"])
        for tool in [CleanupTool.brew, .npm, .pnpm, .yarn] {
            XCTAssertEqual(tool.candidatePaths(home: "/Users/me"),
                           ["/opt/homebrew/bin/\(tool.rawValue)", "/usr/local/bin/\(tool.rawValue)"])
        }
        XCTAssertEqual(CleanupTool.docker.candidatePaths(home: "/Users/me"), DockerCLI.candidatePaths(home: "/Users/me"))

        for tool in CleanupTool.allCases { try stub(tool.rawValue, "exit 0") }
        let runner = RecordingRunner(recorder: recorder)
        let commands = commands(runner: runner)
        let executor = CleanupExecutor(protection: protection, commands: commands, trash: mover(), freeSpace: { nil })
        let rules = ReclaimRules.all.filter { if case .command = $0.cleanup { true } else { false } }
        XCTAssertEqual(Set(rules.map(\.id)), [.unavailableSimulators, .npmCache, .pnpmStore, .yarnCache, .homebrewCache,
                                              .dockerImages])
        for rule in rules {
            let match = ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [],
                                     bytes: .scanned(private: 100, allocated: 100, complete: true, allocatedUpperBound: false))
            XCTAssertThrowsError(try CleanupPreview.make(match, selection: .items([]), commands: commands,
                                                         protection: protection)) {
                XCTAssertEqual($0 as? CleanupPlanError, .commandHasNoItems)
            }
            let preview = try CleanupPreview.make(match, selection: .all, commands: commands, protection: protection)
            XCTAssertTrue(preview.canConfirm, rule.name)
            _ = await executor.perform(preview, confirmation: CleanupConfirmation(preview))
        }
        XCTAssertEqual(recorder.runs.map(\.executable), rules.map { fixture.path("Bin/" + CleanupTool.allowed(vector($0))!.rawValue) })
        XCTAssertEqual(recorder.runs.map(\.arguments), rules.map { Array(vector($0).dropFirst()) })
        let docker = try XCTUnwrap(recorder.runs.last)
        XCTAssertEqual(docker.environment["DOCKER_HOST"], "unix:///fixture/docker.sock")
        // Nothing is inherited, so no PATH lookup or setting from System's own environment reaches the tool.
        XCTAssertEqual(docker.environment["PATH"], fixture.path("Bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")
        XCTAssertNil(docker.environment["DOCKER_CONTEXT"])
    }

    func testACommandOrArgumentNotOnTheListIsRejected() throws {
        for vector in [["brew", "cleanup", "--prune=all"], ["rm", "-rf", "/"], ["/usr/bin/xcrun", "simctl", "delete", "unavailable"],
                       ["docker", "system", "prune", "-af"], ["npm", "cache", "clean"], ["brew"], []] {
            XCTAssertNil(CleanupTool.allowed(vector), "\(vector)")
        }
        let base = ReclaimRules.rule(.homebrewCache)
        let rule = ReclaimRule(id: base.id, name: base.name, location: base.location, risk: .safe,
                               cleanup: .command(["brew", "cleanup", "-s", "--prune=all"]), yield: base.yield,
                               explanation: base.explanation, rebuild: base.rebuild, developerTool: base.developerTool,
                               homePaths: base.homePaths)
        let match = ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [], bytes: .unavailable("x"))
        XCTAssertThrowsError(try CleanupPreview.make(match, selection: .all, commands: commands(), protection: protection)) {
            XCTAssertEqual($0 as? CleanupPlanError, .commandNotAllowed(["brew", "cleanup", "-s", "--prune=all"]))
        }
    }

    func testAStubCommandsExitStatusOutputAndTimeoutAreReported() async throws {
        // A real process: the stub prints its path and arguments, then fails.
        try stub("npm", "echo \"$0 $*\"; echo warning >&2; exit 3")
        let commands = commands(runner: ProcessCommandRunner())
        let npm = try commands.resolve(.npm).get()
        XCTAssertEqual(npm.executable, fixture.path("Bin/npm"))
        guard case let .exited(3, failed) = await commands.run(npm) else { return XCTFail("npm stub did not exit 3") }
        // Foundation launches `/private/var/…` as `/var/…`, the same folder through its link.
        XCTAssertEqual(failed.lines.count, 2)
        XCTAssertTrue(failed.lines[0].hasSuffix("/Bin/npm cache clean --force"), failed.lines[0])
        XCTAssertEqual(failed.lines.last, "warning")
        XCTAssertEqual(failed.omitted, 0)

        // Only the last 200 lines are kept.
        try stub("brew", "i=1; while [ $i -le 250 ]; do echo line $i; i=$((i+1)); done")
        guard case let .exited(0, output) = await commands.run(try commands.resolve(.brew).get()) else {
            return XCTFail("brew stub did not exit 0")
        }
        XCTAssertEqual(output.lines.count, 200)
        XCTAssertEqual(output.lines.first, "line 51")
        XCTAssertEqual(output.omitted, 50)

        try stub("yarn", "sleep 20")
        let slow = self.commands(runner: ProcessCommandRunner(), timeout: .milliseconds(300))
        let timedOut = await slow.run(try slow.resolve(.yarn).get())
        XCTAssertEqual(timedOut, .timedOut(seconds: 0))
    }

    func testACommandWhoseProgramChangedSinceThePreviewIsNotRun() async throws {
        try stub("pnpm", "exit 0")
        let runner = RecordingRunner(recorder: recorder)
        let commands = commands(runner: runner)
        let match = ReclaimMatch(rule: ReclaimRules.rule(.pnpmStore), app: nil, identifier: nil, items: [],
                                 bytes: .unavailable("x"))
        let preview = try CleanupPreview.make(match, selection: .all, commands: commands, protection: protection)
        try FileManager.default.removeItem(atPath: fixture.path("Bin/pnpm"))
        let executor = CleanupExecutor(protection: protection, commands: commands, trash: mover(), freeSpace: { nil })
        let result = await executor.perform(preview, confirmation: CleanupConfirmation(preview))
        guard case .command(_, .refused) = result.outcome else { return XCTFail("\(result.outcome)") }
        XCTAssertTrue(recorder.runs.isEmpty)

        // A program not found at any fixed path gives a preview that cannot be confirmed.
        let missing = try CleanupPreview.make(match, selection: .all, commands: commands, protection: protection)
        XCTAssertFalse(missing.canConfirm)
        XCTAssertEqual(missing.action, .command(.pnpm, .failure(.notFound(tool: .pnpm, paths: [fixture.path("Bin/pnpm")]))))
    }

    // MARK: Window model

    func testTheDiskSectionCleansUpOnlyThroughItsSheet() async throws {
        try fixture.populate()
        let free = Counter(values: [5_000, 5_000])
        let service = DiskCleanupService(
            protection: protection, commands: commands(),
            executor: CleanupExecutor(protection: protection, commands: commands(), trash: mover(),
                                      freeSpace: { free.next() }))
        let model = DiskWindowModel(service: fixture.service(), cleanup: service, format: fixture.format, home: fixture.home)
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        let matches = try XCTUnwrap(model.analysis?.matches)
        let derived = try XCTUnwrap(matches.firstIndex { $0.rule.id == .xcodeDerivedData })
        let trash = try XCTUnwrap(matches.firstIndex { $0.rule.id == .trash })
        // Only on the Suggestions tab, and not for an information-only rule.
        XCTAssertFalse(model.canCleanUp(.match(derived)))
        model.tab = .suggestions
        XCTAssertTrue(model.canCleanUp(.match(derived)))
        XCTAssertFalse(model.canCleanUp(.match(trash)))
        model.beginCleanup(.match(trash))
        XCTAssertNil(model.cleanupSheet)

        model.beginCleanup(.match(derived))
        let sheet = try XCTUnwrap(model.cleanupSheet)
        let confirmation = try XCTUnwrap(sheet.confirm())
        model.dismissCleanup()
        XCTAssertNotNil(model.cleanupSheet, "a running cleanup's sheet stays open")
        model.perform(confirmation)
        try await DiskFixture.wait { !model.isCleaning }
        guard case let .finished(result) = sheet.phase, case let .trash(items) = result.outcome else {
            return XCTFail("\(sheet.phase)")
        }
        XCTAssertEqual(items.map(\.path), [fixture.path("Library/Developer/Xcode/DerivedData/App-abc")])
        XCTAssertEqual(model.cleanupResults, [result])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.path("Library/Developer/Xcode/DerivedData/App-abc")))
        // Done once: the suggestion offers no second cleanup until the next scan, and says so.
        XCTAssertFalse(model.canCleanUp(.match(derived)))
        XCTAssertTrue(model.rows.first { $0.id == .match(derived) }?.explanation?.hasPrefix("Cleaned up this session") == true)
        model.dismissCleanup()
        XCTAssertNil(model.cleanupSheet)

        // The same confirmation, presented again, does nothing.
        model.beginCleanup(.match(try XCTUnwrap(matches.firstIndex { $0.rule.id == .appLeftovers })))
        let leftovers = try XCTUnwrap(model.cleanupSheet)
        XCTAssertNil(leftovers.confirm(), "a review rule has nothing chosen at first")
        leftovers.setChosen(try XCTUnwrap(leftovers.match.items.first).path, true)
        _ = try XCTUnwrap(leftovers.confirm())
        model.perform(confirmation)
        try await DiskFixture.wait { !model.isCleaning }
        guard case let .finished(stale) = leftovers.phase else { return XCTFail("\(leftovers.phase)") }
        XCTAssertEqual(stale.outcome, .notConfirmed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path("Library/Preferences/com.gone.app.plist")))
        XCTAssertEqual(recorder.moved.count, 1)
    }

    // MARK: Helpers

    /// The fixture's home is in the temporary folder, inside `/private/var`, so that folder is left out here.
    private var protection: CleanupProtection {
        CleanupProtection(home: fixture.home, systemFolders: CleanupProtection.systemFolders.filter { $0 != "/private/var" })
    }

    private func derivedData(_ name: String) -> String {
        fixture.path("Library/Developer/Xcode/DerivedData/" + name)
    }

    private func match(_ id: ReclaimRuleID) async throws -> ReclaimMatch {
        let result = try await DiskScanner(workers: 2).scan(URL(fileURLWithPath: fixture.home))
        return try XCTUnwrap(DiskFixture.analysis(result, home: fixture.home).matches.first { $0.rule.id == id })
    }

    private func vector(_ rule: ReclaimRule) -> [String] {
        guard case let .command(vector) = rule.cleanup else { return [] }
        return vector
    }

    /// Tool commands whose programs are looked for only in the fixture's `Bin` folder, with Docker's socket given.
    private func commands(runner: any CommandRunning = RecordingRunner(recorder: Recorder()),
                          timeout: Duration = CleanupCommands.timeout) -> CleanupCommands {
        let bin = fixture.path("Bin")
        return CleanupCommands(home: fixture.home, runner: runner, timeout: timeout, candidates: { [bin + "/" + $0.rawValue] },
                               dockerTarget: { .success((bin + "/docker", "unix:///fixture/docker.sock")) })
    }

    /// A Trash stand-in: moves the item into the fixture's `Bin` folder and records it.
    private func mover() -> @Sendable (URL) throws -> URL? {
        let recorder = recorder!, bin = fixture.path("Bin")
        return { url in
            recorder.record(url.path)
            let target = bin + "/" + url.lastPathComponent
            try FileManager.default.moveItem(atPath: url.path, toPath: target)
            return URL(fileURLWithPath: target)
        }
    }

    private func stub(_ name: String, _ body: String) throws {
        let path = fixture.path("Bin/" + name)
        try? FileManager.default.removeItem(atPath: path)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertEqual(chmod(path, 0o755), 0)
    }
}

private final class Recorder: @unchecked Sendable {
    struct Run {
        let executable: String
        let arguments: [String]
        let environment: [String: String]
    }

    private let lock = NSLock()
    private var movedPaths: [String] = []
    private var recordedRuns: [Run] = []

    var moved: [String] { lock.withLock { movedPaths } }
    var runs: [Run] { lock.withLock { recordedRuns } }

    func record(_ path: String) { lock.withLock { movedPaths.append(path) } }
    func record(_ run: Run) { lock.withLock { recordedRuns.append(run) } }
}

private struct RecordingRunner: CommandRunning {
    let recorder: Recorder

    func run(_ executable: String, arguments: [String], environment: [String: String], timeout: Duration) async
        -> Result<CommandOutput, CommandFailure> {
        recorder.record(.init(executable: executable, arguments: arguments, environment: environment))
        return .success(CommandOutput(status: 0, stdout: Data(), stderr: Data()))
    }
}

/// Hands out the given values in turn, then `nil`.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64]

    init(values: [Int64]) { self.values = values }

    func next() -> Int64? {
        lock.withLock { values.isEmpty ? nil : values.removeFirst() }
    }
}
