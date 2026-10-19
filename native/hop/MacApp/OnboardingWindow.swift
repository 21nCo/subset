import AppKit
import ApplicationServices
import SwiftUI

/// The Accessibility permission, through public API only.
@MainActor
enum AccessibilityPermission {
    /// The Accessibility pane of Privacy & Security in System Settings.
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Adds Hop to the Accessibility list, so the user only has to switch it on, and opens that pane. macOS lists an
    /// app only after it asks with the prompt option, which may also show the system's own permission alert.
    static func openSettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            NSWorkspace.shared.open(settingsURL)
        }
    }
}

/// The onboarding window: explains why Hop needs Accessibility and links to the setting. While it is open, `onTick`
/// runs every 2 seconds so the host can notice the permission being granted and close it; nothing polls while it is
/// closed.
@MainActor
final class OnboardingWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private var timer: Timer?
    private let shortcutPhrase: () -> String
    private let onTick: () -> Void

    init(shortcutPhrase: @escaping () -> String, onTick: @escaping () -> Void) {
        self.shortcutPhrase = shortcutPhrase
        self.onTick = onTick
    }

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.contentViewController = NSHostingController(rootView: OnboardingView(
            shortcutPhrase: shortcutPhrase(),
            openSettings: AccessibilityPermission.openSettings,
            close: { [weak self] in self?.close() }
        ))
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        startPolling()
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func startPolling() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.onTick() }
        }
        // The common modes keep the check running while a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        )
        window.title = "Allow Accessibility Access"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        return window
    }
}

struct OnboardingView: View {
    let shortcutPhrase: String
    let openSettings: () -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Hop needs Accessibility access")
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text("Hop uses Accessibility to see your open windows and raise the one you pick, and to notice its shortcut: hold \(shortcutPhrase).")
            Text("Nothing leaves your Mac. Hop makes no network connections and never stores or sends window titles.")
            Text("In Privacy & Security, under Accessibility, turn on Hop. This window closes once access is allowed.")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Not Now", action: close)
                    .keyboardShortcut(.cancelAction)
                Button("Open Privacy & Security", action: openSettings)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 8)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .frame(width: 460)
    }
}
