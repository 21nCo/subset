import Foundation
import Observation
import SystemCore

/// The System window's state, testable without the UI: the layer, sort, filter, expansion, and selection, the rows
/// they produce from the latest sample, the header, the footnote, and the selected row's detail.
///
/// Group identities are the same in every sample (`OriginGroupID`), so expansion and selection survive new samples.
/// Each layer remembers its own selection: switching back restores it while its group still exists. A selected
/// process stays selected across layers, since every layer places it.
@MainActor
@Observable
public final class ProcessesWindowModel {
    public private(set) var sample: ProcessesSample?
    public private(set) var memory: SystemMemory?
    /// Why the latest sample failed, or `nil` when it succeeded.
    public private(set) var failure: String?
    public private(set) var cadence: SamplingCadence = .mainWindowVisible

    public var layer: AttributionLayer = .app {
        didSet { if layer != oldValue { layerDidChange() } }
    }
    public var sortKey: UsageSortKey = .memory {
        didSet { if sortKey != oldValue { rebuild() } }
    }
    /// Shows groups and processes whose name contains this text; a group whose name matches shows all its members.
    public var filter = "" {
        didSet {
            guard filter != oldValue else { return }
            filterCollapsed = []
            rebuild()
        }
    }
    public var selection: RowID? {
        didSet { selections[layer] = selection }
    }
    /// The visible rows, in outline order.
    public private(set) var rows: [ProcessRow] = []
    /// Bumped to ask the view to focus the filter field (⌘F).
    public private(set) var filterFocusRequest = 0

    public let format: UsageFormat

    @ObservationIgnored private var selections: [AttributionLayer: RowID] = [:]
    @ObservationIgnored private var expanded: Set<OriginGroupID> = []
    /// Groups the filter opened because a member matches, and which of them the user closed again.
    @ObservationIgnored private var filterOpened: Set<OriginGroupID> = []
    @ObservationIgnored private var filterCollapsed: Set<OriginGroupID> = []
    @ObservationIgnored private var parents: [RowID: RowID] = [:]
    @ObservationIgnored private var facts: [ProcessIdentity: ProcessFacts] = [:]
    @ObservationIgnored private var groups: [OriginGroupID: OriginGroup] = [:]
    @ObservationIgnored private var names: [Int32: String] = [:]

    public init(format: UsageFormat = UsageFormat()) {
        self.format = format
    }

    // MARK: Samples

    /// Shows a new sample. A selection whose group or process is gone is cleared; a selected process that exited
    /// leaves its group selected while that group still exists.
    public func apply(_ sample: ProcessesSample, memory: SystemMemory?, cadence: SamplingCadence) {
        let previous = self.sample?.attribution
        self.sample = sample
        self.memory = memory
        self.cadence = cadence
        failure = nil
        index(sample)
        if let selection, !exists(selection) {
            self.selection = fallback(for: selection, previous: previous)
        }
        rebuild()
    }

    /// Records a failed sample. The last good sample stays on screen, marked as not current.
    public func applyFailure(_ message: String, memory: SystemMemory?) {
        failure = message
        self.memory = memory
    }

    public func setCadence(_ cadence: SamplingCadence) {
        self.cadence = cadence
    }

    public func header(now: Date) -> WindowHeader {
        WindowHeader(sample: sample, memory: memory, failure: failure, cadence: cadence, now: now, format: format)
    }

    /// Memory totals double-count shared pages, and restricted processes are a separate count, never zero.
    public var footnote: String? {
        guard let processes = sample?.snapshot.processes else { return nil }
        let restricted = processes.filter(\.restricted).count
        let memoryNote = "Memory totals are approximate: memory shared between processes is counted once for each process."
        guard restricted > 0 else { return memoryNote }
        let count = restricted == 1 ? "1 process is" : "\(restricted) processes are"
        return memoryNote + " \(count) restricted by macOS: their usage is unknown and is left out of totals, not counted as zero."
    }

    // MARK: Outline

