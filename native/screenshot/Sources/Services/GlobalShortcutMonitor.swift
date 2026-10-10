import Carbon.HIToolbox
import Foundation

struct ShortcutRegistration {
    let id: UInt32
    let name: String
    let keyCode: UInt32
    let modifiers: UInt32
    let handler: () -> Void
}

final class GlobalShortcutMonitor {
    static let shared = GlobalShortcutMonitor()

    private var hotKeyRefs: [EventHotKeyRef] = []
    private var handlers: [UInt32: () -> Void] = [:]
    private var eventHandler: EventHandlerRef?

    /// Registers the shortcuts and returns the names of any that could not be registered.
    @discardableResult
    func start(_ registrations: [ShortcutRegistration]) -> [String] {
        stop()
        let eventSpec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: OSType(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var identifier = EventHotKeyID()
                let result = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &identifier
                )
                guard result == noErr else { return result }
                let monitor = Unmanaged<GlobalShortcutMonitor>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async { monitor.handlers[identifier.id]?() }
                return noErr
            },
            1,
            [eventSpec],
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )
        guard status == noErr else { return registrations.map(\.name) }
        var failed: [String] = []

        for registration in registrations {
            var ref: EventHotKeyRef?
            let identifier = EventHotKeyID(signature: OSType(0x53535043), id: registration.id)
            let result = RegisterEventHotKey(
                registration.keyCode,
                registration.modifiers,
                identifier,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if result == noErr, let ref {
                hotKeyRefs.append(ref)
                handlers[registration.id] = registration.handler
            } else {
                failed.append(registration.name)
            }
        }
        return failed
    }

    func stop() {
        hotKeyRefs.forEach { _ = UnregisterEventHotKey($0) }
        hotKeyRefs = []
        handlers = [:]
        if let eventHandler { RemoveEventHandler(eventHandler) }
        eventHandler = nil
    }
}
