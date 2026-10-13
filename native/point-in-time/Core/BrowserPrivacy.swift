import Foundation

/// How the capture host reads an app's front window, which decides what may be kept from it.
public enum BrowserSupport: Sendable, Equatable {
    /// Safari and Chromium browsers: the active tab's URL is read over Apple Events, and the window title and URL are
    /// kept only when the browser confirms the front window is a normal (not private) window.
    case scriptable
    /// Every other app, including Firefox: no URL. The window title is kept unless it carries a private-mode marker.
    case titleOnly
}

/// What a scriptable browser reported about its front window. Title and URL come from one script run against the same
/// window, so a window switch during the read cannot pair one window's title with another's URL.
public enum BrowserWindowReport: Equatable, Sendable {
    /// A normal window, its title, and its active tab's raw URL. The URL is redacted before it is kept.
    case normal(title: String?, url: String?)
    /// A private or incognito window.
    case privateWindow
    /// No confirmation either way: Automation not allowed, a script error or timeout, no window, or a front window
    /// that cannot be matched to the focused one. Treated like a private window.
    case unconfirmed

    /// Chromium scripts answer `NORMAL`, the active tab's title, and its URL on separate lines only when the front
    /// window's `mode` reads `normal`, and `PRIVATE` otherwise. Anything else, including a failed script (nil), is
    /// unconfirmed.
    public static func chromium(scriptOutput: String?) -> BrowserWindowReport {
        guard let output = scriptOutput else { return .unconfirmed }
        if output == "PRIVATE" { return .privateWindow }
        guard output.hasPrefix("NORMAL\n") else { return .unconfirmed }
        let rest = output.dropFirst("NORMAL\n".count)
        guard let lineBreak = rest.lastIndex(of: "\n") else { return .unconfirmed }
        return .normal(title: nonEmpty(rest[..<lineBreak]), url: nonEmpty(rest[rest.index(after: lineBreak)...]))
    }

    /// Safari's scripting dictionary has no private-window property. Its Accessibility title for a private window is
    /// the page name formatted as "%@, Private Browsing" (localized), while the script reports the bare name, so the
    /// window counts as normal only when the focused window's Accessibility title, read both before and after the
    /// script, equals the scripted name exactly. Without Accessibility there is no title to compare, and nothing is
    /// confirmed. The script answers the front window's name, a line break, and the current tab's URL (empty when
    /// there is none).
    public static func safari(focusedTitleBefore: String?, focusedTitleAfter: String?, scriptOutput: String?) -> BrowserWindowReport {
        guard let output = scriptOutput, let lineBreak = output.lastIndex(of: "\n"),
              let name = nonEmpty(output[..<lineBreak]) else { return .unconfirmed }
        let before = focusedTitleBefore?.trimmingCharacters(in: .whitespacesAndNewlines)
        let after = focusedTitleAfter?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard before == name, after == name else { return .unconfirmed }
        return .normal(title: name, url: nonEmpty(output[output.index(after: lineBreak)...]))
    }

    private static func nonEmpty(_ text: Substring) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
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
    /// focused window's title unless it carries a private-mode marker, and never a URL.
    public static func reduce(focusedTitle: String?, readsTitles: Bool, support: BrowserSupport,
                              report: BrowserWindowReport) -> (title: String?, url: RedactedURL?) {
        switch support {
        case .titleOnly:
            guard readsTitles, !looksPrivate(title: focusedTitle) else { return (nil, nil) }
            return (focusedTitle, nil)
        case .scriptable:
            guard case .normal(let title, let url) = report else { return (nil, nil) }
            return (readsTitles ? title : nil, url.flatMap(RedactedURL.init))
        }
    }
}
