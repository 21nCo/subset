import Foundation

/// What was in front at one moment, as read by the capture host. Every field except the app identity is optional
/// because it depends on a permission the user may not have granted.
public struct Activity: Equatable, Sendable {
    public var bundleID: String
    public var appName: String
    /// Focused window title, read through Accessibility only when the process is trusted.
    public var windowTitle: String?
    /// Active browser tab, already reduced by `RedactedURL`; nil when unsupported, private, or not permitted.
    public var url: RedactedURL?

    public init(bundleID: String, appName: String, windowTitle: String? = nil, url: RedactedURL? = nil) {
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = Segment.boundedTitle(windowTitle)
        self.url = url
    }

    /// Window titles are trimmed and capped at 300 characters, and at `maxTitleBytes` of UTF-8 (see `Segment`). A
    /// character count alone does not bound the stored text: one character can carry any number of combining marks.
    public static let maxTitleLength = 300
    /// pointInTime's own limit, four bytes per character, so a 300-character title of single-scalar characters (CJK
    /// included) is never shortened.
    public static let maxTitleBytes = 1_200
}

extension String {
    /// The longest prefix of whole characters within both limits. It never splits a character, so it never ends in a
    /// partial scalar or a combining run cut from its base; a first character over the byte limit yields "".
    func boundedPrefix(characters maxCharacters: Int = .max, utf8Bytes maxBytes: Int) -> String {
        guard utf8.count > maxBytes || count > maxCharacters else { return self }
        var end = startIndex
        var bytes = 0
        var characters = 0
        while end < endIndex, characters < maxCharacters {
            let next = index(after: end)
            bytes += self[end..<next].utf8.count
            guard bytes <= maxBytes else { break }
            end = next
            characters += 1
        }
        return String(self[..<end])
    }
}

