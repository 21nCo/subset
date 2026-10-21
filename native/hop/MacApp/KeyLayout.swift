import Carbon.HIToolbox
import Foundation

/// A keyboard layout's key map, read through the public Text Input Sources and Unicode keyboard layout APIs.
///
/// Operation keys (⌘W) match the character a key gives with ⌘ held, which is what menu key equivalents match: a
/// Hebrew, Greek or Russian layout gives Q, W, H and M under ⌘ on the US positions, and "Dvorak - QWERTY ⌘" gives the
/// QWERTY letters, while plain AZERTY and Dvorak give their own letters and punctuation under ⌘ too.
///
/// The switcher's search takes the character a key types with ⇧ alone or no modifier (`typedCharacter`), so the ⌥
/// held for the switch does not change it.
struct KeyLayout {
    /// The layout's `UCKeyboardLayout` bytes.
    private let data: Data

    /// The layout of the current keyboard input source (for an input method, the layout it types with), or nil if the
    /// system reports none. Call it on the main thread.
    static func current() -> KeyLayout? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        return KeyLayout(source: source)
    }

    /// An installed layout by its input source identifier (`com.apple.keylayout.French`), enabled or not.
    static func named(_ identifier: String) -> KeyLayout? {
        let filter = [kTISPropertyInputSourceID as String: identifier] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, true)?.takeRetainedValue() as? [TISInputSource],
              let source = list.first else { return nil }
        return KeyLayout(source: source)
    }

    private init?(source: TISInputSource) {
        guard let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        guard !data.isEmpty else { return nil }
        self.data = data
    }

    /// The character the key gives with ⌘ alone, or nil when it gives none. A dead key gives its own character rather
    /// than waiting for the next key.
    func commandCharacter(keyCode: UInt16) -> Character? {
        character(keyCode: keyCode, modifierKeyState: UInt32((cmdKey >> 8) & 0xFF))
    }

    /// The character the key types with ⇧ when `shift`, and with no modifier otherwise, or nil when it types none. A
    /// dead key gives its own character.
    func typedCharacter(keyCode: UInt16, shift: Bool) -> Character? {
        character(keyCode: keyCode, modifierKeyState: shift ? UInt32((shiftKey >> 8) & 0xFF) : 0)
    }

    /// `UCKeyTranslate` for a key-down with the Carbon modifier state shifted right by 8, as it takes it.
    private func character(keyCode: UInt16, modifierKeyState: UInt32) -> Character? {
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)
        let status = data.withUnsafeBytes { bytes -> OSStatus in
            guard let layout = bytes.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return OSStatus(paramErr) }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDown),
                modifierKeyState,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysMask),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length).first
    }
}
