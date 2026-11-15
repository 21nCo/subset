import Foundation
@testable import SubsetCore
import XCTest

/// Detection in temporary folders standing in for /Applications and ~/Applications (/Users/alex/Applications).
final class InstalledAppsTests: XCTestCase {
    private var root: URL!
    private var finder: InstalledAppFinder!

    static let breaks = CatalogApp(
        id: "breaks", name: "Breaks", summary: "Screen breaks.", appName: "Breaks", bundleID: "dev.subset.breaks",
        live: LiveRelease(version: "0.1.0", url: "", sha256: "", releaseURL: ""), beta: nil
    )

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("subset-installed-\(UUID().uuidString)")
        for folder in ["system", "user", "receipts"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        finder = InstalledAppFinder(
            folders: [
                ApplicationsFolder(label: "/Applications", path: "/Applications", directory: root.appendingPathComponent("system")),
                ApplicationsFolder(
                    label: "~/Applications", path: "/Users/alex/Applications", directory: root.appendingPathComponent("user")
                )
            ],
            receipts: root.appendingPathComponent("receipts")
        )
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    @discardableResult
    private func makeApp(_ folder: String, _ name: String, bundleID: String, version: String = "0.1.0", build: String = "1") throws -> URL {
        let bundle = root.appendingPathComponent(folder).appendingPathComponent("\(name).app")
        let contents = bundle.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": bundleID, "CFBundleShortVersionString": version, "CFBundleVersion": build]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .binary, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        return bundle
    }

    private func writeReceipt(_ fields: [String: Any], bundleID: String = "dev.subset.breaks") throws {
        var receipt: [String: Any] = [
            "schema": "subset.receipt@1", "sha256": String(repeating: "a", count: 64), "installedAt": "2026-11-12T09:30:00Z"
        ]
        receipt.merge(fields) { _, new in new }
        let data = try JSONSerialization.data(withJSONObject: receipt)
        try data.write(to: root.appendingPathComponent("receipts/\(bundleID).json"))
    }

    func testAMatchingBundleIDIsFoundInEitherFolderWithItsVersion() throws {
        let system = try makeApp("system", "Breaks", bundleID: "dev.subset.breaks", version: "0.1.0", build: "7")
        let user = try makeApp("user", "Breaks", bundleID: "dev.subset.breaks", version: "0.0.9", build: "3")
        XCTAssertEqual(finder.copies(of: Self.breaks), [
            InstalledCopy(path: system.path, folder: "/Applications", version: "0.1.0", build: "7", channel: nil),
            InstalledCopy(path: user.path, folder: "~/Applications", version: "0.0.9", build: "3", channel: nil)
        ])
    }

    func testAMismatchedBundleIDIsIgnored() throws {
        try makeApp("system", "Breaks", bundleID: "com.example.breaks")
        XCTAssertEqual(finder.copies(of: Self.breaks), [])
    }

    func testAppsOutsideTheTopLevelUnderAnotherNameOrBehindALinkAreNotFound() throws {
        try makeApp("system/Subset", "Breaks", bundleID: "dev.subset.breaks")
        try makeApp("system", "Breaks 2", bundleID: "dev.subset.breaks")
        let elsewhere = try makeApp("receipts", "Breaks", bundleID: "dev.subset.breaks")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("user/Breaks.app"), withDestinationURL: elsewhere)
        XCTAssertEqual(finder.copies(of: Self.breaks), [])
    }

    func testAnInfoPlistBehindALinkIsNotRead() throws {
        let bundle = try makeApp("system", "Breaks", bundleID: "dev.subset.breaks")
        let plist = bundle.appendingPathComponent("Contents/Info.plist")
        let elsewhere = root.appendingPathComponent("Info.plist")
        try FileManager.default.moveItem(at: plist, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: plist, withDestinationURL: elsewhere)
        XCTAssertEqual(finder.copies(of: Self.breaks), [])
    }

