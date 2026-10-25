import Foundation

/// The six tools Ask (SET-51) offers the model. Each only reads the latest sample or scan already in memory: none
/// changes anything, starts a scan, or starts a cleanup, and an answer can only select what it cites.
public enum AskTool: String, CaseIterable, Sendable {
    case topGroups, groupDetail, memoryState, diskSummary, largestItems, reclaimSuggestions

    /// What the model is told the tool does.
    public var summary: String {
        switch self {
        case .topGroups: "The largest process groups in the latest sample by CPU, memory, or energy, in one grouping "
            + "layer, each with its id."
        case .groupDetail: "One process group's facts: what it is, its usage, its processes, and why System placed them "
            + "there. Takes a group id a tool returned, like g1."
        case .memoryState: "The Mac's memory now: pressure, used, app, wired, and compressed memory, and swap."
        case .diskSummary: "The scanned volume's capacity, available and purgeable space, and the latest disk scan's "
            + "folder, state, and total."
        case .largestItems: "The largest files and packages in the latest disk scan, anywhere in it, each with its id."
        case .reclaimSuggestions: "The latest disk scan's reclaim suggestions: what each rule found, its risk, and how "
            + "much space it uses, each with its id."
        }
    }

    var parameters: [AskParameter] {
        switch self {
        case .topGroups: [
            AskParameter("metric", .choice(AskMetric.allCases.map(\.rawValue)), required: true,
                         "cpu, memory, or energy"),
            AskParameter("layer", .choice(AttributionLayer.allCases.map(\.rawValue)), required: false,
                         "How processes are grouped: app (the default), vendor, launchSource, or project"),
            AskParameter("limit", .count(1...10), required: false, "How many groups, 1 to 10; 5 by default")
        ]
        case .groupDetail: [AskParameter("id", .id(AskTarget.groupPrefix), required: true, "A group id, like g1")]
        case .largestItems: [AskParameter("limit", .count(1...20), required: false, "How many items, 1 to 20; 10 by default")]
        case .memoryState, .diskSummary, .reclaimSuggestions: []
        }
    }

    /// The parameters as a JSON schema, as OpenRouter's `tools` take it.
    var schema: [String: Any] {
        var properties: [String: Any] = [:]
        for parameter in parameters {
            var property: [String: Any] = ["description": parameter.description]
            switch parameter.kind {
            case let .choice(values): property.merge(["type": "string", "enum": values]) { $1 }
            case let .count(range): property.merge(["type": "integer", "minimum": range.lowerBound,
                                                    "maximum": range.upperBound]) { $1 }
            case .id: property["type"] = "string"
            }
            properties[parameter.name] = property
        }
        return ["type": "object", "properties": properties,
                "required": parameters.filter(\.required).map(\.name), "additionalProperties": false]
    }
}

/// One argument a tool takes, and the values it accepts.
struct AskParameter {
    enum Kind {
        case choice([String])
        case count(ClosedRange<Int>)
        /// An id a tool returned in this thread, with this prefix.
        case id(String)
    }

    let name: String
    let kind: Kind
    let required: Bool
    let description: String

    init(_ name: String, _ kind: Kind, required: Bool, _ description: String) {
        self.name = name
        self.kind = kind
        self.required = required
        self.description = description
    }
}

/// What `topGroups` orders groups by.
public enum AskMetric: String, CaseIterable, Sendable {
    case cpu, memory, energy
}

/// What a cited id selects in the window: a process group, a scanned item by its path, or a reclaim suggestion by its
/// Explain key, so a citation finds the same thing in a newer sample or scan, or nothing.
public enum AskTarget: Hashable, Sendable {
    case group(OriginGroupID)
    case diskItem(path: String)
    case suggestion(String)

    static let groupPrefix = "g"

    var prefix: String {
        switch self {
        case .group: Self.groupPrefix
        case .diskItem: "d"
        case .suggestion: "s"
        }
    }
}

/// One value of a tool's result. Paths can only be `ExplainPath`s, which only `ExplainRedactor.path(_:)` makes, and
/// names have account names removed, so a result is redacted as Explain's requests are (SET-49).
public enum AskValue: Equatable, Sendable {
    /// A name or identifier: sent with account names removed.
    case name(String)
    case path(ExplainPath)
    /// System's own fixed words and figures, sent as they are.
    case words(String)
    case count(Int)
    case flag(Bool)
    /// An Explain request, already redacted and capped.
    case facts(ExplainRequest)
    case names([String])
}

/// One thing a result lists: what citing it selects, and its facts.
public struct AskEntry: Equatable, Sendable {
    public var target: AskTarget?
    public var fields: [String: AskValue]

    public init(_ target: AskTarget?, _ fields: [String: AskValue]) {
        self.target = target
        self.fields = fields
    }
}

