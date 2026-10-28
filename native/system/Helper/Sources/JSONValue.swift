import Foundation

/// A JSON value whose objects keep their keys in the order written, so every report reads `schemaVersion` first and
/// the same data always prints the same text. A value that is unavailable is `null`, never zero.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case unsigned(UInt64)
    /// Written with at most two decimals; a value that is not finite is written as `null`.
    case double(Double)
    /// A duration in whole milliseconds, written exactly as seconds: `60`, `0.2`, `0.001`, `-1.5`.
    case milliseconds(Int64)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.text(indent: nil) == rhs.text(indent: nil)
    }

    /// The value as text, indented by two spaces per level.
    public var pretty: String { text(indent: 0) }

    private func text(indent: Int?) -> String {
        let inner = indent.map { $0 + 2 }
        let newline = indent.map { "\n" + String(repeating: " ", count: $0) } ?? ""
        let innerNewline = inner.map { "\n" + String(repeating: " ", count: $0) } ?? ""
        switch self {
        case .null: return "null"
        case let .bool(value): return value ? "true" : "false"
        case let .int(value): return String(value)
        case let .unsigned(value): return String(value)
        case let .double(value):
            guard value.isFinite else { return "null" }
            let rounded = (value * 100).rounded() / 100
            return rounded == rounded.rounded() && abs(rounded) < 1e15 ? String(Int64(rounded)) : String(rounded)
        case let .milliseconds(value):
            let (whole, fraction) = value.quotientAndRemainder(dividingBy: 1000)
            guard fraction != 0 else { return String(whole) }
            var decimals = String(format: "%03lld", fraction.magnitude)
            while decimals.hasSuffix("0") { decimals.removeLast() }
            return (value < 0 ? "-" : "") + String(whole.magnitude) + "." + decimals
        case let .string(value): return Self.quoted(value)
        case let .array(values):
            guard !values.isEmpty else { return "[]" }
            return "[" + values.map { innerNewline + $0.text(indent: inner) }.joined(separator: ",") + newline + "]"
        case let .object(members):
            guard !members.isEmpty else { return "{}" }
            let separator = indent == nil ? ":" : ": "
            return "{" + members.map { innerNewline + Self.quoted($0.0) + separator + $0.1.text(indent: inner) }
                .joined(separator: ",") + newline + "}"
        }
    }

    private static func quoted(_ string: String) -> String {
        var result = "\""
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            case _ where scalar.value < 0x20:
                result += String(format: "\\u%04x", scalar.value)
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result + "\""
    }
}

extension JSONValue {
    static func optional(_ value: UInt64?) -> JSONValue { value.map(JSONValue.unsigned) ?? .null }
    static func optional(_ value: Int64?) -> JSONValue { value.map(JSONValue.int) ?? .null }
    static func optional(_ value: Int?) -> JSONValue { value.map { .int(Int64($0)) } ?? .null }
    static func optional(_ value: Double?) -> JSONValue { value.map(JSONValue.double) ?? .null }
    static func optional(_ value: String?) -> JSONValue { value.map(JSONValue.string) ?? .null }
    static func count(_ value: Int) -> JSONValue { .int(Int64(value)) }

    /// An ISO 8601 time in UTC with milliseconds.
    static func time(_ date: Date) -> JSONValue {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return .string(formatter.string(from: date))
    }
}
