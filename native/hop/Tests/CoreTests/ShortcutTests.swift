import CoreGraphics
import Foundation
import HopCore
import XCTest

final class ShortcutTests: XCTestCase {
    func testDefaultIsOptionTab() {
        XCTAssertEqual(Shortcut.default.holdModifier, .option)
        XCTAssertEqual(Shortcut.default.keyCode, KeyCode.tab)
        XCTAssertEqual(Shortcut.default.forwardModifiers, .option)
        XCTAssertEqual(Shortcut.default.backwardModifiers, [.option, .shift])
        XCTAssertEqual(Shortcut.default.displayName, "⌥Tab")
    }

    func testOptionOrControlMayBeHeld() throws {
        XCTAssertEqual(try Shortcut(holdModifier: .control, keyCode: KeyCode.tab).displayName, "⌃Tab")
        XCTAssertEqual(try Shortcut(holdModifier: .option, keyCode: KeyCode.grave).displayName, "⌥`")
    }

    func testCommandShiftAndCombinedModifiersAreRejected() {
        for modifier: ModifierMask in [.command, [.command, .option], .shift, [.option, .shift], [.option, .control], []] {
            XCTAssertThrowsError(try Shortcut(holdModifier: modifier, keyCode: KeyCode.tab)) { error in
                XCTAssertEqual(error as? Shortcut.Invalid, .holdModifier(modifier))
            }
        }
    }

    func testEscapeModifierKeysAndImpossibleCodesAreRejected() {
        for code in [KeyCode.escape, 0x3A /* left Option */, 0x3B /* left Control */, 0x37 /* Command */, 0x80, 0xFFFF] {
            XCTAssertThrowsError(try Shortcut(holdModifier: .option, keyCode: code)) { error in
                XCTAssertEqual(error as? Shortcut.Invalid, .keyCode(code))
            }
        }
    }

    func testTheArrowsThatStepASwitchAreRejected() {
        // While a switch is active ← and → step it and ↑ and ↓ move by row; as the shortcut key one of them would mean
        // two things at once.
        for modifier: ModifierMask in [.option, .control] {
            for code in [KeyCode.leftArrow, KeyCode.rightArrow, KeyCode.upArrow, KeyCode.downArrow] {
                XCTAssertThrowsError(try Shortcut(holdModifier: modifier, keyCode: code)) { error in
                    XCTAssertEqual(error as? Shortcut.Invalid, .keyCode(code))
                }
            }
        }
    }

    func testEventFlagsMapOnlyTheFourModifiers() {
        let all: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
        XCTAssertEqual(ModifierMask(eventFlags: all.rawValue), .all)
        XCTAssertEqual(ModifierMask(eventFlags: CGEventFlags.maskAlternate.rawValue), .option)
        XCTAssertEqual(ModifierMask(eventFlags: CGEventFlags.maskControl.rawValue), .control)
        XCTAssertEqual(ModifierMask(eventFlags: CGEventFlags.maskShift.rawValue), .shift)
        XCTAssertEqual(ModifierMask(eventFlags: CGEventFlags.maskCommand.rawValue), .command)
        // Arrow keys carry the keypad and Fn flags; Caps Lock may be on. None of them is a modifier for a match.
        let ignored: CGEventFlags = [.maskAlphaShift, .maskNumericPad, .maskSecondaryFn, .maskHelp, .maskNonCoalesced]
        XCTAssertEqual(ModifierMask(eventFlags: ignored.rawValue | CGEventFlags.maskAlternate.rawValue), .option)
        // Device-dependent bits for the left Option key (NX_DEVICELALTKEYMASK) do not stand in for the Option flag.
        XCTAssertEqual(ModifierMask(eventFlags: 0x20), [])
    }
}

final class ShortcutStoreTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!

    override func setUp() {
        suiteName = "dev.subset.hop.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func store(modifier: Any?, keyCode: Any?) -> Shortcut {
        if let modifier { defaults.set(modifier, forKey: ShortcutStore.holdModifierKey) }
        if let keyCode { defaults.set(keyCode, forKey: ShortcutStore.keyCodeKey) }
        return ShortcutStore(defaults: defaults).shortcut
    }

    func testNothingStoredReadsTheDefault() {
        XCTAssertEqual(store(modifier: nil, keyCode: nil), .default)
    }

    func testAValidStoredShortcutIsRead() throws {
        let shortcut = store(modifier: ModifierMask.control.rawValue, keyCode: Int(KeyCode.grave))
        XCTAssertEqual(shortcut, try Shortcut(holdModifier: .control, keyCode: KeyCode.grave))
    }

    func testADisallowedOrMalformedStoredShortcutReadsTheDefault() {
        let cases: [(Any?, Any?)] = [
            (ModifierMask.command.rawValue, Int(KeyCode.tab)), // ⌘Tab needs a private API
            (ModifierMask.option.rawValue | 1 << 8, Int(KeyCode.tab)), // unknown modifier bits
            (ModifierMask.option.rawValue, Int(KeyCode.escape)),
            (ModifierMask.option.rawValue, Int(KeyCode.leftArrow)),
            (ModifierMask.control.rawValue, Int(KeyCode.rightArrow)),
            (ModifierMask.option.rawValue, Int(KeyCode.downArrow)),
            (ModifierMask.option.rawValue, -1),
            (ModifierMask.option.rawValue, 70_000),
            ("option", Int(KeyCode.grave)),
            (ModifierMask.control.rawValue, "tab"),
            (ModifierMask.control.rawValue, nil), // half a setting
        ]
        for (modifier, keyCode) in cases {
            defaults.removePersistentDomain(forName: suiteName)
            XCTAssertEqual(store(modifier: modifier, keyCode: keyCode), .default, "\(String(describing: modifier)), \(String(describing: keyCode))")
        }
    }

    func testAStoredArrowShortcutLeavesTheArrowsSteppingTheirOwnWays() {
        defaults.set(ModifierMask.option.rawValue, forKey: ShortcutStore.holdModifierKey)
        defaults.set(Int(KeyCode.leftArrow), forKey: ShortcutStore.keyCodeKey)
        let shortcut = ShortcutStore(defaults: defaults).shortcut
        XCTAssertEqual(shortcut, .default)
        var session = SwitchSession()
        session.handle(.trigger(.forward))
        let left = TapInput.key(KeyEvent(.keyDown, keyCode: KeyCode.leftArrow, modifiers: .option))
        let right = TapInput.key(KeyEvent(.keyDown, keyCode: KeyCode.rightArrow, modifiers: .option))
        XCTAssertEqual(EventClassifier.classify(left, session: session, shortcut: shortcut), Classification(.swallow, .step(.backward)))
        XCTAssertEqual(EventClassifier.classify(right, session: session, shortcut: shortcut), Classification(.swallow, .step(.forward)))
    }
}
