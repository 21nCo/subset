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
        let report = DiskOrigins.report(entries: entries, matches: matches, tree: tree, apps: Self.apps)

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
            return CodeSignature(signingID: "x", teamID: "EXAMPLE123", isPlatformBinary: false)
        }

        XCTAssertEqual(apps.apps.map(\.bundleID).sorted(), ["com.example.agent", "com.example.editor", "com.example.launcher", "com.example.tool"])
        XCTAssertEqual(apps.app(bundleID: "com.example.launcher")?.path, applications + "/Editor.app", "a login item belongs to its app")
        XCTAssertEqual(apps.app(bundleID: "com.example.agent")?.name, "Editor")
        XCTAssertEqual(apps.app(named: "Example Editor")?.path, applications + "/Editor.app")
        XCTAssertEqual(apps.app(named: "Tool")?.path, applications + "/Utilities/Tool.app")
        XCTAssertEqual(Set(signed), [applications + "/Editor.app", applications + "/Utilities/Tool.app"],
                       "each outer app's signature is read once; nested apps share it")
        XCTAssertEqual(signed.count, 2)
    }

    // MARK: Live

    func testThisMacsAppleAppsAreReadWithTheirPlatformSignature() throws {
        let apps = InstalledApps.read(folders: ["/System/Applications"])
        let apple = apps.apps.filter { $0.bundleID.hasPrefix("com.apple.") }
        XCTAssertFalse(apple.isEmpty, "/System/Applications holds Apple's apps")
        XCTAssertTrue(apple.contains { $0.vendor == .apple }, "\(apple.map { ($0.bundleID, $0.vendor) })")
        XCTAssertFalse(apple.contains { $0.vendor == .unsigned }, "Apple's apps are signed")
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