    func testAReceiptThatDescribesTheCopyGivesItsChannel() throws {
        try makeApp("user", "Breaks", bundleID: "dev.subset.breaks", version: "0.1.1", build: "4")
        try writeReceipt(["channel": "beta", "version": "0.1.1", "build": 4, "path": "/Users/alex/Applications/Breaks.app"])
        let copy = try XCTUnwrap(finder.copies(of: Self.breaks).first)
        XCTAssertEqual(copy.channel, .beta)
        XCTAssertEqual(copy.versionLabel, "0.1.1-beta.4")
    }

    func testControlCharactersInTheVersionAreNotShownButAreKeptForComparisons() {
        let replaced = "\u{FFFD}"
        let cases: [(String, String)] = [
            ("1.0\n2", "1.0\(replaced)2"), ("1.0\r", "1.0\(replaced)"), ("\u{0}1.0", "\(replaced)1.0"),
            ("1.0\t\u{1B}[31m", "1.0\(replaced)\(replaced)[31m"), ("1.0\u{7F}", "1.0\(replaced)"),
            ("1.0\u{85}", "1.0\(replaced)"), ("1.0\u{9F}", "1.0\(replaced)"),
            ("1.0\u{2028}x", "1.0\(replaced)x"), ("1.0\u{2029}x", "1.0\(replaced)x"),
            // Not controls: these are shown as they are.
            ("1.0 é", "1.0 é"), ("1.0\u{A0}", "1.0\u{A0}"), ("1.0\u{2027}", "1.0\u{2027}"), ("1.0\u{202A}", "1.0\u{202A}")
        ]
        for (version, shown) in cases {
            let copy = InstalledCopy(path: "/Applications/Breaks.app", folder: "/Applications", version: version, build: "1", channel: .live)
            XCTAssertEqual(copy.versionLabel, shown, version.debugDescription)
            XCTAssertEqual(copy.version, version, "the raw version is kept")
        }
        let beta = InstalledCopy(path: "/Applications/Breaks.app", folder: "/Applications", version: "0.1.1", build: "4\n5", channel: .beta)
        XCTAssertEqual(beta.versionLabel, "0.1.1-beta.4\(replaced)5")
        XCTAssertEqual(beta.build, "4\n5")
        XCTAssertEqual(InstalledCopy(path: "", folder: "", version: nil, build: nil, channel: nil).versionLabel, "unknown version")
    }

    func testAReceiptForAnotherCopyOrAnInvalidOneIsNotUsed() throws {
        try makeApp("system", "Breaks", bundleID: "dev.subset.breaks", version: "0.1.1", build: "4")
        // Another folder, another version, another build, and an invalid receipt (a live one with a build).
        let receipts: [[String: Any]] = [
            ["channel": "live", "version": "0.1.1", "path": "/Users/alex/Applications/Breaks.app"],
            ["channel": "live", "version": "0.1.0", "path": "/Applications/Breaks.app"],
            ["channel": "beta", "version": "0.1.1", "build": 5, "path": "/Applications/Breaks.app"],
            ["channel": "live", "version": "0.1.1", "build": 4, "path": "/Applications/Breaks.app"]
        ]
        for receipt in receipts {
            try writeReceipt(receipt)
            XCTAssertNil(finder.copies(of: Self.breaks).first?.channel, "\(receipt)")
        }
        try writeReceipt(["channel": "live", "version": "0.1.1", "path": "/Applications/Breaks.app"])
        XCTAssertEqual(finder.copies(of: Self.breaks).first?.channel, .live)
    }

    func testTheStandardFoldersAreTheTopLevelApplicationsFolders() {
        let finder = InstalledAppFinder.standard(home: URL(fileURLWithPath: "/Users/alex", isDirectory: true))
        XCTAssertEqual(finder.folders.map(\.path), ["/Applications", "/Users/alex/Applications"])
        XCTAssertEqual(finder.folders.map(\.label), ["/Applications", "~/Applications"])
        XCTAssertEqual(finder.receipts.path, "/Users/alex/Library/Application Support/Subset/receipts")
    }
}
