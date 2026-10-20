import Foundation
import SystemCore

/// Whether the figures on screen are current.
public enum SamplingState: Equatable, Sendable {
    /// No sample has been attempted yet.
    case waiting
    /// The latest sample is at most three intervals old; `interval` is the current one.
    case live(interval: Duration)
    /// No sample has been attempted for more than three intervals (the Mac slept, or sampling stalled); `failure`
    /// is why the last attempt failed, or `nil` when it succeeded.
    case stale(age: Duration, failure: String?)
    /// The latest sample, at most three intervals old, failed; the process figures, if any, are from the last one
    /// that succeeded.
    case failed(String)

    /// After three missed intervals the figures are no longer called current. The interval is the longer of the
    /// current one and the one in effect at the last attempt, since the next attempt may come that late.
    static func classify(lastAttempt: Date?, failure: String?, cadence: SamplingCadence, attemptCadence: SamplingCadence,
                         now: Date) -> SamplingState {
        guard let lastAttempt else { return .waiting }
        let age = Self.age(of: lastAttempt, now: now)
        if age > allowedAge(cadence: cadence, attemptCadence: attemptCadence) { return .stale(age: age, failure: failure) }
        if let failure { return .failed(failure) }
        return .live(interval: cadence.interval)
    }

    static func allowedAge(cadence: SamplingCadence, attemptCadence: SamplingCadence) -> Duration {
        max(cadence.interval, attemptCadence.interval) * 3
    }

    static func age(of date: Date, now: Date) -> Duration {
        .seconds(max(0, now.timeIntervalSince(date)))
    }
}

/// The window header: memory pressure, used, app, and compressed memory, swap, total CPU, logical cores, when the
/// figures were observed, and whether sampling is keeping up.
public struct WindowHeader: Equatable, Sendable {
    public let pressure: MemoryPressure?
    public let pressureText: String
    /// The menu bar's pressure symbol, whose needle rises with the level.
    public let pressureSymbol: String
    public let memoryText: String
    public let swapText: String
    public let cpuText: String
    public let processText: String
    public let observedText: String
    public let state: SamplingState
    public let stateText: String

    /// `memoryObservedAt` is when `memory` was read; `failure` is the latest attempt's, with when it was made.
    init(sample: ProcessesSample?, memory: SystemMemory?, memoryObservedAt: Date?, failure: (message: String, at: Date)?,
         cadence: SamplingCadence, attemptCadence: SamplingCadence, logicalCoreCount: Int, now: Date, format: UsageFormat) {
        let summary = StatusSummary(snapshot: sample?.snapshot, memory: memory, samplingFailed: failure != nil)
        pressure = summary.pressure
        pressureText = summary.pressureRow
        pressureSymbol = summary.pressureSymbolName
        memoryText = "Used \(format.bytes(memory?.used)) of \(format.bytes(memory?.physicalMemory)) · "
            + "App \(format.bytes(memory?.app)) · Compressed \(format.bytes(memory?.compressed))"
        swapText = "Swap \(format.bytes(memory?.swapUsed)) of \(format.bytes(memory?.swapTotal))"
        // The core count is shown even while CPU use is unknown.
        cpuText = summary.cpuRow(logicalCoreCount: nil)
            + " · \(sample?.snapshot.logicalCoreCount ?? logicalCoreCount) logical cores"
        if let processes = sample?.snapshot.processes {
            let restricted = processes.filter(\.restricted).count
            processText = "\(processes.count) processes · \(restricted) restricted by macOS"
        } else {
            processText = "No processes sampled yet"
        }
        observedText = sample.map { "Observed at \(format.time($0.observedAt))" } ?? "Not observed yet"
        state = SamplingState.classify(lastAttempt: failure?.at ?? sample?.observedAt, failure: failure?.message,
                                       cadence: cadence, attemptCadence: attemptCadence, now: now)
        // After a failure the process figures are the last good sample's and the memory figures are from their own
        // read: each says when it was observed, and memory is called current only while that read is.
        let processClause = sample.map { "; process figures are from the sample observed at \(format.time($0.observedAt))" } ?? ""
        var memoryClause = ""
        if memory != nil, let memoryObservedAt {
            let allowed = SamplingState.allowedAge(cadence: cadence, attemptCadence: attemptCadence)
            memoryClause = SamplingState.age(of: memoryObservedAt, now: now) > allowed
                ? "; memory figures are from \(format.time(memoryObservedAt))"
                : "; memory figures are current"
        }
        switch state {
        case .waiting:
            stateText = "Waiting for the first sample"
        case let .live(interval):
            stateText = "Sampling every \(interval.components.seconds) s"
        case let .stale(age, nil):
            stateText = "Stale: no sample for \(age.components.seconds) s; figures are from the last sample"
        case let .stale(age, message?):
            stateText = "Stale: no sample attempted for \(age.components.seconds) s; the last one failed: \(message)"
                + processClause + memoryClause
        case let .failed(message):
            stateText = "Sampling failed: \(message)" + processClause + memoryClause
        }
    }
}
