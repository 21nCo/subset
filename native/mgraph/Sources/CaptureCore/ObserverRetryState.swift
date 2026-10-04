import Foundation

// An AX observer is usable only after every requested notification is registered.
// Failed attempts leave the foreground eligible for a bounded heartbeat retry.
public struct ObserverRetryState {
    public private(set) var registeredPID: Int32?
    public private(set) var consecutiveFailures = 0
    private var nextAttemptAt: TimeInterval = 0

    /// Begins with no registered app and no retry delay.
    public init() {}

    /// Returns true only when this PID lacks a complete registration and its backoff has elapsed.
    public func shouldAttempt(pid: Int32, at uptime: TimeInterval) -> Bool {
        registeredPID != pid && uptime >= nextAttemptAt
    }

    /// Marks a complete observer registration and clears earlier failure diagnostics.
    public mutating func succeeded(pid: Int32) {
        registeredPID = pid
        consecutiveFailures = 0
        nextAttemptAt = 0
    }

    /// Defers another registration attempt by two seconds after a partial or total failure.
    public mutating func failed(at uptime: TimeInterval) {
        registeredPID = nil
        consecutiveFailures += 1
        nextAttemptAt = uptime + 2
    }

    /// Drops registration and backoff state when the foreground app or permission changes.
    public mutating func reset() {
        registeredPID = nil
        consecutiveFailures = 0
        nextAttemptAt = 0
    }
}