    public func isExpanded(_ id: OriginGroupID) -> Bool {
        filterOpened.contains(id) ? !filterCollapsed.contains(id) : expanded.contains(id)
    }

    public func setExpanded(_ id: OriginGroupID, _ open: Bool) {
        if filterOpened.contains(id) {
            if open { filterCollapsed.remove(id) } else { filterCollapsed.insert(id) }
        } else if open {
            expanded.insert(id)
        } else {
            expanded.remove(id)
        }
        rebuild()
    }

    public func toggle(_ id: OriginGroupID) {
        setExpanded(id, !isExpanded(id))
    }

    /// Right arrow: expands the selected group.
    public func expandSelection() {
        guard case let .group(id)? = selection, !isExpanded(id) else { return }
        setExpanded(id, true)
    }

    /// Left arrow: collapses the selected group, or else selects the row it is in.
    public func collapseSelection() {
        guard let selection else { return }
        if case let .group(id) = selection, isExpanded(id) {
            setExpanded(id, false)
        } else if let parent = parents[selection] {
            self.selection = parent
        }
    }

    /// ⌘F.
    public func focusFilter() {
        filterFocusRequest += 1
    }

    /// Shows a group, as the menu bar's top groups do: switches to its layer, opens the group holding a subgroup,
    /// clears a filter that hides it, and selects it.
    public func reveal(_ id: OriginGroupID) {
        layer = id.layer
        if id.subgroup != nil { setExpanded(id.parent, true) }
        selection = .group(id)
        if !rows.contains(where: { $0.id == .group(id) }) { filter = "" }
    }

    // MARK: Detail

    /// The selected row's detail, or `nil` when nothing is selected or the selection is gone.
    public var detail: RowDetail? {
        switch selection {
        case let .group(id)?: groups[id].map(groupDetail)
        case let .process(identity)?: facts[identity].map(processDetail)
        case nil: nil
        }
    }

    private func groupDetail(_ group: OriginGroup) -> RowDetail {
        let totals = group.totals
        var fields = [
            DetailField("Processes", String(totals.processCount)),
            DetailField("Restricted", totals.restrictedCount == 0
                ? "None"
                : "\(totals.restrictedCount): usage unknown, left out of totals"),
            DetailField("CPU", format.spokenTotal(totals.cpuPercent, format.percent)),
            DetailField("Memory", format.spokenTotal(totals.memory, format.bytes)),
            DetailField("Energy used", format.spokenTotal(totals.ownEnergy, format.energy)),
            DetailField("Billed energy", format.spokenTotal(totals.energy, format.energy))
        ]
        let path = Self.path(of: group.id)
        if let path { fields.insert(DetailField("Path", path), at: 0) }
        var runtime: String?
        if case let .containerVM(name) = group.id.origin { runtime = name }
        return RowDetail(
            title: group.name, subtitle: "\(group.id.subgroup == nil ? "Group" : "Subgroup") in the \(layer.title) layer",
            placement: nil, fields: fields, path: path, containerRuntime: runtime, process: nil
        )
    }

    private func processDetail(_ process: ProcessFacts) -> RowDetail {
        let explanation = OriginExplanation(process: process, format: format) { [names] in names[$0] }
        let placement = sample?.attribution.attribution(of: process.identity).map {
            PlacementDetail(layer: layer, attribution: $0, explanation: explanation) { [groups] id in
                groups[id]?.name ?? id.description
            }
        }
        let parent = names[process.ppid].map { "\($0), pid \(process.ppid)" } ?? "pid \(process.ppid)"
        let unmeasured = process.restricted ? "Restricted" : "Not measured"
        let fields = [
            DetailField("Executable", process.executablePath ?? "No path; the kernel reports none"),
            DetailField("PID", String(process.pid)),
            DetailField("Parent", parent),
            DetailField("Team ID", teamID(process)),
            DetailField("launchd label", launchdLabel(process)),
            DetailField("Restricted", process.restricted ? "Yes: macOS denied reading its usage" : "No"),
            DetailField("CPU", process.cpuPercent.map(format.percent) ?? unmeasured),
            DetailField("Memory", process.physFootprint.map(format.bytes) ?? unmeasured),
            DetailField("Energy used", process.energy.map(format.energy) ?? unmeasured)
        ]
        return RowDetail(
            title: process.name, subtitle: "Process \(process.pid)", placement: placement, fields: fields,
            path: process.executablePath, containerRuntime: nil, process: process
        )
    }

