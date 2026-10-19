/// A process as one sample saw it. `(pid, startTime)` identifies it, so a PID the kernel reuses for a later process
/// is a different process. Values macOS refuses to reveal are `nil` with `restricted` set, never zero.
public struct ProcessFacts: Identifiable, Equatable, Sendable {
    public let identity: ProcessIdentity
    public let ppid: Int32
    /// Effective user ID.
    public let uid: UInt32
    /// From `proc_pidpath`; `nil` when the kernel has no path (kernel_task, some exited images). Command-line
    /// arguments are never read: they can hold secrets.
    public let executablePath: String?
    public let name: String
    /// True when macOS denied the usage read (`EPERM`, typically another user's process). The usage values are
    /// then `nil`.
    public let restricted: Bool

    /// `ri_phys_footprint` in bytes: the figure Activity Monitor shows as Memory.
    public let physFootprint: UInt64?
    /// Total user-mode CPU time in nanoseconds.
    public let userCPUTime: UInt64?
    /// Total kernel-mode CPU time in nanoseconds.
    public let systemCPUTime: UInt64?
    /// `ri_energy_nj`: nanojoules the process's own work has used since it started. This is the process's energy.
    public let energy: UInt64?
    /// `ri_billed_energy`: nanojoules billed to this process since it started for work other processes did on its
    /// behalf (voucher accounting). It is not the process's own energy and is usually far below `energy`.
    public let billedEnergy: UInt64?
    /// CPU use since the previous sample, where 100 is one fully used logical core (Activity Monitor's
    /// convention). `nil` on a process's first sample or when its usage is unavailable.
    public internal(set) var cpuPercent: Double?

    // Origin signals, filled by SET-41. Always nil here.
    public var responsiblePID: Int32?
    public var coalitionID: UInt64?
    public var teamID: String?
    public var signingID: String?
    public var isPlatformBinary: Bool?
    public var launchdLabel: String?
    public var workingDirectory: String?
    public var tty: String?

    public var id: ProcessIdentity { identity }
    public var pid: Int32 { identity.pid }

    public init(record: RawProcessRecord, timebase: MachTimebase, cpuPercent: Double? = nil) {
        identity = record.identity
        ppid = record.ppid
        uid = record.uid
        executablePath = record.executablePath
        name = record.name
        switch record.usage {
        case let .available(usage):
            restricted = false
            physFootprint = usage.physFootprint
            userCPUTime = timebase.nanoseconds(usage.userTime)
            systemCPUTime = timebase.nanoseconds(usage.systemTime)
            energy = usage.energy
            billedEnergy = usage.billedEnergy
        case .restricted, .unavailable:
            restricted = record.usage == .restricted
            physFootprint = nil
            userCPUTime = nil
            systemCPUTime = nil
            energy = nil
            billedEnergy = nil
        }
        self.cpuPercent = cpuPercent
    }

    /// User plus system CPU time in nanoseconds, when both are known.
    public var totalCPUTime: UInt64? {
        guard let userCPUTime, let systemCPUTime else { return nil }
        let (sum, overflow) = userCPUTime.addingReportingOverflow(systemCPUTime)
        return overflow ? nil : sum
    }
}

/// A PID alone is reused by later processes; its start time (microseconds since 1970) tells them apart.
public struct ProcessIdentity: Hashable, Comparable, Sendable {
    public let pid: Int32
    public let startTime: UInt64

    public init(pid: Int32, startTime: UInt64) {
        self.pid = pid
        self.startTime = startTime
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        (lhs.pid, lhs.startTime) < (rhs.pid, rhs.startTime)
    }
}

/// Usage counters exactly as `proc_pid_rusage` reports them: CPU times in Mach absolute time units.
public struct RawProcessUsage: Equatable, Sendable {
    public let physFootprint: UInt64
    public let userTime: UInt64
    public let systemTime: UInt64
    /// `ri_energy_nj`, the process's own energy in nanojoules.
    public let energy: UInt64
    /// `ri_billed_energy`, nanojoules billed to the process for other processes' work on its behalf.
    public let billedEnergy: UInt64

    public init(physFootprint: UInt64, userTime: UInt64, systemTime: UInt64, energy: UInt64, billedEnergy: UInt64) {
        self.physFootprint = physFootprint
        self.userTime = userTime
        self.systemTime = systemTime
        self.energy = energy
        self.billedEnergy = billedEnergy
    }
}

/// The outcome of reading one process's usage.
public enum UsageReading: Equatable, Sendable {
    case available(RawProcessUsage)
    /// macOS denied the read (`EPERM`).
    case restricted
    /// The read failed for another reason.
    case unavailable
}

/// One process as a `ProcessSource` read it, before unit conversion.
public struct RawProcessRecord: Equatable, Sendable {
    public let identity: ProcessIdentity
    public let ppid: Int32
    public let uid: UInt32
    public let executablePath: String?
    public let name: String
    public let usage: UsageReading

    public init(identity: ProcessIdentity, ppid: Int32, uid: UInt32, executablePath: String?, name: String, usage: UsageReading) {
        self.identity = identity
        self.ppid = ppid
        self.uid = uid
        self.executablePath = executablePath
        self.name = name
        self.usage = usage
    }
}

/// Every visible process at one moment. `timestamp` is `mach_absolute_time`, which stops while the Mac sleeps,
/// as CPU time does.
public struct RawProcessSample: Equatable, Sendable {
    public let timestamp: UInt64
    public let timebase: MachTimebase
    public let processes: [RawProcessRecord]

    public init(timestamp: UInt64, timebase: MachTimebase, processes: [RawProcessRecord]) {
        self.timestamp = timestamp
        self.timebase = timebase
        self.processes = processes
    }
}

/// `mach_timebase_info`: nanoseconds = ticks × numer / denom. It is 1/1 on Intel and 125/3 on Apple silicon.
public struct MachTimebase: Equatable, Sendable {
    public let numer: UInt32
    public let denom: UInt32

    public init(numer: UInt32, denom: UInt32) {
        self.numer = numer
        self.denom = denom
    }

    /// Converts without intermediate overflow; saturates at `UInt64.max`. A zero term (never reported by the
    /// kernel) is treated as 1.
    public func nanoseconds(_ ticks: UInt64) -> UInt64 {
        let numer = UInt64(max(numer, 1))
        let denom = UInt64(max(denom, 1))
        let product = ticks.multipliedFullWidth(by: numer)
        guard product.high < denom else { return .max }
        return denom.dividingFullWidth(product).quotient
    }
}
