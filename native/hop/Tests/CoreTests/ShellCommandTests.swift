import HopCore
import XCTest

final class ShellCommandTests: XCTestCase {
    func testStatusMenuOffersSettingsAboutAndQuitInOrder() {
        XCTAssertEqual(ShellCommand.allCases.map(\.title), ["Settings…", "About Hop", "Quit Hop"])
    }

    func testSettingsAndQuitUseTheStandardKeyEquivalents() {
        XCTAssertEqual(ShellCommand.settings.keyEquivalent, ",")
        XCTAssertEqual(ShellCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(ShellCommand.about.keyEquivalent, "")
    }

    func testAboutAndQuitAreSeparatedFromSettings() {
        XCTAssertEqual(ShellCommand.allCases.filter(\.startsGroup), [.about, .quit])
    }

    func testIdentityMatchesTheSharedDecisions() {
        XCTAssertEqual(HopIdentity.appName, "Hop")
        XCTAssertEqual(HopIdentity.bundleIdentifier, "dev.subset.hop")
    }
}
