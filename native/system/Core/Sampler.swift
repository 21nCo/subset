import Foundation

/// Every visible process at one moment, with CPU use since the previous sample. Kept in memory only.
public struct ProcessSnapshot: Equatable, Sendable {
    /// When the sample was taken, in nanoseconds of uptime (not advancing while the Mac sleeps).
    public let uptime: UInt64
    public let processes: [ProcessFacts]
    /// Logical cores; 100% CPU per process is one of them, so the busiest possible total is `100 × cores`.
    public let logicalCoreCount: Int

    /// Summed CPU of every process with a measured value, in Activity Monitor's per-core convention, or `nil` on
    /// the first sample. Restricted processes are not included, so this is a lower bound.
    public var totalCPUPercent: Double? {
        let values = processes.compactMap(\.cpuPercent)
        return values.isEmpty ? nil : values.reduce(0, +)
    }

    /// `totalCPUPercent` as a share of the whole machine (0–100), the figure the menu bar shows.
    public var machineCPUPercent: Double? {
        guard let totalCPUPercent, logicalCoreCount > 0 else { return nil }
        return totalCPUPercent / Double(logicalCoreCount)
    }
}

/// Turns consecutive raw samples into snapshots. CPU percent for a process is its CPU time delta over the
/// wall-clock delta between two samples of the same identity. A process seen for the first time, including a new
/// process that reused an earlier PID, has no CPU value until its second sample; a process that exited is dropped.
public struct Sampler {
    private let source: any ProcessSource
    public let logicalCoreCount: Int
    private var previous: (uptime: UInt64, cpuTimes: [ProcessIdentity: UInt64])?

    public init(source: any ProcessSource, logicalCoreCount: Int = ProcessInfo.processInfo.processorCount) {
        self.source = source
        self.logicalCoreCount = logicalCoreCount
    }

    /// Reads one sample. A failed read throws and leaves the previous sample in place for the next delta.
    public mutating func sample() throws -> ProcessSnapshot {
        let raw = try source.sample()
        let uptime = raw.timebase.nanoseconds(raw.timestamp)
        var cpuTimes: [ProcessIdentity: UInt64] = [:]
        var seen = Set<ProcessIdentity>()
        var processes: [ProcessFacts] = []
        processes.reserveCapacity(raw.processes.count)

        for record in raw.processes where seen.insert(record.identity).inserted {
            var facts = ProcessFacts(record: record, timebase: raw.timebase)
            if let cpuTime = facts.totalCPUTime {
                cpuTimes[record.identity] = cpuTime
                if let previous, let before = previous.cpuTimes[record.identity] {
                    facts.cpuPercent = Self.cpuPercent(cpuDelta: (before, cpuTime), wallDelta: (previous.uptime, uptime))
                }
            }
            processes.append(facts)
        }
        previous = (uptime, cpuTimes)
        return ProcessSnapshot(uptime: uptime, processes: processes, logicalCoreCount: logicalCoreCount)
    }

    /// `nil` when either counter went backwards or no time passed, which only a broken source produces.
    static func cpuPercent(cpuDelta: (UInt64, UInt64), wallDelta: (UInt64, UInt64)) -> Double? {
        guard cpuDelta.1 >= cpuDelta.0, wallDelta.1 > wallDelta.0 else { return nil }
        return Double(cpuDelta.1 - cpuDelta.0) / Double(wallDelta.1 - wallDelta.0) * 100
    }
}

/// How often the app samples: every 2 seconds while the main window is visible, every 10 while only the menu bar
/// item is in use.
public enum SamplingCadence: Equatable, Sendable {
    case mainWindowVisible
    case menuBarOnly

    public init(mainWindowVisible: Bool) {
        self = mainWindowVisible ? .mainWindowVisible : .menuBarOnly
    }

    public var interval: Duration {
        switch self {
        case .mainWindowVisible: .seconds(2)
        case .menuBarOnly: .seconds(10)
        }
    }

    /// How long to wait before the next sample when the previous one was `elapsed` ago, so a cadence change takes
    /// effect at once without sampling more often than the new interval.
    public func delay(sinceLastSample elapsed: Duration?) -> Duration {
        guard let elapsed else { return .zero }
        return max(.zero, interval - elapsed)
    }
}
