import Foundation

/// Reads a duration as `subset-timer` does (packages/timer-cli/src/parse-duration.mjs): `90s`, `25m`, `1h30m`,
/// `1:30` (m:ss) or `1:02:03` (h:mm:ss), from 1 second to 24 hours.
public enum DurationParser {
    public static let minimumMs = 1_000
    public static let maximumMs = 86_400_000

    /// The milliseconds, or the message to show for text that is not a valid duration.
    public static func parse(_ text: String) -> Result<Int, DurationError> {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        var ms: Int?
        if let match = value.wholeMatch(of: /(?i)(?:(\d{1,6})h)?(?:(\d{1,6})m)?(?:(\d{1,6})s)?/), !value.isEmpty {
            ms = [(match.1, 3_600_000), (match.2, 60_000), (match.3, 1_000)].reduce(0) { $0 + (Int($1.0 ?? "0") ?? 0) * $1.1 }
        } else if let match = value.wholeMatch(of: /(\d{1,6}):([0-5]\d)/) {
            ms = Int(match.1)! * 60_000 + Int(match.2)! * 1_000
        } else if let match = value.wholeMatch(of: /(\d{1,6}):([0-5]\d):([0-5]\d)/) {
            ms = Int(match.1)! * 3_600_000 + Int(match.2)! * 60_000 + Int(match.3)! * 1_000
        }
        guard let ms else {
            let hint = value.wholeMatch(of: /\d+/) != nil ? " Add a unit, for example \(value)s or \(value)m." : ""
            return .failure(DurationError(message: "\u{201C}\(value)\u{201D} is not a duration such as 90s, 25m, 1h30m or 1:30.\(hint)"))
        }
        guard ms >= minimumMs, ms <= maximumMs else {
            return .failure(DurationError(message: "\u{201C}\(value)\u{201D} must be from 1 second to 24 hours."))
        }
        return .success(ms)
    }
}

public struct DurationError: Error, Equatable, Sendable {
    public var message: String
}
