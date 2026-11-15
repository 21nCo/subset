/// The app's identity, shared by the menu-bar host and its tests. Matches the bundle settings in
/// ProjectGenerator.rb and MacApp/Info.plist.
public enum SystemIdentity {
    public static let appName = "Subset System"
    public static let bundleIdentifier = "dev.subset.system"
}

/// The commands the menu-bar status item offers, in menu order. The host maps each one to an action; later
/// issues add commands here rather than building menu items ad hoc.
public enum ShellCommand: CaseIterable, Sendable {
    case openSystem
    case settings
    case commandLineHelper
    case about
    case quit

    public var title: String {
        switch self {
        case .openSystem: "Open System"
        case .settings: "Settings…"
        case .commandLineHelper: "Command-Line Helper…"
        case .about: "About \(SystemIdentity.appName)"
        case .quit: "Quit"
        }
    }

    /// The Command-key equivalent shown in the menu, or an empty string for none.
    public var keyEquivalent: String {
        switch self {
        case .openSystem: ""
        case .settings: ","
        case .commandLineHelper: ""
        case .about: ""
        case .quit: "q"
        }
    }

    /// Whether a separator precedes this command in the status menu.
    public var startsGroup: Bool {
        switch self {
        case .openSystem: false
        case .settings: false
        case .commandLineHelper: false
        case .about: true
        case .quit: true
        }
    }
}

/// The read-only agent helper (SET-52) inside the app bundle, and how to run it from a terminal: through the `subset`
/// command, which runs the helper of the System app in Applications (SET-232), or by linking the helper onto `PATH`.
/// The app only shows and copies the commands: it never runs them, installs `subset`, edits shell files, or writes to
/// `/usr/local`.
public enum CommandLineHelper {
    public static let name = "subset-system"
    /// The `subset` form of the helper's command.
    public static let subsetCommand = "subset system"
    /// Installs the `subset` command, once.
    public static let setupCommand = "npm i -g subset.dev"

    /// Where the app bundles the helper.
    public static func path(inApp bundlePath: String) -> String {
        bundlePath + "/Contents/Helpers/" + name
    }

    /// A shell command that links the helper into `folder`, with the helper's path quoted for the shell.
    public static func linkCommand(helperPath: String, folder: String = "/usr/local/bin") -> String {
        "ln -s '\(helperPath.replacingOccurrences(of: "'", with: "'\\''"))' \(folder)/\(name)"
    }

    /// The Command-Line Helper window for the helper at `helperPath`: the `subset system` form first, with its setup
    /// step, then linking the helper as the alternative.
    public static func instructions(helperPath: String) -> CommandLineInstructions {
        let link = linkCommand(helperPath: helperPath)
        return CommandLineInstructions(
            text: """
                \(subsetCommand) prints this Mac's CPU and memory by origin and disk usage by folder as text or JSON, \
                for you or an agent that runs shell commands. It only reads: it never cleans up, changes, or sends anything.

                To run it from Terminal, install the subset command once:

                \(setupCommand)

                Then, with \(SystemIdentity.appName) in /Applications or ~/Applications, run for example:

                \(subsetCommand) status

                Or link the helper into a folder on your PATH instead, and run it as \(name):

                \(link)

                System never installs subset, edits shell files, or writes to /usr/local itself. \
                Run \(subsetCommand) --help for its commands.
                """,
            copies: [.init(title: "Copy Setup Command", command: setupCommand),
                     .init(title: "Copy Link Command", command: link)])
    }
}

/// What a Command-Line window shows: its text, and the commands its buttons copy, in button order.
public struct CommandLineInstructions: Equatable, Sendable {
    public struct Copy: Equatable, Sendable {
        public let title: String
        public let command: String

        public init(title: String, command: String) {
            self.title = title
            self.command = command
        }
    }

    public let text: String
    public let copies: [Copy]

    public init(text: String, copies: [Copy]) {
        self.text = text
        self.copies = copies
    }
}
