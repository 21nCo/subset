import Foundation

/// Keeps a subscription to the daemon's `/v1/events` open: parses each stream, and when one ends or fails,
/// waits with exponential backoff and connects again until the consuming task is cancelled.
public enum EventSubscription {
    public enum Update: Sendable {
        case connected
        case event(ServerSentEvent)
        /// The stream ended (`error` is nil) or could not be opened; the next attempt follows after `retryIn` seconds.
        case disconnected(error: Error?, retryIn: TimeInterval)
    }

    public struct Backoff: Sendable {
        public var initial: TimeInterval = 0.5
        public var maximum: TimeInterval = 10

        public init() {}

        /// The wait after `failures` attempts in a row that did not connect; the first wait is `initial`.
        public func delay(after failures: Int) -> TimeInterval {
            min(maximum, initial * pow(2, Double(min(failures, 16))))
        }
    }

    public typealias Connect = @Sendable () async throws -> AsyncThrowingStream<Data, Error>
    public typealias Sleep = @Sendable (TimeInterval) async throws -> Void

    public static func updates(connect: @escaping Connect, backoff: Backoff = Backoff(),
                               sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) -> AsyncStream<Update> {
        AsyncStream { continuation in
            let task = Task {
                var failures = 0
                while !Task.isCancelled {
                    var failure: Error?
                    do {
                        let bytes = try await connect()
                        failures = 0
                        continuation.yield(.connected)
                        var parser = ServerSentEventParser()
                        for try await chunk in bytes {
                            for event in parser.feed(chunk) { continuation.yield(.event(event)) }
                        }
                    } catch {
                        failure = error
                    }
                    if Task.isCancelled { break }
                    let delay = backoff.delay(after: failures)
                    failures += 1
                    continuation.yield(.disconnected(error: failure, retryIn: delay))
                    do { try await sleep(delay) } catch { break }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
