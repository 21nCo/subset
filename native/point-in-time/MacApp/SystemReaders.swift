import AppKit
import ApplicationServices
import CoreGraphics
import PointInTimeCore

/// Seconds since the last keyboard, mouse, or trackpad event in this login session.
func secondsSinceLastInput() -> TimeInterval {
    CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
}

enum AccessibilityAccess {
    static var isGranted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that leads to Privacy & Security > Accessibility. It cannot grant access itself.
    static func request() {
        // The documented value of kAXTrustedCheckOptionPrompt; the global itself is not concurrency-safe to reference.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

/// Browsers whose scripting dictionary reports a window's mode, so a private (incognito) window can be recognized
/// and skipped. Safari exposes no such property and is deliberately absent: its URL is never read.
struct SupportedBrowser: Hashable, Sendable {
    let bundleID: String
    let name: String

    static let all: [SupportedBrowser] = [
        SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome"),
        SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave"),
        SupportedBrowser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge"),
        SupportedBrowser(bundleID: "company.thebrowser.Browser", name: "Arc"),
        SupportedBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi"),
        SupportedBrowser(bundleID: "at.studio.AsideBrowser", name: "Aside")
    ]

    static func matching(_ bundleID: String) -> SupportedBrowser? { all.first { $0.bundleID == bundleID } }

    static var installed: [SupportedBrowser] {
        all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }
}

enum AutomationPermission: Sendable {
    case granted, denied, notDetermined, unavailable
}

/// Reads the focused window title and, for supported browsers, the active tab's URL. Every call runs on one serial
/// background queue so a slow or hung app cannot stall the menu bar; each read is bounded by a timeout.
final class ActivityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.subset.point-in-time.reader", qos: .utility)
    private var scripts: [String: NSAppleScript] = [:]

    struct Result: Sendable {
        var title: String?
        var url: RedactedURL?
        /// True when the browser reported a private window; the title is then dropped too.
        var isPrivateWindow = false
    }

    func read(pid: pid_t, bundleID: String, readTitle: Bool, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            var result = Result()
            if readTitle { result.title = focusedWindowTitle(pid: pid) }
            if let browser = SupportedBrowser.matching(bundleID), Self.permission(for: browser.bundleID, ask: false) == .granted {
                switch activeTab(browser) {
                case .privateWindow: result.isPrivateWindow = true
                case .url(let url): result.url = url
                case .none: break
                }
            }
            if result.isPrivateWindow || Self.looksPrivate(title: result.title) {
                result = Result(title: nil, url: nil, isPrivateWindow: true)
            }
            completion(result)
        }
    }

    /// Asks macOS whether this app may send Apple Events to `bundleID`. With `ask`, macOS shows its consent prompt
    /// once; that call can block, so it is only made off the main thread.
    static func permission(for bundleID: String, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .unavailable }
        // Ask about the get-data event the URL script sends: macOS does not prompt for wildcard event codes.
        let status = AEDeterminePermissionToAutomateTarget(descriptor, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), ask)
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined
        default: return .unavailable // procNotFound: the browser is not running
        }
    }

    /// Window titles of private windows in browsers without a reliable scripting signal (or without permission to
    /// ask) are dropped when they carry the browser's private-mode marker.
    static func looksPrivate(title: String?) -> Bool {
        guard let title = title?.lowercased() else { return false }
        return ["private browsing", "incognito", "inprivate"].contains { title.contains($0) }
    }

    private func focusedWindowTitle(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        var window: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &window) == .success,
              let window, CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        let element = window as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success else { return nil }
        return title as? String
    }

    private enum TabResult { case url(RedactedURL), privateWindow }

    private func activeTab(_ browser: SupportedBrowser) -> TabResult? {
        let script: NSAppleScript
        if let cached = scripts[browser.bundleID] {
            script = cached
        } else {
            // The window's mode must read "normal"; any error or other value (including a browser whose dictionary
            // lacks the property) yields no URL.
            let source = """
            tell application id "\(browser.bundleID)"
                with timeout of 2 seconds
                    if (count of windows) is 0 then return ""
                    set frontWindow to front window
                    if (mode of frontWindow as text) is not "normal" then return "PRIVATE"
                    return URL of active tab of frontWindow
                end timeout
            end tell
            """
            guard let compiled = NSAppleScript(source: source) else { return nil }
            var error: NSDictionary?
            guard compiled.compileAndReturnError(&error) else { return nil }
            scripts[browser.bundleID] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        guard error == nil, let value = output.stringValue else { return nil }
        if value == "PRIVATE" { return .privateWindow }
        return RedactedURL(value).map { .url($0) }
    }
}
