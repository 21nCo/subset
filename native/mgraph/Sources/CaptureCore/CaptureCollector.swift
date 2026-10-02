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
    public struct Source: Codable, Sendable {
        public let applicationName: String?
        public let bundleIdentifier: String?
        public let processIdentifier: Int32?
        public let windowTitle: String?
        public let documentURL: String?

        public init(applicationName: String? = nil, bundleIdentifier: String? = nil,
                    processIdentifier: Int32? = nil, windowTitle: String? = nil,
                    documentURL: String? = nil) {
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.processIdentifier = processIdentifier
            self.windowTitle = windowTitle
            self.documentURL = documentURL
        }
    }
    public let state: CaptureState
    public let observedAt: Date
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let documentURL: String?
    public let text: String?
    public let error: String?

    public init(state: CaptureState, observedAt: Date = Date(), source: Source = Source(),
                text: String? = nil, error: String? = nil) {
        self.state = state
        self.observedAt = observedAt
        self.applicationName = source.applicationName
        self.bundleIdentifier = source.bundleIdentifier
        self.processIdentifier = source.processIdentifier
        self.windowTitle = source.windowTitle
        self.documentURL = source.documentURL
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

    @MainActor public static func afterCaptureWorkerDrains(_ completion: @escaping @MainActor @Sendable () -> Void) {
        captureQueue.async { DispatchQueue.main.async(execute: completion) }
    }

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
        CaptureResult(state: .readFailed, source: .init(applicationName: app?.name,
                      bundleIdentifier: app?.bundleID, processIdentifier: app?.pid), error: message)
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
            DispatchQueue.main.async { delivery.deliver(deadline.expired ? nil : result, to: completion) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            deadline.cancel()
            delivery.deliver(nil, to: completion)
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
        @MainActor func deliver(_ result: CaptureResult?,
                                to completion: @escaping @MainActor @Sendable (CaptureResult?) -> Void) {
            once { completion(result) }
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

    public static func cliConsentFailure(approved: Bool, foregroundAvailable: Bool) -> CaptureResult? {
        if !approved { return CaptureResult(state: .readFailed, error: "Command capture was not approved") }
        if !foregroundAvailable {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        return nil
    }

    // The native menu check may inspect alert text only for its own fixture.
    // Reject a foreground switch before the alert receives any captured body.
    public static func bindFixture(_ result: CaptureResult, bundleIdentifier: String,
                                   windowTitle: String) -> CaptureResult {
        guard result.state == .available else { return result }
        guard result.bundleIdentifier == bundleIdentifier,
              result.windowTitle?.contains(windowTitle) == true else {
            return CaptureResult(state: .readFailed, error: "Foreground fixture changed before alert")
        }
        return result
    }

    public static func captureForeground(expectedProcessIdentifier: pid_t? = nil) -> CaptureResult {
        guard isTrusted() else { return status() }
        guard let app = foreground() else {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        if let expectedProcessIdentifier, app.pid != expectedProcessIdentifier {
            return failed(app, "Foreground application changed before capture")
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
        guard let source, let extraction = extractText(from: target, deadline: deadline) else {
            return failed(app, "Accessibility tree exceeded the capture limit")
        }
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let currentWindow = captureWindow(root, deadline: deadline)
        let current = currentWindow.flatMap { window in
            sourceIdentity(root: root, target: window, app: app,
                           title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                           document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                           deadline: deadline)
        }
        // AX can reuse a window, tab, and web-area element across a navigation.
        // Read the current focused window again so missing source attributes cannot
        // make text from the preceding page look current.
        let confirmation = currentWindow.flatMap { extractText(from: $0, deadline: deadline)?.text }
        let finalWindow = captureWindow(root, deadline: deadline)
        let finalRead = confirmAfterFinalText(
            readText: { finalWindow.flatMap { extractText(from: $0, deadline: deadline)?.text } },
            readSource: { focusedSource(root: root, app: app, deadline: deadline) })
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let state = stateForText(extraction.text)
        let result = CaptureResult(state: state, source: .init(applicationName: app.name,
                                   bundleIdentifier: app.bundleID, processIdentifier: app.pid,
                                   windowTitle: title, documentURL: document),
                                   text: extraction.text.isEmpty ? nil : extraction.text,
                                   error: extraction.text.isEmpty ? "No readable text in the Accessibility tree" : nil)
        return checkedCapture(result, initial: source, current: current,
                              confirmation: confirmation, final: finalRead.source, finalText: finalRead.text)
    }

    private static func focusedSource(root: AXUIElement, app: Foreground,
                                      deadline: Deadline) -> SourceIdentity? {
        guard let window = captureWindow(root, deadline: deadline) else { return nil }
        return sourceIdentity(root: root, target: window, app: app,
                              title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                              document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                              deadline: deadline)
    }

    static func confirmAfterFinalText(readText: () -> String?,
                                      readSource: () -> SourceIdentity?) -> (text: String?, source: SourceIdentity?) {
        let text = readText()
        return (text, readSource())
    }

    static func checkedCapture(_ result: CaptureResult, initial: SourceIdentity,
                               current: SourceIdentity?, confirmation: String?,
                               final: SourceIdentity?, finalText: String?) -> CaptureResult {
        guard let current, let final, initial == current, initial == final,
              let confirmation, let finalText,
              result.text == (confirmation.isEmpty ? nil : confirmation),
              result.text == (finalText.isEmpty ? nil : finalText) else {
            return CaptureResult(state: .readFailed, source: .init(applicationName: result.applicationName,
                                 bundleIdentifier: result.bundleIdentifier, processIdentifier: result.processIdentifier),
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
        // AX has a range API for some text controls, but not for arbitrary
        // scalar attributes (notably Chrome static text). Check the length
        // immediately after the provider reply, before normalizing or copying.
        guard let raw = attribute(element, name, deadline: deadline) as? String else { return nil }
        if (raw as NSString).length > 6000 {
            deadline.cancel()
            return nil
        }
        return raw
    }

    private static func textValue(_ element: AXUIElement, remaining: Int, deadline: Deadline) -> String? {
        guard remaining > 0, !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var characterCount: CFTypeRef?
        let countError = AXUIElementCopyAttributeValue(element,
            kAXNumberOfCharactersAttribute as CFString, &characterCount)
        let reportedCount = countError == .success ? (characterCount as? NSNumber)?.intValue : nil
        // TextEdit can report a length; Safari and Firefox static text accept
        // a bounded range without one. Chrome static text currently supports
        // neither and requires the scalar fallback below.
        let requested = min(remaining, max(0, reportedCount ?? remaining))
        if requested > 0 {
            var range = CFRange(location: 0, length: requested)
            if let axRange = AXValueCreate(.cfRange, &range) {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    axRange, &value) == .success, !deadline.expired,
                    let text = value as? String, (text as NSString).length <= remaining {
                    return text
                }
            }
        }
        return stringAttribute(element, kAXValueAttribute as String, deadline: deadline)
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
                                       title: String?, document: String?, deadline: Deadline) -> SourceIdentity? {
        let focused = attribute(root, kAXFocusedUIElementAttribute as String, deadline: deadline)
        let focusedID = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? CFHash($0) : nil }
        guard let content = activeContent(in: target, deadline: deadline) else { return nil }
        return SourceIdentity(pid: app.pid, window: CFHash(target), title: title, document: document,
                              focusedElement: focusedID, selectedTabs: content.tabs, webAreas: content.webAreas)
    }

    // AXUIElementCopyAttributeValue materializes an entire child array. Query its
    // count first, then request only a bounded range. An oversized array fails
    // closed because a source hidden after the range could invalidate identity.
    private static func elements(_ element: AXUIElement, _ name: String, maxCount: Int,
                                 deadline: Deadline) -> [AXUIElement]? {
        guard !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return boundedElements(maxCount: maxCount, count: {
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
            if error == .attributeUnsupported || error == .noValue { return 0 }
            guard error == .success, !deadline.expired else { return nil }
            return count
        }, readRange: { requested in
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, name as CFString, 0, requested, &values) == .success,
                  !deadline.expired, let values else { return nil }
            let array = values as [AnyObject]
            guard array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return array.map { $0 as! AXUIElement }
        })
    }

    // The injected count/range seam proves that a large provider array is
    // rejected without invoking its potentially expensive range read.
    static func boundedElements<T>(maxCount: Int, count: () -> Int?,
                                   readRange: (Int) -> [T]?) -> [T]? {
        guard let length = count(), length >= 0, length <= maxCount else { return nil }
        guard length > 0 else { return [] }
        guard let result = readRange(length), result.count == length else { return nil }
        return result
    }

    private static func activeContent(in root: AXUIElement, deadline: Deadline) -> (tabs: [CFHashCode], webAreas: [CFHashCode])? {
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
                guard let tabs = elements(element, kAXSelectedChildrenAttribute as String,
                                          maxCount: 30, deadline: deadline) else { return nil }
                selected.append(contentsOf: tabs.map(CFHash))
            }
            if role == "AXWebArea" { webAreas.append(CFHash(element)) }
            if depth < 5 {
                guard let children = elements(element, kAXChildrenAttribute as String,
                                              maxCount: min(30, 80 - pending.count), deadline: deadline) else { return nil }
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return (selected, webAreas)
    }

    typealias StringReader = (AXUIElement, String, Deadline) -> String?
    typealias MetadataReader = (AXUIElement, String, Deadline) -> (AXError, String?)
    typealias ValueReader = (AXUIElement, Int, Deadline) -> String?
    typealias ChildrenReader = (AXUIElement, Int, Deadline) -> [AXUIElement]?

    private static func metadata(_ element: AXUIElement, _ key: String, _ deadline: Deadline) -> (AXError, String?) {
        guard !deadline.expired else { return (.cannotComplete, nil) }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard !deadline.expired else { return (.cannotComplete, nil) }
        return (error, raw as? String)
    }

    static func safeRole(_ element: AXUIElement, deadline: Deadline,
                         read: MetadataReader) -> String? {
        let (roleError, role) = read(element, kAXRoleAttribute as String, deadline)
        guard roleError == .success, let role, !role.isEmpty else { return nil }
        let (subroleError, subrole) = read(element, kAXSubroleAttribute as String, deadline)
        guard subroleError == .success || subroleError == .attributeUnsupported || subroleError == .noValue else {
            return nil
        }
        if subroleError == .success && subrole == nil { return nil }
        return shouldSkip(role: role, subrole: subrole ?? "") ? nil : role
    }

    static func extractText(from root: AXUIElement, deadline: Deadline,
                            readMetadata: MetadataReader = metadata,
                            readString: StringReader = stringAttribute,
                            readValue: ValueReader = textValue,
                            checkTrust: () -> Bool = { isTrusted() },
                            readChildren: ChildrenReader = { element, limit, deadline in
                                elements(element, kAXChildrenAttribute as String, maxCount: limit, deadline: deadline)
                            }) -> (text: String, visited: Int)? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = Set<CFHashCode>()
        var snippets: [String] = []
        var seenText = Set<String>()
        var count = 0
        var length = 0

        while index < queue.count && count < 600 && length < 6000 {
            if deadline.expired || !checkTrust() { break }
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            guard safeRole(element, deadline: deadline, read: readMetadata) != nil else { continue }

            for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                let raw = key == (kAXValueAttribute as String)
                    ? readValue(element, 6000 - length, deadline)
                    : readString(element, key, deadline)
                guard let raw else { continue }
                let snippet = normalize(raw, remaining: 6000 - length)
                if !snippet.isEmpty && seenText.insert(snippet).inserted {
                    snippets.append(snippet)
                    length += snippet.count
                }
            }
            if depth < 12 {
                guard let children = readChildren(element, min(100, 600 - queue.count), deadline) else { return nil }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
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
        var compact = ""
        var count = 0
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                if !compact.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                if count == remaining { break }
                compact.append(" ")
                count += 1
                pendingSpace = false
            }
            if count == remaining { break }
            compact.append(character)
            count += 1
        }
        return compact
    }
}
