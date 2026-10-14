import AppKit
import SwiftUI

/// A borderless window. Only the primary display's window, which holds the controls, takes keyboard focus
/// (for Return and Esc, or a hard stop's controls), so clicking another display does not move focus away from them.
private final class OverlayWindow: NSWindow {
    var isPrimary = false
    override var canBecomeKey: Bool { isPrimary }
    override var canBecomeMain: Bool { isPrimary }
}

/// Covers every display with a blurred or dimmed break screen while a break or a hard stop runs.
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
            if let hardStop = controller.hardStop.overlay {
                HardStopOverlayContent(overlay: hardStop, isPrimary: isPrimary)
                    .padding(40)
            } else {
                breakContent
            }
        }
        .preferredColorScheme(.dark)
    }

    private var breakContent: some View {
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

// MARK: - Hard stop

/// A hard stop's screen: its name, when it ends, and on the primary display the extensions left and only the
/// actions its escape hatch allows. It has no Esc or Return shortcuts, no discipline hints, and no snooze count.
private struct HardStopOverlayContent: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let overlay: HardStopPresentation.Overlay
    let isPrimary: Bool

    var body: some View {
        VStack(spacing: 22) {
            Text(overlay.name)
                .font(.title2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.75))
            if let remaining = overlay.remaining {
                Text(remaining.clockDuration)
                    .font(.system(size: 96, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .contentTransition(reduceMotion ? .identity : .numericText(countsDown: true))
                    .accessibilityLabel("Hard stop ends in \(remaining.spokenDuration)")
            }
            Text(overlay.until)
                .font(overlay.remaining == nil ? .system(size: 48, weight: .bold, design: .rounded) : .title3)
                .foregroundStyle(.white.opacity(overlay.remaining == nil ? 1 : 0.85))
            if isPrimary {
                if let extensionsLeft = overlay.extensionsLeft {
                    Text(extensionsLeft)
                        .font(.callout)
                        .foregroundStyle(.white.opacity(0.7))
                }
                if !overlay.actions.isEmpty {
                    HardStopActions(actions: overlay.actions)
                        .padding(.top, 12)
                }
            }
        }
    }
}

/// Extend and Dismiss, each confirmed by a 3-second hold with the pointer, or by activating it and then
/// **Confirm** within 5 seconds with the keyboard (Space) or VoiceOver.
private struct HardStopActions: View {
    @EnvironmentObject private var controller: MacBreakController
    let actions: [HardStopPresentation.OverlayAction]
    @State private var confirmation = HardStopConfirmation()
    @State private var deadline: Task<Void, Never>?
    @FocusState private var confirmFocused: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.05, paused: confirmation.state == .idle)) { context in
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(actions, id: \.self) { action in
                        HoldToConfirmButton(
                            title: action.title,
                            progress: confirmation.holdProgress(of: action, now: context.date),
                            onPressBegan: { pressBegan(action) },
                            onPressEnded: pressEnded,
                            onActivate: { activate(action) }
                        )
                    }
                }
                if case .awaitingConfirm(let action, _) = confirmation.state {
                    Button("Confirm") { confirm() }
                        .controlSize(.large)
                        .focused($confirmFocused)
                        .onAppear { confirmFocused = true }
                        .accessibilityHint("\(action.title). Available for \(confirmation.confirmSecondsLeft(now: context.date) ?? 0) seconds")
                }
                Text(hint(now: context.date))
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
        .onDisappear { deadline?.cancel() }
    }

    private func hint(now: Date) -> String {
        if case .awaitingConfirm(let action, _) = confirmation.state, let seconds = confirmation.confirmSecondsLeft(now: now) {
            return "Choose Confirm within \(seconds) s to \(action.title.lowercased())."
        }
        return "Press and hold for \(Int(HardStopConfirmation.holdDuration)) seconds."
    }

    private func pressBegan(_ action: HardStopPresentation.OverlayAction) {
        confirmation.pressBegan(action, at: .now)
        schedule(after: HardStopConfirmation.holdDuration)
    }

    private func pressEnded() {
        deadline?.cancel()
        run(confirmation.pressEnded(at: .now))
    }

    private func activate(_ action: HardStopPresentation.OverlayAction) {
        confirmation.activate(action, at: .now)
        schedule(after: HardStopConfirmation.confirmWindow)
    }

    private func confirm() {
        deadline?.cancel()
        run(confirmation.confirm(at: .now))
    }

    /// Completes a hold, or closes the confirm window, when its time is up.
    private func schedule(after delay: TimeInterval) {
        deadline?.cancel()
        deadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            run(confirmation.update(now: .now))
        }
    }

    private func run(_ action: HardStopPresentation.OverlayAction?) {
        switch action {
        case .extend: controller.extendHardStop()
        case .dismiss: controller.dismissHardStop()
        case nil: break
        }
    }
}

/// A button that reports pointer press and release (leaving the button counts as a release), and activation by
/// Space or VoiceOver. It is not a `Button`, so a click never runs it, and it has no Return shortcut.
private struct HoldToConfirmButton: View {
    let title: String
    let progress: Double
    let onPressBegan: () -> Void
    let onPressEnded: () -> Void
    let onActivate: () -> Void
    @State private var isTracking = false
    @State private var isPressed = false
    @State private var size = CGSize.zero

    var body: some View {
        Text(title)
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background {
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Color.white.opacity(0.18)
                        Color.white.opacity(0.35)
                            .frame(width: proxy.size.width * progress)
                    }
                    .onAppear { size = proxy.size }
                    .onChange(of: proxy.size) { _, newSize in size = newSize }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !isTracking {
                            // A new press. Returning to the button after leaving it does not start another.
                            isTracking = true
                            isPressed = true
                            onPressBegan()
                        } else if isPressed, !CGRect(origin: .zero, size: size).contains(value.location) {
                            isPressed = false
                            onPressEnded()
                        }
                    }
                    .onEnded { _ in
                        isTracking = false
                        guard isPressed else { return }
                        isPressed = false
                        onPressEnded()
                    }
            )
            .focusable()
            .onKeyPress(.space) {
                onActivate()
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Press and hold for \(Int(HardStopConfirmation.holdDuration)) seconds, or activate it and then Confirm within \(Int(HardStopConfirmation.confirmWindow)) seconds.")
            .accessibilityAction { onActivate() }
    }
}
