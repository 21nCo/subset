import Foundation

/// Checks a parsed JSON value against the closed `subset.catalog@1` and `subset.receipt@1` schemas
/// (`packages/catalog/feed`), collecting each problem as `<JSON pointer>: <what is wrong>`, like the `subset` command's
/// validator. Every object is closed: a property the schema does not define is a problem.
struct JSONChecker {
    private(set) var problems: [String] = []

    mutating func fail(_ pointer: String, _ message: String) {
        problems.append("\(pointer.isEmpty ? "/" : pointer): \(message)")
    }

    /// The object at `pointer` when it is one with every `required` property and no property outside `required` and
    /// `optional`, otherwise nil.
    mutating func object(_ value: Any?, _ pointer: String, required: [String], optional: [String] = []) -> [String: Any]? {
        guard let object = value as? [String: Any] else {
            fail(pointer, "must be an object")
            return nil
        }
        var valid = true
        for key in object.keys.sorted() where !required.contains(key) && !optional.contains(key) {
            fail(pointer, "unknown property \(Self.quoted(key))")
            valid = false
        }
        for key in required where object[key] == nil {
            fail(pointer, "missing required property \(Self.quoted(key))")
            valid = false
        }
        return valid ? object : nil
    }

    mutating func array(_ value: Any?, _ pointer: String) -> [Any]? {
        guard let array = value as? [Any] else {
            fail(pointer, "must be an array")
            return nil
        }
        return array
    }

    /// The string at `pointer` when it is one that matches `pattern` (in full) and is at most `maxLength` code points
    /// long, otherwise nil.
    mutating func string(_ value: Any?, _ pointer: String, pattern: FeedPattern? = nil, minLength: Int = 0, maxLength: Int? = nil) -> String? {
        guard !Self.isNumberOrBool(value), let text = value as? String else {
            fail(pointer, "must be a string")
            return nil
        }
        // JSON Schema counts string length in code points.
        let length = text.unicodeScalars.count
        if length < minLength {
            fail(pointer, "must be at least \(minLength) characters long")
            return nil
        }
        if let maxLength, length > maxLength {
            fail(pointer, "must be at most \(maxLength) characters long")
            return nil
        }
        if let pattern, !pattern.matches(text) {
            fail(pointer, "does not match \(pattern.rawValue)")
            return nil
        }
        return text
    }

    /// The integer at `pointer` within `range`, otherwise nil. A JSON number with no fraction (4 or 4.0) is an integer.
    mutating func integer(_ value: Any?, _ pointer: String, in range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, !Self.isBool(number) else {
            fail(pointer, "must be an integer")
            return nil
        }
        let double = number.doubleValue
        guard double.rounded() == double, double >= Double(range.lowerBound), double <= Double(range.upperBound) else {
            fail(pointer, "must be an integer from \(range.lowerBound) to \(range.upperBound)")
            return nil
        }
        return Int(double)
    }

    mutating func constant(_ value: Any?, _ pointer: String, _ expected: String) -> Bool {
        guard !Self.isNumberOrBool(value), value as? String == expected else {
            fail(pointer, "must be \(Self.quoted(expected))")
            return false
        }
        return true
    }

    mutating func oneOf(_ value: Any?, _ pointer: String, _ allowed: [String]) -> String? {
        guard !Self.isNumberOrBool(value), let text = value as? String, allowed.contains(text) else {
            fail(pointer, "must be one of \(allowed.map(Self.quoted).joined(separator: ", "))")
            return nil
        }
        return text
    }

    static func quoted(_ text: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [text], options: [.fragmentsAllowed, .withoutEscapingSlashes])
        guard let data, let array = String(data: data, encoding: .utf8) else { return "\"\(text)\"" }
        return String(array.dropFirst().dropLast())
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func isNumberOrBool(_ value: Any?) -> Bool {
        value is NSNumber
    }

