import AppKit
import TimerCore

/// The app's state as a daemon client: where Node.js and the CLI are, the timers the daemon last published, and
/// the presets. Every change is a daemon operation; the app never writes timer state itself.
@MainActor
final class TimerController {
    enum Setup: Equatable {
        case locating
        case ready(Runtime)
        case problem(RuntimeProblem)
    }

    private(set) var setup = Setup.locating
    private(set) var timers: [StoredTimer] = []
    private(set) var presets: [Preset] = []
    /// Set while the event stream is down, until it reconnects.
    private(set) var connectionProblem: String?
    /// Called after any of the above changes.
    var onChange: () -> Void = {}
    /// Shows an operation's failure.
    var onError: (String) -> Void = { _ in }

    let paths = DaemonPaths.resolve()
    private var client: DaemonClient { DaemonClient(paths: paths) }
    private var subscription: Task<Void, Never>?

    func start() {
        subscription?.cancel()
        setup = .locating
        timers = []
        onChange()
        Task {
            switch await RuntimeLocator().locate() {
            case .success(let runtime):
                setup = .ready(runtime)
                subscribe(runtime)
            case .failure(let problem):
                setup = .problem(problem)
            }
            onChange()
        }
    }

    private func subscribe(_ runtime: Runtime) {
        let (client, paths) = (client, paths)
        subscription = Task { [weak self] in
            let updates = EventSubscription.updates(connect: {
                try await client.ensureRunning { try Self.launchDaemon(runtime, paths) }
                return try await client.openEvents()
            })
            for await update in updates {
                self?.handle(update)
            }
        }
    }

    /// Starts `node cli.mjs daemon run` detached, so quitting the app leaves the daemon and its timers running.
    nonisolated private static func launchDaemon(_ runtime: Runtime, _ paths: DaemonPaths) throws -> LaunchedDaemon {
        try DaemonLauncher.launch(node: runtime.node, cli: runtime.cli, paths: paths)
    }

    private func handle(_ update: EventSubscription.Update) {
        switch update {
        case .connected:
            connectionProblem = nil
            refreshPresets()
        case .event(let event) where event.event == "state":
            do {
                timers = try DaemonClient.board(from: Data(event.data.utf8)).timers.map(\.stored)
            } catch {
                connectionProblem = error.localizedDescription
            }
        case .event:
            return
        case .disconnected(let error, _):
            connectionProblem = error?.localizedDescription ?? "The Timer daemon closed the connection."
        }
        onChange()
    }

    func refreshPresets() {
        guard case .ready = setup else { return }
        Task {
            guard let presets = try? await client.presets(), presets != self.presets else { return }
            self.presets = presets
            onChange()
        }
    }

    /// Runs an operation, starting the daemon first if none is listening, as the CLI does. Returns the failure's message.
    @discardableResult
    func perform(_ operation: String, _ input: OperationInput) async -> String? {
        guard case .ready(let runtime) = setup else { return RuntimeProblem.nodeMissing.message }
        let (client, paths) = (client, paths)
        do {
            do {
                try await client.perform(operation, input, as: IgnoredResult.self)
            } catch DaemonError.notListening, DaemonError.shuttingDown {
                try await client.ensureRunning { try Self.launchDaemon(runtime, paths) }
                try await client.perform(operation, input, as: IgnoredResult.self)
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    func run(_ operation: String, _ input: OperationInput) {
        Task {
            if let message = await perform(operation, input) { onError(message) }
        }
    }

    /// Opens the web board: runs `cli serve`, which opens the browser, or reopens the one already serving.
    func openBoard() {
        guard case .ready(let runtime) = setup else { return }
        openBoard(runtime)
    }

    /// The one `serve` process this app runs: while it starts, Open Board waits for it (`serve` opens the browser
    /// once it listens) instead of starting another, so Quit always has every board process to stop.
    func openBoard(_ runtime: Runtime) {
        if let board, board.process.isRunning {
            if let url = board.url { NSWorkspace.shared.open(url) }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: runtime.node)
        process.arguments = [runtime.cli, "serve", "--json"]
        var environment = ProcessInfo.processInfo.environment
        environment["SUBSET_TIMER_DATA_DIR"] = paths.dataDir
        process.environment = environment
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        let firstLine = Task { await Self.served(output) }
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failed = process.terminationReason == .exit && process.terminationStatus != 0
            Task { @MainActor in
                let served = await firstLine.value
                guard let self else { return }
                if self.board?.process === process { self.board = nil }
                if failed { self.onError(Served.failureMessage(served, errors: message, status: process.terminationStatus)) }
            }
        }
        do {
            try process.run()
        } catch {
            try? output.fileHandleForWriting.close()
            onError("Could not open the Timer board: \(error.localizedDescription)")
            return
        }
        board = Board(process: process)
        Task { [weak self] in
            if case .serving(let url)? = await firstLine.value, let self, self.board?.process === process { self.board?.url = url }
        }
    }

    /// The board process, and its URL once `serve` is listening.
    struct Board {
        let process: Process
        var url: URL?
    }

    private(set) var board: Board?

    /// `serve --json`'s first stdout line: `{"url":…,"port":…}` once listening, or `{"error":{"code":…,"message":…}}`,
    /// since `--json` reports failures on stdout rather than stderr.
    enum Served: Equatable {
        case serving(URL)
        case failed(String)

        init?(line: Data) {
            struct Line: Decodable {
                struct Failure: Decodable { var message: String }
                var url: URL?
                var error: Failure?
            }
            guard let decoded = try? JSONDecoder().decode(Line.self, from: line) else { return nil }
            if let url = decoded.url { self = .serving(url) } else if let message = decoded.error?.message { self = .failed(message) } else { return nil }
        }

        /// The CLI's own error, else what `serve` wrote to stderr, else its exit code.
        static func failureMessage(_ served: Served?, errors: String, status: Int32) -> String {
            if case .failed(let message)? = served { return message }
            let errors = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return errors.isEmpty ? "The Timer board stopped (exit code \(status))." : errors
        }
    }

    nonisolated private static func served(_ output: Pipe) async -> Served? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var line = Data()
                while let byte = try? output.fileHandleForReading.read(upToCount: 1), let first = byte.first, first != 0x0A { line.append(first) }
                continuation.resume(returning: Served(line: line))
            }
        }
    }

    /// Stops the board server this app started, whether it is still starting or serving. The daemon keeps running.
    func stopBoard() {
        board?.process.terminate()
    }
}

/// An operation's result, which the app does not need: the next `state` event shows its effect.
private struct IgnoredResult: Decodable {}
