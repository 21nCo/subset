import Foundation

/// Whether removing an item is likely safe, as the provider judged it.
public enum RemovalSafety: String, Codable, CaseIterable, Sendable {
    case likelySafe, review, unsafe, unknown

    public var title: String {
        switch self {
        case .likelySafe: "Likely safe to remove"
        case .review: "Review before removing"
        case .unsafe: "Not safe to remove"
        case .unknown: "Safety unknown"
        }
    }
}

public enum ExplanationConfidence: String, Codable, CaseIterable, Sendable {
    case low, medium, high

    public var title: String { rawValue.capitalized }
}

/// A provider's answer before validation. Every field may be missing or malformed: providers return what the model
/// produced, and `Explanation(validating:for:)` decides whether it fits the schema.
public struct ExplanationDraft: Equatable, Sendable {
    public var summary: String?
    public var whatItIs: String?
    public var removalSafety: String?
    public var howToRemove: String?
    public var confidence: String?
    public var suggestedOrigin: String?

    public enum Key: String, CaseIterable {
        case summary, whatItIs, removalSafety, howToRemove, confidence, suggestedOrigin
    }

    public init(summary: String?, whatItIs: String?, removalSafety: String?, howToRemove: String?, confidence: String?,
                suggestedOrigin: String? = nil) {
        self.summary = summary
        self.whatItIs = whatItIs
        self.removalSafety = removalSafety
        self.howToRemove = howToRemove
        self.confidence = confidence
        self.suggestedOrigin = suggestedOrigin
    }

    /// Reads a JSON object with exactly the schema's keys, each a string (`suggestedOrigin` may be null or absent). Any
    /// other key or type is outside the schema and rejected.
    public init(json: Data) throws {
        guard let object = try? JSONSerialization.jsonObject(with: json), let fields = object as? [String: Any] else {
            throw ExplainError.invalidResponse("The answer is not a JSON object.")
        }
        var values: [Key: String] = [:]
        for (name, value) in fields {
            guard let key = Key(rawValue: name) else {
                throw ExplainError.invalidResponse("The answer has a field outside the schema: \(name).")
            }
            if key == .suggestedOrigin, value is NSNull { continue }
            guard let text = value as? String else {
                throw ExplainError.invalidResponse("The answer's \(name) is not text.")
            }
            values[key] = text
        }
        self.init(summary: values[.summary], whatItIs: values[.whatItIs], removalSafety: values[.removalSafety],
                  howToRemove: values[.howToRemove], confidence: values[.confidence],
                  suggestedOrigin: values[.suggestedOrigin])
    }
}

/// A validated explanation, shown as plain text only: never rendered as markup and never run.
public struct Explanation: Equatable, Sendable {
    public let summary: String
    public let whatItIs: String
    public let removalSafety: RemovalSafety
    public let howToRemove: String
    public let confidence: ExplanationConfidence
    /// Only for an Unattributed process group: the origin the provider suggests. It never changes rule-based grouping.
    public let suggestedOrigin: String?

    public static let summaryLimit = 280
    public static let textLimit = 1_200
    public static let originLimit = 80

    /// Accepts a draft only when every required field is present, within its limit, and one of the schema's values. A
    /// suggested origin is kept only when the request allowed one.
    public init(validating draft: ExplanationDraft, for request: ExplainRequest) throws {
        func text(_ value: String?, _ field: String, limit: Int) throws -> String {
            let cleaned = Self.plainText(value ?? "")
            guard !cleaned.isEmpty else { throw ExplainError.invalidResponse("The answer has no \(field).") }
            guard cleaned.count <= limit else {
                throw ExplainError.invalidResponse("The answer's \(field) is longer than \(limit) characters.")
            }
            return cleaned
        }
        summary = try text(draft.summary, "summary", limit: Self.summaryLimit)
        whatItIs = try text(draft.whatItIs, "description of what it is", limit: Self.textLimit)
        howToRemove = try text(draft.howToRemove, "removal steps", limit: Self.textLimit)
        guard let safety = draft.removalSafety.flatMap(RemovalSafety.init(rawValue:)) else {
            throw ExplainError.invalidResponse("The answer's removal safety is not one of the allowed values.")
        }
        guard let confidence = draft.confidence.flatMap(ExplanationConfidence.init(rawValue:)) else {
            throw ExplainError.invalidResponse("The answer's confidence is not one of the allowed values.")
        }
        removalSafety = safety
        self.confidence = confidence
        let origin = Self.plainText(draft.suggestedOrigin ?? "")
        if request.maySuggestOrigin, !origin.isEmpty {
            // A short name is one line: no line break of any kind (LF, CR, VT, FF, U+0085, U+2028, U+2029) and no tab
            // inside it, checked before control characters are removed, so a removed CR does not join two lines.
            let inside = (draft.suggestedOrigin ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard origin.count <= Self.originLimit, !inside.contains(where: { $0.isNewline || $0 == "\t" }) else {
                throw ExplainError.invalidResponse("The suggested origin is not a short name.")
            }
            suggestedOrigin = origin
        } else {
            suggestedOrigin = nil
        }
    }

    /// Trims the text and removes control and format characters (Unicode Cc and Cf) other than line breaks and tabs:
    /// Cf holds the bidirectional overrides that could make shown text read differently from what it is.
    static func plainText(_ text: String) -> String {
        let scalars = text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        }
        return String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum ExplainError: Error, Equatable, Sendable {
    /// The answer is outside the schema.
    case invalidResponse(String)
    /// The provider cannot be used now.
    case unavailable(AIAvailability)
    /// The provider failed to answer.
    case failed(String)
    /// The request was built with a **Send folder names** setting the user changed before it went out, so it was not
    /// sent.
    case outdated

    public var message: String {
        switch self {
        case let .invalidResponse(reason): "The answer was rejected: \(reason)"
        case let .unavailable(availability): "\(availability.title). \(availability.meaning)"
        case let .failed(reason): reason
        case .outdated: "Send folder names changed before the request went out, so it was not sent. Ask again."
        }
    }
}
