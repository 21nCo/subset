import CoreGraphics
import Foundation

/// Identifies one window for as long as its source can tell it apart, so recency and later actions (SET-93) can
/// refer to it. The value is opaque: the source assigns it, nothing derives meaning from it, and it is never shown.
public struct WindowRef: Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) {
        self.rawValue = rawValue
    }
}

/// A display's ID as CoreGraphics reports it (`CGDirectDisplayID`).
public typealias DisplayID = UInt32

/// How an app presents itself, as `NSRunningApplication.activationPolicy` reports it. Only `.regular` apps (those
/// with a Dock icon) have switchable windows.
public enum AppActivationPolicy: Sendable, Equatable {
    case regular
    case accessory
    case prohibited
}

/// A running app as the source reports it.
public struct SourceApp: Sendable, Equatable {
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var name: String
    public var activationPolicy: AppActivationPolicy
    public var isHidden: Bool

    public init(
        pid: pid_t,
        bundleIdentifier: String?,
        name: String,
        activationPolicy: AppActivationPolicy = .regular,
        isHidden: Bool = false
    ) {
        self.pid = pid
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.activationPolicy = activationPolicy
        self.isHidden = isHidden
    }
}

/// One window of an app as the source reports it, before `WindowFilter` decides whether it is switchable.
public struct SourceWindow: Sendable, Equatable {
    public var ref: WindowRef
    /// The window's title; empty when it has none or it could not be read. Never logged or persisted.
    public var title: String
    /// The Accessibility subrole, such as `AXStandardWindow`, or nil when the window reports none.
    public var subrole: String?
    public var isMinimized: Bool
    public var isFullscreen: Bool
    /// The window's frame in global screen points with the origin at the top left of the main display, the
    /// coordinates both Accessibility and `CGWindowListCopyWindowInfo` use; nil when its position or size could not
    /// be read.
    public var frame: CGRect?

    public init(
        ref: WindowRef,
        title: String = "",
        subrole: String?,
        isMinimized: Bool = false,
        isFullscreen: Bool = false,
        frame: CGRect?
    ) {
        self.ref = ref
        self.title = title
        self.subrole = subrole
        self.isMinimized = isMinimized
        self.isFullscreen = isFullscreen
        self.frame = frame
    }
}

/// A display and its bounds, in the same global coordinates as window frames.
public struct SourceDisplay: Sendable, Equatable {
    public var id: DisplayID
    public var bounds: CGRect

    public init(id: DisplayID, bounds: CGRect) {
        self.id = id
        self.bounds = bounds
    }

    /// The display a frame is on: the one it overlaps most, the first of those listed on a tie, or nil when it
    /// overlaps none.
    public static func display(for frame: CGRect, among displays: [SourceDisplay]) -> DisplayID? {
        var best: (id: DisplayID, area: CGFloat)?
        for display in displays {
            let overlap = display.bounds.intersection(frame)
            guard !overlap.isNull else { continue }
            let area = overlap.width * overlap.height
            if area > 0, area > (best?.area ?? 0) { best = (display.id, area) }
        }
        return best?.id
    }
}

/// A switchable window, as the switcher lists it.
public struct WindowEntry: Sendable, Equatable {
    public var ref: WindowRef
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var appName: String
    /// May be empty. Never logged or persisted.
    public var title: String
    public var isMinimized: Bool
    /// Whether the window's app is hidden (⌘H); the window is listed all the same.
    public var isAppHidden: Bool
    public var isFullscreen: Bool
    public var frame: CGRect
    /// The display the window is on, or nil when its frame overlaps no display.
    public var display: DisplayID?

    public init(app: SourceApp, window: SourceWindow, frame: CGRect, display: DisplayID?) {
        ref = window.ref
        pid = app.pid
        bundleIdentifier = app.bundleIdentifier
        appName = app.name
        title = window.title
        isMinimized = window.isMinimized
        isAppHidden = app.isHidden
        isFullscreen = window.isFullscreen
        self.frame = frame
        self.display = display
    }
}

/// A regular app with no switchable window, for the option to list windowless apps (`ShownWindows.windowlessApps`).
public struct AppEntry: Sendable, Equatable {
    public var pid: pid_t
    public var bundleIdentifier: String?
    public var name: String
    public var isHidden: Bool

    public init(_ app: SourceApp) {
        pid = app.pid
        bundleIdentifier = app.bundleIdentifier
        name = app.name
        isHidden = app.isHidden
    }
}

/// An app whose windows could not be read in one refresh. It is left out of that list; the rest are listed.
public struct SkippedApp: Sendable, Equatable {
    public var pid: pid_t
    public var reason: WindowSourceError

    public init(pid: pid_t, reason: WindowSourceError) {
        self.pid = pid
        self.reason = reason
    }
}

/// One refresh's result.
public struct WindowList: Sendable, Equatable {
    /// The switchable windows, most recently used first.
    public var windows: [WindowEntry]
    /// Regular apps that answered but have no switchable window, in source order.
    public var windowlessApps: [AppEntry]
    /// Apps that timed out or failed, in source order.
    public var skippedApps: [SkippedApp]

    public init(windows: [WindowEntry] = [], windowlessApps: [AppEntry] = [], skippedApps: [SkippedApp] = []) {
        self.windows = windows
        self.windowlessApps = windowlessApps
        self.skippedApps = skippedApps
    }
}
