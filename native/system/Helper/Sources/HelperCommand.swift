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
    case disk(path: String, depth: Int, timeout: Duration)
    case suggestions(path: String, timeout: Duration)
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
    public static let defaultTimeout: Duration = .seconds(60)
    public static let defaultDepth = 1

    public static let usage = """
        Usage: subset-system <command> [options]

        Read-only: nothing is changed, deleted, or sent anywhere.

        Commands:
          status [--json]                 CPU, memory pressure, swap, compressed memory, and the 10 largest
                                          App groups by CPU and by memory, from two samples 1 second apart
          processes [--layer app|vendor|launch|project] [--json]
                                          Every process grouped by origin (default layer: app)
          disk --path <dir> [--depth N] [--timeout S] [--json]
                                          Scan a folder (default depth 1, timeout 60 s) with its volume's space
          disk --suggestions --path <dir> [--timeout S] [--json]
                                          Reclaim rule matches for a scan, with the catalog version
          --version                       Print the helper's version

        Options:
          --json       Print JSON (schemaVersion 1) instead of a text summary
          --absolute   Print the home folder's paths in full instead of with ~

        Exit codes: 0 ok, 2 usage error, 3 partial result, 4 timeout, 5 internal error.
        """

    /// Parses `arguments` (without the program name). `home` expands a `--path` starting with `~`. Throws a message
    /// for a usage error.
    public static func parse(_ arguments: [String], home: String) throws(HelperUsageError) -> HelperInvocation {
        var options: [String: String] = [:]
        var flags = Set<String>()
        var words: [String] = []
        var remaining = arguments[...]
        let valued: Set<String> = ["--layer", "--path", "--depth", "--timeout"]
        let switches: Set<String> = ["--json", "--absolute", "--suggestions", "--version", "--help", "-h"]
        while let argument = remaining.popFirst() {
            let parts = argument.split(separator: "=", maxSplits: 1).map(String.init)
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
            try reject(["--layer", "--path", "--depth", "--timeout", "--suggestions"], for: name)
            command = .status
        case "processes":
            try reject(["--path", "--depth", "--timeout", "--suggestions"], for: name)
            let text = options["--layer"] ?? HelperLayer.app.rawValue
            guard let layer = HelperLayer(rawValue: text) else {
                throw HelperUsageError("--layer must be app, vendor, launch, or project, not \(text).")
            }
            command = .processes(layer: layer)
        case "disk":
            try reject(["--layer"], for: name)
            guard let raw = options["--path"], !raw.isEmpty else { throw HelperUsageError("disk needs --path <dir>.") }
            let path = raw == "~" ? home : raw.hasPrefix("~/") ? home + raw.dropFirst() : raw
            var timeout = defaultTimeout
            if let text = options["--timeout"] {
                guard let seconds = Double(text), seconds.isFinite, seconds > 0, seconds <= 86_400 else {
                    throw HelperUsageError("--timeout must be a number of seconds above 0, not \(text).")
                }
                timeout = .milliseconds(Int64((seconds * 1000).rounded(.up)))
            }
            if flags.contains("--suggestions") {
                try reject(["--depth"], for: "disk --suggestions")
                command = .suggestions(path: path, timeout: timeout)
            } else {
                var depth = defaultDepth
                if let text = options["--depth"] {
                    guard let value = Int(text), (0...64).contains(value) else {
                        throw HelperUsageError("--depth must be a whole number from 0 to 64, not \(text).")
                    }
                    depth = value
                }
                command = .disk(path: path, depth: depth, timeout: timeout)
            }
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
