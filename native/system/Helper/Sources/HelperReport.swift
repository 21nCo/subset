import Foundation

/// Writes paths for output: the home folder, as given and as its real path, becomes `~` unless `absolute` is set.
/// Only a whole leading component is replaced, so `/Users/ann2` is not `~2` for `/Users/ann`.
public struct PathDisplay: Sendable {
    public let absolute: Bool
    private let homes: [String]

    public init(home: String, absolute: Bool) {
        self.absolute = absolute
        let real = realpath(home, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        }
        // The longer form first, so a home inside a link is replaced whole.
        homes = Set([home, real].compactMap { $0 }.map { $0.count > 1 && $0.hasSuffix("/") ? String($0.dropLast()) : $0 })
            .filter { $0 != "/" && !$0.isEmpty }
            .sorted { $0.count > $1.count }
    }

    public func callAsFunction(_ path: String) -> String {
        guard !absolute else { return path }
        for home in homes {
            if path == home { return "~" }
            if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        }
        return path
    }

    /// Replaces the home folder wherever a message names it as a whole path: after the start, a space, an opening
    /// quote or bracket, `:`, `=`, or a URL's `://` (`unix:///Users/ann/.docker/run/docker.sock`), and before the end, a `/`, a space, a closing quote or bracket, or punctuation that
    /// ends the text or a clause. So `/Users/ann was not read.` and `(/Users/ann).` are redacted, while `/Users/ann2`,
    /// `/Users/ann.old`, and `/Volumes/x/Users/ann` are not.
    public func message(_ text: String) -> String {
        guard !absolute else { return text }
        return homes.reduce(text) { text, home in Self.replace(home, in: text) }
    }

    private static func replace(_ home: String, in text: String) -> String {
        let opening: Set<Character> = ["\"", "'", "\u{201C}", "\u{2018}", "(", "[", "{", "<", ":", "="]
        let closing: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "}", ">"]
        let punctuation: Set<Character> = [".", ",", ";", ":", "!", "?"]
        func ends(_ rest: Substring) -> Bool {
            guard let next = rest.first else { return true }
            if next == "/" || next.isWhitespace || closing.contains(next) { return true }
            guard punctuation.contains(next) else { return false }
            let after = rest.dropFirst().first
            return after == nil || after!.isWhitespace || closing.contains(after!)
        }
        var result = ""
        var rest = text[...]
        while let range = rest.range(of: home) {
            let before = range.lowerBound == text.startIndex ? nil : text[text.index(before: range.lowerBound)]
            let starts = before == nil || before!.isWhitespace || opening.contains(before!)
                || text[..<range.lowerBound].hasSuffix("://")
            result += rest[..<range.lowerBound] + (starts && ends(text[range.upperBound...]) ? "~" : home)
            rest = text[range.upperBound...]
        }
        return result + rest
    }
}

/// One problem that left a result incomplete or failed it, as reported in `errors[]`.
public struct HelperError: Equatable, Sendable {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    var json: JSONValue { .object([("code", .string(code)), ("message", .string(message))]) }
}

/// A finished command's output: the JSON document, its text summary, and the exit code.
public struct HelperReport: Sendable {
    public let json: JSONValue
    public let text: String
    public let exit: HelperExit

    /// Wraps a command's fields in the envelope every result shares: schema version, command, helper version,
    /// observation time, sources, restricted counts, completeness, and errors. Without an `exit` given, the result is
    /// partial when anything is restricted or an error was recorded.
    init(command: String, observedAt: Date, sources: [(String, String)], restricted: [(String, Int)],
         errors: [HelperError], fields: [(String, JSONValue)], text: String, exit: HelperExit? = nil) {
        let partial = !errors.isEmpty || restricted.contains { $0.1 > 0 }
        let exit = exit ?? (partial ? .partial : .ok)
        json = .object([
            ("schemaVersion", .int(1)),
            ("command", .string(command)),
            ("helperVersion", .string(HelperInvocation.version)),
            ("observedAt", .time(observedAt)),
            ("complete", .bool(exit == .ok)),
            ("sources", .object(sources.map { ($0.0, .string($0.1)) })),
            ("restricted", .object(restricted.map { ($0.0, .count($0.1)) })),
            ("errors", .array(errors.map(\.json)))
        ] + fields)
        self.text = text
        self.exit = exit
    }
}
