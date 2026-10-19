/// A group's usage, summed from its members. A member without a value (restricted, a failed read, or a first sample
/// for CPU) is counted as unmeasured, never as zero.
public struct GroupTotals: Equatable, Sendable {
    public let processCount: Int
    /// Members whose usage macOS refused to reveal. Their usage is in no sum: it is unknown, not zero.
    public let restrictedCount: Int
    /// Physical footprint in bytes. Approximate: memory shared between members counts once per member.
    public let memory: MetricTotal<UInt64>
    /// CPU percent, where 100 is one fully used logical core.
    public let cpuPercent: MetricTotal<Double>
    /// The members' own energy (`ri_energy_nj`) in nanojoules since each started.
    public let energy: MetricTotal<UInt64>
    /// Nanojoules billed to the members for other processes' work on their behalf (`ri_billed_energy`). SET-42 asked
    /// for this sum as the group's energy; SET-40 found it is not a process's own energy, so `energy` carries that.
    public let billedEnergy: MetricTotal<UInt64>

    init<Members: Sequence>(_ members: Members) where Members.Element == ProcessFacts {
        var count = 0, restricted = 0
        var memory = MetricTotal<UInt64>.Builder(isApproximate: true)
        var cpu = MetricTotal<Double>.Builder()
        var energy = MetricTotal<UInt64>.Builder()
        var billed = MetricTotal<UInt64>.Builder()
        for process in members {
            count += 1
            if process.restricted { restricted += 1 }
            memory.add(process.physFootprint) { $0.addingSaturating($1) }
            cpu.add(process.cpuPercent) { $0 + $1 }
            energy.add(process.energy) { $0.addingSaturating($1) }
            billed.add(process.billedEnergy) { $0.addingSaturating($1) }
        }
        processCount = count
        restrictedCount = restricted
        self.memory = memory.total
        cpuPercent = cpu.total
        self.energy = energy.total
        billedEnergy = billed.total
    }
}

/// One summed figure and how many members it covers.
public struct MetricTotal<Value: Equatable & Sendable>: Equatable, Sendable {
    /// The sum over measured members; `nil` when no member was measured.
    public let sum: Value?
    public let measuredCount: Int
    /// Members without a value, restricted ones included.
    public let unmeasuredCount: Int
    /// The figure double-counts shared resources, so it is shown as approximate (memory).
    public let isApproximate: Bool

    /// Every member was measured.
    public var isComplete: Bool { unmeasuredCount == 0 }

    struct Builder {
        var sum: Value?
        var measured = 0
        var unmeasured = 0
        let isApproximate: Bool

        init(isApproximate: Bool = false) {
            self.isApproximate = isApproximate
        }

        mutating func add(_ value: Value?, _ combine: (Value, Value) -> Value) {
            guard let value else { unmeasured += 1; return }
            measured += 1
            sum = sum.map { combine($0, value) } ?? value
        }

        var total: MetricTotal {
            MetricTotal(sum: sum, measuredCount: measured, unmeasuredCount: unmeasured, isApproximate: isApproximate)
        }
    }
}

extension UInt64 {
    func addingSaturating(_ other: UInt64) -> UInt64 {
        let (sum, overflow) = addingReportingOverflow(other)
        return overflow ? .max : sum
    }
}
