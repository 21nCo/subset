#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

enum ActiveAppTextInjectorError: LocalizedError {
    case accessibilityPermissionMissing
    case postEventPermissionMissing
    case automationPermissionMissing
    case failedToGenerateKeyboardEvents
    case failedToInsertText

    var errorDescription: String? {
        switch self {
        case .accessibilityPermissionMissing:
            return "Enable Accessibility permission for this app in System Settings > Privacy & Security > Accessibility."
        case .postEventPermissionMissing:
            return "Enable permission for this app to post keyboard events, then relaunch the app."
        case .automationPermissionMissing:
            return "Allow Dictate to control System Events in System Settings > Privacy & Security > Automation, then retry."
        case .failedToGenerateKeyboardEvents:
            return "Failed to send paste keyboard events to the active app."
        case .failedToInsertText:
            return "Couldn't insert text into the focused field of the target app."
        }
    }
}

enum ActiveAppInsertionMethod: String {
    case accessibilityCurrent = "current focused accessibility"
    case accessibilityFocused = "focused accessibility target"
    case targetedSyntheticTyping = "targeted synthetic typing"
    case syntheticTyping = "synthetic typing"
    case accessibilityActive = "active app accessibility"
    case targetedPasteFallback = "targeted paste fallback"
    case pasteFallback = "paste fallback"
    case systemEventsPasteFallback = "System Events paste fallback"
    case systemEventsMenuPasteFallback = "System Events menu paste fallback"
    case systemEventsTypingFallback = "System Events typing fallback"
}

private enum RichEditorInsertionStrategy {
    case targetedPaste
    case systemEventsMenuPaste
    case systemEventsTyping
}

struct ActiveAppInsertionApplicationTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    init(application: NSRunningApplication) {
        self.processIdentifier = application.processIdentifier
        self.bundleIdentifier = application.bundleIdentifier
        self.localizedName = application.localizedName
    }
}

struct ActiveAppInsertionTarget {
    let application: ActiveAppInsertionApplicationTarget?
    let focusedElement: AXUIElement?
}

@MainActor
enum ActiveAppTextInjector {
    private static var recentInsertions: [String: Date] = [:]

