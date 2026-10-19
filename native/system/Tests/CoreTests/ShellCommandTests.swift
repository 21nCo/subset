import SystemCore
import XCTest

final class ShellCommandTests: XCTestCase {
    func testStatusMenuOffersTheFourShellCommandsInOrder() {
        XCTAssertEqual(ShellCommand.allCases.map(\.title), ["Open System", "Settings…", "About Subset System", "Quit"])
    }

    func testSettingsAndQuitUseTheStandardKeyEquivalents() {
        XCTAssertEqual(ShellCommand.settings.keyEquivalent, ",")
        XCTAssertEqual(ShellCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(ShellCommand.openSystem.keyEquivalent, "")
        XCTAssertEqual(ShellCommand.about.keyEquivalent, "")
    }

    func testAboutAndQuitAreSeparatedFromTheWindowCommands() {
        XCTAssertEqual(ShellCommand.allCases.filter(\.startsGroup), [.about, .quit])
    }

    func testIdentityMatchesTheSharedDecisions() {
        XCTAssertEqual(SystemIdentity.appName, "Subset System")
        XCTAssertEqual(SystemIdentity.bundleIdentifier, "dev.subset.system")
    }
}
