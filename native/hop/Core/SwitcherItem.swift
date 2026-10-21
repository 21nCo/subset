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

    public var bundleIdentifier: String? {
        switch self {
        case let .window(entry): entry.bundleIdentifier
        case let .app(app): app.bundleIdentifier
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

/// The Shown-windows options and excluded apps as one switcher applies them, after `WindowFilter`'s closed rules. The
/// switcher keeps every item it lists passing `shows(_:)`: the items of a fresh list, the items of apps that did not
/// answer a read, the items an operation left (a window just minimized, an app just hidden), and all of them again
/// when the settings change while it is open.
public struct SwitcherFilter: Sendable, Equatable {
    public var shownWindows: ShownWindows
    /// The bundle IDs of excluded apps.
    public var excludedApps: Set<String>
    /// The display under the pointer when the switcher opened, for `ShownWindows.pointerDisplayOnly`; nil when unknown.
    public var pointerDisplay: DisplayID?

    /// Shows every item, app cells included; for a switcher not tied to settings.
    public static let showingEverything: SwitcherFilter = {
        var shownWindows = ShownWindows()
        shownWindows.windowlessApps = true
        return SwitcherFilter(shownWindows: shownWindows, excludedApps: [], pointerDisplay: nil)
    }()

    public init(shownWindows: ShownWindows, excludedApps: Set<String>, pointerDisplay: DisplayID?) {
        self.shownWindows = shownWindows
        self.excludedApps = excludedApps
        self.pointerDisplay = pointerDisplay
    }

    public init(_ settings: Settings, pointerDisplay: DisplayID?) {
        self.init(
            shownWindows: settings.shownWindows,
            excludedApps: Set(settings.excludedApps),
            pointerDisplay: pointerDisplay
        )
    }

    /// Whether the switcher may list `item`:
    ///
    /// - an excluded app's windows, and its app cell, never appear (an app without a bundle ID cannot be excluded);
    /// - minimized windows appear only with `minimized`;
    /// - windows of hidden apps, and hidden apps' cells, appear only with `hiddenApps`;
    /// - with `pointerDisplayOnly`, a window appears only when its display (`WindowEntry.display`, the display it
    ///   overlaps most) is `pointerDisplay`; a window on no display does not. When the pointer's display is unknown
    ///   (nil), no window is left out for it. App cells have no display and are not affected;
    /// - app cells appear only with `windowlessApps`.
    public func shows(_ item: SwitcherItem) -> Bool {
        if let bundleIdentifier = item.bundleIdentifier, excludedApps.contains(bundleIdentifier) { return false }
        if !shownWindows.hiddenApps, item.isAppHidden { return false }
        switch item {
        case let .window(entry):
            return (shownWindows.minimized || !entry.isMinimized)
                && (!shownWindows.pointerDisplayOnly || pointerDisplay == nil || entry.display == pointerDisplay)
        case .app:
            return shownWindows.windowlessApps
        }
    }

    /// The switcher's cells for a window list: its windows in recency order, then a cell for each app it reports
    /// without a switchable window, in its order, keeping those `shows(_:)` allows. An app whose windows an option
    /// removed is not windowless and gets no cell.
    public func items(from list: WindowList) -> [SwitcherItem] {
        list.items.filter(shows)
    }
}

extension WindowList {
    /// Every cell for the list, before the Shown-windows options and excluded apps: its windows in recency order, the
    /// current one first, then a cell for each app it reports without a switchable window. `SwitcherViewModel` takes
    /// these, so it can tell whether its filter left out the current window.
    public var items: [SwitcherItem] {
        windows.map(SwitcherItem.window) + windowlessApps.map(SwitcherItem.app)
    }
}

extension Settings {
    /// The switcher's cells for a window list, applying the Shown-windows options and the excluded apps
    /// (`SwitcherFilter`) after `WindowFilter`'s rules.
    public func items(from list: WindowList, pointerDisplay: DisplayID?) -> [SwitcherItem] {
        SwitcherFilter(self, pointerDisplay: pointerDisplay).items(from: list)
    }
}
