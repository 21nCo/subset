import AppKit
import ApplicationServices
import SwiftUI

@MainActor
final class InputOverlayController: ObservableObject {
    @Published private(set) var currentKeys = ""
    private var monitors: [Any] = []
    private var keyPanel: NSPanel?
    private var clearTask: Task<Void, Never>?

    private var area: CGRect?

    func start(showKeystrokes: Bool, highlightClicks: Bool, area: CGRect? = nil) {
        stop()
        self.area = area
        // Global key-event monitors receive nothing without Accessibility trust; ask for it
        // instead of showing an overlay that silently never appears.
        if showKeystrokes, !AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary) {
            NSLog("Screenshot: keystroke display needs Accessibility permission")
        } else if showKeystrokes {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { [weak self] event in
                Task { @MainActor in self?.show(event: event) }
            }
            if let monitor { monitors.append(monitor) }
        }
        if highlightClicks {
            let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                Task { @MainActor in self?.showClick(at: NSEvent.mouseLocation, right: event.type == .rightMouseDown) }
            }
            if let monitor { monitors.append(monitor) }
        }
    }

    func stop() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        clearTask?.cancel()
        keyPanel?.orderOut(nil)
        keyPanel = nil
        currentKeys = ""
    }

    private func show(event: NSEvent) {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        if event.type == .keyDown {
            let raw = event.charactersIgnoringModifiers ?? ""
            let readable: String
            switch event.keyCode {
            case 36: readable = "↩"
            case 48: readable = "⇥"
            case 49: readable = "Space"
            case 51: readable = "⌫"
            case 53: readable = "Esc"
            case 123: readable = "←"
            case 124: readable = "→"
            case 125: readable = "↓"
            case 126: readable = "↑"
            default: readable = raw.uppercased()
            }
            if !readable.isEmpty { parts.append(readable) }
        }
        let value = parts.joined(separator: (parts.last?.count ?? 0) > 1 ? " " : "")
        guard !value.isEmpty else { return }
        currentKeys = value
        ensureKeyPanel()
        keyPanel?.orderFrontRegardless()
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            guard !Task.isCancelled else { return }
            currentKeys = ""
            keyPanel?.orderOut(nil)
        }
    }

    private func ensureKeyPanel() {
        guard keyPanel == nil else { return }
        // Keep the keystrokes inside the recorded area so they appear in the recording.
        let frame: CGRect
        if let area, area.width >= 360, area.height >= 120 {
            frame = CGRect(x: area.midX - 170, y: area.minY + 24, width: 340, height: 68)
        } else {
            let visible = NSScreen.main?.visibleFrame ?? .zero
            frame = CGRect(x: visible.midX - 170, y: visible.minY + 90, width: 340, height: 68)
        }
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: KeystrokeOverlayView(controller: self))
        keyPanel = panel
    }

    private func showClick(at point: CGPoint, right: Bool) {
        let size: CGFloat = 54
        let panel = NSPanel(contentRect: CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.ignoresMouseEvents = true
        panel.contentView = NSHostingView(rootView: ClickHighlightView(color: right ? .orange : .purple))
        panel.orderFrontRegardless()
        Task {
            try? await Task.sleep(for: .milliseconds(520))
            panel.orderOut(nil)
        }
    }
}

private struct KeystrokeOverlayView: View {
    @ObservedObject var controller: InputOverlayController
    var body: some View {
        Text(controller.currentKeys)
            .font(.system(size: 25, weight: .semibold, design: .rounded))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(minWidth: 80, minHeight: 56)
            .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15).stroke(.white.opacity(0.2)))
    }
}

private struct ClickHighlightView: View {
    let color: Color
    var body: some View {
        TimelineView(.animation) { context in
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.55) / 0.55
            Circle()
                .stroke(color.opacity(1 - phase), lineWidth: 5)
                .scaleEffect(0.35 + phase * 0.65)
        }
        .allowsHitTesting(false)
    }
}
