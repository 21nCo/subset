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

    /// Runs one command line for a helper about to exit, then sends `SIGKILL` at once to every command the run left
    /// running (`CommandRegistry.shutDown()`): a `tmutil` or `docker` command stopped at its timeout gets `SIGTERM`, and
    /// the `SIGKILL` a second later would never fire once the helper has exited, so one ignoring `SIGTERM` would
    /// outlive it.
    public static func runToExit(_ arguments: [String], environment: HelperEnvironment,
                                 registry: CommandRegistry = .shared) async -> HelperOutput {
        let output = await run(arguments, environment: environment)
        registry.shutDown()
        return output
    }

    /// For a helper sent `SIGTERM`, `SIGINT`, or `SIGHUP` (an agent's timeout, Ctrl-C, a closed terminal) while it
    /// awaits a command, which macOS would leave running: sends `SIGKILL` to every command `registry` holds, then exits
    /// with 128 plus the signal's number. A dispatch signal source does the work; the handler installed is empty, and
    /// `exec` resets it for commands launched later. A signal the helper started with ignored (`nohup`, a background
    /// job) is left ignored, for the helper and its commands. Keep the returned cancel closure alive while the helper runs.
    public static func stopCommandsOnTermination(registry: CommandRegistry = .shared,
                                                 exit: @escaping @Sendable (Int32) -> Void = { Darwin.exit($0) }) -> () -> Void {
        let queue = DispatchQueue(label: "subset-system.termination")
        let watched = [SIGTERM, SIGINT, SIGHUP].compactMap { signo -> (DispatchSourceSignal, sig_t?)? in
            var current = sigaction()
            sigaction(signo, nil, &current)
            if unsafeBitCast(current.__sigaction_u.__sa_handler, to: Int.self) == unsafeBitCast(SIG_IGN, to: Int.self) { return nil }
            let source = DispatchSource.makeSignalSource(signal: signo, queue: queue)
            source.setEventHandler {
                registry.shutDown()
                exit(128 + signo)
            }
            source.resume()
            return (source, signal(signo) { _ in /* The signal source does the work. */ })
        }
        return { for (source, previous) in watched { signal(Int32(source.handle), previous); source.cancel() } }
    }
}
