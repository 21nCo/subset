import Foundation
import SystemCore

/// Whether the figures on screen are current.
public enum SamplingState: Equatable, Sendable {
    /// No sample has succeeded yet.
    case waiting
    /// The latest sample is at most three intervals old; `interval` is the current one.
    case live(interval: Duration)
    /// No sample has arrived for more than three intervals (the Mac slept, or sampling stalled); the figures are
    /// from `observedAt`.
    case stale(age: Duration)
    /// The latest sample failed; the figures, if any, are from the last one that succeeded.
    case failed(String)

    /// After three missed intervals the figures are no longer called current. The interval is the longer of the
    /// current one and the one in effect when the sample was taken, since the next sample may come that late.
    static func classify(observedAt: Date?, failure: String?, cadence: SamplingCadence, sampleCadence: SamplingCadence,
                         now: Date) -> SamplingState {
        if let failure { return .failed(failure) }
        guard let observedAt else { return .waiting }
        let age = Duration.seconds(max(0, now.timeIntervalSince(observedAt)))
        let allowed = max(cadence.interval, sampleCadence.interval) * 3
        return age > allowed ? .stale(age: age) : .live(interval: cadence.interval)
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

    init(sample: ProcessesSample?, memory: SystemMemory?, failure: String?, cadence: SamplingCadence,
         sampleCadence: SamplingCadence, now: Date, format: UsageFormat) {
        let summary = StatusSummary(snapshot: sample?.snapshot, memory: memory, samplingFailed: failure != nil)
        pressure = summary.pressure
        pressureText = summary.pressureRow
        pressureSymbol = summary.pressureSymbolName
        memoryText = "Used \(format.bytes(memory?.used)) of \(format.bytes(memory?.physicalMemory)) · "
            + "App \(format.bytes(memory?.app)) · Compressed \(format.bytes(memory?.compressed))"
        swapText = "Swap \(format.bytes(memory?.swapUsed)) of \(format.bytes(memory?.swapTotal))"
        cpuText = summary.cpuRow(logicalCoreCount: sample?.snapshot.logicalCoreCount)
        if let processes = sample?.snapshot.processes {
            let restricted = processes.filter(\.restricted).count
            processText = "\(processes.count) processes · \(restricted) restricted by macOS"
        } else {
            processText = "No processes sampled yet"
        }
        observedText = sample.map { "Observed at \(format.time($0.observedAt))" } ?? "Not observed yet"
        state = SamplingState.classify(observedAt: sample?.observedAt, failure: failure, cadence: cadence,
                                       sampleCadence: sampleCadence, now: now)
        switch state {
        case .waiting:
            stateText = "Waiting for the first sample"
        case let .live(interval):
            stateText = "Sampling every \(interval.components.seconds) s"
        case let .stale(age):
            stateText = "Stale: no sample for \(age.components.seconds) s; figures are from the last sample"
        case let .failed(message):
            stateText = "Sampling failed: \(message)" + (sample == nil ? "" : "; figures are from the last sample")
        }
    }
}
