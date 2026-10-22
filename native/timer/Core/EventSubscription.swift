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

    /// The updates, produced only as the consumer asks for them: each one connects, reads, or waits out the backoff
    /// in the consuming task, so a consumer that stops reading stops the reads too and holds at most one read's events.
    public static func updates(connect: @escaping Connect, backoff: Backoff = Backoff(),
                               sleep: @escaping Sleep = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) -> AsyncStream<Update> {
        let pump = Pump(connect: connect, backoff: backoff, sleep: sleep)
        return AsyncStream(unfolding: { await pump.next() })
    }

    /// The subscription's state between updates. Its stream's iterator calls `next()` one call at a time.
    private final class Pump: @unchecked Sendable {
        let connect: Connect
        let backoff: Backoff
        let sleep: Sleep
        var bytes: AsyncThrowingStream<Data, Error>.AsyncIterator?
        var parser = ServerSentEventParser()
        var events: [ServerSentEvent] = []
        var failures = 0
        var retryIn: TimeInterval?
        var finished = false

        init(connect: @escaping Connect, backoff: Backoff, sleep: @escaping Sleep) {
            self.connect = connect
            self.backoff = backoff
            self.sleep = sleep
        }

        func next() async -> Update? {
            if !events.isEmpty { return .event(events.removeFirst()) }
            if finished || Task.isCancelled { return finish() }
            if var iterator = bytes {
                do {
                    while let chunk = try await iterator.next() {
                        events = parser.feed(chunk)
                        if !events.isEmpty {
                            bytes = iterator
                            return .event(events.removeFirst())
                        }
                    }
                    return disconnected(nil)
                } catch {
                    return disconnected(error)
                }
            }
            if let delay = retryIn {
                retryIn = nil
                do { try await sleep(delay) } catch { return finish() }
            }
            do {
                bytes = try await connect().makeAsyncIterator()
                parser = ServerSentEventParser()
                failures = 0
                return .connected
            } catch {
                return disconnected(error)
            }
        }

        private func disconnected(_ error: Error?) -> Update? {
            bytes = nil
            if Task.isCancelled { return finish() }
            let delay = backoff.delay(after: failures)
            failures += 1
            retryIn = delay
            return .disconnected(error: error, retryIn: delay)
        }

        private func finish() -> Update? {
            finished = true
            bytes = nil
            return nil
        }
    }
}
