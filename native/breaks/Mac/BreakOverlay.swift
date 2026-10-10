import AppKit
import SwiftUI

/// A borderless window. Only the primary display's window, which holds the controls, takes keyboard focus
/// (for Return and Esc), so clicking another display does not move focus away from them.
private final class OverlayWindow: NSWindow {
    var isPrimary = false
    override var canBecomeKey: Bool { isPrimary }
    override var canBecomeMain: Bool { isPrimary }
}

/// Covers every display with a blurred or dimmed break screen while a break runs.
@MainActor
final class BreakOverlayController {
    private unowned let controller: MacBreakController
    private var windows: [NSWindow] = []
    private var previousApp: NSRunningApplication?

    init(controller: MacBreakController) {
        self.controller = controller
    }

    var isVisible: Bool { !windows.isEmpty }

    func show() {
        guard windows.isEmpty else { return }
        previousApp = NSWorkspace.shared.frontmostApplication
        buildWindows()
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        for window in windows {
            window.alphaValue = reduceMotion ? 1 : 0
            window.orderFrontRegardless()
        }
        windows.first?.makeKey()
        NSApp.activate(ignoringOtherApps: true)
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.6
                windows.forEach { $0.animator().alphaValue = 1 }
            }
        }
    }

    func hide() {
        guard !windows.isEmpty else { return }
        let closing = windows
        windows.removeAll()
        let finish = { [previousApp] in
            closing.forEach { $0.orderOut(nil) }
            if let previousApp, previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier {
                previousApp.activate()
            }
        }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            finish()
        } else {
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.35
                closing.forEach { $0.animator().alphaValue = 0 }
            }, completionHandler: { Task { @MainActor in finish() } })
        }
        previousApp = nil
    }

    /// Rebuilds the windows when a display is added, removed, or rearranged during a break.
    func screensChanged() {
        guard !windows.isEmpty else { return }
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        buildWindows()
        windows.forEach { $0.alphaValue = 1; $0.orderFrontRegardless() }
        windows.first?.makeKey()
    }

    private func buildWindows() {
        let screens = NSScreen.screens
        let primary = NSScreen.main ?? screens.first
        // The primary screen's window comes first so it becomes key and holds the controls.
        let ordered = screens.filter { $0 == primary } + screens.filter { $0 != primary }
        for screen in ordered {
            let window = OverlayWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isPrimary = screen == primary
            window.setFrame(screen.frame, display: false)
            window.level = .screenSaver
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none

            let root = BreakOverlayView(isPrimary: screen == primary)
                .environmentObject(controller)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: screen.frame.size)
            hosting.autoresizingMask = [.width, .height]

            if controller.settings.desktop.overlayStyle == .blur {
                let blur = NSVisualEffectView(frame: hosting.frame)
                blur.material = .fullScreenUI
                blur.blendingMode = .behindWindow
                blur.state = .active
                blur.autoresizingMask = [.width, .height]
                blur.addSubview(hosting)
                window.contentView = blur
            } else {
                window.contentView = hosting
            }
            windows.append(window)
        }
    }
}

struct BreakOverlayView: View {
    @EnvironmentObject private var controller: MacBreakController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPrimary: Bool

    var body: some View {
        ZStack {
            Color.black.opacity(controller.settings.desktop.overlayStyle == .blur ? 0.35 : 0.82)
                .ignoresSafeArea()
            VStack(spacing: 22) {
                Text(controller.activeBreakTitle)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.75))
                Text(controller.breakRemaining.clockDuration)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .accessibilityLabel("Break ends in \(controller.breakRemaining.spokenDuration)")
                if isPrimary {
                    Text(controller.activeMessage)
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.85))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 560)
                    ProgressView(value: controller.breakProgress)
                        .progressViewStyle(.linear)
                        .tint(.white)
                        .frame(maxWidth: 360)
                        .accessibilityLabel("Break progress")
                    controls
                        .padding(.top, 12)
                }
            }
            .padding(40)
        }
        .preferredColorScheme(.dark)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 12) {
            if controller.settings.discipline != .hardcore {
                Button(skipTitle) { controller.skipActiveBreak() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(!controller.canSkipBreak)
                    .accessibilityHint("Ends the break now and records it as skipped")
                Menu("Snooze") {
                    Button("1 minute") { controller.snooze(minutes: 1) }
                    Button("5 minutes") { controller.snooze(minutes: 5) }
                }
                .menuStyle(.borderedButton)
                .fixedSize()
                .disabled(!controller.canSnoozeActiveBreak)
                .accessibilityHint("\(controller.snoozesRemaining) snoozes left today")
            }
            if controller.settings.allowEarlyEnd {
                Button("End break") { controller.endBreak() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!controller.canEndEarly)
                    .accessibilityHint("Available near the end of the break; counts as completed")
            }
        }
        .controlSize(.large)
        Text(footnote)
            .font(.footnote)
            .foregroundStyle(.white.opacity(0.6))
    }

    private var skipTitle: String {
        if let wait = controller.skipAvailableIn {
            return "Skip in \(max(1, Int(wait.rounded(.up))))s"
        }
        return "Skip"
    }

    private var footnote: String {
        switch controller.settings.discipline {
        case .casual: "Esc skips. Snoozes left today: \(controller.snoozesRemaining)."
        case .balanced: "Skipping unlocks after a few seconds. Snoozes left today: \(controller.snoozesRemaining)."
        case .hardcore: "Hardcore: this break cannot be skipped."
        }
    }
}
