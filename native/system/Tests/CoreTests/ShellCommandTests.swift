import SystemCore
import XCTest

final class ShellCommandTests: XCTestCase {
    func testStatusMenuOffersTheShellCommandsInOrder() {
        XCTAssertEqual(ShellCommand.allCases.map(\.title),
                       ["Open System", "Settings…", "Command-Line Helper…", "About Subset System", "Quit"])
    }

    /// The menu item shows how to put the bundled helper on PATH; the app never links it itself.
    func testCommandLineHelperLinkCommandQuotesTheBundledPath() {
        let helper = CommandLineHelper.path(inApp: "/Applications/Subset System.app")
        XCTAssertEqual(helper, "/Applications/Subset System.app/Contents/Helpers/subset-system")
        XCTAssertEqual(CommandLineHelper.linkCommand(helperPath: helper),
                       "ln -s '/Applications/Subset System.app/Contents/Helpers/subset-system' /usr/local/bin/subset-system")
        XCTAssertEqual(CommandLineHelper.linkCommand(helperPath: "/Users/me/It's/subset-system"),
                       "ln -s '/Users/me/It'\\''s/subset-system' /usr/local/bin/subset-system")
    }

    func testSettingsAndQuitUseTheStandardKeyEquivalents() {
        XCTAssertEqual(ShellCommand.settings.keyEquivalent, ",")
        XCTAssertEqual(ShellCommand.quit.keyEquivalent, "q")
        XCTAssertEqual(ShellCommand.openSystem.keyEquivalent, "")
        XCTAssertEqual(ShellCommand.about.keyEquivalent, "")
        XCTAssertEqual(ShellCommand.commandLineHelper.keyEquivalent, "")
    }

    func testAboutAndQuitAreSeparatedFromTheWindowCommands() {
        XCTAssertEqual(ShellCommand.allCases.filter(\.startsGroup), [.about, .quit])
    }

    func testIdentityMatchesTheSharedDecisions() {
        XCTAssertEqual(SystemIdentity.appName, "Subset System")
        XCTAssertEqual(SystemIdentity.bundleIdentifier, "dev.subset.system")
    }
}
