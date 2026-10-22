import Foundation

/// What Explain is asked about.
public enum ExplainItemKind: String, Codable, CaseIterable, Sendable {
    case processGroup, process, folder, leftover, suggestion

    public var title: String {
        switch self {
        case .processGroup: "Process group"
        case .process: "Process"
        case .folder: "Folder or file"
        case .leftover: "Leftover of an app that is not installed"
        case .suggestion: "Reclaim suggestion"
        }
    }
}

/// The facts System already has about an item, before redaction. The window models fill these in; paths are raw, and
/// evidence text must show its paths through the redactor it was given.
public struct ExplainFacts: Sendable {
    public var kind: ExplainItemKind
    public var name: String
    /// What the item is to System: "App group in the App layer", "Folder", "Safe to reclaim".
    public var type: String?
    /// The item's own path: an executable, app bundle, project folder, or scanned item.
    public var path: String?
    public var bundleID: String?
    public var signingID: String?
    public var teamID: String?
    /// The vendor: the signing team's name, or Apple.
    public var vendor: String?
    public var launchdLabel: String?
    /// Memory and CPU, or disk sizes, as text.
    public var sizes: String?
    /// How long it has run, or when it last changed.
    public var age: String?
    /// The grouping or reclaim rule that placed it.
    public var matchedRule: String?
    public var evidence: [String] = []
    /// Evidence that is System's own fixed rule text, such as a reclaim rule's location (`~/Library/Developer/Xcode/
    /// DerivedData`): it holds nothing of the user's, so its folder names are sent as they are. Sent before `evidence`.
    public var ruleEvidence: [String] = []
    /// A group's processes, or a suggestion's items, by name.
    public var members: [String] = []
    /// An Unattributed process group, the only kind that may get a suggested origin.
    public var isUnattributedGroup = false

    public init(kind: ExplainItemKind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// Names, each once in the order first seen, with how many there are: "Google Chrome Helper ×12".
    public static func countedNames(_ names: [String]) -> [String] {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for name in names {
            if counts[name] == nil { order.append(name) }
            counts[name, default: 0] += 1
        }
        return order.map { counts[$0] == 1 ? $0 : "\($0) ×\(counts[$0] ?? 0)" }
    }

    /// A duration in the largest whole unit: "3 minutes", "5 hours", "45 days".
    public static func duration(from start: Date, to now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(start))
        let (value, unit): (Int, String) = switch seconds {
        case ..<3_600: (Int(seconds / 60), "minute")
        case ..<86_400: (Int(seconds / 3_600), "hour")
        default: (Int(seconds / 86_400), "day")
        }
        return "\(value) \(unit)\(value == 1 ? "" : "s")"
    }
}

