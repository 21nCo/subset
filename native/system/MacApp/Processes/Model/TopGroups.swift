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

/// The menu's top-group rows: a fixed number of standing slots that are updated in place, never replaced. While the
/// menu is open a new sample's groups wait until it next opens, so the row under the pointer or keyboard keeps the
/// group it shows and a click opens that group.
public struct TopGroupsMenuState: Sendable {
    public static let slotCount = 3

    /// What the menu shows.
    public private(set) var shown = TopGroups(attribution: nil, samplingFailed: false)
    private var pending: TopGroups?
    private var isOpen = false

    public init() {}

    /// One entry per slot, `nil` for a slot to hide.
    public var slots: [TopGroups.Entry?] {
        (0..<Self.slotCount).map { $0 < shown.entries.count ? shown.entries[$0] : nil }
    }

    /// Takes a sample's groups. Returns whether `shown` changed, so the menu needs redrawing.
    public mutating func receive(_ topGroups: TopGroups) -> Bool {
        guard !isOpen else {
            pending = topGroups
            return false
        }
        pending = nil
        return show(topGroups)
    }

    /// Shows any groups that arrived while the menu was open. Returns whether `shown` changed.
    public mutating func menuWillOpen() -> Bool {
        isOpen = true
        defer { pending = nil }
        return pending.map { show($0) } ?? false
    }

    /// Groups that arrive from now on are shown at once. A pending set waits for the next sample or the next open,
    /// so the action of the item just chosen, which AppKit may send after this, still finds the group it showed.
    public mutating func menuDidClose() {
        isOpen = false
    }

    private mutating func show(_ topGroups: TopGroups) -> Bool {
        guard topGroups != shown else { return false }
        shown = topGroups
        return true
    }
}
