import Foundation

/// Reads a duration as `subset-timer` does (packages/timer-cli/src/parse-duration.mjs): `90s`, `25m`, `1h30m`,
/// `1:30` (m:ss) or `1:02:03` (h:mm:ss), from 1 second to 24 hours.
public enum DurationParser {
    public static let minimumMs = 1_000
    public static let maximumMs = 86_400_000

    /// The milliseconds, or the message to show for text that is not a valid duration.
    public static func parse(_ text: String) -> Result<Int, DurationError> {
        let value = trimmed(text)
        // ASCII only, as the CLI's patterns: Swift's `\d` and `(?i)` would take other scripts' digits and letters.
        var ms: Int?
        if let match = value.wholeMatch(of: /(?:([0-9]{1,6})[hH])?(?:([0-9]{1,6})[mM])?(?:([0-9]{1,6})[sS])?/), !value.isEmpty {
            ms = [(match.1, 3_600_000), (match.2, 60_000), (match.3, 1_000)].reduce(0) { $0 + (Int($1.0 ?? "0") ?? 0) * $1.1 }
        } else if let match = value.wholeMatch(of: /([0-9]{1,6}):([0-5][0-9])/) {
            ms = [(match.1, 60_000), (match.2, 1_000)].reduce(0) { $0 + (Int($1.0) ?? 0) * $1.1 }
        } else if let match = value.wholeMatch(of: /([0-9]{1,6}):([0-5][0-9]):([0-5][0-9])/) {
            ms = [(match.1, 3_600_000), (match.2, 60_000), (match.3, 1_000)].reduce(0) { $0 + (Int($1.0) ?? 0) * $1.1 }
        }
        guard let ms else {
            let hint = value.wholeMatch(of: /[0-9]+/) != nil ? " Add a unit, for example \(value)s or \(value)m." : ""
            return .failure(DurationError(message: "\u{201C}\(value)\u{201D} is not a duration such as 90s, 25m, 1h30m or 1:30.\(hint)"))
        }
        guard ms >= minimumMs, ms <= maximumMs else {
            return .failure(DurationError(message: "\u{201C}\(value)\u{201D} must be from 1 second to 24 hours."))
        }
        return .success(ms)
    }

    /// JavaScript's `trim`: Foundation's white space and line ends, but with U+FEFF and without U+0085.
    static func trimmed(_ text: String) -> String {
        let isSpace = { (scalar: Unicode.Scalar) in
            scalar == "\u{FEFF}" || (scalar != "\u{85}" && CharacterSet.whitespacesAndNewlines.contains(scalar))
        }
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }), let last = scalars.lastIndex(where: { !isSpace($0) }) else { return "" }
        return String(scalars[first...last])
    }
}

public struct DurationError: Error, Equatable, Sendable {
    public var message: String
}
