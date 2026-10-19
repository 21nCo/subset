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
}
