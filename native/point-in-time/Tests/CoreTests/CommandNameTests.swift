import Foundation
import Testing
@testable import PointInTimeCore

/// `subset point-in-time` (SET-234): started through the `subset` launcher, the command names itself that way in help
/// and on standard error; its JSON, `--version` and exit codes stay as they were.
@Suite struct CommandNameTests {
    private func environment(_ directory: URL?, command: String = StatusCommand.name) -> StatusEnvironment {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 21, hour: 12))!
        return StatusEnvironment(now: now, timeZone: calendar.timeZone, storeDirectory: directory,
                                 settings: StoredSettings([StoredSettings.Key.onboardingCompleted: true, StoredSettings.Key.trackingEnabled: true]),
                                 appRunning: true, version: "0.1.0 (1)", command: command)
    }

    @Test func onlyASubsetToolValueOfSubsetCommandIsUsed() {
        #expect(StatusCommand.commandName([:]) == "point-in-time")
        #expect(StatusCommand.commandName(["SUBSET_COMMAND": "subset point-in-time"]) == "subset point-in-time")
        for ignored in ["", "subset", "subset ", "subset  point-in-time", "subset Point-In-Time", "subset point-in-time\n",
                        "subset point-in-time --json", "npx subset.dev point-in-time", "point-in-time; rm -rf ~", "subset point_in_time"] {
            #expect(StatusCommand.commandName(["SUBSET_COMMAND": ignored]) == "point-in-time", "\(ignored.debugDescription)")
        }
    }

    @Test func helpNamesTheCommandThatStartedIt() {
        let plain = StatusCommand.run(["--help"], environment: environment(nil))
        #expect(plain.exitCode == .ok)
        #expect(plain.standardOutput.hasPrefix("Usage: point-in-time status [--date YYYY-MM-DD] [--json] [--include-titles]\n       point-in-time --version\n"))

        let subset = StatusCommand.run(["--help"], environment: environment(nil, command: "subset point-in-time"))
        #expect(subset.exitCode == .ok)
        #expect(subset.standardOutput.hasPrefix(
            "Usage: subset point-in-time status [--date YYYY-MM-DD] [--json] [--include-titles]\n       subset point-in-time --version\n"))
        #expect(!subset.standardOutput.contains("Usage: point-in-time"))
        // The rest of the help is the same text.
        #expect(subset.standardOutput.replacingOccurrences(of: "subset point-in-time", with: "point-in-time") == plain.standardOutput)
    }

    @Test func usageErrorsNameTheCommandThatStartedIt() {
        let command = "subset point-in-time"
        for arguments in [[], ["serve"], ["status", "--verbose"], ["status", "--date", "tomorrow"], ["--version", "status"]] {
            let plain = StatusCommand.run(arguments, environment: environment(nil))
            let subset = StatusCommand.run(arguments, environment: environment(nil, command: command))
            #expect(subset.exitCode == .usage, "\(arguments)")
            #expect(subset.standardOutput.isEmpty, "\(arguments)")
            #expect(subset.standardError.hasPrefix("\(command): "), "\(arguments)")
            #expect(subset.standardError.hasSuffix("\n\n" + StatusCommand.usage(command: command)), "\(arguments)")
            #expect(plain.standardError.hasPrefix("point-in-time: "), "\(arguments)")
            #expect(subset.standardError.replacingOccurrences(of: command, with: "point-in-time") == plain.standardError, "\(arguments)")
        }
    }

    @Test func statusErrorsOnStandardErrorNameTheCommandButJSONAndVersionDoNot() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pit-command-\(UUID().uuidString)", isDirectory: true)
        let command = "subset point-in-time"
        let text = StatusCommand.run(["status"], environment: environment(directory, command: command))
        #expect(text.exitCode == .storeMissing)
        #expect(text.standardError.hasPrefix("\(command): No activity store was found"))
        #expect(!text.standardError.contains("\npoint-in-time:"))

        let json = StatusCommand.run(["status", "--json"], environment: environment(directory, command: command))
        #expect(json == StatusCommand.run(["status", "--json"], environment: environment(directory)))
        #expect(!json.standardOutput.contains(command))

        #expect(StatusCommand.run(["--version"], environment: environment(nil, command: command))
                == .init(standardOutput: "point-in-time 0.1.0 (1)\n", standardError: "", exitCode: .ok))
        #expect(StatusCommand.json(["focusPercent": Double.nan], exitCode: .ok, command: command)
                == .init(standardOutput: "", standardError: "\(command): The status could not be encoded as JSON.\n", exitCode: .internalError))
    }
}

/// The Command-Line Tool window (SET-234): `subset point-in-time` with its `npm i -g subset.dev` setup first, linking the
/// bundled command onto PATH as the alternative.
@Suite struct CommandLineToolTests {
    private let helper = "/Applications/pointInTime.app/Contents/Helpers/point-in-time"

    @Test func theBundledCommandIsInHelpers() {
        #expect(CommandLineTool.path(inApp: "/Applications/pointInTime.app") == helper)
    }

    @Test func theSubsetFormComesFirstAndTheLinkIsTheAlternative() throws {
        let instructions = CommandLineTool.instructions(helperPath: helper)
        let text = instructions.text
        let link = "sudo mkdir -p /usr/local/bin && sudo ln -sf '\(helper)' /usr/local/bin/point-in-time"
        let lines = text.split(separator: "\n").map(String.init)
        // Every command stands on its own line, so it can be selected and copied whole.
        let setup = try #require(lines.firstIndex(of: "npm i -g subset.dev"))
        let run = try #require(lines.firstIndex(of: "subset point-in-time status"))
        let linked = try #require(lines.firstIndex(of: link))
        #expect(setup < run && run < linked)
        #expect(text.hasPrefix("pointInTime includes a read-only command for scripts and AI agents. subset point-in-time status --json prints"))
        #expect(lines[run + 1 ..< linked].contains { $0.hasPrefix("Or link the command into a folder on your PATH instead") })
        #expect(text.contains("with pointInTime in /Applications or ~/Applications"))
        #expect(instructions.copies == [.init(title: "Copy Setup Command", command: "npm i -g subset.dev"),
                                        .init(title: "Copy Link Command", command: link)])
    }

    @Test func theLinkQuotesTheBundledPathForTheShell() {
        #expect(CommandLineTool.linkCommand(helperPath: "/Users/me/It's Apps/pointInTime.app/Contents/Helpers/point-in-time")
                == "sudo mkdir -p /usr/local/bin && sudo ln -sf '/Users/me/It'\\''s Apps/pointInTime.app/Contents/Helpers/point-in-time' /usr/local/bin/point-in-time")
    }
}
