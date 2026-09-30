import AppKit
import ApplicationServices
import Foundation

public enum CaptureState: String, Codable, Sendable {
    case available
    case permissionRequired
    case noForegroundApplication
    case unsupportedApplication
    case readFailed
}

public struct CaptureResult: Codable, Sendable {
    public let state: CaptureState
    public let observedAt: Date
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let documentURL: String?
    public let text: String?
    public let error: String?

    public init(state: CaptureState, observedAt: Date = Date(), applicationName: String? = nil,
                bundleIdentifier: String? = nil, processIdentifier: Int32? = nil,
                windowTitle: String? = nil, documentURL: String? = nil, text: String? = nil,
                error: String? = nil) {
        self.state = state
        self.observedAt = observedAt
        self.applicationName = applicationName
        self.bundleIdentifier = bundleIdentifier
        self.processIdentifier = processIdentifier
        self.windowTitle = windowTitle
        self.documentURL = documentURL
        self.text = text
        self.error = error
    }
}

// The menu can cancel a worker without stopping an AX call already in progress.
// Only the most recent live request may present a result.
@MainActor public final class CaptureRequestGate {
    private var current: UUID?

    public init() {}

    public func begin() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    public func cancel() { current = nil }

    public func finish(_ token: UUID) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }
}

public enum CaptureCollector {
    public static let captureTimeout: TimeInterval = 4
    private static let captureQueue = DispatchQueue(label: "dev.subset.mgraph.ax-capture", qos: .userInitiated)

    private struct Foreground: Sendable {
        let pid: pid_t
        let name: String?
        let bundleID: String?
    }

    // AX window elements identify separate windows even when their titles match.
    // Selected tabs and focused elements distinguish sources inside one window.
    struct SourceIdentity: Equatable {
        let pid: pid_t
        let window: CFHashCode
        let title: String?
        let document: String?
        let focusedElement: CFHashCode?
        let selectedTabs: [CFHashCode]
        let webAreas: [CFHashCode]
    }

    // The lock also prevents a late AX reply from publishing text after a deadline.
    public final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let end: UInt64
        private var cancelled = false

        public init(seconds: TimeInterval) {
            end = DispatchTime.now().uptimeNanoseconds + UInt64(max(0, seconds) * 1_000_000_000)
        }

