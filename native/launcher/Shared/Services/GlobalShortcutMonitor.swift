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

    func start(shortcuts: [GlobalShortcutRegistration]) -> Bool {
        stop()
        guard !shortcuts.isEmpty else { return false }

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

        guard handlerStatus == noErr else { return false }

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

            guard registrationStatus == noErr, let hotKeyRef else {
                stop()
                return false
            }

            hotKeyRefs[shortcut.id] = hotKeyRef
            handlers[shortcut.id] = shortcut.onPress
        }

        return true
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
