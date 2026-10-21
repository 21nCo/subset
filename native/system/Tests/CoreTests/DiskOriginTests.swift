import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// Library entries attributed to injected apps by bundle ID, name, and Team ID, and grouped by app, vendor,
/// developer tool, and leftovers; plus this Mac's installed apps and simulator runtimes read live.
final class DiskOriginTests: XCTestCase {
    private var home: String!

    static let editor = ReclaimRulesTests.editor
    static let safari = ReclaimRulesTests.safari
    static let suiteWriter = InstalledApp(
        path: "/Applications/Suite/Writer.app", bundleID: "com.suite.writer", name: "Writer",
        signature: CodeSignature(signingID: "com.suite.writer", teamID: "SUITE00001", isPlatformBinary: false, teamName: "Suite Inc."))
    static let suiteSheets = InstalledApp(
        path: "/Applications/Suite/Sheets.app", bundleID: "com.suite.sheets", name: "Sheets",
        signature: CodeSignature(signingID: "com.suite.sheets", teamID: "SUITE00001", isPlatformBinary: false, teamName: "Suite Inc."))
    static let unsignedTool = InstalledApp(path: "/Applications/Hack.app", bundleID: "org.example.hack", name: "Hack",
                                           signature: CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false))
    static let apps = InstalledApps([editor, safari, suiteWriter, suiteSheets, unsignedTool])

    override func setUpWithError() throws {
        let base = NSTemporaryDirectory() + "DiskOriginTests-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: false)
        let real = try XCTUnwrap(realpath(base, nil))
        defer { free(real) }
        home = String(cString: real)
    }

    override func tearDownWithError() throws {
        if let home { try? FileManager.default.removeItem(atPath: home) }
    }

    func testEachLibraryEntryIsAttributedByBundleIDNameOrTeamID() async throws {
        let expected: [(String, DiskOriginRule, String?, Origin?, Origin?)] = [
            ("Application Support/com.example.editor", .bundleID, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Application Support/Example Editor", .appName, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Application Support/Google", .unattributed, nil, nil, nil),
            ("Caches/com.example.editor.ShipIt", .bundleID, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Caches/Homebrew", .developerTool, nil, nil, nil),
            ("Containers/0BA4F0CB-F15B-43A3-AEED-57CCD731680B", .unattributed, nil, nil, nil),
            ("Containers/com.apple.Safari", .bundleID, "/Applications/Safari.app", .app(bundlePath: "/Applications/Safari.app"), .apple),
            ("Containers/com.apple.mail", .appleIdentifier, nil, .macOS, .apple),
            ("Containers/org.example.hack", .bundleID, "/Applications/Hack.app", .app(bundlePath: "/Applications/Hack.app"), .unsigned),
            ("Group Containers/243LU875E5.groups.com.apple.podcasts", .appleIdentifier, nil, .macOS, .apple),
            ("Group Containers/EXAMPLE123.notes", .teamID, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Group Containers/NOSUCHTEAM.com.gone.app", .leftover, nil, nil, .vendor(teamID: "NOSUCHTEAM")),
            ("Group Containers/SUITE00001.com.suite.sheets.shared", .bundleID, "/Applications/Suite/Sheets.app", .app(bundlePath: "/Applications/Suite/Sheets.app"), .vendor(teamID: "SUITE00001")),
            ("Group Containers/SUITE00001.office", .teamID, nil, nil, .vendor(teamID: "SUITE00001")),
            ("Group Containers/group.com.example", .bundleID, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("HTTPStorages/com.example.editor.binarycookies", .bundleID, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Logs/DiagnosticReports", .unattributed, nil, nil, nil),
            ("Logs/Editor", .appName, "/Applications/Editor.app", .app(bundlePath: "/Applications/Editor.app"), .vendor(teamID: "EXAMPLE123")),
            ("Preferences/.GlobalPreferences.plist", .unattributed, nil, nil, nil),
            ("Preferences/com.gone.app.plist", .leftover, nil, nil, nil),
            ("Preferences/com.suite.writer.plist", .bundleID, "/Applications/Suite/Writer.app", .app(bundlePath: "/Applications/Suite/Writer.app"), .vendor(teamID: "SUITE00001"))
        ]
        for (relative, _, _, _, _) in expected { try write("Library/" + relative + "/data", bytes: 4_096) }

        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree
        let entries = DiskOrigins.entries(in: tree, home: home, apps: Self.apps)
            .sorted { $0.path < $1.path }

        XCTAssertEqual(entries.map(\.path), expected.map { home + "/Library/" + $0.0 }.sorted())
        for (entry, expectation) in zip(entries, expected.sorted { $0.0 < $1.0 }) {
            XCTAssertEqual(entry.rule, expectation.1, expectation.0)
            XCTAssertEqual(entry.app?.path, expectation.2, expectation.0)
            XCTAssertEqual(entry.appOrigin, expectation.3, expectation.0)
            XCTAssertEqual(entry.vendor, expectation.4, expectation.0)
            XCTAssertEqual(entry.risk, expectation.1 == .leftover ? .review : nil, expectation.0)
        }
        XCTAssertEqual(entries.first { $0.path.hasSuffix("com.gone.app.plist") }?.identifier, "com.gone.app")
        XCTAssertEqual(entries.first { $0.path.hasSuffix("NOSUCHTEAM.com.gone.app") }?.identifier, "com.gone.app")
        XCTAssertEqual(entries.first { $0.path.hasSuffix("Homebrew") }?.developerTool, "Homebrew")
    }

    func testGroupsSumEntriesByAppAndVendorAndMatchesByDeveloperTool() async throws {
        try write("Library/Application Support/com.example.editor/state.db", bytes: 300_000)
        try write("Library/Caches/com.example.editor/Cache.db", bytes: 100_000)
        try write("Library/Preferences/com.suite.writer.plist/data", bytes: 4_096)
        try write("Library/Preferences/com.suite.sheets.plist/data", bytes: 4_096)
        try write("Library/Containers/com.gone.app/Data/file", bytes: 50_000)
        try write("Library/Logs/DiagnosticReports/crash.ips", bytes: 8_000)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 70_000)
        try write("Library/Developer/Xcode/DerivedData/App-abc/data", bytes: 200_000)

        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree
        let entries = DiskOrigins.entries(in: tree, home: home, apps: Self.apps)
        let context = ReclaimContext(home: home, installedApps: Self.apps, simulatorRuntimes: .installed([]))
        let matches = ReclaimMatcher.matches(in: tree, origins: entries, context: context)
        let report = DiskOrigins.report(entries: entries, matches: matches, tree: tree, home: home, apps: Self.apps)

        func bytes(_ relative: String) throws -> UInt64 { try ReclaimRulesTests.allocated(under: home + "/" + relative) }
        let editor = try bytes("Library/Application Support/com.example.editor") + bytes("Library/Caches/com.example.editor")
        let suite = try bytes("Library/Preferences/com.suite.writer.plist") + bytes("Library/Preferences/com.suite.sheets.plist")

        XCTAssertEqual(report.apps.map(\.name), ["Editor", "Sheets", "Writer"])
        XCTAssertEqual(report.apps[0].id, .origin(.app(bundlePath: "/Applications/Editor.app")))
        XCTAssertEqual(report.apps[0].allocated, editor)
        XCTAssertEqual(report.apps[0].private, editor)
        XCTAssertFalse(report.apps[0].isLowerBound)
        XCTAssertEqual(report.vendors.map(\.name), ["Example Ltd", "Suite Inc."])
        XCTAssertEqual(report.vendors.map(\.allocated), [editor, suite])
        XCTAssertEqual(report.developerTools.map(\.name), ["Xcode", "Homebrew"])
        XCTAssertEqual(report.developerTools.map(\.allocated),
                       [try bytes("Library/Developer/Xcode/DerivedData/App-abc"), try bytes("Library/Caches/Homebrew")])
        XCTAssertEqual(report.leftovers?.items, [tree.index(atPath: home + "/Library/Containers/com.gone.app")!])
        XCTAssertEqual(report.leftovers?.allocated, try bytes("Library/Containers/com.gone.app"))
        XCTAssertEqual(report.unattributed?.items, [tree.index(atPath: home + "/Library/Logs/DiagnosticReports")!])
        XCTAssertEqual(report.unlistedFolders, [])
        XCTAssertFalse(report.developerTools.contains { $0.isLowerBound })
    }

    func testGroupsAreLowerBoundsWhenAMatchOrALibraryFolderIsIncomplete() async throws {
        try write("Library/Developer/Xcode/DerivedData/App-abc/data", bytes: 200_000)
        try write("Library/Developer/CoreSimulator/Caches/dyld/cache", bytes: 100_000)
        try write("Library/Caches/Homebrew/downloads/bottle.tar.gz", bytes: 70_000)
        try write("Library/Application Support/com.example.editor/state.db", bytes: 300_000)
        try write("Library/Containers/com.example.editor/Data/file", bytes: 4_096)
        let derivedData = home + "/Library/Developer/Xcode/DerivedData"
        let containers = home + "/Library/Containers"
        XCTAssertEqual(chmod(derivedData, 0), 0)
        XCTAssertEqual(chmod(containers, 0), 0)
        defer {
            chmod(derivedData, 0o755)
            chmod(containers, 0o755)
        }

        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree
        let entries = DiskOrigins.entries(in: tree, home: home, apps: Self.apps)
        let space = try XCTUnwrap(DockerOutput.imageSpace(DockerOutputTests.systemDF))
        let context = ReclaimContext(home: home, installedApps: Self.apps, simulatorRuntimes: .installed([]),
                                     dockerImages: .reported(space, observedAt: Date()))
        let matches = ReclaimMatcher.matches(in: tree, origins: entries, context: context)
        let report = DiskOrigins.report(entries: entries, matches: matches, tree: tree, home: home, apps: Self.apps)

        // DerivedData could not be read, so the Xcode group is at least the simulator caches.
        let xcode = try XCTUnwrap(report.developerTools.first { $0.name == "Xcode" })
        XCTAssertTrue(xcode.isLowerBound)
        XCTAssertEqual(xcode.allocated, try ReclaimRulesTests.allocated(under: home + "/Library/Developer/CoreSimulator/Caches/dyld"))
        XCTAssertFalse(try XCTUnwrap(report.developerTools.first { $0.name == "Homebrew" }).isLowerBound)
        // Docker's image space is inside its VM: no group, and no exact zero.
        XCTAssertTrue(matches.contains { $0.rule.id == .dockerImages })
        XCTAssertFalse(report.developerTools.contains { $0.name == "Docker" })
        // Containers could not be listed, so any app's or leftover's total may be missing entries there.
        XCTAssertEqual(report.unlistedFolders, ["\(containers) could not be read."])
        XCTAssertEqual(report.apps.map(\.name), ["Editor"])
        XCTAssertTrue(report.apps[0].isLowerBound)
        XCTAssertTrue(try XCTUnwrap(report.leftovers).isLowerBound)
    }

    func testInstalledAppsAreFoundBeforeAnyHeuristicMakesALeftover() async throws {
        // Editor's signature could not be read, so no team lists it; its bundle ID still does.
        let editor = InstalledApp(path: "/Applications/Editor.app", bundleID: "com.example.editor", name: "Editor", signature: nil)
        let shortcuts = InstalledApp(
            path: "/System/Applications/Shortcuts.app", bundleID: "com.apple.shortcuts", name: "Shortcuts",
            signature: CodeSignature(signingID: "com.apple.shortcuts", teamID: nil, isPlatformBinary: true),
            appGroups: ["group.com.apple.shortcuts", "group.is.workflow.my.app", "group.is.workflow.shortcuts"])
        let writer = InstalledApp(path: Self.suiteWriter.path, bundleID: Self.suiteWriter.bundleID, name: "Writer",
                                  signature: Self.suiteWriter.signature, appGroups: ["SUITE00001.office"])
        let sheets = InstalledApp(path: Self.suiteSheets.path, bundleID: Self.suiteSheets.bundleID, name: "Sheets",
                                  signature: Self.suiteSheets.signature, appGroups: ["SUITE00001.office", "group.suite.docs"])
        let signed = InstalledApps([Self.safari, shortcuts, writer, sheets])
        for relative in ["Group Containers/EXAMPLE123.com.example.editor", "Containers/COM.EXAMPLE.EDITOR",
                         "Group Containers/group.is.workflow.my.app", "Group Containers/group.is.workflow.shortcuts",
                         "Group Containers/group.suite.docs", "Group Containers/SUITE00001.office",
                         "Group Containers/group.org.example.gone.app", "Group Containers/NOSUCHTEAM.com.gone.app",
                         "Preferences/com.gone.app.plist"] {
            try write("Library/" + relative + "/data", bytes: 4_096)
        }
        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home)).tree
        func placed(_ apps: InstalledApps) -> [String: DiskOriginEntry] {
            Dictionary(uniqueKeysWithValues: DiskOrigins.entries(in: tree, home: home, apps: apps).map {
                (String($0.path.dropFirst(home.count + "/Library/".count)), $0)
            })
        }

        let withEditor = placed(InstalledApps(signed.apps + [editor]))
        for relative in ["Group Containers/EXAMPLE123.com.example.editor", "Containers/COM.EXAMPLE.EDITOR"] {
            let entry = try XCTUnwrap(withEditor[relative])
            XCTAssertEqual(entry.rule, .bundleID, relative)
            XCTAssertEqual(entry.app?.path, "/Applications/Editor.app", relative)
            XCTAssertEqual(entry.vendor, .signatureUnavailable, relative)
            XCTAssertNil(entry.risk, relative)
        }
        // With one signature unread, an app group no app declares may be that app's: not attributed, never a leftover.
        XCTAssertEqual(withEditor["Group Containers/group.org.example.gone.app"]?.rule, .unattributed)
        XCTAssertEqual(withEditor["Group Containers/NOSUCHTEAM.com.gone.app"]?.rule, .unattributed)
        XCTAssertEqual(withEditor["Preferences/com.gone.app.plist"]?.rule, .leftover, "outside Group Containers names say it all")

        let all = placed(signed)
        for relative in ["Group Containers/group.is.workflow.my.app", "Group Containers/group.is.workflow.shortcuts"] {
            let entry = try XCTUnwrap(all[relative])
            XCTAssertEqual(entry.rule, .appGroup, relative)
            XCTAssertEqual(entry.app?.path, "/System/Applications/Shortcuts.app", relative)
            XCTAssertEqual(entry.vendor, .apple, relative)
        }
        XCTAssertEqual(all["Group Containers/group.suite.docs"]?.app?.path, Self.suiteSheets.path)
        let shared = try XCTUnwrap(all["Group Containers/SUITE00001.office"])
        XCTAssertEqual(shared.rule, .appGroup)
        XCTAssertNil(shared.app, "two apps declare it")
        XCTAssertEqual(shared.vendor, .vendor(teamID: "SUITE00001"))
        // Every signature read: what no app has or declares is a leftover.
        for relative in ["Group Containers/group.org.example.gone.app", "Group Containers/NOSUCHTEAM.com.gone.app"] {
            XCTAssertEqual(all[relative]?.rule, .leftover, relative)
            XCTAssertEqual(all[relative]?.risk, .review, relative)
        }
    }

    func testAmbiguousNamesMatchNoAppAndTwoCopiesOfOneAppResolveTheSameWay() {
        let first = InstalledApp(path: "/Applications/Xcode.app", bundleID: "com.apple.dt.Xcode", name: "Xcode", signature: nil)
        let second = InstalledApp(path: "/Applications/Xcode-26.4.0.app", bundleID: "com.apple.dt.Xcode", name: "Xcode-26.4.0",
                                  names: ["Xcode-26.4.0", "Xcode"], signature: nil)
        let notes = InstalledApp(path: "/Applications/Notes Pro.app", bundleID: "com.a.notes", name: "Notes Pro", names: ["Notes Pro", "Notes"], signature: nil)
        let other = InstalledApp(path: "/Applications/Notes Lite.app", bundleID: "com.b.notes", name: "Notes Lite", names: ["Notes Lite", "Notes"], signature: nil)
        let apps = InstalledApps([first, second, notes, other])

        XCTAssertEqual(apps.app(bundleID: "COM.APPLE.DT.XCODE")?.path, "/Applications/Xcode-26.4.0.app")
        XCTAssertEqual(InstalledApps([second, first]).app(bundleID: "com.apple.dt.Xcode")?.path, "/Applications/Xcode-26.4.0.app")
        XCTAssertNil(apps.app(named: "Notes"), "two different apps are called Notes")
        XCTAssertNil(apps.app(named: "Xcode"), "two copies of Xcode are two bundles")
        XCTAssertEqual(apps.app(named: "notes pro")?.path, "/Applications/Notes Pro.app")
        XCTAssertEqual(apps.app(bundleID: "com.a.notes.widget")?.path, "/Applications/Notes Pro.app")
        XCTAssertNil(apps.app(bundleID: "com.a.notesx"), "only whole components extend a bundle ID")
        XCTAssertEqual(first.vendor, .signatureUnavailable, "an unread signature is never unsigned")
    }

    func testOnlyReverseDNSNamesAreBundleIDs() {
        for name in ["com.example.app", "at.studio.AsideUpdater", "app.keysmith.Keysmith-setapp", "net.whatsapp.WhatsApp", "io.foo_bar.baz"] {
            XCTAssertTrue(DiskOrigins.isBundleID(name), name)
        }
        for name in ["Google", "Adobe_CCXProcess.node", "com.example", "Creative Cloud Content Manager.node",
                     "0BA4F0CB-F15B-43A3-AEED-57CCD731680B", "JetBrains.Toolbox.data", "fsck_hfs.log", "com..app", ".com.example.app"] {
            XCTAssertFalse(DiskOrigins.isBundleID(name), name)
        }
    }

    func testAppsAreReadFromTheirInfoPlistsWithTheirLoginItemsAndHelpers() throws {
        let applications = home + "/Applications"
        try bundle(applications + "/Editor.app", id: "com.example.editor", name: "Example Editor")
        try bundle(applications + "/Editor.app/Contents/Library/LoginItems/Launcher.app", id: "com.example.launcher", name: "Launcher")
        try bundle(applications + "/Editor.app/Contents/Helpers/Agent.app", id: "com.example.agent", name: "Agent")
        try bundle(applications + "/Utilities/Tool.app", id: "com.example.tool", name: nil)
        try bundle(applications + "/Broken.app", id: nil, name: "Broken")
        try bundle(applications + "/Deep/Deeper/Hidden.app", id: "com.example.hidden", name: nil)
        var signed: [String] = []

        let apps = InstalledApps.read(folders: [applications, home + "/missing"]) { path in
            signed.append(path)
            let team = path.hasSuffix("/Editor.app") ? "EXAMPLE123" : "OTHERTEAM1"
            return AppSigning(signature: CodeSignature(signingID: "x", teamID: team, isPlatformBinary: false),
                              appGroups: ["group." + (path as NSString).lastPathComponent])
        }

        XCTAssertEqual(apps.apps.map(\.bundleID).sorted(), ["com.example.agent", "com.example.editor", "com.example.launcher", "com.example.tool"])
        XCTAssertEqual(apps.app(bundleID: "com.example.launcher")?.path, applications + "/Editor.app", "a login item belongs to its app")
        XCTAssertEqual(apps.app(bundleID: "com.example.agent")?.name, "Editor")
        XCTAssertEqual(apps.app(named: "Example Editor")?.path, applications + "/Editor.app")
        XCTAssertEqual(apps.app(named: "Tool")?.path, applications + "/Utilities/Tool.app")
        XCTAssertEqual(signed.sorted(), [applications + "/Editor.app", applications + "/Editor.app/Contents/Helpers/Agent.app",
                                         applications + "/Editor.app/Contents/Library/LoginItems/Launcher.app",
                                         applications + "/Utilities/Tool.app"])
        XCTAssertEqual(apps.app(bundleID: "com.example.agent")?.vendor, .vendor(teamID: "EXAMPLE123"), "a helper is its app's vendor's")
        XCTAssertEqual(apps.apps(group: "group.Agent.app").map(\.bundleID), ["com.example.agent"], "a helper declares its own groups")
        XCTAssertEqual(apps.unread, [applications + "/Broken.app has no readable bundle identifier."])
        XCTAssertFalse(apps.isComplete)
        XCTAssertFalse(apps.signingComplete)
    }

    func testWrappedAppsAreReadAndAnAppThatCannotBeReadMakesNoLeftover() async throws {
        let applications = home + "/Applications"
        let inner = applications + "/Extra.app/Wrapper/Extra.app"
        try FileManager.default.createDirectory(atPath: inner, withIntermediateDirectories: true)
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.buildforever.extra"], format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: inner + "/Info.plist"))
        try FileManager.default.createSymbolicLink(atPath: applications + "/Extra.app/WrappedBundle", withDestinationPath: "Wrapper/Extra.app")
        try bundle(applications + "/Editor.app", id: "com.example.editor", name: nil)
        for relative in ["Containers/com.buildforever.extra", "Group Containers/group.com.buildforever.shared",
                         "Caches/com.gone.app", "Preferences/com.gone.app.plist", "Group Containers/group.com.gone.app"] {
            try write("Library/" + relative + "/data", bytes: 4_096)
        }
        let tree = try await DiskScanner().scan(URL(fileURLWithPath: home + "/Library")).tree
        var signed: [String] = []
        func read(_ folders: [String]) -> InstalledApps {
            InstalledApps.read(folders: folders) { path in
                signed.append(path)
                return AppSigning(signature: CodeSignature(signingID: "x", teamID: "EXTRA00001", isPlatformBinary: false),
                                  appGroups: path.hasSuffix("Wrapper/Extra.app") ? ["group.com.buildforever.shared"] : [])
            }
        }
        func rules(_ apps: InstalledApps) -> [String: DiskOriginRule] {
            Dictionary(uniqueKeysWithValues: DiskOrigins.entries(in: tree, home: home, apps: apps).map {
                (String($0.path.dropFirst(home.count + "/Library/".count)), $0.rule)
            })
        }

        let complete = read([applications])
        XCTAssertEqual(complete.app(bundleID: "com.buildforever.extra")?.path, applications + "/Extra.app")
        XCTAssertTrue(signed.contains(inner), "a wrapped app is signed as its inner bundle")
        XCTAssertTrue(complete.signingComplete)
        XCTAssertEqual(rules(complete), [
            "Containers/com.buildforever.extra": .bundleID, "Group Containers/group.com.buildforever.shared": .appGroup,
            "Caches/com.gone.app": .leftover, "Preferences/com.gone.app.plist": .leftover, "Group Containers/group.com.gone.app": .leftover
        ])

        // An app whose Info.plist cannot be read or is missing, or a vendor folder that cannot be listed, may own any
        // entry: nothing is a leftover, though installed apps' data is still theirs.
        let locked = home + "/Locked"
        try bundle(locked + "/Unreadable.app", id: "com.example.unreadable", name: nil)
        XCTAssertEqual(chmod(locked + "/Unreadable.app/Contents/Info.plist", 0), 0)
        let missing = home + "/Missing"
        try FileManager.default.createDirectory(atPath: missing + "/Empty.app/Contents", withIntermediateDirectories: true)
        let vendor = home + "/Vendor"
        try bundle(vendor + "/Suite/Writer.app", id: "com.suite.writer", name: nil)
        XCTAssertEqual(chmod(vendor + "/Suite", 0), 0)
        defer { chmod(locked + "/Unreadable.app/Contents/Info.plist", 0o644); chmod(vendor + "/Suite", 0o755) }
        for (folder, reason) in [(locked, "/Unreadable.app has no readable bundle identifier."),
                                 (missing, "/Empty.app has no readable bundle identifier."),
                                 (vendor, "/Suite could not be listed: Permission denied.")] {
            let apps = read([applications, folder])
            XCTAssertEqual(apps.unread, [folder + reason])
            XCTAssertEqual(rules(apps), [
                "Containers/com.buildforever.extra": .bundleID, "Group Containers/group.com.buildforever.shared": .appGroup,
                "Caches/com.gone.app": .unattributed, "Preferences/com.gone.app.plist": .unattributed,
                "Group Containers/group.com.gone.app": .unattributed
            ], folder)
        }
    }

    func testAppGroupsAreReadFromEntitlements() {
        XCTAssertEqual(InstalledApps.appGroups(entitlements: nil), [], "no entitlements declare no groups")
        XCTAssertEqual(InstalledApps.appGroups(entitlements: ["com.apple.security.application-groups": ["group.a"],
                                                              "com.apple.private.security.restricted-application-groups": ["group.b"]]),
                       ["group.a", "group.b"])
        XCTAssertNil(InstalledApps.appGroups(entitlements: "not a dictionary"))
        XCTAssertNil(InstalledApps.appGroups(entitlements: ["com.apple.security.application-groups": [1]]))
        XCTAssertFalse(InstalledApps([InstalledApp(path: "/A.app", bundleID: "com.a.app", name: "A", signature: nil)]).signingComplete)
        XCTAssertFalse(InstalledApps([InstalledApp(path: "/A.app", bundleID: "com.a.app", name: "A", signature: Self.editor.signature,
                                                   appGroups: nil)]).signingComplete)
    }

    // MARK: Live

    func testThisMacsAppleAppsAreReadWithTheirPlatformSignature() throws {
        let apps = InstalledApps.read(folders: ["/System/Applications"])
        let apple = apps.apps.filter { $0.bundleID.hasPrefix("com.apple.") }
        XCTAssertFalse(apple.isEmpty, "/System/Applications holds Apple's apps")
        XCTAssertTrue(apple.contains { $0.vendor == .apple }, "\(apple.map { ($0.bundleID, $0.vendor) })")
        XCTAssertFalse(apple.contains { $0.vendor == .unsigned }, "Apple's apps are signed")
        // Shortcuts keeps the user's library in groups not named com.apple.
        XCTAssertEqual(apps.apps(group: "group.is.workflow.my.app").map(\.bundleID), ["com.apple.shortcuts"])
    }

    func testThisMacsSimulatorRuntimeListIsRead() {
        if case let .unknown(reason) = SimulatorRuntimes.read() { XCTFail(reason) }
    }

    func testSimulatorRuntimesComeFromTheImageListAndRuntimeBundles() throws {
        let images = home + "/images.plist"
        let plist: [String: Any] = ["images": [["runtimeInfo": ["bundleIdentifier": "com.apple.CoreSimulator.SimRuntime.iOS-18-3"]],
                                               ["state": 1]]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: URL(fileURLWithPath: images))
        try bundle(home + "/Runtimes/watchOS 11.0.simruntime", id: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", name: nil)
        try bundle(home + "/Volumes/tvOS_22J/Library/Developer/CoreSimulator/Profiles/Runtimes/tvOS 18.0.simruntime",
                   id: "com.apple.CoreSimulator.SimRuntime.tvOS-18-0", name: nil)

        XCTAssertEqual(SimulatorRuntimes.read(imagesPlist: images, runtimesFolder: home + "/Runtimes", volumesFolder: home + "/Volumes"),
                       .installed(["com.apple.CoreSimulator.SimRuntime.iOS-18-3", "com.apple.CoreSimulator.SimRuntime.watchOS-11-0",
                                   "com.apple.CoreSimulator.SimRuntime.tvOS-18-0"]))
        XCTAssertEqual(SimulatorRuntimes.read(imagesPlist: home + "/none.plist", runtimesFolder: home + "/none", volumesFolder: home + "/none"),
                       .installed([]), "no list and no bundles: nothing is installed")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: images))
        guard case .unknown = SimulatorRuntimes.read(imagesPlist: images, runtimesFolder: home + "/Runtimes", volumesFolder: home + "/Volumes")
        else { return XCTFail("an unreadable image list is unknown, not empty") }
    }

    func testARuntimeSourceThatCannotBeReadMakesTheListUnknown() throws {
        let none = home + "/none"
        try bundle(home + "/Runtimes/iOS 18.3.simruntime", id: "com.apple.CoreSimulator.SimRuntime.iOS-18-3", name: nil)
        func read(runtimes: String = home + "/Runtimes", volumes: String = none) -> SimulatorRuntimes {
            SimulatorRuntimes.read(imagesPlist: none + ".plist", runtimesFolder: runtimes, volumesFolder: volumes)
        }
        XCTAssertEqual(read(), .installed(["com.apple.CoreSimulator.SimRuntime.iOS-18-3"]))

        // A runtime bundle whose Info.plist is malformed, missing, or names no runtime.
        let broken = home + "/Runtimes/watchOS 11.0.simruntime/Contents"
        try FileManager.default.createDirectory(atPath: broken, withIntermediateDirectories: true)
        XCTAssertEqual(read(), .unknown("\(broken)/Info.plist could not be read: not found."))
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: broken + "/Info.plist"))
        XCTAssertEqual(read(), .unknown("\(broken)/Info.plist could not be read: not a property list dictionary."))
        try bundle(home + "/Runtimes/watchOS 11.0.simruntime", id: nil, name: "watchOS")
        XCTAssertEqual(read(), .unknown("\(broken)/Info.plist has no bundle identifier."))
        try FileManager.default.removeItem(atPath: home + "/Runtimes/watchOS 11.0.simruntime")

        // A runtimes or volumes folder that exists but cannot be listed.
        for folder in [home + "/Runtimes", home + "/Volumes"] {
            try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            XCTAssertEqual(chmod(folder, 0), 0)
            defer { chmod(folder, 0o755) }
            guard case let .unknown(reason) = read(volumes: home + "/Volumes") else { return XCTFail("\(folder) is unreadable") }
            XCTAssertTrue(reason.hasPrefix("\(folder) could not be read"), reason)
        }
        // A file where a folder would be is no runtime.
        try Data().write(to: URL(fileURLWithPath: home + "/Volumes/stray"))
        XCTAssertEqual(read(volumes: home + "/Volumes"), .installed(["com.apple.CoreSimulator.SimRuntime.iOS-18-3"]))
    }

    // MARK: Helpers

    private func write(_ relative: String, bytes: Int) throws {
        let url = URL(fileURLWithPath: home + "/" + relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var data = Data(count: bytes)
        data.withUnsafeMutableBytes { arc4random_buf($0.baseAddress!, bytes) }
        try data.write(to: url)
    }

    private func bundle(_ path: String, id: String?, name: String?) throws {
        try FileManager.default.createDirectory(atPath: path + "/Contents", withIntermediateDirectories: true)
        var info: [String: Any] = [:]
        if let id { info["CFBundleIdentifier"] = id }
        if let name { info["CFBundleName"] = name }
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: URL(fileURLWithPath: path + "/Contents/Info.plist"))
    }
}
