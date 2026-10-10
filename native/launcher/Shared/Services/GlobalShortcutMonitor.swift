import Carbon.HIToolbox
import Foundation

struct GlobalShortcutRegistration {
    let id: UInt32
    let keyCode: UInt32
    let modifiers: UInt32
    let onPress: () -> Void
}

@MainActor
final class GlobalShortcutMonitor {
    static let shared = GlobalShortcutMonitor()

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?
    private var handlers: [UInt32: () -> Void] = [:]
    private let hotKeySignature: OSType = 0x53555052 // SUPR

    /// Registers each shortcut independently and returns the IDs that could not be registered
    /// (for example because another app already owns the combination).
    @discardableResult
    func start(shortcuts: [GlobalShortcutRegistration]) -> Set<UInt32> {
        stop()
        let allIDs = Set(shortcuts.map(\.id))
        guard !shortcuts.isEmpty else { return allIDs }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                monitor.handle(event: event)
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandlerRef
        )

        guard handlerStatus == noErr else { return allIDs }

        var failedIDs: Set<UInt32> = []

        for shortcut in shortcuts {
            var hotKeyRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: hotKeySignature, id: shortcut.id)
            let registrationStatus = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &hotKeyRef
            )

            // One conflict must not unregister the others (for example ⌥Space owned by another app).
            guard registrationStatus == noErr, let hotKeyRef else {
                NSLog("Launcher: global shortcut %u is unavailable (status %d)", shortcut.id, registrationStatus)
                failedIDs.insert(shortcut.id)
                continue
            }

            hotKeyRefs[shortcut.id] = hotKeyRef
            handlers[shortcut.id] = shortcut.onPress
        }

        if hotKeyRefs.isEmpty {
            stop()
        }
        return failedIDs
    }

    func stop() {
        for hotKeyRef in hotKeyRefs.values {
            UnregisterEventHotKey(hotKeyRef)
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
        }

        hotKeyRefs.removeAll()
        eventHandlerRef = nil
        handlers.removeAll()
    }

    private func handle(event: EventRef) {
        var resolvedHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &resolvedHotKeyID
        )

        guard status == noErr, resolvedHotKeyID.signature == hotKeySignature else { return }
        handlers[resolvedHotKeyID.id]?()
    }
}
