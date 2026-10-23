import Foundation
import XCTest

/// HopCore stays pure Swift so its logic is testable without a window server: the host owns AppKit, SwiftUI, and
/// the Accessibility APIs.
final class CoreBoundaryTests: XCTestCase {
    func testCoreSourcesImportNoUIOrAccessibilityFramework() throws {
        let core = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core")
        let sources = try FileManager.default.contentsOfDirectory(at: core, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty, "found no sources in \(core.path)")
        let forbidden = try NSRegularExpression(
            pattern: #"^\s*(@\w+\s+)*import\s+(\w+\s+)?(AppKit|Cocoa|SwiftUI|ApplicationServices)\b"#,
            options: .anchorsMatchLines
        )
        for source in sources {
            let text = try String(contentsOf: source, encoding: .utf8)
            let range = NSRange(text.startIndex..., in: text)
            XCTAssertNil(forbidden.firstMatch(in: text, range: range), "\(source.lastPathComponent) imports a host framework")
        }
    }

    /// The Debug and Release builds have different bundle IDs, so app and core code reads Hop's identity from the
    /// running bundle (`HopIdentity`) or a build setting. Any mention of the release ID there fails, comments
    /// included, so no literal slips through a string this check would have to parse.
    func testAppAndCoreNeverNameTheReleaseBundleIdentifier() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let scan = try Self.releaseIdentifierMentions(
            under: ["Core", "MacApp"].map { root.appendingPathComponent($0) }, relativeTo: root
        )
        XCTAssertEqual(scan.offenders, [], "these sources name \(Self.releaseIdentifier)")
        XCTAssertGreaterThan(scan.checked, 10, "found too few sources under \(root.path)")
    }

    /// The check reads only Hop's text sources, so a stray Finder `.DS_Store` or other binary in a checkout cannot
    /// error it, and it still catches the literal in a nested source.
    func testReleaseIdentifierScanSkipsHiddenAndBinaryFilesButCatchesNestedSources() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let binary = Data([0x00, 0x00, 0x00, 0x01, 0x42, 0x75, 0x64, 0x31, 0xFF, 0xFE, 0x80])
        XCTAssertNil(String(data: binary, encoding: .utf8), "the probe must not be valid UTF-8")
        try binary.write(to: root.appendingPathComponent(".DS_Store"))
        try binary.write(to: root.appendingPathComponent("Icon.png"))
        try Data("let id = \"\(Self.releaseIdentifier)\"".utf8).write(to: root.appendingPathComponent(".Hidden.swift"))
        try Data("let id = Bundle.main.bundleIdentifier".utf8).write(to: root.appendingPathComponent("Clean.swift"))
        try Data("let id = \"\(Self.releaseIdentifier)\"".utf8).write(to: root.appendingPathComponent("Named.swift"))
        try Data("<string>\(Self.releaseIdentifier)</string>".utf8).write(to: nested.appendingPathComponent("Info.plist"))
        try Data("<key>\(Self.releaseIdentifier).group</key>".utf8).write(to: nested.appendingPathComponent("App.entitlements"))

        let scan = try Self.releaseIdentifierMentions(under: [root], relativeTo: root)

        XCTAssertEqual(scan.checked, 4)
        XCTAssertEqual(scan.offenders, ["Named.swift", "Nested/App.entitlements", "Nested/Info.plist"])
    }

    private static let releaseIdentifier = ["dev", "subset", "hop"].joined(separator: ".")
    private static let sourceExtensions: Set<String> = ["swift", "plist", "entitlements"]

    /// Scans the Swift, property-list and entitlements sources under `folders`, recursively and skipping hidden
    /// files, and returns how many it read and the root-relative paths of those naming the release identifier.
    private static func releaseIdentifierMentions(
        under folders: [URL], relativeTo root: URL
    ) throws -> (checked: Int, offenders: [String]) {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        var checked = 0
        var offenders: [String] = []
        for folder in folders {
            guard let files = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]
            ) else {
                throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: folder.path])
            }
            for case let file as URL in files where sourceExtensions.contains(file.pathExtension) {
                guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
                let text = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                if text.contains(releaseIdentifier) {
                    let path = file.standardizedFileURL.resolvingSymlinksInPath().path
                    offenders.append(path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path)
                }
            }
        }
        return (checked, offenders.sorted())
    }
}
