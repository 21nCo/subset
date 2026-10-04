import Foundation

// An AX observer is usable only after every requested notification is registered.
// Failed attempts leave the foreground eligible for a bounded heartbeat retry.
public struct ObserverRetryState {
    public private(set) var registeredPID: Int32?
    public private(set) var consecutiveFailures = 0
    private var nextAttemptAt: TimeInterval = 0

    public init() {}

    public func shouldAttempt(pid: Int32, at uptime: TimeInterval) -> Bool {
        registeredPID != pid && uptime >= nextAttemptAt
    }

    public mutating func succeeded(pid: Int32) {
        registeredPID = pid
        consecutiveFailures = 0
        nextAttemptAt = 0
    }

    public mutating func failed(at uptime: TimeInterval) {
        registeredPID = nil
        consecutiveFailures += 1
        nextAttemptAt = uptime + 2
    }

    public mutating func reset() {
        registeredPID = nil
        consecutiveFailures = 0
        nextAttemptAt = 0
    }
}
