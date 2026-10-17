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
        self.windowTitle = Activity.normalizedTitle(windowTitle)
        self.url = url
    }

    /// Window titles are trimmed and capped at 300 characters, and at `maxTitleBytes` of UTF-8, which is what SQLite
    /// stores. A character count alone does not bound storage: one character can carry any number of combining marks.
    public static let maxTitleLength = 300
    /// Four bytes per character, so a 300-character title of single-scalar characters (CJK included) is never shortened.
    public static let maxTitleBytes = 1_200

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let bounded = title.trimmingCharacters(in: .whitespacesAndNewlines).boundedPrefix(characters: maxTitleLength, utf8Bytes: maxTitleBytes)
        return bounded.isEmpty ? nil : bounded
    }
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
    /// `about:`, or extension pages. The path is capped at `maxPathBytes` of UTF-8 on a character boundary.
    public init?(_ raw: String) {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty, host.utf8.count <= Self.maxHostBytes else { return nil }
        self.scheme = scheme
        self.host = host
        let path = components.percentEncodedPath
        self.path = path.isEmpty ? "/" : path.boundedPrefix(utf8Bytes: Self.maxPathBytes)
    }

    /// Rebuilds a URL the store already reduced. Internal so no caller can bypass the reduction above.
    init(scheme: String, host: String, path: String) {
        self.scheme = scheme
        self.host = host
        self.path = path
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
public struct Segment: Equatable, Sendable {
    public var start: Date
    public var end: Date
    public var excluded: Bool
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var url: RedactedURL?

    /// The app's bundle metadata sets both identity fields, so each is capped at `maxIdentityBytes` of UTF-8 here, after
    /// `CapturePolicy` has matched exclusions against the full bundle ID.
    public static let maxIdentityBytes = 255

    /// An excluded segment drops any identity it is given, so no caller can store an excluded app's name, title, or URL.
    public init(start: Date, end: Date, excluded: Bool, bundleID: String?, appName: String?, windowTitle: String?, url: RedactedURL?) {
        self.start = start
        self.end = end
        self.excluded = excluded
        self.bundleID = excluded ? nil : bundleID?.boundedPrefix(utf8Bytes: Self.maxIdentityBytes)
        self.appName = excluded ? nil : appName?.boundedPrefix(utf8Bytes: Self.maxIdentityBytes)
        self.windowTitle = excluded ? nil : windowTitle
        self.url = excluded ? nil : url
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
