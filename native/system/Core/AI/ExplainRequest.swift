import Foundation

/// What Explain is asked about.
public enum ExplainItemKind: String, Encodable, CaseIterable, Sendable {
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

/// The facts System already has about an item, before redaction. The window models fill these in with structured
/// values only: names and identifiers, raw paths (`path`, and each evidence's), System's own fixed text for the type,
/// sizes, age, and rule, and closed categories for what could not be measured or read. No tool message, error text,
/// or command text goes in.
public struct ExplainFacts: Sendable {
    public var kind: ExplainItemKind
    /// The item's name, as the redactor names it when it is taken from a path.
    public var name: String
    /// What the item is to System, in System's fixed words: "Group in the App layer", "Folder", "Safe to reclaim
    /// suggestion". Never a name or path.
    public var type: String?
    /// For a process, the group it is in, named as that group is.
    public var group: String?
    /// The item's own path: an executable, app bundle, project folder, or scanned item.
    public var path: String?
    /// The installed app it belongs to, by name.
    public var app: String?
    public var bundleID: String?
    public var signingID: String?
    public var teamID: String?
    /// The vendor: the signing team's name, or Apple.
    public var vendor: String?
    public var launchdLabel: String?
    /// Memory and CPU, or disk sizes, as System formats its numbers.
    public var sizes: String?
    /// Why a suggestion's space was not measured.
    public var notMeasured: ExplainNotMeasured?
    /// How long it has run, or when it last changed.
    public var age: String?
    /// The grouping or reclaim rule that placed it, in the rule's fixed words.
    public var matchedRule: String?
    public var evidence: [Evidence] = []
    /// A group's processes, or a suggestion's items, by name.
    public var members: [String] = []
    /// An Unattributed process group, the only kind that may get a suggested origin.
    public var isUnattributedGroup = false

    public init(kind: ExplainItemKind, name: String) {
        self.kind = kind
        self.name = name
    }

    /// One piece of evidence before redaction: its path is raw.
    public struct Evidence: Sendable {
        public var kind: ExplainEvidence.Kind
        public var path: String?
        public var name: String?
        public var identifier: String?
        public var failure: ExplainFailure?

        public init(_ kind: ExplainEvidence.Kind, path: String? = nil, name: String? = nil, identifier: String? = nil,
                    failure: ExplainFailure? = nil) {
            self.kind = kind
            self.path = path
            self.name = name
            self.identifier = identifier
            self.failure = failure
        }
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

