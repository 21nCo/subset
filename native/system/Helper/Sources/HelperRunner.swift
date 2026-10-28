import Foundation
import SystemCore

/// What the helper reads, injected so tests run every command on fixtures.
public struct HelperEnvironment: Sendable {
    /// The home folder, for `~` in paths and for which scan asks Docker.
    public var home: String
    public var processes: ProcessProbe
    public var disk: DiskProbe
    public var now: @Sendable () -> Date

    public init(home: String, processes: ProcessProbe, disk: DiskProbe, now: @escaping @Sendable () -> Date = { Date() }) {
        self.home = home
        self.processes = processes
        self.disk = disk
        self.now = now
    }

    public static func live() -> HelperEnvironment {
        HelperEnvironment(home: NSHomeDirectory(), processes: .live(), disk: .live)
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
            invocation = try HelperInvocation.parse(arguments, home: environment.home)
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
        case let .disk(path, depth, timeout):
            report = await DiskReports.disk(path: path, depth: depth, timeout: timeout, probe: environment.disk,
                                            paths: paths, now: environment.now)
        case let .suggestions(path, timeout):
            let home = realpath(environment.home, nil).map { pointer in
                defer { free(pointer) }
                return String(cString: pointer)
            } ?? environment.home
            report = await DiskReports.suggestions(path: path, timeout: timeout, home: home, probe: environment.disk,
                                                   paths: paths, now: environment.now)
        }
        return HelperOutput(stdout: (invocation.json ? report.json.pretty : report.text) + "\n", stderr: "", exit: report.exit)
    }
}