        public var expired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled || DispatchTime.now().uptimeNanoseconds >= end
        }

        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    private static func foreground() -> Foreground? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Foreground(pid: app.processIdentifier, name: app.localizedName, bundleID: app.bundleIdentifier)
    }

    private static func failed(_ app: Foreground?, _ message: String) -> CaptureResult {
        CaptureResult(state: .readFailed, applicationName: app?.name, bundleIdentifier: app?.bundleID,
                      processIdentifier: app?.pid, error: message)
    }

    private static func validate(_ result: CaptureResult, app: Foreground?, deadline: Deadline) -> CaptureResult {
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app?.pid {
            return failed(app, "Foreground application changed during capture")
        }
        return result
    }

    // Called on the main thread by both entry points. AX work never occupies the menu loop.
    @discardableResult
    @MainActor public static func captureForeground(completion: @escaping @MainActor @Sendable (CaptureResult) -> Void) -> Deadline? {
        guard isTrusted() else { completion(status()); return nil }
        guard let app = foreground() else {
            completion(CaptureResult(state: .noForegroundApplication, error: "No foreground application"))
            return nil
        }
        let deadline = Deadline(seconds: captureTimeout)
        runAsync(deadline: deadline, seconds: captureTimeout, work: {
            performCapture(app, deadline: deadline)
        }) { result in
            completion(validate(result ?? failed(app, "Accessibility capture deadline exceeded"),
                                app: app, deadline: deadline))
        }
        return deadline
    }

    @MainActor static func runAsync(deadline: Deadline, seconds: TimeInterval,
                                    work: @escaping @Sendable () -> CaptureResult,
                                    completion: @escaping @MainActor @Sendable (CaptureResult?) -> Void) {
        let delivery = Delivery()
        captureQueue.async {
            let result = work()
            DispatchQueue.main.async {
                delivery.once { completion(deadline.expired ? nil : result) }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            delivery.once {
                deadline.cancel()
                completion(nil)
            }
        }
    }

    private final class Delivery: @unchecked Sendable {
        private var delivered = false
        private let lock = NSLock()
        func once(_ body: () -> Void) {
            lock.lock()
            let shouldDeliver = !delivered
            delivered = true
            lock.unlock()
            if shouldDeliver { body() }
        }
    }
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    @discardableResult
    public static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    public static func status() -> CaptureResult {
        let trusted = isTrusted()
        return CaptureResult(state: trusted ? .available : .permissionRequired,
                             error: trusted ? nil : "Grant Accessibility access in System Settings > Privacy & Security > Accessibility.")
    }

    public static func captureForeground() -> CaptureResult {
        guard isTrusted() else { return status() }
        guard let app = foreground() else {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        let deadline = Deadline(seconds: captureTimeout)
        let result = runBounded(deadline: deadline, seconds: captureTimeout) {
            performCapture(app, deadline: deadline)
        }
        return validate(result ?? failed(app, "Accessibility capture deadline exceeded"), app: app,
                        deadline: deadline)
    }

    // The bounded runner is also exercised with a deliberately slow fake tree.
    static func runBounded(deadline: Deadline, seconds: TimeInterval,
                           work: @escaping @Sendable () -> CaptureResult) -> CaptureResult? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        captureQueue.async {
            box.result = work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut { deadline.cancel(); return nil }
        return deadline.expired ? nil : box.result
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CaptureResult?
        var result: CaptureResult? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    private static func performCapture(_ app: Foreground, deadline: Deadline) -> CaptureResult {
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var roleValue: CFTypeRef?
        let rootError = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleValue)
        if rootError == .apiDisabled { return status() }
        if rootError == .cannotComplete {
            return failed(app, "Accessibility request timed out")
        }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        guard let target = captureWindow(root, deadline: deadline) else {
            return failed(app, "Focused Accessibility window unavailable")
        }
        let title = stringAttribute(target, kAXTitleAttribute as String, deadline: deadline)
        let document = stringAttribute(target, kAXDocumentAttribute as String, deadline: deadline)
        let source = sourceIdentity(root: root, target: target, app: app, title: title,
                                    document: document, deadline: deadline)
        let extraction = extractText(from: target, deadline: deadline)
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let currentWindow = captureWindow(root, deadline: deadline)
        let current = currentWindow.map { window in
            sourceIdentity(root: root, target: window, app: app,
                           title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                           document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                           deadline: deadline)
        }
        // AX can reuse a window, tab, and web-area element across a navigation.
        // Read the current focused window again so missing source attributes cannot
        // make text from the preceding page look current.
        let confirmation = currentWindow.map { extractText(from: $0, deadline: deadline).text }
        let finalWindow = captureWindow(root, deadline: deadline)
        let final = finalWindow.map { window in
            sourceIdentity(root: root, target: window, app: app,
                           title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                           document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                           deadline: deadline)
        }
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let state = stateForText(extraction.text)
        let result = CaptureResult(state: state, applicationName: app.name, bundleIdentifier: app.bundleID,
                                   processIdentifier: app.pid, windowTitle: title, documentURL: document,
                                   text: extraction.text.isEmpty ? nil : extraction.text,
                                   error: extraction.text.isEmpty ? "No readable text in the Accessibility tree" : nil)
        return checkedCapture(result, initial: source, current: current,
                              confirmation: confirmation, final: final)
    }

    static func checkedCapture(_ result: CaptureResult, initial: SourceIdentity,
                               current: SourceIdentity?, confirmation: String?,
                               final: SourceIdentity?) -> CaptureResult {
        guard let current, let final, initial == current, initial == final,
              let confirmation, result.text == (confirmation.isEmpty ? nil : confirmation) else {
            return CaptureResult(state: .readFailed, applicationName: result.applicationName,
                                 bundleIdentifier: result.bundleIdentifier, processIdentifier: result.processIdentifier,
                                 error: "Foreground source or content changed during capture")
        }
        return result
    }

    static func stateForText(_ text: String) -> CaptureState {
        text.isEmpty ? .unsupportedApplication : .available
    }

    private static func attribute(_ element: AXUIElement, _ name: String, deadline: Deadline) -> CFTypeRef? {
        guard !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        guard !deadline.expired else { return nil }
        return result
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String, deadline: Deadline) -> String? {
        attribute(element, name, deadline: deadline) as? String
    }

    private static func captureWindow(_ root: AXUIElement, deadline: Deadline) -> AXUIElement? {
        verifiedFocusedWindow { attribute(root, $0, deadline: deadline) }
    }

    // AXWindows contains background windows and its order does not identify the foreground source.
    static func verifiedFocusedWindow(_ readAttribute: (String) -> CFTypeRef?) -> AXUIElement? {
        guard let focused = readAttribute(kAXFocusedWindowAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    private static func sourceIdentity(root: AXUIElement, target: AXUIElement, app: Foreground,
                                       title: String?, document: String?, deadline: Deadline) -> SourceIdentity {
        let focused = attribute(root, kAXFocusedUIElementAttribute as String, deadline: deadline)
        let focusedID = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? CFHash($0) : nil }
        let content = activeContent(in: target, deadline: deadline)
        return SourceIdentity(pid: app.pid, window: CFHash(target), title: title, document: document,
                              focusedElement: focusedID, selectedTabs: content.tabs, webAreas: content.webAreas)
    }

    private static func activeContent(in root: AXUIElement, deadline: Deadline) -> (tabs: [CFHashCode], webAreas: [CFHashCode]) {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var seen = Set<CFHashCode>()
        var selected: [CFHashCode] = []
        var webAreas: [CFHashCode] = []
        while index < pending.count && index < 80 && !deadline.expired {
            let (element, depth) = pending[index]
            index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            let role = stringAttribute(element, kAXRoleAttribute as String, deadline: deadline)
            if role == (kAXTabGroupRole as String) {
                if let tabs = attribute(element, kAXSelectedChildrenAttribute as String, deadline: deadline) as? [AXUIElement] {
                    selected.append(contentsOf: tabs.map(CFHash))
                }
            }
            if role == "AXWebArea" { webAreas.append(CFHash(element)) }
            if depth < 5, let children = attribute(element, kAXChildrenAttribute as String, deadline: deadline) as? [AXUIElement] {
                pending.append(contentsOf: children.prefix(30).map { ($0, depth + 1) })
            }
        }
        return (selected, webAreas)
    }

    private static func extractText(from root: AXUIElement, deadline: Deadline) -> (text: String, visited: Int) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = Set<CFHashCode>()
        var snippets: [String] = []
        var seenText = Set<String>()
        var count = 0
        var length = 0

        while index < queue.count && count < 600 && length < 6000 {
            if deadline.expired || !isTrusted() { break }
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            let role = stringAttribute(element, kAXRoleAttribute as String, deadline: deadline) ?? ""
            let subrole = stringAttribute(element, kAXSubroleAttribute as String, deadline: deadline) ?? ""
            if shouldSkip(role: role, subrole: subrole) { continue }

            for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                guard let raw = stringAttribute(element, key, deadline: deadline) else { continue }
                let snippet = normalize(raw, remaining: 6000 - length)
                if !snippet.isEmpty && seenText.insert(snippet).inserted {
                    snippets.append(snippet)
                    length += snippet.count
                }
            }
            if depth < 12, let children = attribute(element, kAXChildrenAttribute as String, deadline: deadline) as? [AXUIElement] {
                queue.append(contentsOf: children.prefix(100).map { ($0, depth + 1) })
            }
        }
        return (String(snippets.joined(separator: "\n").prefix(6000)), count)
    }

    public static func shouldSkip(role: String, subrole: String) -> Bool {
        let combined = "\(role) \(subrole)".lowercased()
        return combined.contains("secure") || combined.contains("password")
    }

    public static func normalize(_ raw: String, remaining: Int) -> String {
        guard remaining > 0 else { return "" }
        let compact = raw.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return String(compact.prefix(remaining)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
