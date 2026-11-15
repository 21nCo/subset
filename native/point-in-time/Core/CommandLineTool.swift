/// The read-only `point-in-time` command bundled in pointInTime.app, and how to run it from a terminal: through the
/// `subset` command, which runs the command of the pointInTime app in Applications (SET-232), or by linking it onto
/// `PATH`. The app only shows and copies the commands: it never runs them, installs `subset`, writes the link or
/// `/usr/local`, or edits a shell file.
public enum CommandLineTool {
    /// The `subset` form of the command.
    public static let subsetCommand = "subset \(StatusCommand.name)"
    /// Installs the `subset` command, once.
    public static let setupCommand = "npm i -g subset.dev"

    /// Where the app bundles the command.
    public static func path(inApp bundlePath: String) -> String {
        bundlePath + "/Contents/Helpers/" + StatusCommand.name
    }

    /// A shell command that links the command at `helperPath` into /usr/local/bin, with the path quoted for the shell.
    public static func linkCommand(helperPath: String) -> String {
        let quoted = "'" + helperPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "sudo mkdir -p /usr/local/bin && sudo ln -sf \(quoted) /usr/local/bin/\(StatusCommand.name)"
    }

    /// The Command-Line Tool window for the command at `helperPath`: the `subset point-in-time` form first, with its
    /// setup step, then linking the command as the alternative.
    public static func instructions(helperPath: String) -> Instructions {
        let link = linkCommand(helperPath: helperPath)
        return Instructions(
            text: """
                pointInTime includes a read-only command for scripts and AI agents. \(subsetCommand) status --json prints \
                today's focus summary from this Mac without starting the app, changing data, or using the network; titles \
                and page paths are left out unless you add --include-titles.

                To run it from a terminal, install the subset command once:

                \(setupCommand)

                Then, with pointInTime in /Applications or ~/Applications, run for example:

                \(subsetCommand) status

                Or link the command into a folder on your PATH instead, and run it as \(StatusCommand.name):

                \(link)

                pointInTime does not install subset, create this link, or change your shell files. If you move the app, \
                create the link again.
                """,
            copies: [.init(title: "Copy Setup Command", command: setupCommand),
                     .init(title: "Copy Link Command", command: link)])
    }

    /// What the window shows: its text, and the commands its Copy buttons copy, in button order.
    public struct Instructions: Equatable, Sendable {
        public struct Copy: Equatable, Sendable {
            public let title: String
            public let command: String
        }

        public let text: String
        public let copies: [Copy]
    }
}
