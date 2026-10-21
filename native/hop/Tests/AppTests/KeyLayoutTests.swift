@testable import Hop
import HopCore
import XCTest

/// Operation keys over installed Apple layouts: the tap derives the character with `KeyLayout` and the classifier
/// decides from it, so these cover what a key press does on each layout.
@MainActor
final class KeyLayoutTests: XCTestCase {
    private var active: SwitchSession {
        var session = SwitchSession()
        session.handle(.trigger(.forward))
        return session
    }

    private func outcome(_ layoutID: String, _ keyCode: UInt16) throws -> WindowOperation? {
        let layout = try XCTUnwrap(KeyLayout.named("com.apple.keylayout.\(layoutID)"), "\(layoutID) is not installed")
        let key = KeyEvent(
            .keyDown,
            keyCode: keyCode,
            modifiers: [.option, .command],
            character: layout.commandCharacter(keyCode: keyCode)
        )
        let classification = EventClassifier.classify(.key(key), session: active, shortcut: .default)
        guard case let .operation(operation) = classification.event else {
            XCTAssertEqual(classification, .pass, "\(layoutID) \(keyCode)")
            return nil
        }
        XCTAssertEqual(classification.disposition, .swallow)
        return operation
    }

    func testUSPositionsOperate() throws {
        XCTAssertEqual(try outcome("US", 0x2E), .minimize)
        XCTAssertEqual(try outcome("US", 0x0D), .close)
        XCTAssertEqual(try outcome("US", 0x04), .hideApp)
        XCTAssertEqual(try outcome("US", 0x0C), .quitApp)
        XCTAssertNil(try outcome("US", 0x2B))
    }

    func testFrenchFollowsItsOwnLetters() throws {
        // AZERTY: a comma on the US M position, Z on the US W position, W where US Z is.
        XCTAssertNil(try outcome("French", 0x2E))
        XCTAssertNil(try outcome("French", 0x0D))
        XCTAssertEqual(try outcome("French", 0x06), .close)
        XCTAssertEqual(try outcome("French", 0x04), .hideApp)
    }

    func testDvorakPunctuationPasses() throws {
        // Dvorak: a comma on the US W position and an apostrophe on Q.
        XCTAssertNil(try outcome("Dvorak", 0x0D))
        XCTAssertNil(try outcome("Dvorak", 0x0C))
        XCTAssertEqual(try outcome("Dvorak", 0x2B), .close)
    }

    func testDvorakQwertyCommandUsesTheQwertyLettersUnderCommand() throws {
        // It types Dvorak, but with ⌘ the keys are QWERTY: the W key closes and the key typing W does not.
        XCTAssertEqual(try outcome("DVORAK-QWERTYCMD", 0x0D), .close)
        XCTAssertEqual(try outcome("DVORAK-QWERTYCMD", 0x0C), .quitApp)
        XCTAssertNil(try outcome("DVORAK-QWERTYCMD", 0x2B))
    }

    func testNonLatinLayoutsOperateOnTheirCommandLetters() throws {
        // Hebrew types / on the US Q position and Greek types ;, but both give Q with ⌘, as does Russian.
        for layout in ["Hebrew", "Greek", "Russian"] {
            XCTAssertEqual(try outcome(layout, 0x0C), .quitApp, layout)
            XCTAssertEqual(try outcome(layout, 0x0D), .close, layout)
            XCTAssertEqual(try outcome(layout, 0x2E), .minimize, layout)
            XCTAssertEqual(try outcome(layout, 0x04), .hideApp, layout)
        }
    }

    func testTheSearchTakesTheCharacterTypedWithoutOption() throws {
        let us = try XCTUnwrap(KeyLayout.named("com.apple.keylayout.US"))
        // ⌥E is a dead acute accent on US; the search gets the e the key types without ⌥.
        XCTAssertEqual(us.typedCharacter(keyCode: 0x0E, shift: false), "e")
        XCTAssertEqual(us.typedCharacter(keyCode: 0x0E, shift: true), "E")
        XCTAssertEqual(us.typedCharacter(keyCode: 0x31, shift: false), " ")
        let french = try XCTUnwrap(KeyLayout.named("com.apple.keylayout.French"))
        XCTAssertEqual(french.typedCharacter(keyCode: 0x00, shift: false), "q", "AZERTY types q on the US A position")
        XCTAssertEqual(french.typedCharacter(keyCode: 0x13, shift: false), "é")
        let greek = try XCTUnwrap(KeyLayout.named("com.apple.keylayout.Greek"))
        XCTAssertEqual(greek.typedCharacter(keyCode: 0x00, shift: false), "α")
        let classification = EventClassifier.classify(
            .key(KeyEvent(.keyDown, keyCode: 0x13, modifiers: .option, text: french.typedCharacter(keyCode: 0x13, shift: false))),
            session: active,
            shortcut: .default
        )
        XCTAssertEqual(classification, Classification(.swallow, .type("é")))
        XCTAssertFalse(SwitcherSearch.isSearchCharacter(try XCTUnwrap(us.typedCharacter(keyCode: KeyCode.tab, shift: false))))
    }

    func testTheTapReadsTheTypedCharacterOnlyDuringASwitch() throws {
        let us = try XCTUnwrap(KeyLayout.named("com.apple.keylayout.US"))
        var lookups = 0
        let layout = { () -> KeyLayout? in
            lookups += 1
            return us
        }
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0x0E, keyDown: true))
        event.flags = .maskAlternate
        guard case let .key(idle) = tapInput(type: .keyDown, event: event, readsText: false, layout: layout) else {
            return XCTFail("a key-down is a key")
        }
        XCTAssertNil(idle.text)
        XCTAssertEqual(lookups, 0, "an ⌥ chord outside a switch never consults the layout")
        guard case let .key(active) = tapInput(type: .keyDown, event: event, readsText: true, layout: layout) else {
            return XCTFail("a key-down is a key")
        }
        XCTAssertEqual(active.text, "e", "the e the key types without ⌥")
        event.flags = [.maskAlternate, .maskCommand]
        guard case let .key(command) = tapInput(type: .keyDown, event: event, readsText: true, layout: layout) else {
            return XCTFail("a key-down is a key")
        }
        XCTAssertNil(command.text, "a ⌘ chord never types")
        XCTAssertEqual(command.character, "e")
    }

    func testAnUnknownLayoutIsNil() {
        XCTAssertNil(KeyLayout.named("com.apple.keylayout.NoSuchLayout"))
    }
}
