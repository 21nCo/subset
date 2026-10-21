import Foundation

/// One cell of the switcher: a window, or an app that has no switchable window (shown only with
/// `ShownWindows.windowlessApps`). Committing a window focuses it; committing an app activates it.
public enum SwitcherItem: Sendable, Equatable {
    case window(WindowEntry)
    case app(AppEntry)

    /// What the switcher keeps the selection on across list changes. An app cell is its app's: a pid names one
    /// running app, and an app with windows has no app cell.
    public enum ID: Hashable, Sendable {
        case window(WindowRef)
        case app(pid_t)
    }

    public var id: ID {
        switch self {
        case let .window(entry): .window(entry.ref)
        case let .app(app): .app(app.pid)
        }
    }

    /// The window, or nil for an app cell.
    public var window: WindowEntry? {
        if case let .window(entry) = self { entry } else { nil }
    }

    public var pid: pid_t {
        switch self {
        case let .window(entry): entry.pid
        case let .app(app): app.pid
        }
    }

    public var appName: String {
        switch self {
        case let .window(entry): entry.appName
        case let .app(app): app.name
        }
    }

    public var isMinimized: Bool {
        window?.isMinimized ?? false
    }

    public var isAppHidden: Bool {
        switch self {
        case let .window(entry): entry.isAppHidden
        case let .app(app): app.isHidden
        }
    }

    /// The cell's text: the window's title, or the app's name for an app cell or a window without a title.
    public var displayTitle: String {
        window?.displayTitle ?? appName
    }

    /// The badges the cell shows, in order. An app cell says it has no open windows.
    public var badges: [String] {
        switch self {
        case let .window(entry): entry.badges
        case let .app(app): ["no open windows"] + (app.isHidden ? ["hidden"] : [])
        }
    }

    /// What VoiceOver reads for the cell. Only VoiceOver reads it; it is never logged.
    public var accessibilityLabel: String {
        switch self {
        case let .window(entry): entry.accessibilityLabel
        case .app: ([appName] + badges).joined(separator: ", ")
        }
    }

    mutating func markMinimized() {
        if case var .window(entry) = self {
            entry.isMinimized = true
            self = .window(entry)
        }
    }

    mutating func markAppHidden() {
        switch self {
        case var .window(entry):
            entry.isAppHidden = true
            self = .window(entry)
        case var .app(app):
            app.isHidden = true
            self = .app(app)
        }
    }
}

extension Settings {
    /// The switcher's cells for a window list, applying the Shown-windows options and the excluded apps after
    /// `WindowFilter`'s rules:
    ///
    /// - an excluded app's windows, and its app cell, never appear;
    /// - minimized windows appear only with `minimized`;
    /// - windows of hidden apps, and hidden apps' cells, appear only with `hiddenApps`;
    /// - with `pointerDisplayOnly`, a window appears only when its display (`WindowEntry.display`, the display it
    ///   overlaps most) is `pointerDisplay`; a window on no display does not. When the pointer's display is unknown
    ///   (nil), no window is left out for it. App cells have no display and are not affected;
    /// - with `windowlessApps`, each app the list reports without a switchable window gets a cell after the windows,
    ///   in the list's order. An app whose windows the options above removed is not windowless and gets none.
    ///
    /// The windows keep the list's recency order.
    public func items(from list: WindowList, pointerDisplay: DisplayID?) -> [SwitcherItem] {
        let windows = list.windows.filter { entry in
            allows(bundleIdentifier: entry.bundleIdentifier)
                && (shownWindows.minimized || !entry.isMinimized)
                && (shownWindows.hiddenApps || !entry.isAppHidden)
                && (!shownWindows.pointerDisplayOnly || pointerDisplay == nil || entry.display == pointerDisplay)
        }
        let apps = !shownWindows.windowlessApps ? [] : list.windowlessApps.filter { app in
            allows(bundleIdentifier: app.bundleIdentifier) && (shownWindows.hiddenApps || !app.isHidden)
        }
        return windows.map(SwitcherItem.window) + apps.map(SwitcherItem.app)
    }
}