    /// `countedNames(_:)` of the first names of `items` that a request keeps, for names that are costly to make: items
    /// with the same `key` have the same name, and `name` is called once per key, in the order first seen, only until
    /// `limit` different names are found, while every item is counted. So a suggestion of many thousand items redacts
    /// about `limit` paths, not one per item. Two keys whose names turn out the same are counted as one name when both
    /// are found.
    public static func countedNames<Item, Key: Hashable>(_ items: [Item], limit: Int, key: (Item) -> Key,
                                                         name: (Item) -> String) -> [String] {
        var order: [Key] = []
        var first: [Key: Item] = [:]
        var counts: [Key: Int] = [:]
        for item in items {
            let key = key(item)
            if counts[key] == nil {
                order.append(key)
                first[key] = item
            }
            counts[key, default: 0] += 1
        }
        var names: [String] = []
        var nameCounts: [String: Int] = [:]
        for key in order where names.count < limit {
            guard let item = first[key] else { continue }
            let name = name(item)
            if nameCounts[name] == nil { names.append(name) }
            nameCounts[name, default: 0] += counts[key] ?? 0
        }
        return names.map { nameCounts[$0] == 1 ? $0 : "\($0) ×\(nameCounts[$0] ?? 0)" }
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

/// What is sent to the provider: structured fields only. Paths are values of their own (`ExplainPath`), redacted
/// component by component (`ExplainRedactor`); names and identifiers have account names removed, System's own words
/// (the type, sizes, age, and rule) are sent as they are; why something was
/// not measured or read is a closed category. No field holds a tool's message, error text, or command text, so no
/// text is scanned for paths. Every string value is kept on one line (`oneLine`), so the prompt's lines are System's
/// own. Each field is capped, and the whole is kept within an estimated 1,500 tokens
/// (characters ÷ 4) with the instructions. The same contract serves SET-50's OpenRouter provider, which sends it as
/// JSON.
public struct ExplainRequest: Encodable, Equatable, Sendable {
    public private(set) var kind: ExplainItemKind
    public private(set) var name: String
    public private(set) var type: String?
    public private(set) var group: String?
    public private(set) var path: ExplainPath?
    public private(set) var app: String?
    public private(set) var bundleID: String?
    public private(set) var signingID: String?
    public private(set) var teamID: String?
    public private(set) var vendor: String?
    public private(set) var launchdLabel: String?
    public private(set) var sizes: String?
    public private(set) var notMeasured: ExplainNotMeasured?
    public private(set) var age: String?
    public private(set) var matchedRule: String?
    public private(set) var evidence: [ExplainEvidence]
    public private(set) var members: [String]
    /// Whether the answer may suggest an origin: only for an Unattributed process group.
    public private(set) var maySuggestOrigin: Bool
    /// Facts were shortened or left out to fit.
    public private(set) var truncated: Bool

    public enum CodingKeys: String, CodingKey, CaseIterable {
        case kind, name, type, group, path, app, bundleID, signingID, teamID, vendor, launchdLabel, sizes, notMeasured
        case age, matchedRule, evidence, members, maySuggestOrigin, truncated
    }

    /// The most tokens the instructions and the request may take together, estimated as characters ÷ 4.
    public static let tokenBudget = 1_500
    static let nameLimit = 200
    static let fieldLimit = 300
    /// A reclaim rule's fixed words: its name, what the data is, where it is, how it comes back, and what a cleanup frees.
    static let ruleLimit = 700
    static let evidenceLimit = 12
    public static let memberLimit = 10
    static let memberNameLimit = 100

    public init(_ facts: ExplainFacts, redactor: ExplainRedactor) {
        var truncated = false
        // System's own words (`type`, `sizes`, `age`, `matchedRule`) hold no name, so account names are removed only
        // from names and identifiers: a short name that is also a word ("in") leaves System's words as they are.
        func cap(_ value: String?, _ limit: Int = Self.fieldLimit, systemWords: Bool = false) -> String? {
            guard let value else { return nil }
            let line = Self.oneLine(value)
            let text = (systemWords ? line : redactor.removingAccountNames(line)).trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            guard text.count > limit else { return text }
            truncated = true
            return String(text.prefix(limit - 1)) + "…"
        }
        func capPath(_ path: String?) -> ExplainPath? {
            guard let path, !path.isEmpty else { return nil }
            let sent = redactor.path(path)
            guard sent.value.count > Self.fieldLimit else { return sent }
            truncated = true
            return ExplainPath(String(sent.value.prefix(Self.fieldLimit - 1)) + "…")
        }
        func list<T>(_ values: [T], count: Int, _ transform: (T) -> String?) -> [String] {
            if values.count > count { truncated = true }
            return values.prefix(count).compactMap(transform)
        }
        kind = facts.kind
        name = cap(facts.name, Self.nameLimit) ?? "Unnamed"
        type = cap(facts.type, systemWords: true)
        group = cap(facts.group, Self.nameLimit)
        path = capPath(facts.path)
        app = cap(facts.app, Self.nameLimit)
        bundleID = cap(facts.bundleID)
        signingID = cap(facts.signingID)
        teamID = cap(facts.teamID)
        vendor = cap(facts.vendor)
        launchdLabel = cap(facts.launchdLabel)
        sizes = cap(facts.sizes, systemWords: true)
        notMeasured = facts.notMeasured
        age = cap(facts.age, systemWords: true)
        matchedRule = cap(facts.matchedRule, Self.ruleLimit, systemWords: true)
        if facts.evidence.count > Self.evidenceLimit { truncated = true }
        evidence = facts.evidence.prefix(Self.evidenceLimit).map { item in
            ExplainEvidence(kind: item.kind, path: capPath(item.path), name: cap(item.name, Self.memberNameLimit),
                            identifier: cap(item.identifier, Self.memberNameLimit), failure: item.failure)
        }
        members = list(facts.members, count: Self.memberLimit) { cap($0, Self.memberNameLimit) }
        maySuggestOrigin = facts.kind == .processGroup && facts.isUnattributedGroup
        self.truncated = truncated
        fit()
    }

    /// `text` on one line: every control, format, line separator, and paragraph separator character (a line break, a
    /// tab, a bidirectional override) becomes a space. Every string value sent, each path included, goes through it, so
    /// no value can start a line of the prompt that reads as one of System's own facts.
    static func oneLine(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator: scalars.append(" ")
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The estimated tokens of the instructions and this request.
    public var estimatedTokens: Int {
        (ExplainPrompt.instructions.count + promptText.count + 3) / 4
    }

    /// Leaves out evidence, then members, then halves the longest field, until the estimate fits the budget.
    private mutating func fit() {
        let fields: [WritableKeyPath<ExplainRequest, String?>] = [
            \.type, \.group, \.app, \.bundleID, \.signingID, \.teamID, \.vendor, \.launchdLabel, \.sizes, \.age,
            \.matchedRule
        ]
        while estimatedTokens > Self.tokenBudget {
            truncated = true
            let longest = fields.max { (self[keyPath: $0]?.count ?? 0) < (self[keyPath: $1]?.count ?? 0) }
            let longestCount = longest.flatMap { self[keyPath: $0]?.count } ?? 0
            if !evidence.isEmpty {
                evidence.removeLast()
            } else if !members.isEmpty {
                members.removeLast()
            } else if let path, path.value.count > max(40, longestCount) {
                self.path = ExplainPath(String(path.value.prefix(path.value.count / 2)) + "…")
            } else if let longest, let value = self[keyPath: longest], value.count > 40 {
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
            ("What System knows it as", type), ("Group", group), ("Path", path?.value), ("App", app),
            ("Bundle ID", bundleID), ("Signing identifier", signingID), ("Team ID", teamID), ("Vendor", vendor),
            ("launchd label", launchdLabel), ("Sizes", sizes), ("Not measured because", notMeasured?.title),
            ("Age", age), ("Matched rule", matchedRule)
        ]
        lines += fields.compactMap { label, value in value.map { "\(label): \($0)" } }
        if !members.isEmpty { lines.append("Members: " + members.joined(separator: ", ")) }
        if !evidence.isEmpty { lines += ["Evidence:"] + evidence.map { "- \($0.line)" } }
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
        ExplainField(.type, "What System knows it as, in System's own words, such as a group in the App layer or a folder."),
        ExplainField(.group, "For a process, its group's name, withheld as the group's own name is."),
        ExplainField(.path, "Its path, with your home folder as ~ and deeper folder names, its own included, replaced "
            + "unless Send folder names is on."),
        ExplainField(.app, "The installed app it belongs to, named as its group is in Processes."),
        ExplainField(.bundleID, "The app's bundle ID for a Library entry named for an installed app; or the app group, "
            + "Apple identifier, or bundle ID a Library entry is named for. A name after a Team ID no single installed "
            + "app has is the folder's own, sent only with Send folder names."),
        ExplainField(.signingID, "The code signature's identifier."),
        ExplainField(.teamID, "The code signature's Team ID; for a group, only when every process's signature was "
            + "read and has it."),
        ExplainField(.vendor, "The signing team's name, or Apple; for a group, only when every process's signature was "
            + "read and names that vendor."),
        ExplainField(.launchdLabel, "The launchd job's label."),
        ExplainField(.sizes, "Memory and CPU, or disk sizes."),
        ExplainField(.notMeasured, "Why a suggestion's space was not measured, as one of a fixed list of reasons; never "
            + "a tool's message."),
        ExplainField(.age, "How long it has run, or when it last changed."),
        ExplainField(.matchedRule, "The grouping or reclaim rule that placed it, in the rule's own words."),
        ExplainField(.evidence, "Why System placed it there, each as a fixed kind with the path, name, or identifier it "
            + "names, paths redacted the same way; an unavailable signal's reason as one of a fixed list."),
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
