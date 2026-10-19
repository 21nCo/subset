import Foundation

/// Every visible process at one moment, with CPU use since the previous sample. Kept in memory only.
public struct ProcessSnapshot: Equatable, Sendable {
    /// When the sample was taken, in nanoseconds of uptime (not advancing while the Mac sleeps).
    public let uptime: UInt64
    public let processes: [ProcessFacts]
    /// Logical cores; 100% CPU per process is one of them, so the busiest possible total is `100 × cores`.
    public let logicalCoreCount: Int
    /// The whole machine's busy share (0–100) since the previous sample, from the host's CPU ticks, so it includes
    /// processes whose own usage is restricted. `nil` on the first sample or when the ticks could not be read.
    public let machineCPUPercent: Double?
}

/// Turns consecutive raw samples into snapshots. CPU percent for a process is its CPU time delta over the
/// wall-clock delta between two samples of the same identity. A process seen for the first time, including a new
/// process that reused an earlier PID, has no CPU value until its second sample; a process that exited is dropped.
public struct Sampler {
    private let source: any ProcessSource
    private let hostCPU: (any HostCPUSource)?
    public let logicalCoreCount: Int
    private var previous: (uptime: UInt64, cpuTimes: [ProcessIdentity: UInt64])?
    private var previousTicks: HostCPUTicks?

    /// Without `hostCPU`, snapshots have no machine CPU figure.
    public init(
        source: any ProcessSource,
        hostCPU: (any HostCPUSource)? = nil,
        logicalCoreCount: Int = ProcessInfo.processInfo.processorCount
    ) {
        self.source = source
        self.hostCPU = hostCPU
        self.logicalCoreCount = logicalCoreCount
    }

    /// Reads one sample. A failed read throws and leaves the previous sample in place for the next delta.
    public mutating func sample() throws -> ProcessSnapshot {
        let raw = try source.sample()
        let ticks = hostCPU?.read()
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
        var machineCPUPercent: Double?
        if let before = previousTicks, let ticks {
            machineCPUPercent = HostCPUTicks.busyPercent(from: before, to: ticks)
        }
        previousTicks = ticks
        return ProcessSnapshot(
            uptime: uptime,
            processes: processes,
            logicalCoreCount: logicalCoreCount,
            machineCPUPercent: machineCPUPercent
        )
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
}

/// When the app may start its next sample: never while one is running, and never sooner than the cadence's
/// interval after the previous sample started, so a cadence change takes effect at once without sampling twice in
/// a row.
public struct SamplingSchedule: Sendable {
    public private(set) var lastStart: ContinuousClock.Instant?
    public private(set) var isSampling = false

    public init() {}

    /// How long to wait before trying to sample. While a sample runs, check again after a full interval.
    public func delay(for cadence: SamplingCadence, now: ContinuousClock.Instant) -> Duration {
        guard !isSampling else { return cadence.interval }
        guard let lastStart else { return .zero }
        return max(.zero, cadence.interval - (now - lastStart))
    }

    /// Marks a sample as started, or returns `false` when one is already running.
    public mutating func begin(at now: ContinuousClock.Instant) -> Bool {
        guard !isSampling else { return false }
        isSampling = true
        lastStart = now
        return true
    }

    public mutating func finish() {
        isSampling = false
    }
}