    private func teamID(_ process: ProcessFacts) -> String {
        guard let signature = process.origin?.codeSignature else { return "Not read yet" }
        switch signature {
        case let .value(value, _):
            return value.teamID ?? (value.isPlatformBinary ? "None (Apple platform binary)" : "None")
        case let .unavailable(failure, _):
            return "Unavailable: \(failure.reason)"
        }
    }

    private func launchdLabel(_ process: ProcessFacts) -> String {
        guard process.origin != nil else { return "Not read yet" }
        return process.launchdLabel ?? "None identified"
    }

    /// What a row's Reveal in Finder and Copy path act on: a process's executable, or the app bundle or folder a group
    /// stands for. `nil` when there is none, and the actions are not offered.
    public func path(for row: RowID) -> String? {
        switch row {
        case let .group(id): Self.path(of: id)
        case let .process(identity): facts[identity]?.executablePath
        }
    }

    /// The file or folder a group stands for, for Reveal in Finder and Copy path.
    static func path(of id: OriginGroupID) -> String? {
        guard id.subgroup == nil else { return id.subgroup?.hasPrefix("/") == true ? id.subgroup : nil }
        switch id.origin {
        case let .app(path), let .loginItem(path), let .project(path): return path
        case let .unattributed(executable): return executable.hasPrefix("/") ? executable : nil
        default: return nil
        }
    }

    // MARK: Building rows

    private func index(_ sample: ProcessesSample) {
        facts = Dictionary(sample.snapshot.processes.map { ($0.identity, $0) }, uniquingKeysWith: { first, _ in first })
        names = Dictionary(sample.snapshot.processes.map { ($0.pid, $0.name) }, uniquingKeysWith: { first, _ in first })
        var groups: [OriginGroupID: OriginGroup] = [:]
        for layer in AttributionLayer.allCases {
            for group in sample.attribution.groups(layer) {
                groups[group.id] = group
                for subgroup in group.subgroups { groups[subgroup.id] = subgroup }
            }
        }
        self.groups = groups
    }

    private func exists(_ row: RowID) -> Bool {
        switch row {
        case let .group(id): groups[id] != nil
        case let .process(identity): facts[identity] != nil
        }
    }

    /// For a process that exited: its subgroup, else its group, in the current layer, while that still exists.
    private func fallback(for row: RowID, previous: AttributionResult?) -> RowID? {
        guard case let .process(identity) = row, let placed = previous?.attribution(of: identity) else { return nil }
        let (group, subgroup) = Self.placement(placed, layer)
        return [subgroup, group].compactMap { $0 }.first { groups[$0] != nil }.map(RowID.group)
    }

    private func layerDidChange() {
        if case let .process(identity)? = selection, facts[identity] != nil {
            if let placed = sample?.attribution.attribution(of: identity) {
                let (group, subgroup) = Self.placement(placed, layer)
                expanded.insert(group)
                if let subgroup { expanded.insert(subgroup) }
            }
            selections[layer] = selection
        } else {
            selection = selections[layer].flatMap { exists($0) ? $0 : nil }
        }
        rebuild()
    }

    static func placement(_ attribution: ProcessAttribution, _ layer: AttributionLayer) -> (OriginGroupID, OriginGroupID?) {
        switch layer {
        case .app: (attribution.app.group, attribution.app.subgroup)
        case .vendor: (attribution.vendor.group, attribution.vendor.subgroup)
        case .launchSource: (attribution.launchSource.group, attribution.launchSource.subgroup)
        case .project: (attribution.project.group, attribution.project.subgroup)
        }
    }