/// A tool's result: its facts, and the things it lists, which the toolbox gives ids.
public struct AskOutput: Equatable, Sendable {
    public var fields: [String: AskValue]
    public var entries: [AskEntry]

    public init(_ fields: [String: AskValue], entries: [AskEntry] = []) {
        self.fields = fields
        self.entries = entries
    }
}

/// What the tools read: the window's latest sample and scan. Every method only reads; `select(_:)` only changes what
/// the window shows.
@MainActor
public protocol AskSource: AnyObject {
    func topGroups(by metric: AskMetric, layer: AttributionLayer, limit: Int, redactor: ExplainRedactor) -> AskOutput
    /// `nil` when the group is no longer in the sample.
    func groupDetail(_ group: OriginGroupID, redactor: ExplainRedactor) -> AskOutput?
    func memoryState() -> AskOutput
    func diskSummary(redactor: ExplainRedactor) -> AskOutput
    func largestItems(limit: Int, redactor: ExplainRedactor) -> AskOutput
    func reclaimSuggestions(redactor: ExplainRedactor) -> AskOutput
    /// Shows and selects the target in the window; `false` when it is no longer in the sample or scan.
    func select(_ target: AskTarget) -> Bool
}

/// A tool call as the toolbox recorded it, for the thread to show which tools an answer used.
public struct AskToolRecord: Equatable, Sendable {
    /// The tool and its arguments, or the name asked for when no such tool exists, kept short.
    public let call: String
    /// Whether it ran: not when the tool is unknown, its arguments were invalid, or the limit was reached.
    public let ran: Bool
}

/// Runs the model's tool calls for one Ask thread: validates the tool and its arguments, runs at most `callLimit` per
/// question, gives every listed thing an id that stays the same for the thread, and encodes results as JSON with
/// every text value on one line and capped. A call it refuses runs nothing and returns `{"error": …}`.
@MainActor
public final class AskToolbox {
    public nonisolated static let callLimit = 4
    nonisolated static let textLimit = 300

    private let source: AskSource
    private var redactor: ExplainRedactor
    private var targets: [String: AskTarget] = [:]
    private var ids: [AskTarget: String] = [:]
    /// The question whose calls run now; calls made for an earlier one are refused.
    private var question = 0
    private var calls = 0
    public private(set) var records: [AskToolRecord] = []

    public init(source: AskSource, redactor: ExplainRedactor) {
        self.source = source
        self.redactor = redactor
    }

    /// Starts a question: its calls count from zero, and run with `redactor`.
    func begin(_ question: Int, redactor: ExplainRedactor) {
        self.question = question
        self.redactor = redactor
        calls = 0
        records = []
    }

    /// Ends the question: its calls made from now on are refused.
    func end() {
        question = 0
    }

    /// The question's tools as a provider calls them, from any actor.
    func tools(for question: Int) -> AskTools {
        AskTools { name, arguments in await self.call(name, arguments: arguments, question: question) }
    }

    /// What a cited id selects, when a tool returned it in this thread.
    public func target(for id: String) -> AskTarget? {
        targets[id]
    }

