import Foundation

/// How the capture host reads an app's front window, which decides what may be kept from it.
public enum BrowserSupport: Sendable, Equatable {
    /// Chromium browsers: the active tab's URL is read over Apple Events, and the window title and URL are kept only
    /// when the browser confirms the window is a normal (not private) window.
    case scriptable
    /// Every other app, including Safari: no URL. The window title is kept unless it is a private-window title or
    /// carries a private-mode marker.
    case titleOnly
    /// Firefox and its forks: the app name only. They have no scriptable private-window property, and their private
    /// windows' titles are localized in every language they ship, so a private window cannot be told apart reliably.
    case appOnly

    /// Bundle IDs of Firefox-family browsers. Any ID starting with `org.mozilla.firefox` also counts, which covers
    /// Firefox Beta and Developer Edition.
    public static let firefoxFamily: Set<String> = [
        "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly", "org.torproject.torbrowser",
        "net.mullvad.mullvadbrowser", "io.gitlab.librewolf-community", "org.mozilla.librewolf", "net.waterfox.waterfox",
        "app.zen-browser.zen", "one.ablaze.floorp"
    ]

    /// How to read the app with `bundleID`; `scriptable` when the host can read its window mode over Apple Events.
    public static func forApp(_ bundleID: String, scriptable: Bool) -> BrowserSupport {
        if scriptable { return .scriptable }
        if firefoxFamily.contains(bundleID) || bundleID.hasPrefix("org.mozilla.firefox") { return .appOnly }
        return .titleOnly
    }
}

/// The get-data Apple Events a Chromium read sends, so the order of reads can be tested without a browser. Each call is
/// one event. A thrown error means the event failed or timed out; nil means the browser answered `missing value`.
public protocol ChromiumScripting {
    /// A window's or tab's scripting id.
    associatedtype ID
    func frontWindowID() throws -> ID
    func mode(ofWindow window: ID) throws -> String?
    func activeTabID(ofWindow window: ID) throws -> ID
    func title(ofTab tab: ID, inWindow window: ID) throws -> String?
    func url(ofTab tab: ID, inWindow window: ID) throws -> String?
}

/// What a scriptable browser reported about the window being recorded.
public enum BrowserWindowReport: Equatable, Sendable {
    /// A normal window, its title, and its active tab's raw URL. The URL is redacted before it is kept.
    case normal(title: String?, url: String?)
    /// A private or incognito window.
    case privateWindow
    /// No confirmation either way: Automation not allowed, an Apple Event error or timeout, no window, or a dictionary
    /// without `mode`. Treated like a private window.
    case unconfirmed

    /// Reads the front Chromium window. Nothing about its tabs is asked until the window's own `mode` reads `normal`,
    /// so a private window's title and URL are never requested. The active tab is then resolved once to its id, and
    /// its title and URL are both read from that tab, so a tab switch during the read cannot pair one tab's title with
    /// another's URL. A failed event or a missing `mode` keeps nothing, and the URL is not read when the title carries
    /// a private-mode marker.
    public static func chromium<Browser: ChromiumScripting>(reading browser: Browser) -> BrowserWindowReport {
        do {
            let window = try browser.frontWindowID()
            guard let mode = try browser.mode(ofWindow: window) else { return .unconfirmed }
            guard mode == "normal" else { return .privateWindow }
            let tab = try browser.activeTabID(ofWindow: window)
            let title = nonEmpty(try browser.title(ofTab: tab, inWindow: window))
            if WindowPrivacy.looksPrivate(title: title) { return .privateWindow }
            return .normal(title: title, url: nonEmpty(try browser.url(ofTab: tab, inWindow: window)))
        } catch {
            return .unconfirmed
        }
    }

    private static func nonEmpty(_ text: String?) -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// Safari's private-window titles in every language it ships: a format such as "%@, Private Browsing" wrapped around
/// the page name (Safari's Accessibility title for a private window), and the bare title of a blank or locked private
/// window, such as "Private Browsing". Safari has no scriptable private-window property, so these titles are how its
/// private windows are recognized.
public struct PrivateWindowTitles: Equatable, Sendable {
    /// Safari's string table keys for the two titles.
    public static let formatKey = "%@, Private Browsing"
    public static let titleKey = "Private Browsing (window title)"

    /// The English titles alone. Every set includes them, so a missing or moved string table still fails closed.
    public static let english = PrivateWindowTitles(tables: [])
    private static let englishTable = [formatKey: "%@, Private Browsing", titleKey: "Private Browsing"]

    private var affixes: Set<Affix> = []
    private var titles: Set<String> = []

    private struct Affix: Hashable {
        var prefix: String
        var suffix: String
    }

    /// Builds the set from Safari's `Localizable.strings` tables, one per localization, plus English.
    public init(tables: [[String: String]]) {
        for table in tables + [Self.englishTable] {
            if let format = table[Self.formatKey], let range = format.range(of: #"%(\d+\$)?@"#, options: .regularExpression) {
                let affix = Affix(prefix: String(format[..<range.lowerBound]), suffix: String(format[range.upperBound...]))
                if !(affix.prefix + affix.suffix).trimmingCharacters(in: .whitespaces).isEmpty { affixes.insert(affix) }
            }
            if let title = table[Self.titleKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                titles.insert(title)
            }
        }
    }

    public func matches(_ title: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if titles.contains(title) { return true }
        return affixes.contains { affix in
            title.count >= affix.prefix.count + affix.suffix.count && title.hasPrefix(affix.prefix) && title.hasSuffix(affix.suffix)
        }
    }
}

public enum WindowPrivacy {
    /// English private-mode markers browsers put in window titles, such as Chrome's "New Incognito Tab".
    public static let privateTitleMarkers = ["private browsing", "incognito", "inprivate"]

    public static func looksPrivate(title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return privateTitleMarkers.contains { title.contains($0) }
    }

    /// The window title and URL that may be recorded for the front window. Titles are kept only when `readsTitles`
    /// (Accessibility is granted). A scriptable browser keeps its title and URL only for a confirmed normal window and
    /// takes both from the browser's report; a private or unconfirmed window keeps neither. Firefox-family browsers
    /// keep neither. Other apps keep the focused window's title unless it is one of `privateTitles` or carries a
    /// private-mode marker, and never a URL.
    public static func reduce(focusedTitle: String?, readsTitles: Bool, support: BrowserSupport, report: BrowserWindowReport,
                              privateTitles: PrivateWindowTitles) -> (title: String?, url: RedactedURL?) {
        switch support {
        case .appOnly:
            return (nil, nil)
        case .titleOnly:
            guard readsTitles, let focusedTitle, !looksPrivate(title: focusedTitle), !privateTitles.matches(focusedTitle) else { return (nil, nil) }
            return (focusedTitle, nil)
        case .scriptable:
            guard case .normal(let title, let url) = report else { return (nil, nil) }
            return (readsTitles ? title : nil, url.flatMap(RedactedURL.init))
        }
    }
}
