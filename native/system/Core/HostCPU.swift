import Foundation

/// `host_statistics(HOST_CPU_LOAD_INFO)`: scheduler ticks summed over every logical core since boot. Unlike the
/// per-process counters, any user may read these, so they cover the processes macOS restricts too.
public struct HostCPUTicks: Equatable, Sendable {
    public let user: UInt32
    public let system: UInt32
    public let idle: UInt32
    public let nice: UInt32

    public init(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32) {
        self.user = user
        self.system = system
        self.idle = idle
        self.nice = nice
    }

    /// The share of the whole machine (0–100) that was busy between two readings, or `nil` when no tick passed or
    /// a counter went backwards. The 32-bit counters wrap after weeks of uptime and reset only on reboot; either
    /// gives one unavailable interval rather than a wrong figure.
    public static func busyPercent(from before: Self, to after: Self) -> Double? {
        func delta(_ path: KeyPath<Self, UInt32>) -> UInt64? {
            after[keyPath: path] >= before[keyPath: path] ? UInt64(after[keyPath: path] - before[keyPath: path]) : nil
        }
        guard let user = delta(\.user), let system = delta(\.system), let idle = delta(\.idle), let nice = delta(\.nice)
        else { return nil }
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return nil }
        return Double(busy) / Double(total) * 100
    }
}

/// Reads the machine's CPU tick counters, or `nil` when the read fails.
public protocol HostCPUSource: Sendable {
    func read() -> HostCPUTicks?
}

/// Reads this Mac's CPU tick counters.
public struct LiveHostCPUSource: HostCPUSource {
    public init() {}

    public func read() -> HostCPUTicks? {
        var info = host_cpu_load_info()
        // HOST_CPU_LOAD_INFO_COUNT is a macro Swift does not import.
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(MachHost.port, HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks
        // Indexed by CPU_STATE_USER, CPU_STATE_SYSTEM, CPU_STATE_IDLE, CPU_STATE_NICE.
        return HostCPUTicks(user: ticks.0, system: ticks.1, idle: ticks.2, nice: ticks.3)
    }
}

/// Replays recorded tick readings in order, then reports a failed read.
public final class FixtureHostCPUSource: HostCPUSource, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [HostCPUTicks?]

    public init(_ readings: [HostCPUTicks?]) {
        remaining = readings
    }

    public func read() -> HostCPUTicks? {
        lock.withLock { remaining.isEmpty ? nil : remaining.removeFirst() }
    }
}

enum MachHost {
    /// `mach_host_self` adds a send right on every call; take one and keep it for the life of the process.
    static let port = mach_host_self()
}
