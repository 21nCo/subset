import Foundation
import SystemCore

/// How the helper exits. Documented in the README; agents branch on these.
public enum HelperExit: Int32, Sendable {
    case ok = 0
    case usage = 2
    /// The result is usable but incomplete: restricted processes, unreadable folders, or a value that could not be read.
    case partial = 3
    case timeout = 4
    case internalError = 5
}

/// The processes layer the `processes` command groups by, named as on the command line.
public enum HelperLayer: String, CaseIterable, Sendable {
    case app, vendor, launch, project

    var attribution: AttributionLayer {
        switch self {
        case .app: .app
        case .vendor: .vendor
        case .launch: .launchSource
        case .project: .project
        }
    }
}

/// One parsed command line. Every command only reads: there is no cleanup, write, network, or AI command.
public enum HelperCommand: Equatable, Sendable {
    case status
    case processes(layer: HelperLayer)
    case version
    case help
}

public struct HelperInvocation: Equatable, Sendable {
    public var command: HelperCommand
    public var json: Bool
    /// Print paths as they are, instead of with `~` for the home folder.
    public var absolute: Bool

    public init(command: HelperCommand, json: Bool = false, absolute: Bool = false) {
        self.command = command
        self.json = json
        self.absolute = absolute
    }

    public static let version = "0.1.0"

    public static let usage = """
        Usage: subset-system <command> [options]

        Read-only: nothing is changed, deleted, or sent anywhere.

        Commands:
          status [--json]                 CPU, memory pressure, swap, compressed memory, and the 10 largest
                                          App groups by CPU and by memory, from two samples 1 second apart
          processes [--layer app|vendor|launch|project] [--json]
                                          Every process grouped by origin (default layer: app)
          --version                       Print the helper's version

        Options:
          --json       Print JSON (schemaVersion 1) instead of a text summary
          --absolute   Print the home folder's paths in full instead of with ~

        Exit codes: 0 ok, 2 usage error, 3 partial result, 4 timeout, 5 internal error.
        """

    /// Parses `arguments` (without the program name). Throws a message for a usage error.
    public static func parse(_ arguments: [String]) throws(HelperUsageError) -> HelperInvocation {
        var options: [String: String] = [:]
        var flags = Set<String>()
        var words: [String] = []
        var remaining = arguments[...]
        let valued: Set<String> = ["--layer"]
        let switches: Set<String> = ["--json", "--absolute", "--version", "--help", "-h"]
        while let argument = remaining.popFirst() {
            guard !argument.isEmpty, !argument.hasPrefix("=") else {
                throw HelperUsageError(argument.isEmpty ? "An argument is empty." : "Unexpected argument \(argument).")
            }
            let parts = argument.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            if valued.contains(parts[0]) {
                guard let value = parts.count == 2 ? parts[1] : remaining.popFirst() else {
                    throw HelperUsageError("\(parts[0]) needs a value.")
                }
                guard options.updateValue(value, forKey: parts[0]) == nil else {
                    throw HelperUsageError("\(parts[0]) is given more than once.")
                }
            } else if switches.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("-") {
                throw HelperUsageError("Unknown option \(argument).")
            } else {
                words.append(argument)
            }
        }
        let json = flags.contains("--json")
        let absolute = flags.contains("--absolute")
        func reject(_ names: [String], for command: String) throws(HelperUsageError) {
            if let name = names.first(where: { options[$0] != nil || flags.contains($0) }) {
                throw HelperUsageError("\(name) does not apply to \(command).")
            }
        }

        if flags.contains("--help") || flags.contains("-h") || words == ["help"] {
            return HelperInvocation(command: .help)
        }
        if flags.contains("--version") {
            guard words.isEmpty else { throw HelperUsageError("--version takes no command.") }
            return HelperInvocation(command: .version, json: json)
        }
        guard let name = words.first else { throw HelperUsageError("No command given.") }
        guard words.count == 1 else { throw HelperUsageError("Unexpected argument \(words[1]).") }
        let command: HelperCommand
        switch name {
        case "status":
            try reject(["--layer"], for: name)
            command = .status
        case "processes":
            let text = options["--layer"] ?? HelperLayer.app.rawValue
            guard let layer = HelperLayer(rawValue: text) else {
                throw HelperUsageError("--layer must be app, vendor, launch, or project, not \(text).")
            }
            command = .processes(layer: layer)
        default:
            throw HelperUsageError("Unknown command \(name).")
        }
        return HelperInvocation(command: command, json: json, absolute: absolute)
    }
}

public struct HelperUsageError: Error, Equatable, Sendable {
    public let message: String

    init(_ message: String) {
        self.message = message
    }
}
