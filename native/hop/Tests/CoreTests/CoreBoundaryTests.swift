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
        let releaseIdentifier = ["dev", "subset", "hop"].joined(separator: ".")
        var checked = 0
        for folder in ["Core", "MacApp"] {
            let files = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil
            )
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                checked += 1
                XCTAssertFalse(text.contains(releaseIdentifier), "\(folder)/\(file.lastPathComponent) names \(releaseIdentifier)")
            }
        }
        XCTAssertGreaterThan(checked, 10, "found too few sources under \(root.path)")
    }
}
