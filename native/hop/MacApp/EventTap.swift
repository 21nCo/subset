import AppKit
import ApplicationServices
import HopCore

/// A keyboard event tap at the session level, inserted ahead of other taps. It hands every key-down, key-up and
/// modifier change to `handle`, which decides synchronously whether the event passes unchanged or is swallowed, and
/// reports the system disabling the tap as `.tapDisabled`.
///
/// The tap's run loop source is on the main run loop in the common modes, so the callback runs on the main thread,
/// also while a menu is open. `handle` must return quickly: the system disables a tap whose callback stalls.
@MainActor
final class EventTap {
    private let handle: (TapInput) -> Disposition
    /// Whether a key's typed character can matter: only while a switch is active, whose search takes it.
    fileprivate let readsText: () -> Bool
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    /// The retained reference the C callback receives; released when the tap is removed, so the callback can never
    /// see a deallocated tap.
    private var context: Unmanaged<EventTap>?

    init(readsText: @escaping () -> Bool, handle: @escaping (TapInput) -> Disposition) {
        self.readsText = readsText
        self.handle = handle
    }

    var isInstalled: Bool { port != nil }

    /// Creates and enables the tap. Returns false if the system refuses it, which it does unless the process has the
    /// Accessibility permission.
    func install() -> Bool {
        guard port == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let context = Unmanaged.passRetained(self)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: context.toOpaque()
        ) else {
            context.release()
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.port = port
        self.source = source
        self.context = context
        return true
    }

    /// Turns the tap back on after the system disabled it.
    func reenable() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: true)
    }

    /// Disables and removes the tap. Safe to call when it is not installed.
    func remove() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        context?.release()
        context = nil
    }

    /// Classifies one input from the callback; returns true to swallow its event.
    fileprivate func receive(_ input: TapInput) -> Bool {
        handle(input) == .swallow
    }
}

/// The input an event delivers to the tap, or nil for an event type the tap does not handle. The typed character is
/// read only when `readsText`, so ⌥ and ⌃ chords outside a switch never consult the keyboard layout (`layout`, the
/// current one unless a test fixes it).
func tapInput(
    type: CGEventType,
    event: CGEvent,
    readsText: Bool,
    layout currentLayout: () -> KeyLayout? = KeyLayout.current
) -> TapInput? {
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        return .tapDisabled
    case .keyDown, .keyUp, .flagsChanged:
        let kind: KeyEvent.Kind = type == .keyDown ? .keyDown : (type == .keyUp ? .keyUp : .flagsChanged)
        let keyCode = UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode))
        let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let modifiers = ModifierMask(eventFlags: event.flags.rawValue)
        // Only a ⌘ key-down can be an operation key, which matches the character the layout gives the key with ⌘. Only
        // a key-down with ⌥ and neither ⌘ nor ⌃ during a switch can type into its search, which takes the character
        // without ⌥.
        let command = modifiers.contains(.command)
        let types = readsText && modifiers.contains(.option) && modifiers.isDisjoint(with: [.command, .control])
        let layout = kind == .keyDown && (command || types) ? currentLayout() : nil
        let character = command ? layout?.commandCharacter(keyCode: keyCode) : nil
        let text = types ? layout?.typedCharacter(keyCode: keyCode, shift: modifiers.contains(.shift)) : nil
        return .key(KeyEvent(
            kind, keyCode: keyCode, modifiers: modifiers, isRepeat: isRepeat, character: character, text: text
        ))
    default:
        return nil
    }
}

/// The tap's C callback. The run loop source is on the main run loop, so this runs on the main thread.
private func eventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let tap = Unmanaged<EventTap>.fromOpaque(userInfo).takeUnretainedValue()
    let readsText = MainActor.assumeIsolated { tap.readsText() }
    guard let input = tapInput(type: type, event: event, readsText: readsText) else {
        return Unmanaged.passUnretained(event)
    }
    let swallow = MainActor.assumeIsolated { tap.receive(input) }
    return swallow ? nil : Unmanaged.passUnretained(event)
}
