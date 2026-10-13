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

/// Chromium browsers, whose active tab URL is read over Apple Events once the window's `mode` reads `normal`. Safari
/// is title-only: its dictionary has no private-window property, so its URLs are not read (see the README).
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

/// Sends get-data Apple Events to one running app. Unlike NSAppleScript, which Apple lists as main-thread only, this is
/// safe on the reader's background queue. Each event waits at most two seconds.
struct AppleEventReader {
    private let target: NSAppleEventDescriptor

    init(pid: pid_t) { target = NSAppleEventDescriptor(processIdentifier: pid) }

    /// The value of `specifier`, or nil on any error or timeout. A `missing value` answer is returned as is.
    func get(_ specifier: NSAppleEventDescriptor) -> NSAppleEventDescriptor? {
        let event = NSAppleEventDescriptor.appleEvent(withEventClass: AEEventClass(kAECoreSuite), eventID: AEEventID(kAEGetData),
                                                      targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID),
                                                      transactionID: AETransactionID(kAnyTransactionID))
        event.setParam(specifier, forKeyword: AEKeyword(keyDirectObject))
        guard let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 2) else { return nil }
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 { return nil }
        return reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))
    }

    /// Text of a successful answer; nil for `missing value` or a non-text answer.
    static func text(_ descriptor: NSAppleEventDescriptor) -> String? {
        if descriptor.descriptorType == DescType(typeType), descriptor.typeCodeValue == code("msng") { return nil }
        return descriptor.stringValue
    }

    static func window(index: Int32) -> NSAppleEventDescriptor {
        specifier(want: DescType(cWindow), form: DescType(formAbsolutePosition), data: NSAppleEventDescriptor(int32: index), of: .null())
    }

    static func window(id: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: DescType(cWindow), form: DescType(formUniqueID), data: id, of: .null())
    }

    /// A property by its four-character code from the app's scripting dictionary, such as "pnam" for name.
    static func property(_ code: String, of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        specifier(want: DescType(cProperty), form: DescType(formPropertyID), data: NSAppleEventDescriptor(typeCode: Self.code(code)), of: container)
    }

    private static func code(_ text: String) -> DescType { text.utf8.reduce(0) { $0 << 8 | DescType($1) } }

    private static func specifier(want: DescType, form: DescType, data: NSAppleEventDescriptor,
                                  of container: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: want), forKeyword: AEKeyword(keyAEDesiredClass))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: form), forKeyword: AEKeyword(keyAEKeyForm))
        record.setDescriptor(data, forKeyword: AEKeyword(keyAEKeyData))
        record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
        return record.coerce(toDescriptorType: DescType(typeObjectSpecifier)) ?? record
    }
}

enum AutomationPermission: Sendable {
    case granted, denied, notDetermined, unavailable
}

/// Reads the focused window title and, for supported browsers, the active tab's URL. Every call runs on one serial
/// background queue so a slow or hung app cannot stall the menu bar; each read is bounded by a timeout.
final class ActivityReader: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.subset.point-in-time.reader", qos: .utility)
    /// Loaded on first use, on `queue`. Applied to every title-only app, so Safari's private windows keep no title.
    private lazy var privateTitles = Self.loadSafariPrivateTitles()

    /// What may be recorded for the front window, after `WindowPrivacy.reduce`.
    struct Result: Sendable {
        var title: String?
        var url: RedactedURL?
    }

    func read(pid: pid_t, bundleID: String, readTitle: Bool, completion: @escaping @Sendable (Result) -> Void) {
        queue.async { [self] in
            let title = readTitle ? focusedWindowTitle(pid: pid) : nil
            guard let browser = SupportedBrowser.matching(bundleID) else {
                let reduced = WindowPrivacy.reduce(focusedTitle: title, readsTitles: readTitle, support: .titleOnly,
                                                   report: .unconfirmed, privateTitles: privateTitles)
                completion(Result(title: reduced.title, url: reduced.url))
                return
            }
            var report = BrowserWindowReport.unconfirmed
            if Self.permission(for: browser.bundleID, ask: false) == .granted {
                report = .chromium(frontWindow(AppleEventReader(pid: pid)))
            }
            let reduced = WindowPrivacy.reduce(focusedTitle: title, readsTitles: readTitle, support: .scriptable,
                                               report: report, privateTitles: privateTitles)
            completion(Result(title: reduced.title, url: reduced.url))
        }
    }

    /// The front window's id, `mode`, active tab title, and URL, every event addressed to that window by its id. A
    /// failed event yields nil; a dictionary without `mode` yields a nil mode. Both keep nothing.
    private func frontWindow(_ events: AppleEventReader) -> ScriptedWindow? {
        typealias AE = AppleEventReader
        guard let id = events.get(AE.property("ID  ", of: AE.window(index: 1))), let idText = id.stringValue else { return nil }
        let window = AE.window(id: id)
        guard let mode = events.get(AE.property("mode", of: window)) else { return ScriptedWindow(id: idText) }
        let tab = AE.property("acTa", of: window)
        guard let title = events.get(AE.property("pnam", of: tab)), let url = events.get(AE.property("URL ", of: tab)) else { return nil }
        return ScriptedWindow(id: idText, mode: AE.text(mode), title: AE.text(title), url: AE.text(url))
    }

    /// Asks macOS whether this app may send Apple Events to `bundleID`. With `ask`, macOS shows its consent prompt
    /// once; that call can block, so it is only made off the main thread.
    static func permission(for bundleID: String, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let descriptor = target.aeDesc else { return .unavailable }
        // Ask about the get-data event the reader sends: macOS does not prompt for wildcard event codes.
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

    /// Safari's private-window titles in every language its framework ships, plus English.
    private static func loadSafariPrivateTitles() -> PrivateWindowTitles {
        let frameworks = ["/System/Library/PrivateFrameworks/Safari.framework", "/System/Cryptexes/App/System/Library/PrivateFrameworks/Safari.framework"]
        var tables: [[String: String]] = []
        for path in frameworks {
            guard let bundle = Bundle(path: path) else { continue }
            for localization in bundle.localizations {
                guard let file = bundle.path(forResource: "Localizable", ofType: "strings", inDirectory: nil, forLocalization: localization),
                      let table = NSDictionary(contentsOfFile: file) as? [String: Any] else { continue }
                var keys: [String: String] = [:]
                for key in [PrivateWindowTitles.formatKey, PrivateWindowTitles.titleKey] { keys[key] = table[key] as? String }
                tables.append(keys)
            }
        }
        return PrivateWindowTitles(tables: tables)
    }
}
