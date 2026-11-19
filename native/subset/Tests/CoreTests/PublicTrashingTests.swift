import Foundation
import SubsetCore
import XCTest

/// A Trash adapter written outside SubsetCore, with its public API only (no @testable import), can say where a copy went
/// and why it kept its hidden name.
struct OutsideTrash: Trashing {
    var renameFailure: String?

    func trash(_ bundle: URL, appName _: String, at _: Date) throws -> Trashed {
        let url = URL(fileURLWithPath: "/tmp/Trash").appendingPathComponent(bundle.lastPathComponent)
        guard let renameFailure else { return Trashed(url: url) }
        return Trashed(url: url, renameFailure: renameFailure)
    }
}

final class PublicTrashingTests: XCTestCase {
    func testATrashAdapterOutsideTheModuleBuildsItsResults() throws {
        let bundle = URL(fileURLWithPath: "/Applications/.Breaks.app.subset-trash-1-0123456789ab")
        let plain = try OutsideTrash().trash(bundle, appName: "Breaks", at: Date())
        XCTAssertEqual(plain.url.lastPathComponent, bundle.lastPathComponent)
        XCTAssertNil(plain.renameFailure)
        XCTAssertEqual(try OutsideTrash(renameFailure: "name taken").trash(bundle, appName: "Breaks", at: Date()).renameFailure, "name taken")
    }
}