    private func rebuild() {
        var rows: [ProcessRow] = []
        parents = [:]
        filterOpened = []
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        for group in UsageOrder.groups(sample?.attribution.groups(layer) ?? [], by: sortKey) {
            append(group, depth: 0, parent: nil, query: query.isEmpty ? nil : query, into: &rows)
        }
        self.rows = rows
    }

    private func append(_ group: OriginGroup, depth: Int, parent: RowID?, query: String?, into rows: inout [ProcessRow]) {
        // A group whose name matches shows everything in it; otherwise only what matches.
        let childQuery = query.flatMap { group.name.localizedCaseInsensitiveContains($0) ? nil : $0 }
        let inSubgroup = Set(group.subgroups.flatMap(\.members))
        let processes = group.members.filter { !inSubgroup.contains($0) }.compactMap { facts[$0] }
            .filter { process in childQuery.map { process.name.localizedCaseInsensitiveContains($0) } ?? true }
        let subgroups = group.subgroups.filter { subgroup in childQuery.map { matches(subgroup, $0) } ?? true }
        if childQuery != nil {
            guard !processes.isEmpty || !subgroups.isEmpty else { return }
            filterOpened.insert(group.id)
        }
        let open = isExpanded(group.id)
        let id = RowID.group(group.id)
        rows.append(.group(group, depth: depth, isExpanded: open, format: format))
        if let parent { parents[id] = parent }
        guard open else { return }
        for subgroup in UsageOrder.groups(subgroups, by: sortKey) {
            append(subgroup, depth: depth + 1, parent: id, query: childQuery, into: &rows)
        }
        for process in UsageOrder.processes(processes, by: sortKey) {
            rows.append(.process(process, depth: depth + 1, format: format))
            parents[.process(process.identity)] = id
        }
    }

    private func matches(_ group: OriginGroup, _ query: String) -> Bool {
        group.name.localizedCaseInsensitiveContains(query)
            || group.members.contains { facts[$0]?.name.localizedCaseInsensitiveContains(query) == true }
    }
}

/// A labeled value in the detail pane.
public struct DetailField: Equatable, Sendable {
    public let label: String
    public let value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Why a process is in its group in one layer.
public struct PlacementDetail: Equatable, Sendable {
    public let group: String
    public let rule: String
    public let confidence: AttributionConfidence
    public let evidence: [String]
    /// Later rules that matched another group (App layer only).
    public let conflicts: [String]

    init(layer: AttributionLayer, attribution: ProcessAttribution, explanation: OriginExplanation,
         groupName: (OriginGroupID) -> String) {
        func make<Rule>(_ placement: Placement<Rule>, _ rule: String) -> (String, String, AttributionConfidence, [String], [String]) {
            let group = groupName(placement.group) + (placement.subgroup.map { " › \(groupName($0))" } ?? "")
            return (group, rule, placement.confidence, placement.evidence.map(explanation.describe),
                    placement.conflicts.map { explanation.describe($0, groupName: groupName($0.group)) })
        }
        let values = switch layer {
        case .app: make(attribution.app, OriginExplanation.rule(attribution.app.rule))
        case .vendor: make(attribution.vendor, OriginExplanation.rule(attribution.vendor.rule))
        case .launchSource: make(attribution.launchSource, OriginExplanation.rule(attribution.launchSource.rule))
        case .project: make(attribution.project, OriginExplanation.rule(attribution.project.rule))
        }
        (group, rule, confidence, evidence, conflicts) = values
    }
}

/// The detail pane for the selected group or process.
public struct RowDetail: Equatable, Sendable {
    public let title: String
    public let subtitle: String
    /// For a process: its placement in the current layer.
    public let placement: PlacementDetail?
    public let fields: [DetailField]
    /// What Reveal in Finder and Copy path act on: the executable, or the app bundle or folder a group stands for.
    public let path: String?
    /// For a container VM's group, the runtime's name, so the view can show the containers inside it.
    public let containerRuntime: String?
    /// For a process, its facts, so the view can show the raw origin signals.
    public let process: ProcessFacts?
}
