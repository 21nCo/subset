import Foundation
import SubsetCore
import XCTest

/// The bundle ID is declared in four places that must agree: SubsetIdentity, macos-release.json (read by the release
/// script, the catalog feed and `subset`), the generated Xcode project, and Info.plist (which takes it from the
/// project). The app's no-Dock-icon and macOS 14 decisions live in Info.plist and the project.
final class SubsetIdentityTests: XCTestCase {
    private let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../..").standardized

    private func text(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testReleaseConfigNamesTheAppAndItsBundleID() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("macos-release.json"))
        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(manifest["bundleId"] as? String, SubsetIdentity.bundleID)
        XCTAssertEqual(manifest["app"] as? String, SubsetIdentity.appName)
        XCTAssertEqual(manifest["project"] as? String, "Subset.xcodeproj")
        XCTAssertEqual(manifest["scheme"] as? String, "Subset")
    }

    func testXcodeProjectBuildsTheAppWithItsBundleIDAndVersion() throws {
        let project = try text("Subset.xcodeproj/project.pbxproj")
        let ids = Set(project.matches(of: /PRODUCT_BUNDLE_IDENTIFIER = "?([^";]+)"?;/).map { String($0.1) })
        XCTAssertTrue(ids.contains(SubsetIdentity.bundleID), "\(ids)")
        XCTAssertEqual(Set(project.matches(of: /MARKETING_VERSION = "?([^";]+)"?;/).map { String($0.1) }), ["0.1.0"])
        XCTAssertEqual(Set(project.matches(of: /MACOSX_DEPLOYMENT_TARGET = "?([^";]+)"?;/).map { String($0.1) }), ["14.0"])
    }

    func testInfoPlistHidesTheDockIconAndTakesItsIdentityFromTheProject() throws {
        let data = try Data(contentsOf: root.appendingPathComponent("MacApp/Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertEqual(plist["CFBundleIdentifier"] as? String, "$(PRODUCT_BUNDLE_IDENTIFIER)")
        XCTAssertEqual(plist["CFBundleShortVersionString"] as? String, "$(MARKETING_VERSION)")
        XCTAssertEqual(plist["LSMinimumSystemVersion"] as? String, "$(MACOSX_DEPLOYMENT_TARGET)")
        XCTAssertEqual(plist["CFBundleName"] as? String, SubsetIdentity.appName)
    }
}
