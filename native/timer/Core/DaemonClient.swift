import Foundation
import Network

/// The files the per-user daemon owns (packages/timer-cli/src/daemon/paths.mjs).
public struct DaemonPaths: Equatable, Sendable {
    public var dataDir: String
    public var socket: String { Self.join(dataDir, "daemon.sock") }
    public var log: String { Self.join(dataDir, "daemon.log") }
    public var lock: String { Self.join(dataDir, "daemon.lock") }

    public init(dataDir: String) {
        self.dataDir = dataDir
    }

    /// `SUBSET_TIMER_DATA_DIR`, else `~/.local/share/subset/timer`, as the CLI resolves it.
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment,
                               home: String = FileManager.default.homeDirectoryForCurrentUser.path,
                               workingDirectory: String = FileManager.default.currentDirectoryPath) -> DaemonPaths {
        if let override = environment["SUBSET_TIMER_DATA_DIR"], !override.isEmpty {
            if override.hasPrefix("/") { return DaemonPaths(dataDir: override) }
            return DaemonPaths(dataDir: join(workingDirectory, override))
        }
        return DaemonPaths(dataDir: join(home, ".local/share/subset/timer"))
    }

    /// Node's `path.join`, normalized lexically: `/a/link/../timer` is `/a/timer`, as the daemon sees it.
    static func join(_ parts: String...) -> String {
        let path = parts.joined(separator: "/")
        var components: [Substring] = []
        for part in path.split(separator: "/") where part != "." {
            if part == "..", let last = components.last, last != ".." { components.removeLast() }
            else if part != ".." || !path.hasPrefix("/") { components.append(part) }
        }
        let joined = components.joined(separator: "/")
        return path.hasPrefix("/") ? "/" + joined : (joined.isEmpty ? "." : joined)
    }
}

public enum DaemonError: Error, Equatable, LocalizedError {
    /// No daemon listens on the socket: it is missing or refuses connections.
    case notListening
    case connectionFailed(String)
    case timedOut
    case malformedReply(String)
    /// The daemon is shutting down and did not run the request.
    case shuttingDown
    /// The daemon refused the request, for example an operation on a timer in the wrong state.
    case rejected(status: Int, TimerError)
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .notListening: "The Timer daemon is not running."
        case .connectionFailed(let reason): "Could not reach the Timer daemon: \(reason)"
        case .timedOut: "The Timer daemon did not answer in time."
        case .malformedReply(let reason): "The Timer daemon sent a reply this app cannot read: \(reason)"
        case .shuttingDown: "The Timer daemon is shutting down."
        case .rejected(_, let error): error.message
        case .unsupportedSchema(let version): "The Timer daemon uses schema version \(version); this app reads version \(supportedSchemaVersion). Update the app and the CLI together."
        }
    }
}

/// A client of the daemon's HTTP/1.1 JSON API on its Unix socket. Each request opens its own connection.
public struct DaemonClient: Sendable {
    public let paths: DaemonPaths
    /// How long the event stream may stay silent; the daemon sends a heartbeat every 15 seconds.
    public var streamIdleTimeout: TimeInterval = 45

    public init(paths: DaemonPaths) {
        self.paths = paths
    }

    /// One request. Returns the status and body of any complete reply.
    public func send(_ method: String, _ path: String, body: Data? = nil, timeout: TimeInterval = 10) async throws -> (status: Int, body: Data) {
        let connection = SocketConnection(path: paths.socket)
        defer { connection.cancel() }
        connection.setDeadline(timeout)
        try await connection.open()
        try await connection.send(Self.request(method, path, body: body))
        var parser = HTTPResponseParser()
        var status: Int?
        var data = Data()
        while true {
            let events = try await connection.parse(&parser)
            for event in events {
                switch event {
                case .head(let head): status = head.status
                case .body(let chunk): data.append(chunk)
                case .end: return (status ?? 0, data)
                }
            }
        }
    }

