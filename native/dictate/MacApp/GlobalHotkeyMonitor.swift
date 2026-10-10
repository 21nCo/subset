import AppKit
import Foundation

@MainActor
final class GlobalHotkeyMonitor {
    static let shared = GlobalHotkeyMonitor()

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var onPress: (() -> Void)?
    private var onRelease: (() -> Void)?
    private var onCancel: (() -> Void)?
    /// Set when Esc cancels a held session, so releasing fn does not insert anything.
    private var cancelledWhileHeld = false
    private var isFunctionKeyDown = false
    private var lastTransitionAt = Date.distantPast
    private let minimumTransitionInterval: TimeInterval = 0.2

    func start(
        onPress: @escaping () -> Void,
        onRelease: @escaping () -> Void,
        onCancel: @escaping () -> Void
    ) {
        stop()
        self.onPress = onPress
        self.onRelease = onRelease
        self.onCancel = onCancel

        // keyDown is observed only to detect Esc while fn is held; key contents are not stored.
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            Task { @MainActor [weak self] in
                self?.handle(event)
            }
        }

        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { [weak self] event in
            guard let self else { return event }
            return self.handleLocal(event)
        }
    }

    func stop() {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
        }
        if let localMonitor {
            NSEvent.removeMonitor(localMonitor)
        }
        globalMonitor = nil
        localMonitor = nil
        onPress = nil
        onRelease = nil
        onCancel = nil
        cancelledWhileHeld = false
        isFunctionKeyDown = false
        lastTransitionAt = .distantPast
    }

    private func handle(_ event: NSEvent) {
        if event.type == .keyDown {
            handleKeyDown(event)
        } else {
            handleFlagsChanged(event)
        }
    }

    private func handleKeyDown(_ event: NSEvent) {
        let escapeKeyCode: UInt16 = 53
        guard event.keyCode == escapeKeyCode, isFunctionKeyDown, !cancelledWhileHeld else { return }
        cancelledWhileHeld = true
        onCancel?()
    }

    private func handleLocal(_ event: NSEvent) -> NSEvent? {
        handle(event)
        return event
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == 63 else { return }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        handleFunctionKey(isPressed: flags.contains(.function))
    }

    /// The fn press/release state machine, separated from NSEvent for tests.
    func handleFunctionKey(isPressed: Bool, at now: Date = Date()) {
        if isPressed && !isFunctionKeyDown {
            guard now.timeIntervalSince(lastTransitionAt) >= minimumTransitionInterval else { return }
            isFunctionKeyDown = true
            cancelledWhileHeld = false
            lastTransitionAt = now
            onPress?()
        } else if !isPressed && isFunctionKeyDown {
            // Only presses are debounced: the release of an accepted press must always be
            // delivered, or a quick tap would leave dictation recording with fn released.
            isFunctionKeyDown = false
            lastTransitionAt = now
            if cancelledWhileHeld {
                // Cancel again in case recording started after Esc was pressed.
                cancelledWhileHeld = false
                onCancel?()
                return
            }
            onRelease?()
        }
    }
}
