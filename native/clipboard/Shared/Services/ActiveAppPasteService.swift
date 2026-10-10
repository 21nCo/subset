import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation

enum ActiveAppPasteServiceError: LocalizedError {
    case clipboardWriteFailed
    case accessibilityPermissionMissing
    case targetApplicationMissing
    case targetActivationFailed
    case keyboardEventFailed

    var errorDescription: String? {
        switch self {
        case .clipboardWriteFailed:
            return "The selected item could not be restored to the system clipboard."
        case .accessibilityPermissionMissing:
            return "The selected item is on your clipboard. macOS should show the Accessibility prompt now. Enable Clipboard, then try the paste again."
        case .targetApplicationMissing:
            return "Clipboard could not find the app that was active before the shelf opened. Switch back to the app you want and try again."
        case .targetActivationFailed:
            return "Clipboard found the target app, but macOS would not return focus to it for pasting."
        case .keyboardEventFailed:
            return "The selected item is on your clipboard, but the direct paste shortcut could not be sent to the target app."
        }
    }
}

struct ActiveAppTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
    let localizedName: String?

    init(application: NSRunningApplication) {
        processIdentifier = application.processIdentifier
        bundleIdentifier = application.bundleIdentifier
        localizedName = application.localizedName
    }
}

@MainActor
enum ActiveAppPasteService {
    private static var hasRequestedAccessibilityPromptThisSession = false

    static func hasAccessibilityTrust() -> Bool {
        let isTrusted = AXIsProcessTrusted()
        if isTrusted {
            hasRequestedAccessibilityPromptThisSession = false
        }
        return isTrusted
    }

    static func captureTarget(excludingSelf: Bool = true) -> ActiveAppTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        if excludingSelf, application.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            return nil
        }

        return ActiveAppTarget(application: application)
    }

    static func openAccessibilitySettings() {
        _ = requestAccessibilityPermissionPrompt()

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }

        NSWorkspace.shared.open(url)
    }

    static func requestAccessibilityPermissionPrompt() -> Bool {
        hasRequestedAccessibilityPromptThisSession = true
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    static func requestAccessibilityPermissionIfNeeded() -> Bool {
        if hasAccessibilityTrust() {
            return true
        }

        if !hasRequestedAccessibilityPromptThisSession {
            _ = requestAccessibilityPermissionPrompt()
        }

        return false
    }

    /// `didWrite` receives the pasteboard change count of Clipboard's own write, before any
    /// await, so the monitor can skip exactly that change.
    static func paste(
        item: ClipboardItem,
        to target: ActiveAppTarget?,
        didWrite: (Int) -> Void = { _ in }
    ) async throws {
        let pasteboard = NSPasteboard.general
        guard item.write(to: pasteboard) else {
            throw ActiveAppPasteServiceError.clipboardWriteFailed
        }
        didWrite(pasteboard.changeCount)

        try? await Task.sleep(for: .milliseconds(80))

        guard requestAccessibilityPermissionIfNeeded() else {
            throw ActiveAppPasteServiceError.accessibilityPermissionMissing
        }

        guard let targetApplication = resolveApplication(for: target) else {
            throw ActiveAppPasteServiceError.targetApplicationMissing
        }

        if targetApplication.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            targetApplication.unhide()

            let activated = targetApplication.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            guard activated else {
                throw ActiveAppPasteServiceError.targetActivationFailed
            }

            try await waitForActivation(of: targetApplication.processIdentifier)
        }

        try? await Task.sleep(for: .milliseconds(80))

        try postCommandV(to: targetApplication.processIdentifier)
    }

    private static func resolveApplication(for target: ActiveAppTarget?) -> NSRunningApplication? {
        guard let target else { return nil }

        if let runningApplication = NSRunningApplication(processIdentifier: target.processIdentifier) {
            return runningApplication
        }

        if let bundleIdentifier = target.bundleIdentifier {
            return NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first
        }

        if let localizedName = target.localizedName {
            return NSWorkspace.shared.runningApplications.first(where: { $0.localizedName == localizedName })
        }

        return nil
    }

    private static func waitForActivation(of processIdentifier: pid_t) async throws {
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == processIdentifier {
                return
            }

            try? await Task.sleep(for: .milliseconds(50))
        }

        throw ActiveAppPasteServiceError.targetActivationFailed
    }

    private static func postCommandV(to processIdentifier: pid_t) throws {
        guard let source = CGEventSource(stateID: .hidSystemState) else {
            throw ActiveAppPasteServiceError.keyboardEventFailed
        }

        guard
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: true
            ),
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CGKeyCode(kVK_ANSI_V),
                keyDown: false
            )
        else {
            throw ActiveAppPasteServiceError.keyboardEventFailed
        }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.postToPid(processIdentifier)
        keyUp.postToPid(processIdentifier)
    }
}
