import Foundation
import SystemCore

/// One sample as the window shows it: the processes, their attribution, and when it was taken.
public struct ProcessesSample: Sendable {
    public let snapshot: ProcessSnapshot
    public let attribution: AttributionResult
    /// Wall-clock time the sample was taken.
    public let observedAt: Date

    public init(snapshot: ProcessSnapshot, attribution: AttributionResult, observedAt: Date) {
        self.snapshot = snapshot
        self.attribution = attribution
        self.observedAt = observedAt
    }
}

/// A row of the outline. Group IDs carry their layer, and a process appears once per layer, so either identifies one
/// row.
public enum RowID: Hashable, Sendable {
    case group(OriginGroupID)
    case process(ProcessIdentity)
}

/// What the window can sort by, largest first.
public enum UsageSortKey: String, CaseIterable, Sendable {
    case cpu, memory, energy

    public var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .energy: "Energy"
        }
    }
}

extension AttributionLayer {
    public var title: String {
        switch self {
        case .app: "App"
        case .vendor: "Vendor"
        case .launchSource: "Launch source"
        case .project: "Project"
        }
    }
}

/// One visible row: a group, a subgroup, or a process, with its figures as text and as spoken text.
public struct ProcessRow: Identifiable, Equatable, Sendable {
    public let id: RowID
    /// 0 for a group, 1 for a subgroup or a group's process, 2 for a subgroup's process.
    public let depth: Int
    public let name: String
    /// "12 processes · 2 restricted" for a group, "pid 123" for a process.
    public let detail: String
    public let isExpandable: Bool
    public let isExpanded: Bool
    public let cpu: String
    public let memory: String
    public let energy: String
    /// Members whose usage macOS refused to reveal; for a process, 1 when it is restricted.
    public let restrictedCount: Int
    public let accessibilityLabel: String
    public let accessibilityValue: String

    static func group(_ group: OriginGroup, depth: Int, isExpanded: Bool, format: UsageFormat) -> ProcessRow {
        let totals = group.totals
        let count = totals.processCount == 1 ? "1 process" : "\(totals.processCount) processes"
        let restricted = totals.restrictedCount > 0 ? " · \(totals.restrictedCount) restricted" : ""
        let kind = depth == 0 ? "group" : "subgroup"
        let cpu = format.spokenTotal(totals.cpuPercent, format.percent)
        let memory = format.spokenTotal(totals.memory, format.bytes)
        let energy = format.spokenTotal(totals.ownEnergy, format.energy)
        let spokenRestricted = totals.restrictedCount > 0 ? ", \(totals.restrictedCount) restricted by macOS" : ""
        // An unattributed process without a path or kernel name gives its group an empty name.
        let name = group.name.isEmpty ? "Unnamed" : group.name
        return ProcessRow(
            id: .group(group.id), depth: depth, name: name, detail: count + restricted, isExpandable: true,
            isExpanded: isExpanded,
            cpu: format.total(totals.cpuPercent, format.percent),
            memory: format.total(totals.memory, format.bytes),
            energy: format.total(totals.ownEnergy, format.energy),
            restrictedCount: totals.restrictedCount,
            accessibilityLabel: "\(name), \(kind), \(count), \(isExpanded ? "expanded" : "collapsed")",
            accessibilityValue: "CPU \(cpu), memory \(memory), energy \(energy)\(spokenRestricted)"
        )
    }

    static func process(_ process: ProcessFacts, depth: Int, format: UsageFormat) -> ProcessRow {
        let unmeasured = process.restricted ? "Restricted" : "–"
        let spokenUnmeasured = process.restricted ? "restricted by macOS" : "not measured"
        let name = process.name.isEmpty ? "Unnamed" : process.name
        return ProcessRow(
            id: .process(process.identity), depth: depth, name: name, detail: "pid \(process.pid)",
            isExpandable: false, isExpanded: false,
            cpu: process.cpuPercent.map(format.percent) ?? unmeasured,
            memory: process.physFootprint.map(format.bytes) ?? unmeasured,
            energy: process.energy.map(format.energy) ?? unmeasured,
            restrictedCount: process.restricted ? 1 : 0,
            accessibilityLabel: "\(name), process \(process.pid)",
            accessibilityValue: process.restricted
                ? "Usage restricted by macOS"
                : "CPU \(process.cpuPercent.map(format.percent) ?? spokenUnmeasured), "
                    + "memory \(process.physFootprint.map(format.bytes) ?? spokenUnmeasured), "
                    + "energy \(process.energy.map(format.energy) ?? spokenUnmeasured)"
        )
    }
}

/// Sort order, largest first. A missing value sorts last; ties go by name, then identity, so the order is stable
/// from sample to sample.
enum UsageOrder {
    static func groups(_ groups: [OriginGroup], by key: UsageSortKey) -> [OriginGroup] {
        groups.sorted { lhs, rhs in
            switch compare(value(lhs.totals, key), value(rhs.totals, key)) {
            case .orderedAscending: return false
            case .orderedDescending: return true
            case .orderedSame:
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.id < rhs.id : byName == .orderedAscending
            }
        }
    }

    static func processes(_ processes: [ProcessFacts], by key: UsageSortKey) -> [ProcessFacts] {
        processes.sorted { lhs, rhs in
            switch compare(value(lhs, key), value(rhs, key)) {
            case .orderedAscending: return false
            case .orderedDescending: return true
            case .orderedSame:
                let byName = lhs.name.localizedStandardCompare(rhs.name)
                return byName == .orderedSame ? lhs.identity < rhs.identity : byName == .orderedAscending
            }
        }
    }

    private static func value(_ totals: GroupTotals, _ key: UsageSortKey) -> Double? {
        switch key {
        case .cpu: totals.cpuPercent.sum
        case .memory: totals.memory.sum.map(Double.init)
        case .energy: totals.ownEnergy.sum.map(Double.init)
        }
    }

    private static func value(_ process: ProcessFacts, _ key: UsageSortKey) -> Double? {
        switch key {
        case .cpu: process.cpuPercent
        case .memory: process.physFootprint.map(Double.init)
        case .energy: process.energy.map(Double.init)
        }
    }

    /// A present value is larger than a missing one.
    private static func compare(_ lhs: Double?, _ rhs: Double?) -> ComparisonResult {
        switch (lhs, rhs) {
        case (nil, nil): .orderedSame
        case (nil, _): .orderedAscending
        case (_, nil): .orderedDescending
        case let (lhs?, rhs?): lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
        }
    }
}
