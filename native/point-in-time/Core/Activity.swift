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

    /// Window titles are trimmed and capped so a pathological title cannot grow the store without bound.
    public static let maxTitleLength = 300

    static func normalizedTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > maxTitleLength ? String(trimmed.prefix(maxTitleLength)) : trimmed
    }
}

/// A browser URL reduced to scheme, host, and path. Query strings, fragments, credentials, and ports are dropped
/// because they routinely carry tokens, search terms, and other private data.
public struct RedactedURL: Equatable, Sendable {
    public let scheme: String
    public let host: String
    public let path: String

    /// Returns nil for anything that is not an http(s) URL with a host, such as `file:`, `about:`, or extension pages.
    public init?(_ raw: String) {
        guard let components = URLComponents(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(), !host.isEmpty else { return nil }
        self.scheme = scheme
        self.host = host
        let path = components.percentEncodedPath
        self.path = path.isEmpty ? "/" : String(path.prefix(512))
    }

    public init(scheme: String, host: String, path: String) {
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

    public init(start: Date, end: Date, excluded: Bool, bundleID: String?, appName: String?, windowTitle: String?, url: RedactedURL?) {
        self.start = start
        self.end = end
        self.excluded = excluded
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.url = url
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