    static func currentApplicationTarget(excludingSelf: Bool = true) -> ActiveAppInsertionApplicationTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if excludingSelf, application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        return ActiveAppInsertionApplicationTarget(application: application)
    }

    static func captureTarget(excludingSelf: Bool = true) -> ActiveAppInsertionTarget? {
        var focusedElement = copyFocusedElement(from: AXUIElementCreateSystemWide())
        // A field inside Dictate itself is never an insertion target.
        if excludingSelf, let element = focusedElement, processIdentifier(of: element) == ProcessInfo.processInfo.processIdentifier {
            focusedElement = nil
        }
        let focusedApplication = focusedElement.flatMap(applicationTarget(for:))
        let application = focusedApplication ?? currentApplicationTarget(excludingSelf: excludingSelf)

        if excludingSelf, application?.processIdentifier == ProcessInfo.processInfo.processIdentifier, focusedElement == nil {
            return nil
        }

        if application == nil, focusedElement == nil {
            return nil
        }

        return ActiveAppInsertionTarget(application: application, focusedElement: focusedElement)
    }

    static func insert(text: String, target: ActiveAppInsertionTarget? = nil) async throws -> ActiveAppInsertionMethod {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .accessibilityFocused }

        guard ensureAccessibilityTrust(prompt: true) else {
            throw ActiveAppTextInjectorError.accessibilityPermissionMissing
        }

        let targetApplication = resolveApplication(for: target?.application)
        let shouldBypassAccessibility = shouldBypassAccessibilityReplacement(
            for: targetApplication,
            target: target
        )
        purgeRecentInsertions()

        if shouldSuppressDuplicateInsertion(text: trimmed, application: targetApplication) {
            throw ActiveAppTextInjectorError.failedToInsertText
        }

        // The element captured when dictation started comes first; live focus is used only
        // when it belongs to the same app, so switching apps mid-dictation cannot redirect text.
        if !shouldBypassAccessibility,
           let focusedElement = target?.focusedElement,
           replaceSelectedText(trimmed, on: focusedElement) {
            return .accessibilityFocused
        }

        if !shouldBypassAccessibility,
           replaceSelectedTextOnCurrentFocusedElement(trimmed, requiredPID: targetApplication?.processIdentifier) {
            return .accessibilityCurrent
        }

        if shouldRetargetCurrentFrontmostApp(to: targetApplication) {
            bringToFront(target: target, resolvedApplication: targetApplication)
            try await waitForTargetActivation(targetApplication)
        }

        if !shouldBypassAccessibility,
           try insertViaAccessibility(text: trimmed, targetPID: targetApplication?.processIdentifier) {
            return .accessibilityActive
        }

        guard ensurePostEventAccess() else {
            throw ActiveAppTextInjectorError.postEventPermissionMissing
        }

        let pasteboard = PasteboardGuard(.general)

        if shouldBypassAccessibility {
            pasteboard.write(trimmed)
            do {
                switch richEditorInsertionStrategy(for: targetApplication, target: target) {
                case .targetedPaste:
                    try postCommandV(targetPID: targetApplication?.processIdentifier)
                    try await Task.sleep(for: richEditorSettleDelay(for: targetApplication))
                    pasteboard.restore()
                    markInsertion(text: trimmed, application: targetApplication)
                    return .targetedPasteFallback
                case .systemEventsMenuPaste:
                    try pasteViaSystemEventsMenu(on: targetApplication)
                    try await Task.sleep(for: richEditorSettleDelay(for: targetApplication))
                    pasteboard.restore()
                    markInsertion(text: trimmed, application: targetApplication)
                    return .systemEventsMenuPasteFallback
                case .systemEventsTyping:
                    pasteboard.restore()
                    try typeViaSystemEvents(text: trimmed, on: targetApplication)
                    try await Task.sleep(for: richEditorSettleDelay(for: targetApplication))
                    markInsertion(text: trimmed, application: targetApplication)
                    return .systemEventsTypingFallback
                }
            } catch {
                pasteboard.restore()
                throw error
            }
        }

        // Each remaining method sends text that cannot be withdrawn. Move on to the next one
        // only when the target exposes its text and the transcript is verifiably absent;
        // otherwise a target without readable AX text would receive one copy per method.
        let targetPID = targetApplication?.processIdentifier
        func finished(_ method: ActiveAppInsertionMethod) -> ActiveAppInsertionMethod? {
            guard insertionCheck(text: trimmed, targetPID: targetPID) != .absent else { return nil }
            pasteboard.restore()
            markInsertion(text: trimmed, application: targetApplication)
            return method
        }

        if let targetPID {
            try typeUnicodeText(trimmed, targetPID: targetPID)
            try await Task.sleep(for: .milliseconds(220))
            if let method = finished(.targetedSyntheticTyping) { return method }
        }

        try typeUnicodeText(trimmed, targetPID: nil)
        try await Task.sleep(for: .milliseconds(80))
        if let method = finished(.syntheticTyping) { return method }

        pasteboard.write(trimmed)
        do {
            if let targetPID {
                try postCommandV(targetPID: targetPID)
                try await Task.sleep(for: .milliseconds(260))
                if let method = finished(.targetedPasteFallback) { return method }
            }

            try postCommandV(targetPID: nil)
            try await Task.sleep(for: .milliseconds(120))
            if let method = finished(.pasteFallback) { return method }

            try pasteViaSystemEvents(on: targetApplication)
            try await Task.sleep(for: .milliseconds(180))
            if let method = finished(.systemEventsPasteFallback) { return method }

            try pasteViaSystemEventsMenu(on: targetApplication)
            try await Task.sleep(for: .milliseconds(220))
            if let method = finished(.systemEventsMenuPasteFallback) { return method }

            try typeViaSystemEvents(text: trimmed, on: targetApplication)
            try await Task.sleep(for: .milliseconds(220))
            if let method = finished(.systemEventsTypingFallback) { return method }
        } catch {
            pasteboard.restore()
            throw error
        }

        pasteboard.restore()
        throw ActiveAppTextInjectorError.failedToInsertText
    }

    static func canPostEvents() -> Bool {
        CGPreflightPostEventAccess()
    }

    private static func ensureAccessibilityTrust(prompt: Bool) -> Bool {
        if AXIsProcessTrusted() {
            return true
        }

        guard prompt else {
            return false
        }

        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return AXIsProcessTrusted()
    }

    private static func resolveApplication(for target: ActiveAppInsertionApplicationTarget?) -> NSRunningApplication? {
        guard let target else {
            return NSWorkspace.shared.frontmostApplication
        }

        if let byPID = NSRunningApplication(processIdentifier: target.processIdentifier),
           !byPID.isTerminated {
            return byPID
        }

        guard let bundleIdentifier = target.bundleIdentifier else {
            return nil
        }

        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
            .first(where: { !$0.isTerminated })
    }

    private static func shouldBypassAccessibilityReplacement(
        for application: NSRunningApplication?,
        target: ActiveAppInsertionTarget?
    ) -> Bool {
        let derivedApplicationTarget = target?.focusedElement.flatMap(applicationTarget(for:))
        let bundleIdentifier = (
            application?.bundleIdentifier
            ?? target?.application?.bundleIdentifier
            ?? derivedApplicationTarget?.bundleIdentifier
            ?? ""
        ).lowercased()
        let localizedName = (
            application?.localizedName
            ?? target?.application?.localizedName
            ?? derivedApplicationTarget?.localizedName
            ?? ""
        ).lowercased()

        let richEditorMarkers = [
            "pages",
            "whatsapp",
            "codex",
            "cursor",
            "electron",
            "slack",
            "discord"
        ]

        if richEditorMarkers.contains(where: { localizedName.contains($0) }) {
            return true
        }

        if bundleIdentifier.contains("iwork.pages")
            || bundleIdentifier.contains("whatsapp")
            || bundleIdentifier.contains("codex")
            || bundleIdentifier.contains("cursor")
            || bundleIdentifier.contains("slack")
            || bundleIdentifier.contains("discord") {
            return true
        }

        // Browser-hosted editors (Docs/Keep/Discord web/etc.) are handled
        // through a single paste path to avoid cascading fallback inserts.
        if isBrowserBundleIdentifier(bundleIdentifier) {
            return true
        }

        if targetContainsRichWebEditor(target) {
            if richEditorMarkers.contains(where: { localizedName.contains($0) }) {
                return true
            }

            if isBrowserBundleIdentifier(bundleIdentifier) {
                return true
            }
        }

        if targetContainsRichDocumentEditor(target) {
            return true
        }

        return false
    }

    private static func isBrowserBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.contains("chrome")
            || bundleIdentifier.contains("arc")
            || bundleIdentifier.contains("safari")
            || bundleIdentifier.contains("firefox")
            || bundleIdentifier.contains("edge")
            || bundleIdentifier.contains("brave")
    }

    private static func targetContainsRichWebEditor(_ target: ActiveAppInsertionTarget?) -> Bool {
        guard let focusedElement = target?.focusedElement else { return false }

        let rolesToTreatAsRichWebEditors = [
            "AXWebArea",
            "AXGroup",
            "AXLayoutArea",
            "AXGenericElement"
        ]

        if let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement),
           rolesToTreatAsRichWebEditors.contains(role) {
            return true
        }

        if let title = copyStringAttribute(kAXTitleAttribute as CFString, from: focusedElement)?.lowercased(),
           isKnownRichWebEditorText(title) {
            return true
        }

        if let description = copyStringAttribute(kAXDescriptionAttribute as CFString, from: focusedElement)?.lowercased(),
           isKnownRichWebEditorText(description) {
            return true
        }

        if let window = copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement),
           let windowTitle = copyStringAttribute(kAXTitleAttribute as CFString, from: window)?.lowercased(),
           isKnownRichWebEditorText(windowTitle) {
            return true
        }

        if copyStringAttribute(kAXValueAttribute as CFString, from: focusedElement) == nil,
           copySelectedRange(from: focusedElement) == nil {
            return true
        }

        return false
    }

    private static func isKnownRichWebEditorText(_ text: String) -> Bool {
        text.contains("discord")
            || text.contains("whatsapp")
            || text.contains("codex")
            || text.contains("cursor")
            || text.contains("slack")
            || text.contains("google docs")
            || text.contains("docs.google")
    }

    private static func targetContainsRichDocumentEditor(_ target: ActiveAppInsertionTarget?) -> Bool {
        guard let focusedElement = target?.focusedElement else { return false }

        let rolesToTreatAsRichDocumentEditors = [
            "AXScrollArea",
            "AXDocument",
            "AXTextArea",
            "AXGroup"
        ]

        if let role = copyStringAttribute(kAXRoleAttribute as CFString, from: focusedElement),
           rolesToTreatAsRichDocumentEditors.contains(role),
           copyStringAttribute(kAXValueAttribute as CFString, from: focusedElement) == nil {
            return true
        }

        return false
    }

    private static func insertionKey(text: String, application: NSRunningApplication?) -> String {
        let target = application?.bundleIdentifier ?? application?.localizedName ?? "unknown"
        return target + "::" + text
    }

    private static func shouldSuppressDuplicateInsertion(text: String, application: NSRunningApplication?) -> Bool {
        let key = insertionKey(text: text, application: application)
        guard let previous = recentInsertions[key] else { return false }
        return Date().timeIntervalSince(previous) < 2.0
    }

    private static func richEditorSettleDelay(for application: NSRunningApplication?) -> Duration {
        let bundleIdentifier = application?.bundleIdentifier?.lowercased() ?? ""
        let localizedName = application?.localizedName?.lowercased() ?? ""

        if bundleIdentifier.contains("iwork.pages") || localizedName.contains("pages") {
            return .milliseconds(520)
        }

        if bundleIdentifier.contains("discord") || localizedName.contains("discord") {
            return .milliseconds(420)
        }

        if bundleIdentifier.contains("whatsapp") || localizedName.contains("whatsapp") {
            return .milliseconds(420)
        }

        return .milliseconds(360)
    }

    private static func richEditorInsertionStrategy(
        for application: NSRunningApplication?,
        target: ActiveAppInsertionTarget?
    ) -> RichEditorInsertionStrategy {
        let bundleIdentifier = application?.bundleIdentifier?.lowercased() ?? ""
        let localizedName = application?.localizedName?.lowercased() ?? ""

        if bundleIdentifier.contains("iwork.pages")
            || localizedName.contains("pages")
            || bundleIdentifier.contains("cursor")
            || localizedName.contains("cursor") {
            return .systemEventsMenuPaste
        }

        if let target, targetContainsRichDocumentEditor(target) {
            return .systemEventsMenuPaste
        }

        if let target,
           targetContainsRichWebEditor(target),
           isBrowserBundleIdentifier(bundleIdentifier) {
            return .systemEventsMenuPaste
        }

        return .targetedPaste
    }

    private static func markInsertion(text: String, application: NSRunningApplication?) {
        recentInsertions[insertionKey(text: text, application: application)] = Date()
    }

    private static func purgeRecentInsertions() {
        let cutoff = Date().addingTimeInterval(-5)
        recentInsertions = recentInsertions.filter { $0.value >= cutoff }
    }

    private static func applicationTarget(for element: AXUIElement) -> ActiveAppInsertionApplicationTarget? {
        var pid: pid_t = 0
        let result = AXUIElementGetPid(element, &pid)
        guard result == .success, pid != 0, pid != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }

        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return nil
        }

        return ActiveAppInsertionApplicationTarget(application: application)
    }

    private static func insertViaAccessibility(text: String, targetPID: pid_t?) throws -> Bool {
        let candidates = focusedElementCandidates(targetPID: targetPID)

        for element in candidates {
            if replaceSelectedText(text, on: element) {
                return true
            }
        }

        return false
    }

    private static func focusedElementCandidates(targetPID: pid_t?) -> [AXUIElement] {
        var elements: [AXUIElement] = []

        if let targetPID {
            let appElement = AXUIElementCreateApplication(targetPID)
            if let focused = copyFocusedElement(from: appElement) {
                elements.append(focused)
            }
        }

        let systemWide = AXUIElementCreateSystemWide()
        if let focused = copyFocusedElement(from: systemWide) {
            if !elements.contains(where: { CFEqual($0, focused) }) {
                elements.append(focused)
            }
        }

        return elements
    }

    private static func copyFocusedElement(from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedUIElementAttribute as CFString, &value)
        guard result == .success, let focused = value else {
            return nil
        }
        return (focused as! AXUIElement)
    }

    private static func copyElementAttribute(_ attribute: CFString, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success, let value else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private static func replaceSelectedTextOnCurrentFocusedElement(_ text: String, requiredPID: pid_t?) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        let accepts: (AXUIElement) -> Bool = { element in
            guard let requiredPID else { return true }
            return processIdentifier(of: element) == requiredPID
        }

        if let focusedApplication = copyFocusedApplication(from: systemWide),
           let focusedElement = copyFocusedElement(from: focusedApplication),
           accepts(focusedElement),
           replaceSelectedText(text, on: focusedElement) {
            return true
        }

        if let focusedElement = copyFocusedElement(from: systemWide),
           accepts(focusedElement),
           replaceSelectedText(text, on: focusedElement) {
            return true
        }

        return false
    }

    private static func processIdentifier(of element: AXUIElement) -> pid_t? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid != 0 else { return nil }
        return pid
    }

    private static func copyFocusedApplication(from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXFocusedApplicationAttribute as CFString, &value)
        guard result == .success, let focused = value else {
            return nil
        }

        return (focused as! AXUIElement)
    }

    private static func shouldRetargetCurrentFrontmostApp(to application: NSRunningApplication?) -> Bool {
        guard let application else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier != application.processIdentifier
    }

    private static func bringToFront(target: ActiveAppInsertionTarget?, resolvedApplication: NSRunningApplication?) {
        if let focusedElement = target?.focusedElement,
           let window = copyElementAttribute(kAXWindowAttribute as CFString, from: focusedElement) {
            _ = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        }

        if let processIdentifier = target?.application?.processIdentifier {
            let appElement = AXUIElementCreateApplication(processIdentifier)
            _ = AXUIElementSetAttributeValue(appElement, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        }

        _ = resolvedApplication?.activate(options: [.activateIgnoringOtherApps])
    }

    private static func waitForTargetActivation(_ application: NSRunningApplication?) async throws {
        guard let application else {
            try await Task.sleep(for: .milliseconds(180))
            return
        }

        for _ in 0..<8 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == application.processIdentifier {
                return
            }

            _ = application.activate(options: [.activateIgnoringOtherApps])
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    private static func replaceSelectedText(_ text: String, on element: AXUIElement) -> Bool {
        let directReplace = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            text as CFTypeRef
        )
        if directReplace == .success {
            return true
        }

        guard
            let currentValue = copyStringAttribute(kAXValueAttribute as CFString, from: element),
            let selectedRange = copySelectedRange(from: element)
        else {
            return false
        }

        let utf16Length = currentValue.utf16.count
        let safeLocation = max(0, min(selectedRange.location, utf16Length))
        let safeLength = max(0, min(selectedRange.length, utf16Length - safeLocation))
        let updated = (currentValue as NSString).replacingCharacters(
            in: NSRange(location: safeLocation, length: safeLength),
            with: text
        )

        let setValueResult = AXUIElementSetAttributeValue(
            element,
            kAXValueAttribute as CFString,
            updated as CFTypeRef
        )
        guard setValueResult == .success else {
            return false
        }

        var caretRange = CFRange(location: safeLocation + (text as NSString).length, length: 0)
        guard let rangeValue = AXValueCreate(.cfRange, &caretRange) else {
            return true
        }

        _ = AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextRangeAttribute as CFString,
            rangeValue
        )

        return true
    }

    private static func copyStringAttribute(_ attribute: CFString, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute, &value)
        guard result == .success else {
            return nil
        }
        return value as? String
    }

    private static func copySelectedRange(from element: AXUIElement) -> CFRange? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard result == .success, let value else {
            return nil
        }

        let axValue = value as! AXValue
        guard AXValueGetType(axValue) == .cfRange else {
            return nil
        }

        var range = CFRange()
        guard AXValueGetValue(axValue, .cfRange, &range) else {
            return nil
        }

        return range
    }

    enum InsertionCheck: Equatable {
        case confirmed
        /// The focused element exposes its text and the transcript is not in it.
        case absent
        /// No focused element exposes readable text, so the result cannot be checked.
        case unverifiable
    }

    private static func insertionCheck(text: String, targetPID: pid_t?) -> InsertionCheck {
        var sawReadableText = false
        for element in focusedElementCandidates(targetPID: targetPID) {
            if let selectedText = copyStringAttribute(kAXSelectedTextAttribute as CFString, from: element) {
                if selectedText == text { return .confirmed }
            }
            if let value = copyStringAttribute(kAXValueAttribute as CFString, from: element) {
                sawReadableText = true
                if value.contains(text) { return .confirmed }
            }
        }
        return sawReadableText ? .absent : .unverifiable
    }

    private static func ensurePostEventAccess() -> Bool {
        if CGPreflightPostEventAccess() {
            return true
        }

        _ = CGRequestPostEventAccess()
        return CGPreflightPostEventAccess()
    }

    private static func typeUnicodeText(_ text: String, targetPID: pid_t?) throws {
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }

        let utf16Scalars = Array(text.utf16)
        let chunkSize = 64
        var startIndex = 0

        while startIndex < utf16Scalars.count {
            var endIndex = min(startIndex + chunkSize, utf16Scalars.count)
            // Never split a surrogate pair across two events.
            if endIndex < utf16Scalars.count, UTF16.isLeadSurrogate(utf16Scalars[endIndex - 1]) {
                endIndex -= 1
            }
            let chunk = Array(utf16Scalars[startIndex..<endIndex])

            guard
                let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true),
                let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            else {
                throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
            }

            keyDown.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            keyUp.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: chunk)
            post(keyDown, targetPID: targetPID)
            post(keyUp, targetPID: targetPID)

            startIndex = endIndex
        }
    }

    private static func postCommandV(targetPID: pid_t?) throws {
        let keyCodeV: CGKeyCode = 9
        let commandKeyCode: CGKeyCode = 55
        guard let source = CGEventSource(stateID: .combinedSessionState) else {
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }

        guard
            let commandDown = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: true),
            let commandUp = CGEvent(keyboardEventSource: source, virtualKey: commandKeyCode, keyDown: false),
            let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: true),
            let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCodeV, keyDown: false)
        else {
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        post(commandDown, targetPID: targetPID)
        post(keyDown, targetPID: targetPID)
        post(keyUp, targetPID: targetPID)
        post(commandUp, targetPID: targetPID)
    }

    private static func post(_ event: CGEvent, targetPID: pid_t?) {
        if let targetPID, targetPID != ProcessInfo.processInfo.processIdentifier {
            event.postToPid(targetPID)
        } else {
            event.post(tap: .cghidEventTap)
        }
    }

    private static func pasteViaSystemEvents(on application: NSRunningApplication?) throws {
        let activationTarget = applicationScriptTarget(for: application)
        let processActivation = systemEventsProcessActivation(for: application)
        let scriptSource = """
        tell application \(activationTarget) to activate
        delay 0.12
        \(processActivation)
        tell application "System Events"
            keystroke "v" using command down
        end tell
        """

        var error: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        script?.executeAndReturnError(&error)

        guard error == nil else {
            if let error,
               let errorNumber = error[NSAppleScript.errorNumber] as? Int,
               errorNumber == -1743 {
                throw ActiveAppTextInjectorError.automationPermissionMissing
            }
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }
    }

    private static func typeViaSystemEvents(text: String, on application: NSRunningApplication?) throws {
        let activationTarget = applicationScriptTarget(for: application)
        let processActivation = systemEventsProcessActivation(for: application)
        let scriptSource = """
        tell application \(activationTarget) to activate
        delay 0.12
        \(processActivation)
        tell application "System Events"
            keystroke \(quotedAppleScript(text))
        end tell
        """

        var error: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        script?.executeAndReturnError(&error)

        guard error == nil else {
            if let error,
               let errorNumber = error[NSAppleScript.errorNumber] as? Int,
               errorNumber == -1743 {
                throw ActiveAppTextInjectorError.automationPermissionMissing
            }
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }
    }

    private static func pasteViaSystemEventsMenu(on application: NSRunningApplication?) throws {
        let activationTarget = applicationScriptTarget(for: application)
        let processName = application?.localizedName ?? ""
        let scriptSource = """
        tell application \(activationTarget) to activate
        delay 0.16
        tell application "System Events"
            if exists process \(quotedAppleScript(processName)) then
                tell process \(quotedAppleScript(processName))
                    set frontmost to true
                    if exists menu bar 1 then
                        if exists menu bar item "Edit" of menu bar 1 then
                            click menu item "Paste" of menu "Edit" of menu bar item "Edit" of menu bar 1
                        else
                            keystroke "v" using command down
                        end if
                    else
                        keystroke "v" using command down
                    end if
                end tell
            else
                keystroke "v" using command down
            end if
        end tell
        """

        var error: NSDictionary?
        let script = NSAppleScript(source: scriptSource)
        script?.executeAndReturnError(&error)

        guard error == nil else {
            if let error,
               let errorNumber = error[NSAppleScript.errorNumber] as? Int,
               errorNumber == -1743 {
                throw ActiveAppTextInjectorError.automationPermissionMissing
            }
            throw ActiveAppTextInjectorError.failedToGenerateKeyboardEvents
        }
    }

    private static func applicationScriptTarget(for application: NSRunningApplication?) -> String {
        if let bundleIdentifier = application?.bundleIdentifier, !bundleIdentifier.isEmpty {
            return "id \(quotedAppleScript(bundleIdentifier))"
        }

        if let localizedName = application?.localizedName, !localizedName.isEmpty {
            return quotedAppleScript(localizedName)
        }

        return "current application"
    }

    private static func systemEventsProcessActivation(for application: NSRunningApplication?) -> String {
        guard let processName = application?.localizedName, !processName.isEmpty else {
            return ""
        }

        let quotedProcessName = quotedAppleScript(processName)
        return """
        tell application "System Events"
            if exists process \(quotedProcessName) then
                tell process \(quotedProcessName)
                    set frontmost to true
                end tell
            end if
        end tell
        delay 0.08
        """
    }

    private static func quotedAppleScript(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
/// Saves every item and type on a pasteboard before Dictate writes a transcript to it, and
/// restores them afterwards unless the user has copied something new in the meantime.
@MainActor
final class PasteboardGuard {
    private let pasteboard: NSPasteboard
    private let savedItems: [[(NSPasteboard.PasteboardType, Data)]]
    private var ownChangeCount: Int?

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        savedItems = (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    func write(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        ownChangeCount = pasteboard.changeCount
    }

    func restore(after delay: TimeInterval = 0.2) {
        guard let expected = ownChangeCount else { return }
        ownChangeCount = nil
        let pasteboard = pasteboard
        let items = savedItems
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            guard pasteboard.changeCount == expected else { return }
            pasteboard.clearContents()
            let restored = items.map { entries -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (type, data) in entries { item.setData(data, forType: type) }
                return item
            }
            if !restored.isEmpty { pasteboard.writeObjects(restored) }
        }
    }
}
#endif
