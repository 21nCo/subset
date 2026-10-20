/// Collects one layer's placements into groups and subgroups with their totals and display names.
enum GroupBuilder {
    static func groups(_ layer: AttributionLayer, processes: [ProcessFacts], attributions: [ProcessAttribution]) -> [OriginGroup] {
        var members: [OriginGroupID: [Int]] = [:]
        var subgroups: [OriginGroupID: [OriginGroupID: [Int]]] = [:]
        for (index, attribution) in attributions.enumerated() {
            let group = attribution.group(layer)
            members[group, default: []].append(index)
            if let subgroup = attribution.subgroup(layer) {
                subgroups[group, default: [:]][subgroup, default: []].append(index)
            }
        }
        func group(_ id: OriginGroupID, _ indices: [Int], subgroups: [OriginGroup] = []) -> OriginGroup {
            let facts = indices.map { processes[$0] }
            return OriginGroup(id: id, name: name(id, members: facts), members: facts.map(\.identity),
                               totals: GroupTotals(facts), subgroups: subgroups)
        }
        return members.keys.sorted().map { id in
            let subs = (subgroups[id] ?? [:]).sorted { $0.key < $1.key }.map { group($0.key, $0.value) }
            return group(id, members[id] ?? [], subgroups: subs)
        }
    }

    /// The name a group is shown with. A team's name comes from its members' signatures; when they disagree, the
    /// first in sort order is used, so the name does not change with process order.
    static func name(_ id: OriginGroupID, members: [ProcessFacts]) -> String {
        if let subgroup = id.subgroup {
            if case .macOS = id.origin { return subgroup }
            return lastComponent(subgroup)
        }
        switch id.origin {
        case let .app(bundlePath):
            let file = lastComponent(bundlePath)
            return file.hasSuffix(".app") ? String(file.dropLast(4)) : file
        case .macOS: return "macOS"
        case let .containerVM(name): return name
        case let .agent(name): return "Agent: \(name)"
        case .terminal: return "Terminal"
        case let .homebrew(formula): return formula.map { "Homebrew: \($0)" } ?? "Homebrew"
        case let .team(id), let .vendor(id): return teamName(id, members: members) ?? "Team \(id)"
        case let .unattributed(executable): return executable
        case .apple: return "Apple"
        case .unsigned: return "Unsigned"
        case .signatureUnavailable: return "Signature unavailable"
        case let .launchdJob(label): return label
        case let .loginItem(bundlePath): return "Login item: \(name(OriginGroupID(.app(bundlePath: bundlePath)), members: []))"
        case let .codingAgentSession(name): return "Coding agent: \(name)"
        case .terminalSession: return "Terminal session"
        case .appLaunched: return "Launched by an app"
        case .system: return "System"
        case let .project(path): return lastComponent(path)
        case .noProject: return "No project"
        }
    }

    private static func teamName(_ teamID: String, members: [ProcessFacts]) -> String? {
        members.compactMap { process in
            guard let signature = process.origin?.codeSignature.value, signature.teamID == teamID else { return nil }
            return signature.teamName
        }.min()
    }

    private static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

extension OriginGroupID {
    /// The name this group has, or would have, with these members: how to name a group a placement or conflict
    /// points to when the sample has no group for it. A team's name comes from the members' signatures.
    public func name(members: [ProcessFacts]) -> String {
        GroupBuilder.name(self, members: members)
    }
}
