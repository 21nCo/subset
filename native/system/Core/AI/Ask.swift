import Foundation

/// One Ask question as a provider is given it (SET-51): the thread's earlier questions and answers, kept in memory
/// only, then the question. Tool results are not repeated; each question calls the tools again.
public struct AskPrompt: Equatable, Sendable {
    public struct Turn: Equatable, Sendable {
        public let question: String
        /// The answer as shown, its citations kept as `[id]`.
        public let answer: String
    }

    public let history: [Turn]
    public let question: String

    public static let instructions = """
        You answer the user's questions about their Mac right now, using only what System's tools return: the latest \
        process sample and the latest disk scan, both kept in memory. Call a tool only when you need its facts, at most \
        \(AskToolbox.callLimit) times per question. The tools only read: nothing you say can change, clean up, or \
        remove anything, so never say you did or will. If the tools do not answer the question, say what is missing, \
        such as no disk scan yet. You cannot see history or trends, so say so when asked what changed over time.
        Answer in at most six short sentences of plain text: no Markdown, HTML, links, or code blocks. When you name a \
        group, item, or suggestion a tool returned, put its id in square brackets right after it, like Google Chrome \
        [g1]. Use only ids the tools returned. Paths show the home folder as ~, and folder-… names stand for folders \
        whose names were withheld.
        """

    public init(history: [Turn], question: String) {
        self.history = history
        self.question = question
    }

    /// The prompt for a model given one text: the earlier questions and answers, then the question.
    public var text: String {
        let earlier = history.map { "Earlier question: \($0.question)\nYour answer: \($0.answer)" }
        return (earlier + ["Question: \(question)"]).joined(separator: "\n\n")
    }
}

/// The question's tools, as a provider calls them from any actor: a tool's name and its JSON arguments in, its JSON
/// result out. Refusals are results too (`{"error": …}`), so the model can answer with what it has. A call that throws
/// returns nothing, and ends the question: its model called tools past what one question takes
/// (`AskToolbox.exhausted`), or the question has already ended. The provider sends nothing more and fails with it.
public struct AskTools: Sendable {
    private let run: @Sendable (_ name: String, _ arguments: Data) async throws -> String

    public init(_ run: @escaping @Sendable (_ name: String, _ arguments: Data) async throws -> String) {
        self.run = run
    }

    public func call(_ name: String, arguments: Data) async throws -> String {
        try await run(name, arguments)
    }
}

/// What a provider that sends off this Mac does around each body it sends, so Ask keeps Explain's send preview
/// (SET-160) and its checks (SET-165): `check` before each read of its key, which takes one of the checks shared with
/// Explain and returns its number, and throws when nothing more must be sent; `confirm` before sending, which returns
/// whether the user confirmed the body in the preview (`false` when none was needed) and throws when it must not be
/// sent; `sending` as the body is handed over to be sent, before it is known whether it arrived, since a timeout or a
/// lost connection can come after it left this Mac; `answered` at most once per body, as the provider's first answer to
/// it comes, even one a failed retry follows.
public struct AskSendGate: Sendable {
    private let startCheck: @Sendable () async throws -> Int
    private let confirmBody: @Sendable (Data) async throws -> Bool
    private let sendingBody: @Sendable (Data) async -> Void
    private let answeredBody: @Sendable (Data, Bool) async -> Void

    public init(check: @escaping @Sendable () async throws -> Int = { 0 },
                confirm: @escaping @Sendable (Data) async throws -> Bool,
                sending: @escaping @Sendable (Data) async -> Void = { _ in /* Nothing is kept. */ },
                answered: @escaping @Sendable (Data, Bool) async -> Void) {
        startCheck = check
        confirmBody = confirm
        sendingBody = sending
        answeredBody = answered
    }

    /// Sends nothing that needs confirming: for tests and providers on this Mac.
    public static let none = AskSendGate(confirm: { _ in false }, answered: { _, _ in /* Nothing was confirmed. */ })

    public func check() async throws -> Int {
        try await startCheck()
    }

    public func confirm(_ body: Data) async throws -> Bool {
        try await confirmBody(body)
    }

    public func sending(_ body: Data) async {
        await sendingBody(body)
    }

    public func answered(_ body: Data, confirmed: Bool) async {
        await answeredBody(body, confirmed)
    }
}

/// An answer as shown: plain text, with each cited id a tool returned in this thread kept as a link, and every other
/// id removed. A bracket may cite several ids, as `[g1, G3]`; each one kept becomes its own `[id]`, and a bracket that
/// keeps none is removed.
public struct AskAnswer: Equatable, Sendable {
    public enum Part: Equatable, Sendable {
        case text(String)
        case citation(id: String, target: AskTarget)
    }

    public let parts: [Part]

    public static let limit = 2_000

    /// Accepts any non-empty text: control and format characters are removed as from an explanation, and text past
    /// `limit` is cut off. Text left with no citation and no letter or digit once unknown ids are removed, such as
    /// `[g99].`, is empty too.
    public init(validating raw: String, target: (String) -> AskTarget?) throws {
        var text = Explanation.plainText(raw)
        guard !text.isEmpty else { throw ExplainError.invalidResponse("The answer is empty.") }
        if text.count > Self.limit { text = String(text.prefix(Self.limit - 1)) + "…" }
        var parts: [Part] = []
        var rest = Substring(text)
        func add(_ piece: Substring) {
            guard !piece.isEmpty else { return }
            if case let .text(previous)? = parts.last {
                parts[parts.count - 1] = .text(previous + piece)
            } else {
                parts.append(.text(String(piece)))
            }
        }
        while let match = rest.firstMatch(of: /\[[ ,]*[A-Za-z][0-9]{1,6}(?:[ ,]+[A-Za-z][0-9]{1,6})*[ ,]*\]/) {
            var before = rest[..<match.range.lowerBound]
            var seen: Set<String> = []
            let cited = match.output.matches(of: /([A-Za-z])([0-9]{1,6})/).compactMap { id -> Part? in
                let id = id.output.1.lowercased() + String(Int(id.output.2) ?? 0)
                guard seen.insert(id).inserted else { return nil }
                return target(id).map { .citation(id: id, target: $0) }
            }
            // A bracket with no id a tool returned takes the space before it, so "Chrome [x9]." reads "Chrome.".
            if cited.isEmpty, before.last == " " { before = before.dropLast() }
            add(before)
            for (position, citation) in cited.enumerated() {
                if position > 0 { add(" ") }
                parts.append(citation)
            }
            rest = rest[match.range.upperBound...]
        }
        add(rest)
        let kept = parts.contains { if case .citation = $0 { true } else { false } }
        guard kept || parts.contains(where: { part in
            guard case let .text(text) = part else { return false }
            return text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
        }) else { throw ExplainError.invalidResponse("The answer is empty.") }
        self.parts = parts
    }

    /// The answer's text with its citations as `[id]`, as a follow-up gives it back.
    public var text: String {
        parts.map { part in
            switch part {
            case let .text(text): text
            case let .citation(id, _): "[\(id)]"
            }
        }.joined()
    }
}
