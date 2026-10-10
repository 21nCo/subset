import AppKit
import SwiftUI

/// A small floating panel that never takes focus from the app the user is working in.
private final class FloatingPanel: NSPanel {
    private let allowsKey: Bool

    init(size: NSSize, allowsKey: Bool) {
        self.allowsKey = allowsKey
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isFloatingPanel = true
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        isMovableByWindowBackground = true
    }

    // A non-activating panel can become key without activating Breaks, so its buttons respond to the
    // first click while the user's app stays active.
    override var canBecomeKey: Bool { allowsKey }
}

/// Accepts the first click, so a button in an inactive panel responds immediately.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor
private func place(_ panel: NSPanel, position: ReminderPosition) {
    // Use the display the pointer is on, where the user is most likely looking.
    let mouse = NSEvent.mouseLocation
    let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
    guard let frame = screen?.visibleFrame else { return }
    let size = panel.frame.size
    let margin: CGFloat = 16
    let x: CGFloat = switch position {
    case .topLeading: frame.minX + margin
    case .top: frame.midX - size.width / 2
    case .topTrailing: frame.maxX - size.width - margin
    }
    panel.setFrameOrigin(NSPoint(x: x, y: frame.maxY - size.height - margin))
}

@MainActor
private func fade(_ panel: NSPanel, in fadeIn: Bool, completion: (() -> Void)? = nil) {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
        panel.alphaValue = fadeIn ? 1 : 0
        completion?()
        return
    }
    NSAnimationContext.runAnimationGroup({ context in
        context.duration = 0.25
        panel.animator().alphaValue = fadeIn ? 1 : 0
    }, completionHandler: { Task { @MainActor in completion?() } })
}

// MARK: - Heads-up notice

/// The gentle pre-break notice: a countdown with Start now, Snooze, and Skip.
@MainActor
final class HeadsUpPanelController {
    private unowned let controller: MacBreakController
    private var panel: NSPanel?

    init(controller: MacBreakController) {
        self.controller = controller
    }

    func show() {
        guard panel == nil else { return }
        let panel = FloatingPanel(size: NSSize(width: 380, height: 132), allowsKey: true)
        let hosting = FirstMouseHostingView(rootView: HeadsUpNoticeView().environmentObject(controller))
        hosting.frame = NSRect(origin: .zero, size: panel.frame.size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        place(panel, position: controller.settings.reminder.position)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(panel, in: true)
        self.panel = panel
    }

    func hide() {
        guard let panel else { return }
        self.panel = nil
        fade(panel, in: false) { panel.orderOut(nil) }
    }
}

struct HeadsUpNoticeView: View {
    @EnvironmentObject private var controller: MacBreakController

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "eye")
                    .accessibilityHidden(true)
                Text("\(controller.upcomingBreakKind.title) in \(controller.nextBreakRemaining.clockDuration)")
                    .font(.headline)
                    .monospacedDigit()
                    .accessibilityLabel("\(controller.upcomingBreakKind.title) in \(controller.nextBreakRemaining.spokenDuration)")
                Spacer()
                Button {
                    controller.dismissHeadsUp()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Dismiss notice")
            }
            Text(snoozeCaption)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                Button("Start now") { controller.startUpcomingBreak() }
                    .buttonStyle(.borderedProminent)
                Menu("Snooze") {
                    Button("1 minute") { controller.snooze(minutes: 1) }
                    Button("5 minutes") { controller.snooze(minutes: 5) }
                    Button("15 minutes") { controller.snooze(minutes: 15) }
                }
                .fixedSize()
                .disabled(controller.snoozesRemaining == 0)
                if controller.canSkipUpcomingBreak {
                    Button("Skip") { controller.skipUpcomingBreak() }
                        .accessibilityHint("Records this break as skipped")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var snoozeCaption: String {
        switch controller.snoozesRemaining {
        case 0: "No snoozes left today."
        case 1: "1 snooze left today."
        default: "\(controller.snoozesRemaining) snoozes left today."
        }
    }
}

// MARK: - Blink and posture nudges

/// Brief, non-interactive reminders that disappear on their own.
@MainActor
final class WellnessNudgeController {
    private var panel: NSPanel?
    private var hideTask: Task<Void, Never>?

    func show(_ reminder: BreakScheduler.WellnessReminder, large: Bool) {
        hideTask?.cancel()
        panel?.orderOut(nil)

        let size = large ? NSSize(width: 420, height: 96) : NSSize(width: 300, height: 64)
        let panel = FloatingPanel(size: size, allowsKey: false)
        panel.ignoresMouseEvents = true
        let hosting = NSHostingView(rootView: WellnessNudgeView(reminder: reminder, large: large))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting
        place(panel, position: .top)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        fade(panel, in: true)
        self.panel = panel

        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: WellnessNudgeView.text(for: reminder), .priority: NSAccessibilityPriorityLevel.medium.rawValue]
        )

        hideTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self, let panel = self.panel else { return }
            self.panel = nil
            fade(panel, in: false) { panel.orderOut(nil) }
        }
    }
}

struct WellnessNudgeView: View {
    let reminder: BreakScheduler.WellnessReminder
    let large: Bool

    static func text(for reminder: BreakScheduler.WellnessReminder) -> String {
        switch reminder {
        case .blink: "Blink slowly a few times."
        case .posture: "Check your posture. Drop your shoulders."
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: reminder == .blink ? "eye" : "figure.stand")
                .font(large ? .title : .title3)
            Text(Self.text(for: reminder))
                .font(large ? .title3.weight(.semibold) : .headline)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