    /// Parses `data` as UTF-8 JSON by the rules of the `subset` command (`TextDecoder` with `fatal`, then `JSON.parse`),
    /// or returns why it is not: bytes that are not UTF-8 (UTF-16 and UTF-32 text among them), anything outside the
    /// RFC 8259 grammar (a trailing comma, a NUL byte), and, where the app is stricter than `subset`, a property name
    /// that appears twice or an unpaired surrogate escape such as `\uD800` (see `StrictJSON`). A
    /// leading byte order mark is refused, as `subset` refuses it in a feed and its cache, unless
    /// `allowingByteOrderMark` (`subset` skips one at the start of a receipt).
    static func parse(_ data: Data, allowingByteOrderMark: Bool = false) -> Result<Any, FeedRefusal> {
        var bytes = [UInt8](data)
        if bytes.starts(with: [0xEF, 0xBB, 0xBF]) {
            guard allowingByteOrderMark else { return .failure(FeedRefusal(["not JSON: it starts with a byte order mark"])) }
            bytes.removeFirst(3)
        }
        // Swift's decoder is as strict as TextDecoder's fatal mode: an invalid sequence is replaced, so the bytes change.
        guard String(decoding: bytes, as: UTF8.self).utf8.elementsEqual(bytes) else {
            return .failure(FeedRefusal(["not JSON: it is not UTF-8"]))
        }
        if let problem = StrictJSON.problem(bytes) { return .failure(FeedRefusal(["not JSON: \(problem)"])) }
        do {
            return .success(try JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]))
        } catch {
            let detail = (error as NSError).userInfo[NSDebugDescriptionErrorKey] as? String ?? "it cannot be parsed"
            return .failure(FeedRefusal(["not JSON: \(detail)"]))
        }
    }
}

/// The patterns of `catalog.schema.json` and `receipt.schema.json`, with `\d` written as `[0-9]` (ICU's `\d` matches
/// any Unicode digit; the schemas mean ASCII digits). `CatalogFeedTests.testPatternsAreTheSchemasPatterns` checks this list against both schema files.
enum FeedPattern: String, CaseIterable, Sendable {
    case utcTimestamp = #"^(?:[0-9]{4}-(?:(?:0[13578]|1[02])-(?:0[1-9]|[12][0-9]|3[01])|(?:0[469]|11)-(?:0[1-9]|[12][0-9]|30)|02-(?:0[1-9]|1[0-9]|2[0-8]))|(?:[0-9]{2}(?:0[48]|[2468][048]|[13579][26])|(?:[02468][048]|[13579][26])00)-02-29)T(?:[01][0-9]|2[0-3]):[0-5][0-9]:[0-5][0-9]Z$"#
    case id = #"^[a-z0-9][a-z0-9-]*$"#
    case sha256 = #"^[0-9a-f]{64}$"#
    case dmgURL = #"^https://github\.com/21nCo/subset/releases/download/(?:(?!\.\.?/)[A-Za-z0-9._+-]+/)+[A-Za-z0-9._+-]+\.dmg$"#
    case releaseURL = #"^https://github\.com/21nCo/subset/releases/tag/(?:(?!\.\.?/)[A-Za-z0-9._+-]+/)*(?!\.\.?$)[A-Za-z0-9._+-]+$"#
    case appName = #"^[A-Za-z0-9][A-Za-z0-9 ._-]*$"#
    case bundleID = #"^[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+$"#
    case helperPath = #"^Contents(?:/(?!\.\.?(?:/|$))[A-Za-z0-9._-]+)+$"#
    case nodeHelperPath = #"\.mjs$"#
    case version = #"^[0-9]+\.[0-9]+\.[0-9]+$"#
    case toolPackage = #"^@subset\.dev/[a-z0-9][a-z0-9.-]*$"#
    case toolBin = #"^subset-[a-z0-9][a-z0-9-]*$"#
    case betaDistTag = #"^[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]{0,8}$"#
    case receiptPath = #"^(?:/Users/(?!\.)[^/\u0000-\u001f\u007f-\u009f]+)?/Applications/(?!\.)[^/\u0000-\u001f\u007f-\u009f]+\.app$"#

    private static let compiled: [FeedPattern: NSRegularExpression] = Dictionary(
        uniqueKeysWithValues: allCases.map { pattern in
            // The patterns are constants that compile; a failure here is a programming error the tests catch.
            (pattern, try! NSRegularExpression(pattern: pattern.rawValue))
        }
    )

    /// Whether the pattern matches `text` as JSON Schema does (anywhere, unless anchored). An anchored pattern must
    /// match the whole string: ICU's `$` would also match before a final line break, which JavaScript's does not.
    func matches(_ text: String) -> Bool {
        let whole = NSRange(text.startIndex..., in: text)
        guard let regex = Self.compiled[self] else { return false }
        if rawValue.hasPrefix("^") {
            return regex.firstMatch(in: text, options: [], range: whole)?.range == whole
        }
        // Unanchored at the start (\.mjs$): the match must still end at the end of the string.
        return regex.matches(in: text, options: [], range: whole).contains { $0.range.upperBound == whole.upperBound }
    }
}