    static func request(_ method: String, _ path: String, body: Data?) -> Data {
        var head = "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n"
        if let body { head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\n" }
        return Data((head + "\r\n").utf8) + (body ?? Data())
    }

    /// Decodes a 200 reply as `T`, and any other as the `DaemonError` it describes.
    public static func decode<T: Decodable>(_ type: T.Type, status: Int, body: Data) throws -> T {
        let decoder = JSONDecoder()
        guard status == 200 else {
            guard let reply = try? decoder.decode(ErrorReply.self, from: body) else { throw DaemonError.malformedReply("HTTP \(status)") }
            if status == 503, reply.error.code == "daemon_unavailable" { throw DaemonError.shuttingDown }
            throw DaemonError.rejected(status: status, reply.error)
        }
        do {
            return try decoder.decode(T.self, from: body)
        } catch {
            throw DaemonError.malformedReply(String(describing: error))
        }
    }

    public func info(timeout: TimeInterval = 10) async throws -> DaemonInfo {
        let reply = try await send("GET", "/v1/daemon", timeout: timeout)
        return try Self.decode(DaemonInfo.self, status: reply.status, body: reply.body)
    }

    public func board() async throws -> TimerBoard {
        let reply = try await send("GET", "/v1/timers")
        return try Self.board(from: reply.body, status: reply.status)
    }

    /// A board from `GET /v1/timers` or a `state` event, refusing a schema this app does not read.
    public static func board(from body: Data, status: Int = 200) throws -> TimerBoard {
        if status == 200, let version = (try? JSONDecoder().decode(SchemaProbe.self, from: body))?.structuredContent.schemaVersion,
           version != supportedSchemaVersion {
            throw DaemonError.unsupportedSchema(version)
        }
        return try decode(AgentTimerResult.self, status: status, body: body).structuredContent
    }

    private struct SchemaProbe: Decodable {
        struct Content: Decodable { var schemaVersion: Int }
        var structuredContent: Content
    }

    public func presets() async throws -> [Preset] {
        let reply = try await send("GET", "/v1/presets")
        return try Self.decode(PresetList.self, status: reply.status, body: reply.body).presets
    }

    /// Runs an operation, such as `start` or `pause`, and decodes its result as `T`.
    @discardableResult
    public func perform<T: Decodable>(_ operation: String, _ input: OperationInput, as type: T.Type = TimerResult.self) async throws -> T {
        let reply = try await send("POST", "/v1/ops/\(operation)", body: try JSONEncoder().encode(input))
        return try Self.decode(T.self, status: reply.status, body: reply.body)
    }

    /// Opens `/v1/events`. Returns once the daemon accepts the stream; the stream then yields its bytes until the
    /// daemon ends it, and fails when it stays silent longer than `streamIdleTimeout`.
    public func openEvents() async throws -> AsyncThrowingStream<Data, Error> {
        let connection = SocketConnection(path: paths.socket)
        do {
            connection.setDeadline(10)
            try await connection.open()
            try await connection.send(Self.request("GET", "/v1/events", body: nil))
            var parser = HTTPResponseParser(maxBodyBytes: .max)
            var pending: [Data] = []
            var head: HTTPResponseHead?
            var ended = false
            while head == nil {
                for event in try await connection.parse(&parser) {
                    switch event {
                    case .head(let value): head = value
                    case .body(let chunk): pending.append(chunk)
                    case .end: ended = true
                    }
                }
            }
            guard let head, head.status == 200 else {
                throw head?.status == 503 ? DaemonError.shuttingDown : DaemonError.malformedReply("HTTP \(head?.status ?? 0) for the event stream")
            }
            let idleTimeout = streamIdleTimeout
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            for chunk in pending { continuation.yield(chunk) }
            if ended {
                connection.cancel()
                continuation.finish()
                return stream
            }
            let reader = Task { [parser] in
                var parser = parser
                do {
                    while true {
                        connection.setDeadline(idleTimeout)
                        for event in try await connection.parse(&parser) {
                            switch event {
                            case .body(let chunk): continuation.yield(chunk)
                            case .end: return continuation.finish()
                            case .head: break
                            }
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in
                reader.cancel()
                connection.cancel()
            }
            return stream
        } catch {
            connection.cancel()
            throw error
        }
    }

    /// Makes sure a daemon answers, as client.mjs `startDaemon` does: when none listens, or the one there is shutting
    /// down, calls `launch`, again once it has exited while no live process holds the lock, and waits for its socket.
    public func ensureRunning(timeout: TimeInterval = 3, maxLaunches: Int = 3, launch: @Sendable () throws -> LaunchedDaemon) async throws {
        try await ensureRunning(timeout: timeout, maxLaunches: maxLaunches, probe: { _ = try await info(timeout: $0) },
                                lockHeld: { DaemonLock.held(at: paths.lock) }, launch: launch)
    }

    func ensureRunning(timeout: TimeInterval, maxLaunches: Int, probe: (TimeInterval) async throws -> Void,
                       lockHeld: () -> Bool, launch: () throws -> LaunchedDaemon) async throws {
        do {
            return try await probe(10)
        } catch DaemonError.notListening, DaemonError.shuttingDown {}
        var child = try launch()
        var launches = 1
        let deadline = ContinuousClock.now + .seconds(timeout)
        var lastError: Error = DaemonError.notListening
        while ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            do {
                // Each probe gets only what is left of the wait.
                return try await probe(max(0.001, Double((deadline - ContinuousClock.now) / .milliseconds(1)) / 1000))
            } catch {
                lastError = error
            }
            if child.hasExited, launches < maxLaunches, !lockHeld() {
                child = try launch()
                launches += 1
            }
        }
        throw lastError is DaemonError ? lastError : DaemonError.connectionFailed(String(describing: lastError))
    }
}

/// One `NWConnection` to a Unix socket, with its errors mapped to `DaemonError`. A deadline cancels the connection
/// unless it is set again first.
final class SocketConnection: @unchecked Sendable {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "dev.subset.timer.socket")
    private let lock = NSLock()
    // Guarded by `lock`.
    private var deadlineGeneration = 0
    private var timedOut = false

    init(path: String) {
        connection = NWConnection(to: .unix(path: path), using: .tcp)
    }

    func setDeadline(_ seconds: TimeInterval) {
        let generation = lock.withLock {
            deadlineGeneration += 1
            return deadlineGeneration
        }
        queue.asyncAfter(deadline: .now() + seconds) { [self] in
            let expired = lock.withLock {
                if generation == deadlineGeneration { timedOut = true }
                return timedOut
            }
            if expired { connection.cancel() }
        }
    }

    func cancel() {
        connection.cancel()
    }

    private func mapped(_ error: Error) -> Error {
        if lock.withLock({ timedOut }) { return DaemonError.timedOut }
        if let error = error as? DaemonError { return error }
        if case .posix(let code) = error as? NWError, [.ENOENT, .ECONNREFUSED].contains(code) { return DaemonError.notListening }
        return DaemonError.connectionFailed(error.localizedDescription)
    }

    func open() async throws {
        let once = Once()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready: once.run { continuation.resume() }
                    // A missing socket leaves the connection waiting to retry; this client fails at once instead.
                    case .waiting(let error), .failed(let error):
                        connection.cancel()
                        once.run { continuation.resume(throwing: mapped(error)) }
                    case .cancelled: once.run { continuation.resume(throwing: mapped(CancellationError())) }
                    default: break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            connection.cancel()
        }
    }

    func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { [self] error in
                if let error { continuation.resume(throwing: mapped(error)) } else { continuation.resume() }
            })
        }
    }

    /// The next bytes, or nil once the daemon closed its side.
    func receive() async throws -> Data? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data?, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
                    if let data, !data.isEmpty {
                        continuation.resume(returning: data)
                    } else if let error {
                        continuation.resume(throwing: mapped(error))
                    } else {
                        continuation.resume(returning: isComplete ? nil : Data())
                    }
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    /// Reads until `parser` has something to report.
    func parse(_ parser: inout HTTPResponseParser) async throws -> [HTTPResponseParser.Event] {
        while true {
            guard let bytes = try await receive() else {
                do {
                    // A reply that had already ended reports its end again rather than nothing.
                    let events = try parser.finish()
                    return events.isEmpty ? [.end] : events
                } catch {
                    throw DaemonError.malformedReply("the connection closed before the reply was complete")
                }
            }
            let events: [HTTPResponseParser.Event]
            do {
                events = try parser.feed(bytes)
            } catch {
                throw DaemonError.malformedReply(String(describing: error))
            }
            if !events.isEmpty { return events }
        }
    }
}

/// Runs its closure at most once, from any thread.
final class Once: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}
