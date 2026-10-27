import Foundation
import SystemCore

/// What Ask's process tools (SET-51) read: the latest sample's groups and the memory read with it, redacted as Explain
/// redacts (SET-49). Nothing here changes the window.
extension ProcessesWindowModel {
    /// The `limit` largest groups of `layer` by `metric`, as the window orders them, with whether they are current.
    public func askTopGroups(by metric: AskMetric, layer: AttributionLayer, limit: Int, redactor: ExplainRedactor,
                             now: Date = .now) -> AskOutput {
        guard let sample else {
            return AskOutput(askSampling(now: now).merging(["status": .words("No process sample yet.")]) { $1 })
        }
        let key: UsageSortKey = switch metric {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .energy
        }
        let groups = UsageOrder.groups(sample.attribution.groups(layer), by: key)
        return AskOutput(askSampling(now: now).merging([
            "layer": .words(layer.title),
            "orderedBy": .words(key.title),
            "groups": .count(groups.count)
        ]) { $1 }, entries: groups.prefix(limit).map { AskEntry(.group($0.id), askFields($0, redactor: redactor)) })
    }

    /// A group's facts, as Explain sends them, its subgroups, and whether they are current; `nil` when it is no longer in
    /// the sample.
    public func askGroupDetail(_ id: OriginGroupID, redactor: ExplainRedactor, now: Date = .now) -> AskOutput? {
        guard let group = groups[id], let request = explainRequest(for: .group(id), redactor: redactor) else { return nil }
        let subgroups = UsageOrder.groups(group.subgroups, by: .memory).prefix(ExplainRequest.memberLimit)
        return AskOutput(askSampling(now: now).merging([
            "group": .facts(request),
            "energyUsed": .words(format.spokenTotal(group.totals.ownEnergy, format.energy)),
            "subgroups": .count(group.subgroups.count)
        ]) { $1 }, entries: subgroups.map { AskEntry(.group($0.id), askFields($0, redactor: redactor)) })
    }

    /// The latest memory read, with when it was made and whether it is current, and the header's CPU and process
    /// counts with the process sample's state. A failed process sample still reads memory, so the two are told apart.
    public func askMemoryState(now: Date = .now) -> AskOutput {
        let header = header(now: now)
        guard let memory, let memoryObservedAt else {
            return AskOutput(askSampling(header).merging(["status": .words("Memory has not been read yet.")]) { $1 })
        }
        let allowed = SamplingState.allowedAge(cadence: cadence, attemptCadence: attemptCadence)
        let memoryCurrent = SamplingState.age(of: memoryObservedAt, now: now) <= allowed
        let fields: [String: AskValue] = [
            "pressure": .words(memory.pressure?.title ?? "Unknown"),
            "physicalMemory": .words(format.bytes(memory.physicalMemory)),
            "used": .words(format.bytes(memory.used)),
            "app": .words(format.bytes(memory.app)),
            "wired": .words(format.bytes(memory.wired)),
            "compressed": .words(format.bytes(memory.compressed)),
            "swapUsed": .words(format.bytes(memory.swapUsed)),
            "swapTotal": .words(format.bytes(memory.swapTotal)),
            "memoryRead": .words("Read at \(format.time(memoryObservedAt))"),
            "memoryReading": .words(memoryCurrent ? "Current" : "Stale: no recent memory read"),
            "cpu": .words(header.cpuText),
            "processes": .words(header.processText)
        ]
        return AskOutput(askSampling(header).merging(fields) { $1 })
    }

    /// When the figures were observed and whether they are current, without a failure's message: the window keeps the
    /// last good sample's groups after a failed or late sample, so every tool that reads them says so.
    private func askSampling(now: Date) -> [String: AskValue] {
        askSampling(header(now: now))
    }

    private func askSampling(_ header: WindowHeader) -> [String: AskValue] {
        let sampling = switch header.state {
        case .waiting: "Waiting for the first sample"
        case .live: "Current"
        case .stale: "Stale: no recent sample"
        case .failed: "The latest sample failed; process figures are from the one before"
        }
        return ["sample": .words(header.observedText), "sampling": .words(sampling)]
    }

    private func askFields(_ group: OriginGroup, redactor: ExplainRedactor) -> [String: AskValue] {
        let totals = group.totals
        var fields: [String: AskValue] = [
            "name": .name(Self.explainName(group.id, group.displayName, redactor: redactor)),
            "processes": .count(totals.processCount),
            "memory": .words(format.spokenTotal(totals.memory, format.bytes)),
            "cpu": .words(format.spokenTotal(totals.cpuPercent, format.percent) + " of one core"),
            "energyUsed": .words(format.spokenTotal(totals.ownEnergy, format.energy))
        ]
        if totals.restrictedCount > 0 { fields["restrictedProcesses"] = .count(totals.restrictedCount) }
        if let path = Self.path(of: group.id) { fields["path"] = .path(redactor.path(path)) }
        if !group.subgroups.isEmpty { fields["subgroups"] = .count(group.subgroups.count) }
        return fields
    }
}
