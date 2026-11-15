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

    /// SET-234: the window shows `subset system` with its `npm i -g subset.dev` setup first, and linking the bundled
    /// helper onto PATH as the alternative; its Copy buttons copy those two commands.
    func testCommandLineHelperWindowShowsTheSubsetFormFirst() throws {
        let helper = CommandLineHelper.path(inApp: "/Applications/Subset System.app")
        let instructions = CommandLineHelper.instructions(helperPath: helper)
        let link = "ln -s '/Applications/Subset System.app/Contents/Helpers/subset-system' /usr/local/bin/subset-system"
        let lines = instructions.text.split(separator: "\n").map(String.init)
        // Every command stands on its own line, so it can be selected and copied whole.
        let setup = try XCTUnwrap(lines.firstIndex(of: "npm i -g subset.dev"))
        let run = try XCTUnwrap(lines.firstIndex(of: "subset system status"))
        let linked = try XCTUnwrap(lines.firstIndex(of: link))
        XCTAssertLessThan(setup, run)
        XCTAssertLessThan(run, linked)
        XCTAssertTrue(instructions.text.hasPrefix("subset system prints this Mac's CPU and memory"))
        XCTAssertTrue(lines[run + 1 ..< linked].contains { $0.hasPrefix("Or link the helper into a folder on your PATH instead") })
        XCTAssertTrue(instructions.text.contains("with Subset System in /Applications or ~/Applications"))
        XCTAssertTrue(lines.last?.hasSuffix("Run subset system --help for its commands.") == true)
        XCTAssertEqual(instructions.copies, [.init(title: "Copy Setup Command", command: "npm i -g subset.dev"),
                                             .init(title: "Copy Link Command", command: link)])
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
