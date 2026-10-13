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

/// Browsers whose active tab URL is read over Apple Events. Chromium browsers report a window's `mode`; Safari's
/// private windows are recognized by comparing titles (see `BrowserWindowReport.safari`).
struct SupportedBrowser: Hashable, Sendable {
    enum Engine: Sendable { case safari, chromium }

    let bundleID: String
    let name: String
    let engine: Engine

    static let all: [SupportedBrowser] = [
        SupportedBrowser(bundleID: "com.apple.Safari", name: "Safari", engine: .safari),
        SupportedBrowser(bundleID: "com.google.Chrome", name: "Google Chrome", engine: .chromium),
        SupportedBrowser(bundleID: "com.brave.Browser", name: "Brave", engine: .chromium),
        SupportedBrowser(bundleID: "com.microsoft.edgemac", name: "Microsoft Edge", engine: .chromium),
        SupportedBrowser(bundleID: "company.thebrowser.Browser", name: "Arc", engine: .chromium),
        SupportedBrowser(bundleID: "com.vivaldi.Vivaldi", name: "Vivaldi", engine: .chromium),
        SupportedBrowser(bundleID: "at.studio.AsideBrowser", name: "Aside", engine: .chromium)
    ]

    static func matching(_ bundleID: String) -> SupportedBrowser? { all.first { $0.bundleID == bundleID } }

    static var installed: [SupportedBrowser] {
        all.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0.bundleID) != nil }
    }

    /// The script whose answer `BrowserWindowReport` interprets. Any error or timeout yields no confirmation.
    var scriptSource: String {
        switch engine {
        case .chromium:
            // The window's mode must read "normal"; a browser whose dictionary lacks the property errors out.
            """
            tell application id "\(bundleID)"
                with timeout of 2 seconds
                    if (count of windows) is 0 then return ""
                    set frontWindow to front window
                    if (mode of frontWindow as text) is not "normal" then return "PRIVATE"
                    set tabTitle to title of active tab of frontWindow
                    if tabTitle is missing value then set tabTitle to ""
                    set tabURL to URL of active tab of frontWindow
                    if tabURL is missing value then set tabURL to ""
                    return "NORMAL" & linefeed & tabTitle & linefeed & tabURL
                end timeout
            end tell
            """
        case .safari:
            """
            tell application id "\(bundleID)"
                with timeout of 2 seconds
                    if (count of windows) is 0 then return ""
                    set frontWindow to front window
                    set tabURL to URL of current tab of frontWindow
                    if tabURL is missing value then set tabURL to ""
                    return (name of frontWindow) & linefeed & tabURL
                end timeout
            end tell
            """
        }
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

    /// What may be recorded for the front window, after `WindowPrivacy.reduce`.
    struct Result: Sendable {
        var title: String?
        var url: RedactedURL?
    }

    func read(pid: pid_t, bundleID: String, readTitle: Bool, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            let title = readTitle ? focusedWindowTitle(pid: pid) : nil
            guard let browser = SupportedBrowser.matching(bundleID) else {
                let reduced = WindowPrivacy.reduce(focusedTitle: title, readsTitles: readTitle, support: .titleOnly, report: .unconfirmed)
                completion(Result(title: reduced.title, url: reduced.url))
                return
            }
            var report = BrowserWindowReport.unconfirmed
            if Self.permission(for: browser.bundleID, ask: false) == .granted {
                let output = runScript(for: browser)
                switch browser.engine {
                case .chromium:
                    report = .chromium(scriptOutput: output)
                case .safari:
                    // Read the focused title again so a window switch during the script cannot be confirmed.
                    let after = readTitle ? focusedWindowTitle(pid: pid) : nil
                    report = .safari(focusedTitleBefore: title, focusedTitleAfter: after, scriptOutput: output)
                }
            }
            let reduced = WindowPrivacy.reduce(focusedTitle: title, readsTitles: readTitle, support: .scriptable, report: report)
            completion(Result(title: reduced.title, url: reduced.url))
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

    private func runScript(for browser: SupportedBrowser) -> String? {
        let script: NSAppleScript
        if let cached = scripts[browser.bundleID] {
            script = cached
        } else {
            guard let compiled = NSAppleScript(source: browser.scriptSource) else { return nil }
            var error: NSDictionary?
            guard compiled.compileAndReturnError(&error) else { return nil }
            scripts[browser.bundleID] = compiled
            script = compiled
        }
        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        return error == nil ? output.stringValue : nil
    }
}
