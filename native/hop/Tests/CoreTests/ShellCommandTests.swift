import Foundation
import HopCore
import XCTest

final class ShellCommandTests: XCTestCase {
    private let appName = HopIdentity.appName

    func testStatusMenuOffersSettingsAboutAndQuitInOrder() {
        XCTAssertEqual(ShellCommand.statusMenu(trusted: true).map(\.title), ["Settings…", "About \(appName)", "Quit \(appName)"])
    }

    func testStatusMenuLeadsWithAccessibilityWhileUntrusted() {
        XCTAssertEqual(
            ShellCommand.statusMenu(trusted: false).map(\.title),
            ["Allow Accessibility Access…", "Settings…", "About \(appName)", "Quit \(appName)"]
        )
    }

    func testSettingsAndQuitUseTheStandardKeyEquivalents() {
        XCTAssertEqual(ShellCommand.settings.keyEquivalent, ",")
        XCTAssertEqual(ShellCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(ShellCommand.about.keyEquivalent, "")
    }

    func testGroupsAreSeparated() {
        XCTAssertEqual(ShellCommand.allCases.filter(\.startsGroup), [.settings, .about, .quit])
        XCTAssertEqual(ShellCommand.grantAccessibility.keyEquivalent, "")
    }

    func testIdentityIsTheRunningBundles() {
        XCTAssertEqual(HopIdentity.bundleIdentifier, Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
        XCTAssertEqual(
            HopIdentity.current,
            HopIdentity(infoDictionary: Bundle.main.infoDictionary, processName: ProcessInfo.processInfo.processName)
        )
    }

    /// The Info.plist values ProjectGenerator.rb gives the Debug and Release builds (Tests/app-identity.sh checks the
    /// build settings themselves).
    func testDebugAndReleaseBundlesAreDifferentApps() {
        let debug = HopIdentity(
            infoDictionary: ["CFBundleIdentifier": "dev.subset.hop.debug", "CFBundleDisplayName": "Hop Debug", "CFBundleName": "Hop Debug"],
            processName: "Hop"
        )
        let release = HopIdentity(
            infoDictionary: ["CFBundleIdentifier": "dev.subset.hop", "CFBundleDisplayName": "Hop", "CFBundleName": "Hop"],
            processName: "Hop"
        )
        XCTAssertEqual(debug.bundleIdentifier, "dev.subset.hop.debug")
        XCTAssertEqual(debug.appName, "Hop Debug")
        XCTAssertEqual(release.bundleIdentifier, "dev.subset.hop")
        XCTAssertEqual(release.appName, "Hop")
        XCTAssertNotEqual(debug, release)
    }

    func testAnUnbundledProcessIsIdentifiedByItsProcessName() {
        XCTAssertEqual(HopIdentity(infoDictionary: nil, processName: "Hop"), HopIdentity(infoDictionary: [:], processName: "Hop"))
        let unbundled = HopIdentity(infoDictionary: ["CFBundleIdentifier": "", "CFBundleName": ""], processName: "Hop")
        XCTAssertEqual(unbundled.bundleIdentifier, "Hop")
        XCTAssertEqual(unbundled.appName, "Hop")
        let nameOnly = HopIdentity(infoDictionary: ["CFBundleIdentifier": "com.example.host", "CFBundleName": "Host"], processName: "x")
        XCTAssertEqual(nameOnly.appName, "Host", "CFBundleName when there is no display name")
    }
}
