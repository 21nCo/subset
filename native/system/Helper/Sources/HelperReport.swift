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

    /// Replaces every occurrence of the home folder inside a message, where a path may follow other text.
    func message(_ text: String) -> String {
        guard !absolute else { return text }
        var result = text
        for home in homes {
            result = result.replacingOccurrences(of: home + "/", with: "~/")
            if result.hasSuffix(home) { result = String(result.dropLast(home.count)) + "~" }
        }
        return result
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
