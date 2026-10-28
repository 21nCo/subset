import Foundation
import SystemCore

/// What the helper reads, injected so tests run every command on fixtures.
public struct HelperEnvironment: Sendable {
    /// The home folder, for `~` in paths.
    public var home: String
    public var processes: ProcessProbe

    public init(home: String, processes: ProcessProbe) {
        self.home = home
        self.processes = processes
    }

    public static func live() -> HelperEnvironment {
        HelperEnvironment(home: NSHomeDirectory(), processes: .live())
    }
}

/// What the helper prints, and its exit code.
public struct HelperOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exit: HelperExit
}

public enum HelperRunner {
    /// Runs one command line (without the program name).
    public static func run(_ arguments: [String], environment: HelperEnvironment) async -> HelperOutput {
        let invocation: HelperInvocation
        do {
            invocation = try HelperInvocation.parse(arguments)
        } catch {
            return HelperOutput(stdout: "", stderr: "subset-system: \(error.message)\nRun subset-system --help for usage.\n",
                                exit: .usage)
        }
        let paths = PathDisplay(home: environment.home, absolute: invocation.absolute)
        let report: HelperReport
        switch invocation.command {
        case .help:
            return HelperOutput(stdout: HelperInvocation.usage + "\n", stderr: "", exit: .ok)
        case .version:
            return HelperOutput(stdout: "subset-system \(HelperInvocation.version)\n", stderr: "", exit: .ok)
        case .status:
            report = ProcessReports.status(await environment.processes.measure(), paths: paths)
        case let .processes(layer):
            report = ProcessReports.processes(await environment.processes.measure(), layer: layer, paths: paths)
        }
        return HelperOutput(stdout: (invocation.json ? report.json.pretty : report.text) + "\n", stderr: "", exit: report.exit)
    }
}
