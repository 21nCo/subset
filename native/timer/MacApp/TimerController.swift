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
    private var board: Process?
    private var boardURL: URL?

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
    nonisolated private static func launchDaemon(_ runtime: Runtime, _ paths: DaemonPaths) throws {
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
        if let board, board.isRunning, let boardURL {
            NSWorkspace.shared.open(boardURL)
            return
        }
        guard case .ready(let runtime) = setup else { return }
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
        process.terminationHandler = { [weak self] process in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let failed = process.terminationReason == .exit && process.terminationStatus != 0
            Task { @MainActor in
                guard let self, self.board === process else { return }
                self.board = nil
                self.boardURL = nil
                if failed { self.onError(message.isEmpty ? "The Timer board stopped (exit code \(process.terminationStatus))." : message) }
            }
        }
        do {
            try process.run()
        } catch {
            onError("Could not open the Timer board: \(error.localizedDescription)")
            return
        }
        board = process
        Task { [weak self] in
            let url = await Self.servedURL(output)
            if let self, self.board === process { self.boardURL = url }
        }
    }

    /// The URL in `serve --json`'s first line, `{"url":…,"port":…}`, which it prints once the board is listening.
    nonisolated private static func servedURL(_ output: Pipe) async -> URL? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var line = Data()
                while let byte = try? output.fileHandleForReading.read(upToCount: 1), let first = byte.first, first != 0x0A { line.append(first) }
                struct Served: Decodable { var url: URL }
                continuation.resume(returning: (try? JSONDecoder().decode(Served.self, from: line))?.url)
            }
        }
    }

    /// Stops the board server this app started. The daemon keeps running.
    func stopBoard() {
        board?.terminate()
    }
}

/// An operation's result, which the app does not need: the next `state` event shows its effect.
private struct IgnoredResult: Decodable {}