/// What is sent to the provider: the facts, redacted (`ExplainRedactor`), each field capped, and the whole kept within
/// an estimated 1,500 tokens (characters ÷ 4) with the instructions. The same contract serves SET-50's OpenRouter
/// provider, which sends it as JSON.
public struct ExplainRequest: Codable, Equatable, Sendable {
    public private(set) var kind: ExplainItemKind
    public private(set) var name: String
    public private(set) var type: String?
    public private(set) var path: String?
    public private(set) var bundleID: String?
    public private(set) var signingID: String?
    public private(set) var teamID: String?
    public private(set) var vendor: String?
    public private(set) var launchdLabel: String?
    public private(set) var sizes: String?
    public private(set) var age: String?
    public private(set) var matchedRule: String?
    public private(set) var evidence: [String]
    public private(set) var members: [String]
    /// Whether the answer may suggest an origin: only for an Unattributed process group.
    public private(set) var maySuggestOrigin: Bool
    /// Facts were shortened or left out to fit.
    public private(set) var truncated: Bool

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, name, type, path, bundleID, signingID, teamID, vendor, launchdLabel, sizes, age, matchedRule, evidence
        case members, maySuggestOrigin, truncated
    }

    /// The most tokens the instructions and the request may take together, estimated as characters ÷ 4.
    public static let tokenBudget = 1_500
    static let nameLimit = 200
    static let fieldLimit = 300
    static let evidenceLimit = 12
    static let memberLimit = 10
    static let memberNameLimit = 100

    public init(_ facts: ExplainFacts, redactor: ExplainRedactor) {
        var truncated = false
        func cap(_ value: String?, _ limit: Int = Self.fieldLimit, redactor: ExplainRedactor = redactor) -> String? {
            guard let value else { return nil }
            let text = redactor.text(value).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            guard text.count > limit else { return text }
            truncated = true
            return String(text.prefix(limit - 1)) + "…"
        }
        func list(_ values: [String], count: Int, limit: Int) -> [String] {
            if values.count > count { truncated = true }
            return values.prefix(count).compactMap { cap($0, limit) }
        }
        kind = facts.kind
        name = cap(facts.name, Self.nameLimit) ?? "Unnamed"
        type = cap(facts.type)
        path = cap(facts.path.map(redactor.path))
        bundleID = cap(facts.bundleID)
        signingID = cap(facts.signingID)
        teamID = cap(facts.teamID)
        vendor = cap(facts.vendor)
        launchdLabel = cap(facts.launchdLabel)
        sizes = cap(facts.sizes)
        age = cap(facts.age)
        matchedRule = cap(facts.matchedRule)
        let ruleEvidence = facts.ruleEvidence.prefix(Self.evidenceLimit)
            .compactMap { cap($0, redactor: redactor.sendingFolderNames(true)) }
        evidence = ruleEvidence + list(facts.evidence, count: Self.evidenceLimit - ruleEvidence.count, limit: Self.fieldLimit)
        if facts.ruleEvidence.count > Self.evidenceLimit { truncated = true }
        members = list(facts.members, count: Self.memberLimit, limit: Self.memberNameLimit)
        maySuggestOrigin = facts.kind == .processGroup && facts.isUnattributedGroup
        self.truncated = truncated
        fit()
    }

    /// The estimated tokens of the instructions and this request.
    public var estimatedTokens: Int {
        (ExplainPrompt.instructions.count + promptText.count + 3) / 4
    }

    /// Leaves out evidence, then members, then halves the longest field, until the estimate fits the budget.
    private mutating func fit() {
        let fields: [WritableKeyPath<ExplainRequest, String?>] = [
            \.type, \.path, \.bundleID, \.signingID, \.teamID, \.vendor, \.launchdLabel, \.sizes, \.age, \.matchedRule
        ]
        while estimatedTokens > Self.tokenBudget {
            truncated = true
            if !evidence.isEmpty {
                evidence.removeLast()
            } else if !members.isEmpty {
                members.removeLast()
            } else if let longest = fields.max(by: { (self[keyPath: $0]?.count ?? 0) < (self[keyPath: $1]?.count ?? 0) }),
                      let value = self[keyPath: longest], value.count > 40 {
                self[keyPath: longest] = String(value.prefix(value.count / 2)) + "…"
            } else if name.count > 40 {
                name = String(name.prefix(name.count / 2)) + "…"
            } else {
                break
            }
        }
    }

    /// The request as the prompt's text, one fact per line; a missing fact is left out.
    public var promptText: String {
        var lines = ["Item kind: \(kind.title)", "Name: \(name)"]
        let fields: [(String, String?)] = [
            ("What System knows it as", type), ("Path", path), ("Bundle ID", bundleID), ("Signing identifier", signingID),
            ("Team ID", teamID), ("Vendor", vendor), ("launchd label", launchdLabel), ("Sizes", sizes), ("Age", age),
            ("Matched rule", matchedRule)
        ]
        lines += fields.compactMap { label, value in value.map { "\(label): \($0)" } }
        if !members.isEmpty { lines.append("Members: " + members.joined(separator: ", ")) }
        if !evidence.isEmpty { lines += ["Evidence:"] + evidence.map { "- \($0)" } }
        lines.append(maySuggestOrigin
            ? "No rule identified its origin; you may suggest the app, tool, or vendor it most likely belongs to."
            : "Do not suggest an origin.")
        if truncated { lines.append("Some facts were shortened or left out to fit.") }
        return lines.joined(separator: "\n")
    }

    /// Every field sent, with what it holds, for Settings. Tests check it names every field.
    public static let fieldGuide: [ExplainField] = [
        ExplainField(.kind, "Whether it is a process group, process, folder or file, leftover, or reclaim suggestion."),
        ExplainField(.name, "The group, file, or rule name, or a placeholder when its path's last name is withheld; a "
            + "process's name as macOS reports it (its executable's), even when that name is withheld in its path."),
        ExplainField(.type, "What System knows it as, such as an app group or a folder."),
        ExplainField(.path, "Its path, with your home folder as ~ and deeper folder names, its own included, replaced "
            + "unless Send folder names is on."),
        ExplainField(.bundleID, "The app's bundle ID, never its name, for a Library entry named for an installed app; or "
            + "the app group, Apple identifier, or bundle ID a Library entry is named for. A name after a Team ID no "
            + "single installed app has is the folder's own, sent only with Send folder names."),
        ExplainField(.signingID, "The code signature's identifier."),
        ExplainField(.teamID, "The code signature's Team ID."),
        ExplainField(.vendor, "The signing team's name, or Apple."),
        ExplainField(.launchdLabel, "The launchd job's label."),
        ExplainField(.sizes, "Memory and CPU, or disk sizes, or why they were not measured, with paths redacted the same way."),
        ExplainField(.age, "How long it has run, or when it last changed."),
        ExplainField(.matchedRule, "The grouping or reclaim rule that placed it."),
        ExplainField(.evidence, "Why System grouped it there, with paths redacted the same way, and a reclaim rule's fixed "
            + "location, such as ~/Library/Developer/Xcode/DerivedData, as it is."),
        ExplainField(.members, "A group's process names, or a suggestion's item names (up to 10)."),
        ExplainField(.maySuggestOrigin, "Whether an origin may be suggested: only for an Unattributed process group."),
        ExplainField(.truncated, "Whether facts were shortened to keep the request small.")
    ]
}

/// One field Explain sends, for Settings.
public struct ExplainField: Equatable, Sendable {
    public let name: String
    public let meaning: String

    init(_ key: ExplainRequest.CodingKeys, _ meaning: String) {
        name = key.rawValue
        self.meaning = meaning
    }
}