    func call(_ name: String, arguments: Data, question: Int) -> String {
        guard question == self.question else { return Self.error("This question has ended.") }
        calls += 1
        let shown = ExplainRequest.oneLine(String(name.prefix(40)))
        guard calls <= Self.callLimit else {
            records.append(AskToolRecord(call: shown, ran: false))
            return Self.error("No more tool calls are allowed for this question (at most \(Self.callLimit)). Answer "
                + "with the results you have.")
        }
        guard let tool = AskTool(rawValue: name) else {
            records.append(AskToolRecord(call: shown, ran: false))
            return Self.error("There is no tool named \(shown). The tools are "
                + AskTool.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        let values: [String: Any]
        do {
            values = try Self.validate(arguments, for: tool) { self.targets[$0] }
        } catch {
            records.append(AskToolRecord(call: shown, ran: false))
            return Self.error((error as? Invalid)?.message ?? "The arguments are not valid.")
        }
        let argumentsShown = values.keys.sorted().map { "\($0): \(values[$0]!)" }.joined(separator: ", ")
        records.append(AskToolRecord(call: "\(name)(\(argumentsShown))", ran: true))
        return encode(run(tool, values))
    }

    private func run(_ tool: AskTool, _ values: [String: Any]) -> AskOutput {
        switch tool {
        case .topGroups:
            let metric = (values["metric"] as? String).flatMap(AskMetric.init(rawValue:)) ?? .memory
            let layer = (values["layer"] as? String).flatMap(AttributionLayer.init(rawValue:)) ?? .app
            return source.topGroups(by: metric, layer: layer, limit: values["limit"] as? Int ?? 5, redactor: redactor)
        case .groupDetail:
            guard case let .group(id)? = (values["id"] as? String).flatMap({ targets[$0] }),
                  let output = source.groupDetail(id, redactor: redactor) else {
                return AskOutput(["error": .words("That group is no longer in the sample.")])
            }
            return output
        case .memoryState: return source.memoryState()
        case .diskSummary: return source.diskSummary(redactor: redactor)
        case .largestItems: return source.largestItems(limit: values["limit"] as? Int ?? 10, redactor: redactor)
        case .reclaimSuggestions: return source.reclaimSuggestions(redactor: redactor)
        }
    }

    struct Invalid: Error {
        let message: String
    }

    /// The arguments as a JSON object holding only the tool's parameters, each of its kind and in range, and every
    /// required one. An id must be one a tool returned in this thread, with the parameter's prefix.
    static func validate(_ arguments: Data, for tool: AskTool,
                         target: (String) -> AskTarget?) throws -> [String: Any] {
        let object: Any
        if arguments.allSatisfy({ $0 == 0x20 || $0 == 0x0A || $0 == 0x0D || $0 == 0x09 }) {
            object = [String: Any]()
        } else {
            do { object = try JSONSerialization.jsonObject(with: arguments) } catch {
                throw Invalid(message: "The arguments are not JSON.")
            }
        }
        guard let given = object as? [String: Any] else { throw Invalid(message: "The arguments are not a JSON object.") }
        let parameters = Dictionary(uniqueKeysWithValues: tool.parameters.map { ($0.name, $0) })
        if let extra = given.keys.sorted().first(where: { parameters[$0] == nil }) {
            throw Invalid(message: "\(tool.rawValue) takes no argument named \(ExplainRequest.oneLine(String(extra.prefix(40)))).")
        }
        var values: [String: Any] = [:]
        for parameter in tool.parameters {
            guard let value = given[parameter.name], !(value is NSNull) else {
                if parameter.required { throw Invalid(message: "\(tool.rawValue) needs \(parameter.name).") }
                continue
            }
            switch parameter.kind {
            case let .choice(choices):
                guard let text = value as? String, choices.contains(text) else {
                    throw Invalid(message: "\(parameter.name) must be one of " + choices.joined(separator: ", ") + ".")
                }
                values[parameter.name] = text
            case let .count(range):
                // JSON numbers arrive as NSNumber; a Boolean or a fraction is not a count.
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                      let count = Int(exactly: number.doubleValue), range.contains(count) else {
                    throw Invalid(message: "\(parameter.name) must be a whole number from \(range.lowerBound) to "
                        + "\(range.upperBound).")
                }
                values[parameter.name] = count
            case let .id(prefix):
                guard let id = value as? String, id.hasPrefix(prefix), let found = target(id), found.prefix == prefix else {
                    throw Invalid(message: "\(parameter.name) must be a group id a tool returned in this conversation, "
                        + "like \(prefix)1.")
                }
                values[parameter.name] = id
            }
        }
        return values
    }

    /// The result as JSON, sorted, each listed thing with its id first given now or earlier in the thread.
    private func encode(_ output: AskOutput) -> String {
        var object = output.fields.mapValues(json)
        if !output.entries.isEmpty {
            object["results"] = output.entries.map { entry -> [String: Any] in
                var fields = entry.fields.mapValues(json)
                if let target = entry.target { fields["id"] = id(for: target) }
                return fields
            }
        }
        return Self.text(object)
    }

    private func id(for target: AskTarget) -> String {
        if let id = ids[target] { return id }
        let id = target.prefix + String(ids.keys.count { $0.prefix == target.prefix } + 1)
        ids[target] = id
        targets[id] = target
        return id
    }

    private func json(_ value: AskValue) -> Any {
        func capped(_ text: String) -> String {
            let line = ExplainRequest.oneLine(text).trimmingCharacters(in: .whitespaces)
            return line.count > Self.textLimit ? String(line.prefix(Self.textLimit - 1)) + "…" : line
        }
        switch value {
        case let .name(name): return capped(redactor.removingAccountNames(name))
        case let .path(path): return capped(path.value)
        case let .words(words): return capped(words)
        case let .count(count): return count
        case let .flag(flag): return flag
        case let .names(names): return names.map { capped(redactor.removingAccountNames($0)) }
        case let .facts(request):
            let data = (try? JSONEncoder().encode(request)) ?? Data("{}".utf8)
            return (try? JSONSerialization.jsonObject(with: data)) ?? [:]
        }
    }

    static func error(_ message: String) -> String {
        text(["error": message])
    }

    private static func text(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            ?? Data(#"{"error":"The result could not be encoded."}"#.utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
