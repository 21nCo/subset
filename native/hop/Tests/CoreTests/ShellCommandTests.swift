import HopCore
import XCTest

final class ShellCommandTests: XCTestCase {
    func testStatusMenuOffersSettingsAboutAndQuitInOrder() {
        XCTAssertEqual(ShellCommand.statusMenu(trusted: true).map(\.title), ["Settings…", "About Hop", "Quit Hop"])
    }

    func testStatusMenuLeadsWithAccessibilityWhileUntrusted() {
        XCTAssertEqual(
            ShellCommand.statusMenu(trusted: false).map(\.title),
            ["Allow Accessibility Access…", "Settings…", "About Hop", "Quit Hop"]
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

    func testIdentityMatchesTheSharedDecisions() {
        XCTAssertEqual(HopIdentity.appName, "Hop")
        XCTAssertEqual(HopIdentity.bundleIdentifier, "dev.subset.hop")
    }
}
