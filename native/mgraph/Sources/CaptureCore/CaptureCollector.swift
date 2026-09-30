import AppKit
import ApplicationServices
import Foundation

public enum CaptureState: String, Codable {
    case available
    case permissionRequired
    case noForegroundApplication
    case unsupportedApplication
    case readFailed
}

public struct CaptureResult: Codable {
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

public enum CaptureCollector {
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
        guard let app = NSWorkspace.shared.frontmostApplication else {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        let pid = app.processIdentifier
        let name = app.localizedName
        let bundleID = app.bundleIdentifier
        let root = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(root, 1.0)
        var roleValue: CFTypeRef?
        let rootError = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleValue)
        if rootError == .apiDisabled { return status() }
        if rootError == .cannotComplete {
            return CaptureResult(state: .readFailed, applicationName: name, bundleIdentifier: bundleID,
                                 processIdentifier: pid, error: "Accessibility request timed out")
        }

        let focused = attribute(root, kAXFocusedWindowAttribute as String)
        let windows = attribute(root, kAXWindowsAttribute as String) as? [AXUIElement]
        let focusedElement = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? ($0 as! AXUIElement) : nil }
        let target = focusedElement ?? windows?.first ?? root
        let title = stringAttribute(target, kAXTitleAttribute as String)
        let document = stringAttribute(target, kAXDocumentAttribute as String)
        let extraction = extractText(from: target)
        if !isTrusted() { return status() }
        let state: CaptureState = extraction.text.isEmpty ? .unsupportedApplication : .available
        return CaptureResult(state: state, applicationName: name, bundleIdentifier: bundleID,
                             processIdentifier: pid, windowTitle: title, documentURL: document,
                             text: extraction.text.isEmpty ? nil : extraction.text,
                             error: extraction.text.isEmpty ? "No readable text in the Accessibility tree" : nil)
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func extractText(from root: AXUIElement) -> (text: String, visited: Int) {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = Set<CFHashCode>()
        var snippets: [String] = []
        var seenText = Set<String>()
        var count = 0
        var length = 0

        while index < queue.count && count < 600 && length < 6000 {
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            let role = stringAttribute(element, kAXRoleAttribute as String) ?? ""
            let subrole = stringAttribute(element, kAXSubroleAttribute as String) ?? ""
            if shouldSkip(role: role, subrole: subrole) { continue }

            for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                guard let raw = stringAttribute(element, key) else { continue }
                let snippet = normalize(raw, remaining: 6000 - length)
                if !snippet.isEmpty && seenText.insert(snippet).inserted {
                    snippets.append(snippet)
                    length += snippet.count
                }
            }
            if depth < 12, let children = attribute(element, kAXChildrenAttribute as String) as? [AXUIElement] {
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
