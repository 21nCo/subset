import Foundation

/// How the capture host reads an app's front window, which decides what may be kept from it.
public enum BrowserSupport: Sendable, Equatable {
    /// Chromium browsers: the active tab's URL is read over Apple Events, and the window title and URL are kept only
    /// when the browser confirms the window is a normal (not private) window.
    case scriptable
    /// Every other app, including Safari and Firefox: no URL. The window title is kept unless it is a private-window
    /// title or carries a private-mode marker.
    case titleOnly
}

/// What a browser answered over Apple Events about one window. Every value comes from events addressed to the same
/// window id, so a window switch during the read cannot pair one window's title with another's URL.
public struct ScriptedWindow: Equatable, Sendable {
    /// The browser's scripting id for the window.
    public var id: String
    /// The window's `mode` (`normal` or `incognito`); nil when the browser has no such property.
    public var mode: String?
    /// The active tab's title.
    public var title: String?
    /// The active tab's raw URL, redacted before it is kept.
    public var url: String?

    public init(id: String, mode: String? = nil, title: String? = nil, url: String? = nil) {
        self.id = id
        self.mode = mode
        self.title = title
        self.url = url
    }
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

    /// A Chromium window is normal only when its own `mode` reads `normal`. A failed read (nil), a missing `mode`, or
    /// a title carrying a private-mode marker keeps nothing.
    public static func chromium(_ window: ScriptedWindow?) -> BrowserWindowReport {
        guard let window, let mode = window.mode else { return .unconfirmed }
        guard mode == "normal" else { return .privateWindow }
        let title = nonEmpty(window.title)
        if WindowPrivacy.looksPrivate(title: title) { return .privateWindow }
        return .normal(title: title, url: nonEmpty(window.url))
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
    /// Private-mode markers browsers put in window titles, such as Firefox's "— Private Browsing".
    public static let privateTitleMarkers = ["private browsing", "incognito", "inprivate"]

    public static func looksPrivate(title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return privateTitleMarkers.contains { title.contains($0) }
    }

    /// The window title and URL that may be recorded for the front window. Titles are kept only when `readsTitles`
    /// (Accessibility is granted). A scriptable browser keeps its title and URL only for a confirmed normal window and
    /// takes both from the browser's report; a private or unconfirmed window keeps neither. Other apps keep the
    /// focused window's title unless it is one of `privateTitles` or carries a private-mode marker, and never a URL.
    public static func reduce(focusedTitle: String?, readsTitles: Bool, support: BrowserSupport, report: BrowserWindowReport,
                              privateTitles: PrivateWindowTitles) -> (title: String?, url: RedactedURL?) {
        switch support {
        case .titleOnly:
            guard readsTitles, let focusedTitle, !looksPrivate(title: focusedTitle), !privateTitles.matches(focusedTitle) else { return (nil, nil) }
            return (focusedTitle, nil)
        case .scriptable:
            guard case .normal(let title, let url) = report else { return (nil, nil) }
            return (readsTitles ? title : nil, url.flatMap(RedactedURL.init))
        }
    }
}
