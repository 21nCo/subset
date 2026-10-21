import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// One fixture tree per reclaim rule, built in a temporary home folder on the runner's APFS volume, scanned with the
/// real `DiskScanner`, and matched with an injected app list, runtime list, and Docker report.
final class ReclaimRulesTests: XCTestCase {
    private var home: String!
    private let now = Date()

    static let editor = InstalledApp(
        path: "/Applications/Editor.app", bundleID: "com.example.editor", name: "Editor", names: ["Editor", "Example Editor"],
        signature: CodeSignature(signingID: "com.example.editor", teamID: "EXAMPLE123", isPlatformBinary: false, teamName: "Example Ltd"))
    static let safari = InstalledApp(
        path: "/Applications/Safari.app", bundleID: "com.apple.Safari", name: "Safari",
        signature: CodeSignature(signingID: "com.apple.Safari", teamID: nil, isPlatformBinary: true))
    static let apps = InstalledApps([editor, safari])

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "ReclaimRulesTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: false)
        let real = try XCTUnwrap(realpath(base, nil))
        defer { free(real) }
        home = String(cString: real)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(atPath: home) }
    }

    // MARK: Catalog

    func testTheCatalogIsVersionOneWithExactlyTheIssuesRules() {
        XCTAssertEqual(ReclaimRules.catalogVersion, 1)
        let table: [(ReclaimRuleID, ReclaimRisk, ReclaimCleanup)] = [
            (.xcodeDerivedData, .safe, .trash),
            (.xcodeDeviceSupport, .safe, .trash),
            (.unavailableSimulators, .safe, .command(["xcrun", "simctl", "delete", "unavailable"])),
            (.simulatorCaches, .safe, .trash),
            (.xcodeArchives, .review, .trashEachItem),
            (.staleNodeModules, .safe, .trash),
            (.npmCache, .safe, .command(["npm", "cache", "clean", "--force"])),
            (.pnpmStore, .safe, .command(["pnpm", "store", "prune"])),
            (.yarnCache, .safe, .command(["yarn", "cache", "clean"])),
            (.homebrewCache, .safe, .command(["brew", "cleanup"])),
            (.dockerImages, .safe, .command(["docker", "image", "prune", "-f"])),
            (.cargoRegistryCache, .safe, .trash),
            (.gradleCaches, .safe, .trash),
            (.pipCache, .safe, .trash),
            (.appCaches, .safe, .trashPerApp),
            (.deviceBackups, .review, .trashEachItem),
            (.oldInstallers, .review, .trashEachItem),
            (.appLeftovers, .review, .trashEachItem),
            (.trash, .info, .none)
        ]
        XCTAssertEqual(ReclaimRules.all.map(\.id), table.map(\.0))
        XCTAssertEqual(ReclaimRules.all.map(\.id), ReclaimRuleID.allCases)
        for (rule, expected) in zip(ReclaimRules.all, table) {
            XCTAssertEqual(rule.risk, expected.1, "\(rule.id)")
            XCTAssertEqual(rule.cleanup, expected.2, "\(rule.id)")
            XCTAssertFalse(rule.explanation.isEmpty || rule.rebuild.isEmpty || rule.name.isEmpty || rule.location.isEmpty)
        }
    }

    // MARK: One fixture per rule

    func testXcodeDerivedDataMatchesEachProjectFolder() async throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/Build/Products/app", bytes: 300_000)
        try write("Library/Developer/Xcode/DerivedData/Tool-def/Index.noindex/data", bytes: 100_000)

        let match = try only(.xcodeDerivedData, in: try await analyze())

        try assertItems(match, ["Library/Developer/Xcode/DerivedData/App-abc", "Library/Developer/Xcode/DerivedData/Tool-def"],
                        root: "Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(match.risk, .safe)
    }

    func testXcodeDeviceSupportMatchesEveryOSVersionInEachDeviceSupportFolder() async throws {
        try write("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 18.0 (22A3354)/Symbols/dyld", bytes: 400_000)
        try write("Library/Developer/Xcode/watchOS DeviceSupport/Watch6,1 11.0 (22R349)/Symbols/dyld", bytes: 200_000)
        try write("Library/Developer/Xcode/UserData/IDEEditorInteractivityHistory", bytes: 50_000)

        let match = try only(.xcodeDeviceSupport, in: try await analyze())

        XCTAssertEqual(match.items.map(\.path), [
            path("Library/Developer/Xcode/iOS DeviceSupport/iPhone15,2 18.0 (22A3354)"),
            path("Library/Developer/Xcode/watchOS DeviceSupport/Watch6,1 11.0 (22R349)")
        ])
        XCTAssertEqual(match.items.map(\.root), [path("Library/Developer/Xcode/iOS DeviceSupport"),
                                                 path("Library/Developer/Xcode/watchOS DeviceSupport")])
        try assertBytes(match)
        XCTAssertEqual(match.risk, .safe)
    }

    func testUnavailableSimulatorsAreDevicesWhoseRuntimeIsNotInstalled() async throws {
        let devices = "Library/Developer/CoreSimulator/Devices"
        try device("\(devices)/11111111-1111-1111-1111-111111111111", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-0", bytes: 500_000)
        try device("\(devices)/22222222-2222-2222-2222-222222222222", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-18-3", bytes: 300_000)
        let runtimes = SimulatorRuntimes.installed(["com.apple.CoreSimulator.SimRuntime.iOS-18-3"])

        let match = try only(.unavailableSimulators, in: try await analyze(runtimes: runtimes))

        try assertItems(match, ["\(devices)/11111111-1111-1111-1111-111111111111"], root: devices)
        XCTAssertEqual(match.cleanup, .command(["xcrun", "simctl", "delete", "unavailable"]))

        // A device whose plist cannot be read is not counted, and the sum says it is incomplete.
        try write("\(devices)/33333333-3333-3333-3333-333333333333/data/disk", bytes: 100_000)
        let partial = try only(.unavailableSimulators, in: try await analyze(runtimes: runtimes))
        XCTAssertEqual(partial.items.count, 1)
        guard case .scanned(_, _, complete: false) = partial.bytes else { return XCTFail("\(partial.bytes)") }

        // Without the runtime list no device is called unavailable.
        let unknown = try only(.unavailableSimulators, in: try await analyze(runtimes: .unknown("images.plist is unreadable")))
        XCTAssertEqual(unknown.items, [])
        XCTAssertEqual(unknown.bytes, .unavailable("images.plist is unreadable"))
    }

    func testSimulatorCachesMatchTheirContents() async throws {
        try write("Library/Developer/CoreSimulator/Caches/dyld/24A335/dyld_sim_shared_cache_arm64e", bytes: 600_000)

        let match = try only(.simulatorCaches, in: try await analyze())

        try assertItems(match, ["Library/Developer/CoreSimulator/Caches/dyld"], root: "Library/Developer/CoreSimulator/Caches")
        XCTAssertEqual(match.risk, .safe)
    }

    func testXcodeArchivesAreEachArchiveInItsDateFolderForReview() async throws {
        try write("Library/Developer/Xcode/Archives/2026-09-01/App 01-09-2026, 10.00.xcarchive/Info.plist", bytes: 10_000)
        try write("Library/Developer/Xcode/Archives/2026-09-01/App 01-09-2026, 10.00.xcarchive/dSYMs/App.dSYM/data", bytes: 300_000)
        try write("Library/Developer/Xcode/Archives/2026-10-02/Tool 02-10-2026, 09.00.xcarchive/Info.plist", bytes: 10_000)

        let match = try only(.xcodeArchives, in: try await analyze())

        try assertItems(match, ["Library/Developer/Xcode/Archives/2026-09-01/App 01-09-2026, 10.00.xcarchive",
                                "Library/Developer/Xcode/Archives/2026-10-02/Tool 02-10-2026, 09.00.xcarchive"],
                        root: "Library/Developer/Xcode/Archives")
        XCTAssertEqual(match.risk, .review)
        XCTAssertEqual(match.cleanup, .trashEachItem)
    }

    func testNodeModulesIsStaleOnlyWhenItsProjectIsUntouchedForMoreThanThirtyDays() async throws {
        try project("dev/old", untouchedFor: 31)
        try project("dev/recent", untouchedFor: 29)
        // A file deep in the project counts, though it leaves the project folder's own time alone.
        try project("dev/edited", untouchedFor: 31)
        try touch("dev/edited/src/index.js", daysAgo: 2)
        // Outside project folders, in Library, and in hidden folders nothing is suggested.
        try project(".vscode/extensions/example.extension-1.0.0", untouchedFor: 90)
        try project("Library/Application Support/Editor/plugin", untouchedFor: 90)
        try write("dev/notaproject/node_modules/x/index.js", bytes: 4_096)
        try touchTree("dev/notaproject", daysAgo: 90)

        let match = try only(.staleNodeModules, in: try await analyze())

        try assertItems(match, ["dev/old/node_modules"], root: "dev/old")
        XCTAssertEqual(match.risk, .safe)
        XCTAssertEqual(match.cleanup, .trash)
    }

    func testNpmCacheIsTheCacacheFolder() async throws {
        try write(".npm/_cacache/content-v2/sha512/ab/cd/blob", bytes: 250_000)
        try write(".npm/_logs/debug.log", bytes: 4_096)

        let match = try only(.npmCache, in: try await analyze())

        try assertItems(match, [".npm/_cacache"], root: ".npm")
        XCTAssertEqual(match.cleanup, .command(["npm", "cache", "clean", "--force"]))
    }

    func testPnpmStoreIsEachDefaultStoreThatExists() async throws {
        try write("Library/pnpm/store/v10/files/00/abc", bytes: 200_000)
        try write(".pnpm-store/v3/files/00/def", bytes: 100_000)

        let match = try only(.pnpmStore, in: try await analyze())

        XCTAssertEqual(match.items.map(\.path), [path(".pnpm-store"), path("Library/pnpm/store")])
        try assertBytes(match)
        XCTAssertEqual(match.cleanup, .command(["pnpm", "store", "prune"]))
    }

    func testYarnCacheIsItsCachesFolderAndYarnsOrigin() async throws {
        try write("Library/Caches/Yarn/v6/npm-left-pad-1.3.0/package.tgz", bytes: 150_000)

        let analysis = try await analyze()
        let match = try only(.yarnCache, in: analysis)

        try assertItems(match, ["Library/Caches/Yarn"], root: "Library/Caches")
        XCTAssertEqual(match.cleanup, .command(["yarn", "cache", "clean"]))
        let entry = try XCTUnwrap(analysis.entries.first { $0.identifier == "Yarn" })
        XCTAssertEqual(entry.rule, .developerTool)
        XCTAssertEqual(entry.developerTool, "Yarn")
        XCTAssertNil(entry.risk, "a tool's cache folder is not a leftover")
    }

    func testHomebrewCacheIsItsCachesFolder() async throws {
        try write("Library/Caches/Homebrew/downloads/abc--wget-1.24.5.bottle.tar.gz", bytes: 350_000)

        let match = try only(.homebrewCache, in: try await analyze())

        try assertItems(match, ["Library/Caches/Homebrew"], root: "Library/Caches")
        XCTAssertEqual(match.cleanup, .command(["brew", "cleanup"]))
    }

    func testDockerImagesComeFromSystemDFAndAreUnavailableWithoutTheCLI() async throws {
        let recorded = DockerOutputTests.systemDF
        let space = try XCTUnwrap(DockerOutput.imageSpace(recorded))
        let reported = try only(.dockerImages, in: try await analyze(docker: .reported(space, observedAt: now)))
        XCTAssertEqual(reported.bytes, .dockerReclaimable(upTo: 2_064_000_000, total: 3_370_000_000))
        // Reclaimable counts every unused image, while the safe cleanup removes only dangling ones: an upper bound,
        // never the amount freed.
        XCTAssertNil(reported.bytes.bytes)
        XCTAssertEqual(reported.bytes.upperBound, 2_064_000_000)
        XCTAssertEqual(reported.risk, .safe)
        XCTAssertEqual(reported.cleanup, .command(["docker", "image", "prune", "-f"]))

        let missing = await DockerCLI(home: home, candidates: [home + "/no-docker"]).imageUsage()
        XCTAssertEqual(missing, .unavailable(.cliNotFound))
        let unavailable = try only(.dockerImages, in: try await analyze(docker: missing))
        XCTAssertEqual(unavailable.bytes, .unavailable(ContainerUnavailable.cliNotFound.reason))

        // Without a report the rule is left out.
        let notAsked = try await analyze()
        XCTAssertTrue(notAsked.matches.allSatisfy { $0.rule.id != .dockerImages })
    }

    func testCargoRegistryCacheMatchesItsContents() async throws {
        try write(".cargo/registry/cache/index.crates.io-1949cf8c6b5b557f/serde-1.0.210.crate", bytes: 80_000)
        try write(".cargo/registry/src/index.crates.io-1949cf8c6b5b557f/serde-1.0.210/lib.rs", bytes: 20_000)

        let match = try only(.cargoRegistryCache, in: try await analyze())

        try assertItems(match, [".cargo/registry/cache/index.crates.io-1949cf8c6b5b557f"], root: ".cargo/registry/cache")
    }

    func testGradleCachesMatchTheirContents() async throws {
        try write(".gradle/caches/modules-2/files-2.1/com.example/lib/1.0/lib.jar", bytes: 120_000)
        try write(".gradle/caches/8.10/transforms/abc/out.jar", bytes: 60_000)

        let match = try only(.gradleCaches, in: try await analyze())

        try assertItems(match, [".gradle/caches/8.10", ".gradle/caches/modules-2"], root: ".gradle/caches")
    }

    func testPipCacheMatchesItsContents() async throws {
        try write("Library/Caches/pip/http-v2/a/b/c/body", bytes: 90_000)
        try write("Library/Caches/pip/wheels/ab/cd/pkg-1.0-py3-none-any.whl", bytes: 30_000)

        let match = try only(.pipCache, in: try await analyze())

        try assertItems(match, ["Library/Caches/pip/http-v2", "Library/Caches/pip/wheels"], root: "Library/Caches/pip")
    }

    func testAppCachesAreGroupedPerInstalledApp() async throws {
        try write("Library/Caches/com.example.editor/Cache.db", bytes: 200_000)
        try write("Library/Caches/com.example.editor.ShipIt/update.zip", bytes: 100_000)
        try write("Library/Caches/com.apple.Safari/WebKitCache/blob", bytes: 50_000)
        try write("Library/Caches/com.apple.akd/cache", bytes: 10_000)
        try write("Library/Caches/com.removed.player/cache", bytes: 10_000)

        let analysis = try await analyze()
        let caches = analysis.matches.filter { $0.rule.id == .appCaches }

        XCTAssertEqual(caches.map(\.app?.path), ["/Applications/Editor.app", "/Applications/Safari.app"])
        try assertItems(caches[0], ["Library/Caches/com.example.editor", "Library/Caches/com.example.editor.ShipIt"],
                        root: "Library/Caches")
        try assertItems(caches[1], ["Library/Caches/com.apple.Safari"], root: "Library/Caches")
        XCTAssertEqual(caches[0].cleanup, .trashPerApp)
        XCTAssertEqual(caches[0].risk, .safe)
        // macOS's own cache is neither an app cache nor a leftover; a removed app's is a leftover.
        XCTAssertFalse(analysis.matches.contains { $0.items.contains { $0.path.hasSuffix("com.apple.akd") } })
        XCTAssertEqual(analysis.matches.filter { $0.rule.id == .appLeftovers }.map(\.identifier), ["com.removed.player"])
    }

    func testDeviceBackupsAreEachBackupForReview() async throws {
        try write("Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F70/Manifest.db", bytes: 400_000)
        try write("Library/Application Support/MobileSync/Backup/00008030-000A1B2C3D4E5F60/Manifest.db", bytes: 200_000)

        let match = try only(.deviceBackups, in: try await analyze())

        try assertItems(match, ["Library/Application Support/MobileSync/Backup/00008030-000A1B2C3D4E5F60",
                                "Library/Application Support/MobileSync/Backup/00008110-001A2B3C4D5E6F70"],
                        root: "Library/Application Support/MobileSync/Backup")
        XCTAssertEqual(match.risk, .review)
    }

    func testOldInstallersAreDiskImagesAndPackagesInDownloadsUntouchedForNinetyDays() async throws {
        try write("Downloads/Old App.dmg", bytes: 300_000)
        try touch("Downloads/Old App.dmg", daysAgo: 91)
        try write("Downloads/installers/Driver.PKG", bytes: 200_000)
        try touch("Downloads/installers/Driver.PKG", daysAgo: 200)
        try write("Downloads/New App.pkg", bytes: 100_000)
        try touch("Downloads/New App.pkg", daysAgo: 89)
        try write("Downloads/notes.txt", bytes: 4_096)
        try touch("Downloads/notes.txt", daysAgo: 400)
        // Modified long ago but added to Downloads today, as a download that keeps its server's time.
        try write("Downloads/Fresh Download.dmg", bytes: 100_000)
        try setTimes("Downloads/Fresh Download.dmg", modified: now.addingTimeInterval(-400 * 86_400), added: now)

        let match = try only(.oldInstallers, in: try await analyze())

        try assertItems(match, ["Downloads/Old App.dmg", "Downloads/installers/Driver.PKG"], root: "Downloads")
        XCTAssertEqual(match.risk, .review)
        XCTAssertEqual(match.cleanup, .trashEachItem)
    }

    func testLeftoversAreBundleIDsNoInstalledAppHas() async throws {
        // A fake bundle ID with no installed app, in several Library folders.
        try write("Library/Containers/com.removed.tool/Data/Library/data", bytes: 150_000)
        try write("Library/Preferences/com.removed.tool.plist", bytes: 4_096)
        try write("Library/HTTPStorages/com.removed.tool.binarycookies", bytes: 4_096)
        try write("Library/Group Containers/ZZZZZ99999.com.removed.tool/shared.db", bytes: 50_000)
        // The installed app's own data is not a leftover.
        try write("Library/Application Support/com.example.editor/state.db", bytes: 100_000)
        try write("Library/Preferences/com.example.editor.plist", bytes: 4_096)
        try write("Library/Group Containers/EXAMPLE123.com.example.shared/group.db", bytes: 4_096)
        try write("Library/Logs/com.apple.CloudTelemetry/log", bytes: 4_096)

        let analysis = try await analyze()
        let leftovers = analysis.matches.filter { $0.rule.id == .appLeftovers }

        XCTAssertEqual(leftovers.map(\.identifier), ["com.removed.tool"])
        let match = try XCTUnwrap(leftovers.first)
        XCTAssertEqual(match.items.map(\.path), [
            path("Library/Containers/com.removed.tool"),
            path("Library/Group Containers/ZZZZZ99999.com.removed.tool"),
            path("Library/HTTPStorages/com.removed.tool.binarycookies"),
            path("Library/Preferences/com.removed.tool.plist")
        ])
        XCTAssertEqual(match.items.map(\.root), [path("Library/Containers"), path("Library/Group Containers"),
                                                 path("Library/HTTPStorages"), path("Library/Preferences")])
        try assertBytes(match)
        XCTAssertEqual(match.risk, .review)
        XCTAssertEqual(analysis.entries.filter { $0.risk == .review }.map(\.identifier).sorted(),
                       Array(repeating: "com.removed.tool", count: 4))

        // With the app installed, the same entries are its data and nothing is left over.
        let installed = InstalledApps(Self.apps.apps + [InstalledApp(
            path: "/Applications/Tool.app", bundleID: "com.removed.tool", name: "Tool",
            signature: CodeSignature(signingID: "com.removed.tool", teamID: "ZZZZZ99999", isPlatformBinary: false))])
        let again = try await analyze(apps: installed)
        XCTAssertFalse(again.matches.contains { $0.rule.id == .appLeftovers })
        XCTAssertTrue(again.entries.filter { $0.identifier == "com.removed.tool" }.allSatisfy { $0.app?.path == "/Applications/Tool.app" })
    }

    func testTheTrashIsInformationOnly() async throws {
        try write(".Trash/Old Project/file", bytes: 200_000)

        let match = try only(.trash, in: try await analyze())

        try assertItems(match, [".Trash"], root: "")
        XCTAssertEqual(match.risk, .info)
        XCTAssertEqual(match.cleanup, .none)
    }

    // MARK: Boundaries

    func testAFolderThatCannotBeReadHasUnavailableBytes() async throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/data", bytes: 10_000)
        let folder = path("Library/Developer/Xcode/DerivedData")
        XCTAssertEqual(chmod(folder, 0), 0)
        defer { chmod(folder, 0o755) }

        let match = try only(.xcodeDerivedData, in: try await analyze())

        XCTAssertEqual(match.items, [])
        XCTAssertEqual(match.bytes, .unavailable("\(folder) could not be read."))
    }

    func testRuleFoldersTheScanDidNotReadInFullAreUnknownNotEmpty() async throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/data", bytes: 10_000)
        try write("Library/Developer/Xcode/DerivedData/Tool-def/data", bytes: 10_000)
        try write("Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist", bytes: 10_000)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 10_000)
        let scanned = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree
        let derivedData = "Library/Developer/Xcode/DerivedData"
        func match(_ id: ReclaimRuleID, _ tree: DiskTree) throws -> ReclaimMatch {
            try only(id, in: Analysis(tree: tree, entries: [], matches: ReclaimMatcher.matches(in: tree, origins: [], context: context())))
        }

        // A cancelled scan flags each folder it had queued but not read `partial`, with nothing listed.
        let queued = try match(.xcodeDerivedData, marking(scanned, derivedData, .partial, listing: false))
        XCTAssertEqual(queued.items, [])
        XCTAssertEqual(queued.bytes, .unavailable("\(path(derivedData)) was not read in full."))
        // Cancelled partway through the folder: what was listed counts, as a lower bound.
        let midway = try match(.xcodeDerivedData, marking(scanned, derivedData, .partial, listing: true))
        XCTAssertEqual(midway.items.count, 2)
        guard case .scanned(_, _, complete: false) = midway.bytes else { return XCTFail("\(midway.bytes)") }
        // A folder replaced before it was opened is `incomplete` and lists nothing.
        let replaced = try match(.xcodeDerivedData, marking(scanned, derivedData, .incomplete, listing: false))
        XCTAssertEqual(replaced.bytes, .unavailable("\(path(derivedData)) was not read."))
        // A folder above the rule's not read in full: every rule beneath is unknown, not absent.
        let developer = marking(scanned, "Library/Developer", .partial, listing: false)
        for id in [ReclaimRuleID.xcodeDerivedData, .xcodeDeviceSupport, .unavailableSimulators, .simulatorCaches, .xcodeArchives] {
            XCTAssertEqual(try match(id, developer).bytes, .unavailable("\(path("Library/Developer")) was not read in full."), "\(id)")
        }
        // Read in full, a missing rule folder is simply absent.
        let full = ReclaimMatcher.matches(in: scanned, origins: [], context: context())
        XCTAssertFalse(full.contains { $0.rule.id == .xcodeDeviceSupport || $0.rule.id == .simulatorCaches })
        // A tool's own folder cancelled: its sum is a lower bound.
        let brew = try match(.homebrewCache, marking(scanned, "Library/Caches/Homebrew/downloads", .partial, listing: false))
        guard case .scanned(_, _, complete: false) = brew.bytes else { return XCTFail("\(brew.bytes)") }
    }

    func testUnreadableFoldersARuleSearchesMakeItsSumIncomplete() async throws {
        try write("Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive/Info.plist", bytes: 10_000)
        try write("Library/Developer/Xcode/Archives/2026-10-01/Tool.xcarchive/Info.plist", bytes: 10_000)
        try write("Downloads/Old App.dmg", bytes: 10_000)
        try touch("Downloads/Old App.dmg", daysAgo: 120)
        try write("Downloads/locked/Other.dmg", bytes: 10_000)
        try touch("Downloads/locked/Other.dmg", daysAgo: 120)
        try project("dev/old", untouchedFor: 40)
        try write("dev/locked/app/package.json", bytes: 200)
        let locked = ["Library/Developer/Xcode/Archives/2026-10-01", "Downloads/locked", "dev/locked"].map(path)
        for folder in locked { XCTAssertEqual(chmod(folder, 0), 0) }
        defer { for folder in locked { chmod(folder, 0o755) } }

        let analysis = try await analyze()

        for (id, found) in [(ReclaimRuleID.xcodeArchives, "Library/Developer/Xcode/Archives/2026-09-01/App.xcarchive"),
                            (.oldInstallers, "Downloads/Old App.dmg"), (.staleNodeModules, "dev/old/node_modules")] {
            let match = try only(id, in: analysis)
            XCTAssertEqual(match.items.map(\.path), [path(found)], "\(id)")
            guard case .scanned(_, _, complete: false) = match.bytes else { return XCTFail("\(id): \(match.bytes)") }
        }

        // With nothing found, an unreadable folder still makes the rule unknown, not empty.
        try FileManager.default.removeItem(atPath: path("Downloads/Old App.dmg"))
        let unknown = try only(.oldInstallers, in: try await analyze())
        XCTAssertEqual(unknown.items, [])
        XCTAssertEqual(unknown.bytes, .unavailable("\(path("Downloads/locked")) could not be read."))
    }

    func testAScanOfAFolderInsideHomeFindsItsStaleNodeModules() async throws {
        try project("dev/old", untouchedFor: 40)

        let tree = try await DiskScanner().scan(URL(fileURLWithPath: path("dev"))).tree
        let matches = ReclaimMatcher.matches(in: tree, origins: [], context: context())

        XCTAssertEqual(matches.map(\.rule.id), [.staleNodeModules])
        XCTAssertEqual(matches.first?.items.map(\.path), [path("dev/old/node_modules")])
    }

    func testTheScanRecordsTheLaterOfModificationAndDateAdded() async throws {
        try write("a", bytes: 10)
        try setTimes("a", modified: Date(timeIntervalSince1970: 1_600_000_000), added: Date(timeIntervalSince1970: 1_700_000_000))
        try write("b", bytes: 10)
        try setTimes("b", modified: Date(timeIntervalSince1970: 1_750_000_000), added: Date(timeIntervalSince1970: 1_650_000_000))

        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree

        XCTAssertEqual(tree.item(at: "a")?.touched, Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(tree.item(at: "b")?.touched, Date(timeIntervalSince1970: 1_750_000_000))
    }

    // MARK: Helpers

    /// The tree with the folder at `relative` flagged as the scanner flags one it did not read in full (`partial` when
    /// cancelled, `incomplete` when replaced), its listing dropped when it was not read at all, and every folder above
    /// it `incomplete`, as the scanner's totals mark them.
    func marking(_ tree: DiskTree, _ relative: String, _ flags: DiskItemFlags, listing: Bool) -> DiskTree {
        var marked = tree
        guard let index = tree.index(atPath: path(relative)) else {
            XCTFail("no \(relative)")
            return tree
        }
        marked.nodes[index].flags.formUnion(flags.union(.incomplete))
        if !listing { marked.nodes[index].childCount = 0 }
        var parent = tree[index].parent
        while let above = parent {
            marked.nodes[above].flags.insert(.incomplete)
            parent = tree[above].parent
        }
        return marked
    }

    struct Analysis {
        let tree: DiskTree
        let entries: [DiskOriginEntry]
        let matches: [ReclaimMatch]
    }

    private func context(apps: InstalledApps = ReclaimRulesTests.apps, runtimes: SimulatorRuntimes = .installed([]),
                         docker: DockerImageUsage? = nil) -> ReclaimContext {
        ReclaimContext(home: home, now: now, installedApps: apps, simulatorRuntimes: runtimes, dockerImages: docker)
    }

    private func analyze(apps: InstalledApps = ReclaimRulesTests.apps, runtimes: SimulatorRuntimes = .installed([]),
                         docker: DockerImageUsage? = nil) async throws -> Analysis {
        let result = try await DiskScanner().scan(URL(fileURLWithPath: home))
        let entries = DiskOrigins.entries(in: result.tree, home: home, apps: apps)
        let matches = ReclaimMatcher.matches(in: result.tree, origins: entries,
                                             context: context(apps: apps, runtimes: runtimes, docker: docker))
        return Analysis(tree: result.tree, entries: entries, matches: matches)
    }

    private func only(_ id: ReclaimRuleID, in analysis: Analysis, file: StaticString = #filePath, line: UInt = #line) throws -> ReclaimMatch {
        let found = analysis.matches.filter { $0.rule.id == id }
        XCTAssertEqual(found.count, 1, "matches: \(analysis.matches.map(\.rule.id))", file: file, line: line)
        return try XCTUnwrap(found.first, file: file, line: line)
    }

    private func path(_ relative: String) -> String {
        relative.isEmpty ? home : home + "/" + relative
    }

    /// The items' paths and roots, and bytes equal to what the items allocate on disk.
    private func assertItems(_ match: ReclaimMatch, _ items: [String], root: String,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(match.items.map(\.path), items.map(path), file: file, line: line)
        XCTAssertEqual(Set(match.items.map(\.root)), [path(root)], file: file, line: line)
        try assertBytes(match, file: file, line: line)
    }

    /// The match's private and allocated bytes equal the blocks its items' files and folders hold, from `lstat`, and
    /// are complete. Fresh fixture files share no blocks, so all of them are private.
    private func assertBytes(_ match: ReclaimMatch, file: StaticString = #filePath, line: UInt = #line) throws {
        let expected = try match.items.reduce(UInt64(0)) { $0 + (try Self.allocated(under: $1.path)) }
        XCTAssertGreaterThan(expected, 0, file: file, line: line)
        XCTAssertEqual(match.bytes, .scanned(private: expected, allocated: expected, complete: true), file: file, line: line)
        XCTAssertEqual(match.bytes.bytes, expected, file: file, line: line)
    }

    static func allocated(under path: String) throws -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.ENOENT) }
        var total = UInt64(info.st_blocks) * 512
        guard info.st_mode & S_IFMT == S_IFDIR else { return total }
        for name in try FileManager.default.contentsOfDirectory(atPath: path) {
            total += try allocated(under: path + "/" + name)
        }
        return total
    }

    private func write(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: path(relative))
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Random bytes, so APFS cannot compress them.
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
    }

    private func device(_ relative: String, runtime: String, bytes: Int) throws {
        try write(relative + "/data/disk", bytes: bytes)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["runtime": runtime, "UDID": "x"], format: .xml, options: 0)
        try plist.write(to: URL(fileURLWithPath: path(relative + "/device.plist")))
    }

    /// A project folder with `package.json`, a source file, and `node_modules`, everything but `node_modules` last
    /// touched `days` ago; `node_modules` itself was touched just now.
    private func project(_ relative: String, untouchedFor days: Double) throws {
        try write(relative + "/package.json", bytes: 200)
        try write(relative + "/src/index.js", bytes: 2_000)
        try write(relative + "/node_modules/left-pad/index.js", bytes: 8_000)
        try write(relative + "/node_modules/left-pad/node_modules/inner/index.js", bytes: 4_096)
        try touchTree(relative, daysAgo: days, skipping: "node_modules")
    }

    private func touch(_ relative: String, daysAgo days: Double) throws {
        let date = now.addingTimeInterval(-days * 86_400)
        try setTimes(relative, modified: date, added: date)
    }

    /// Sets the times of a folder and everything in it, deepest first so that no change touches a folder again.
    private func touchTree(_ relative: String, daysAgo days: Double, skipping skipped: String? = nil) throws {
        let root = path(relative)
        let items = (FileManager.default.subpaths(atPath: root) ?? [])
            .filter { subpath in skipped.map { !subpath.split(separator: "/").contains(Substring($0)) } ?? true }
            .sorted { $0.split(separator: "/").count > $1.split(separator: "/").count }
        for item in items { try touch(relative + "/" + item, daysAgo: days) }
        try touch(relative, daysAgo: days)
    }

    /// Sets the modification time and the date added, as `setattrlist` allows.
    private func setTimes(_ relative: String, modified: Date, added: Date) throws {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = attrgroup_t(ATTR_CMN_MODTIME | ATTR_CMN_ADDEDTIME)
        var times = (timespec(tv_sec: Int(modified.timeIntervalSince1970), tv_nsec: 0),
                     timespec(tv_sec: Int(added.timeIntervalSince1970), tv_nsec: 0))
        let status = setattrlist(path(relative), &list, &times, MemoryLayout.size(ofValue: times), UInt32(FSOPT_NOFOLLOW))
        if status != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
