import SystemCore

/// The menu bar's headline: the App layer's three largest groups by memory. A group without a measured memory sum
/// is never listed as zero; it is left out.
public struct TopGroups: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public let id: OriginGroupID
        public let title: String
        public let accessibilityLabel: String
    }

    public let entries: [Entry]
    /// Shown instead of the entries when there are none.
    public let placeholder: String?

    public init(attribution: AttributionResult?, samplingFailed: Bool, format: UsageFormat = UsageFormat(), count: Int = 3) {
        guard !samplingFailed else {
            entries = []
            placeholder = "Top memory: unavailable, sampling failed"
            return
        }
        guard let attribution else {
            entries = []
            placeholder = "Top memory: not measured yet"
            return
        }
        entries = UsageOrder.groups(attribution.app.filter { $0.totals.memory.sum != nil }, by: .memory)
            .prefix(count)
            .map { group in
                let memory = format.total(group.totals.memory, format.bytes)
                return Entry(id: group.id, title: "\(group.name) — \(memory)",
                             accessibilityLabel: "\(group.name), memory \(format.spokenTotal(group.totals.memory, format.bytes)). Opens System on this group.")
            }
        placeholder = entries.isEmpty ? "Top memory: no group measured" : nil
    }
}
