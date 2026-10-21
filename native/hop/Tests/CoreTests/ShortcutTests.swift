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

    func testOptionOrControlWithTabOrGraveAreTheOnlyShortcuts() throws {
        XCTAssertEqual(try Shortcut(holdModifier: .option, keyCode: KeyCode.tab).displayName, "⌥Tab")
        XCTAssertEqual(try Shortcut(holdModifier: .control, keyCode: KeyCode.tab).displayName, "⌃Tab")
        XCTAssertEqual(try Shortcut(holdModifier: .option, keyCode: KeyCode.grave).displayName, "⌥`")
        XCTAssertEqual(try Shortcut(holdModifier: .control, keyCode: KeyCode.grave).displayName, "⌃`")
        XCTAssertEqual(try Shortcut(holdModifier: .control, keyCode: KeyCode.grave).backwardModifiers, [.control, .shift])
    }

    /// Each class of refused combination, with its reason. The checks run in a fixed order, so a combination with
    /// several faults is refused for the first.
    func testEachRefusedClassHasItsReason() {
        let cases: [(ModifierMask, UInt16, Shortcut.Invalid)] = [
            (.command, KeyCode.tab, .command), // ⌘Tab needs a private API
            ([.command, .option], KeyCode.tab, .command),
            ([.command, .shift], KeyCode.grave, .command),
            ([], KeyCode.tab, .noHoldModifier),
            (.shift, KeyCode.tab, .noHoldModifier),
            ([.option, .control], KeyCode.tab, .bothHoldModifiers),
            ([.option, .shift], KeyCode.tab, .shift), // ⇧ reverses, so it is never part of the shortcut
            ([.control, .shift], KeyCode.grave, .shift),
            (.option, 0x31 /* Space */, .key(0x31)),
            (.control, 0x00 /* A */, .key(0x00)),
            (.option, KeyCode.escape, .key(KeyCode.escape)),
            (.option, KeyCode.leftArrow, .key(KeyCode.leftArrow)),
            (.control, KeyCode.downArrow, .key(KeyCode.downArrow)),
            (.option, 0x3A /* left Option */, .key(0x3A)),
            (.option, 0x80, .key(0x80)),
            (.option, 0xFFFF, .key(0xFFFF)),
        ]
        for (modifiers, code, expected) in cases {
            XCTAssertThrowsError(try Shortcut(holdModifier: modifiers, keyCode: code), "\(modifiers) \(code)") { error in
                XCTAssertEqual(error as? Shortcut.Invalid, expected)
                XCTAssertFalse(expected.reason.isEmpty)
            }
        }
        XCTAssertEqual(Shortcut.Invalid.command.reason, "⌘ can't be used: switching with ⌘Tab needs a private macOS API.")
        XCTAssertEqual(Shortcut.Invalid.key(0x31).reason, "The key must be Tab or `.")
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