/// A browser URL reduced to scheme, host, and path. Query strings, fragments, credentials, and ports are dropped
/// because they routinely carry tokens, search terms, and other private data.
public struct RedactedURL: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let path: String

    /// The longest host DNS allows. A longer one is not a real site, and truncating it would store a different host.
    public static let maxHostBytes = 253
    public static let maxPathBytes = 512

    /// Returns nil for anything that is not an http(s) URL with a host of at most `maxHostBytes`, such as `file:`,
    /// `about:`, or extension pages. The path is capped at `maxPathBytes` (see `boundedPath`).
    public init?(_ raw: String) {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty, host.utf8.count <= Self.maxHostBytes else { return nil }
        self.scheme = scheme
        self.host = host
        let path = components.percentEncodedPath
        self.path = path.isEmpty ? "/" : Self.boundedPath(path)
    }

    /// Rebuilds a URL the store already reduced. Internal so no caller can bypass the reduction above; the bounds are
    /// applied again, which leaves a reduced URL unchanged.
    init(scheme: String, host: String, path: String) {
        self.scheme = scheme
        self.host = host.boundedPrefix(utf8Bytes: Self.maxHostBytes)
        self.path = Self.boundedPath(path)
    }

    /// The longest prefix of a percent-encoded path within `maxPathBytes` that ends on a whole character, never inside
    /// a `%HH` escape, and never inside the escapes of one UTF-8 sequence, so it stays a valid path that reparses to
    /// itself and decodes to whole characters. A path within the limit is returned unchanged.
    static func boundedPath(_ path: String) -> String {
        var bytes = Array(path.boundedPrefix(utf8Bytes: maxPathBytes).utf8)
        guard bytes.count < path.utf8.count else { return path }
        // A `%` or `%H` whose escape was cut.
        if let percent = bytes.suffix(2).lastIndex(of: UInt8(ascii: "%")) { bytes.removeSubrange(percent...) }
        // The escapes at the end, last first, and the bytes they encode.
        var escapes: [(start: Int, byte: UInt8)] = []
        var end = bytes.count
        while end >= 3, bytes[end - 3] == UInt8(ascii: "%"), let byte = UInt8(String(decoding: bytes[(end - 2)..<end], as: UTF8.self), radix: 16) {
            escapes.append((end - 3, byte))
            end -= 3
        }
        // Drop a UTF-8 sequence whose lead byte has fewer escapes after it than the sequence needs.
        for (index, escape) in escapes.enumerated() where escape.byte & 0xC0 != 0x80 {
            let length = escape.byte < 0x80 ? 1 : escape.byte >= 0xF0 ? 4 : escape.byte >= 0xE0 ? 3 : 2
            if length > index + 1 { bytes.removeSubrange(escape.start...) }
            break
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    public var string: String { "\(scheme)://\(host)\(path)" }
}

/// How an app the user excluded is recorded.
public enum ExclusionMode: String, Codable, Sendable, CaseIterable {
    /// Keep the time as anonymous "excluded" time with no app name, title, or URL.
    case timeOnly
    /// Record nothing while the app is in front.
    case nothing
}

/// Why recording stopped. A gap closes the open segment; none of these produce activity.
public enum GapReason: String, Sendable {
    case idle, sleep, screenLocked, sessionInactive, paused, trackingOff, ownApp, unavailable
}

/// A contiguous stretch of one activity. Excluded segments carry no app identity, title, or URL.
///
/// A segment bounds its own text, whoever builds it: the content is set only by `init`, which applies the bounds, so
/// no later assignment can hold an unbounded title or identity, and every `RedactedURL` is bounded by its own init.
public struct Segment: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public private(set) var excluded: Bool
    public private(set) var bundleID: String?
    public private(set) var appName: String?
    public private(set) var windowTitle: String?
    public private(set) var url: RedactedURL?

    /// The app's bundle metadata sets both identity fields, so each is capped at `maxIdentityBytes` of UTF-8 here, after
    /// `CapturePolicy` has matched exclusions against the full bundle ID.
    public static let maxIdentityBytes = 255

    /// An excluded segment drops any identity it is given, so no caller can store an excluded app's name, title, or URL.
    public init(start: Date, end: Date, excluded: Bool, bundleID: String?, appName: String?, windowTitle: String?, url: RedactedURL?) {
        self.start = start
        self.end = end
        self.excluded = excluded
        self.bundleID = excluded ? nil : Self.boundedIdentity(bundleID)
        self.appName = excluded ? nil : Self.boundedIdentity(appName)
        self.windowTitle = excluded ? nil : Self.boundedTitle(windowTitle)
        self.url = excluded ? nil : url
    }

    /// A title trimmed and cut to whole characters within `Activity.maxTitleLength` and `Activity.maxTitleBytes`, or nil
    /// when nothing remains. Trimming again after the cut makes this idempotent, so a stored title reads back unchanged.
    static func boundedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let bounded = title.trimmingCharacters(in: .whitespacesAndNewlines)
            .boundedPrefix(characters: Activity.maxTitleLength, utf8Bytes: Activity.maxTitleBytes)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return bounded.isEmpty ? nil : bounded
    }

    static func boundedIdentity(_ text: String?) -> String? {
        text?.boundedPrefix(utf8Bytes: maxIdentityBytes)
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    func sameContent(as other: Segment) -> Bool {
        excluded == other.excluded && bundleID == other.bundleID && windowTitle == other.windowTitle && url == other.url
    }
}

/// The user's capture choices. Pure data so the policy can be tested without the app.
public struct CapturePolicy: Equatable, Sendable {
    public var excludedBundleIDs: Set<String>
    public var exclusionMode: ExclusionMode

    public init(excludedBundleIDs: Set<String> = [], exclusionMode: ExclusionMode = .timeOnly) {
        self.excludedBundleIDs = excludedBundleIDs
        self.exclusionMode = exclusionMode
    }

    /// The segment content for an activity, or nil when nothing should be recorded.
    public func content(for activity: Activity, at date: Date) -> Segment? {
        guard excludedBundleIDs.contains(activity.bundleID) else {
            return Segment(start: date, end: date, excluded: false, bundleID: activity.bundleID, appName: activity.appName,
                           windowTitle: activity.windowTitle, url: activity.url)
        }
        switch exclusionMode {
        case .timeOnly: return Segment(start: date, end: date, excluded: true, bundleID: nil, appName: nil, windowTitle: nil, url: nil)
        case .nothing: return nil
        }
    }
}
