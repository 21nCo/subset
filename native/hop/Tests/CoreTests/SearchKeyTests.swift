import HopCore
import XCTest

/// The keys of the switcher's search and of the same-app shortcut, as the tap classifies them.
final class SearchKeyTests: XCTestCase {
    private let shortcut = Shortcut.default
    private let sameApp = Shortcut.sameAppDefault
    private let idle = SwitchSession()

    private func session(_ scope: SwitchScope) -> SwitchSession {
        var session = SwitchSession()
        session.handle(.trigger(.forward, scope: scope))
        return session
    }

    private func classify(_ key: KeyEvent, _ session: SwitchSession) -> Classification {
        EventClassifier.classify(.key(key), session: session, shortcut: shortcut, sameAppShortcut: sameApp)
    }

    /// A key-down as the tap reports it: `text` is what the layout types without ⌥ or ⌃, `character` with ⌘.
    private func down(
        _ code: UInt16, _ modifiers: ModifierMask, text: Character? = nil, character: Character? = nil
    ) -> KeyEvent {
        KeyEvent(.keyDown, keyCode: code, modifiers: modifiers, character: character, text: text)
    }

    // MARK: - Search keys

    func testAPrintableKeyWithTheHoldingModifierTypesIntoTheSearch() {
        let active = session(.allWindows)
        XCTAssertEqual(classify(down(0x0E /* E */, .option, text: "e"), active), Classification(.swallow, .type("e")))
        XCTAssertEqual(classify(down(0x0E, [.option, .shift], text: "E"), active), Classification(.swallow, .type("E")))
        XCTAssertEqual(classify(down(0x31 /* Space */, .option, text: " "), active), Classification(.swallow, .type(" ")))
        XCTAssertEqual(classify(down(0x12 /* 1 */, .option, text: "1"), active), Classification(.swallow, .type("1")))
    }

    func testDeleteRemovesFromTheSearch() {
        XCTAssertEqual(classify(down(KeyCode.delete, .option, text: "\u{7F}"), session(.allWindows)),
                       Classification(.swallow, .deleteBackward))
        XCTAssertEqual(classify(down(KeyCode.delete, .option), idle), .pass, "Delete passes while idle")
    }

    func testCommandChordsAreOperationsNotSearchCharacters() {
        let active = session(.allWindows)
        // ⌥⌘W closes; ⌥⌘E is no operation and passes rather than typing an e.
        XCTAssertEqual(classify(down(0x0D, [.option, .command], character: "w"), active),
                       Classification(.swallow, .operation(.close)))
        XCTAssertEqual(classify(down(0x0E, [.option, .command], text: "e", character: "e"), active), .pass)
    }

    func testOtherModifiersDoNotType() {
        let active = session(.allWindows)
        XCTAssertEqual(classify(down(0x0E, [.option, .control], text: "e"), active), .pass, "⌃ is not typing")
        XCTAssertEqual(classify(down(0x0E, [.option, .shift, .command], text: "E"), active), .pass)
    }

    func testPrintableKeysPassWhileIdle() {
        XCTAssertEqual(classify(down(0x0E, .option, text: "e"), idle), .pass, "⌥E reaches the app outside a switch")
        XCTAssertEqual(classify(down(0x0E, [], text: "e"), idle), .pass)
    }

    func testKeysThatTypeNoPrintableCharacterPass() {
        let active = session(.allWindows)
        XCTAssertEqual(classify(down(0x24 /* Return */, .option, text: "\r"), active), .pass)
        XCTAssertEqual(classify(down(0x7A /* F1 */, .option, text: "\u{F704}"), active), .pass)
        XCTAssertEqual(classify(down(0x0E, .option), active), .pass, "no character from the layout")
    }

    func testAControlHeldSwitchTypesWithControlButNotOption() throws {
        let control = try Shortcut(holdModifier: .control, keyCode: KeyCode.tab)
        var active = SwitchSession()
        active.handle(.trigger(.forward))
        let typed = EventClassifier.classify(.key(down(0x0E, .control, text: "e")), session: active, shortcut: control)
        XCTAssertEqual(typed, Classification(.swallow, .type("e")))
        let chord = EventClassifier.classify(.key(down(0x0E, [.control, .option], text: "e")), session: active,
                                             shortcut: control)
        XCTAssertEqual(chord, .pass)
    }

    // MARK: - Same-app shortcut

    func testTheSameAppShortcutStartsASwitchOverTheFrontmostApp() {
        XCTAssertEqual(classify(down(KeyCode.grave, .option), idle),
                       Classification(.swallow, .trigger(.forward, scope: .frontmostApp)))
        XCTAssertEqual(classify(down(KeyCode.grave, [.option, .shift]), idle),
                       Classification(.swallow, .trigger(.backward, scope: .frontmostApp)))
        XCTAssertEqual(classify(down(KeyCode.tab, .option), idle), Classification(.swallow, .trigger(.forward)))
        XCTAssertEqual(classify(down(KeyCode.grave, [.option, .command]), idle), .pass)
        XCTAssertEqual(EventClassifier.classify(.key(down(KeyCode.grave, .option)), session: idle, shortcut: shortcut),
                       .pass, "without a same-app shortcut ⌥` passes")
    }

    func testEitherShortcutsKeyStepsWhenTheyShareTheHoldingModifier() {
        for scope in [SwitchScope.allWindows, .frontmostApp] {
            let active = session(scope)
            XCTAssertEqual(classify(down(KeyCode.grave, .option, text: "`"), active), Classification(.swallow, .step(.forward)))
            XCTAssertEqual(classify(down(KeyCode.tab, [.option, .shift], text: "\t"), active),
                           Classification(.swallow, .step(.backward)))
        }
    }

    func testASameAppSwitchUnderAnotherHoldingModifierFollowsItsOwnModifier() throws {
        let controlGrave = try Shortcut(holdModifier: .control, keyCode: KeyCode.grave)
        var recognizer = ShortcutRecognizer(shortcut: .default, sameAppShortcut: controlGrave)
        let start = recognizer.handle(.key(down(KeyCode.grave, .control)))
        XCTAssertEqual(start.event, .trigger(.forward, scope: .frontmostApp))
        XCTAssertEqual(recognizer.session.scope, .frontmostApp)
        XCTAssertEqual(recognizer.handle(.key(down(KeyCode.grave, .control))).event, .step(.forward))
        XCTAssertEqual(recognizer.handle(.key(down(KeyCode.tab, .control, text: "\t"))).disposition, .pass,
                       "⌃Tab is not a shortcut")
        XCTAssertEqual(recognizer.handle(.key(down(0x0E, .control, text: "e"))).event, .type("e"))
        let release = recognizer.handle(.key(KeyEvent(.flagsChanged, keyCode: 0x3B, modifiers: [])))
        XCTAssertEqual(release.outcome, .commit, "releasing ⌃ commits")
        XCTAssertEqual(recognizer.session.scope, .allWindows)
    }

    // MARK: - Presses

    func testHeldLetterAndDeleteRepeatAndTheirKeyUpsAreSwallowed() {
        var recognizer = ShortcutRecognizer(shortcut: .default, sameAppShortcut: .sameAppDefault)
        _ = recognizer.handle(.key(down(KeyCode.tab, .option)))
        XCTAssertEqual(recognizer.handle(.key(down(0x0E, .option, text: "e"))).event, .type("e"))
        let repeated = KeyEvent(.keyDown, keyCode: 0x0E, modifiers: .option, isRepeat: true, text: "e")
        XCTAssertEqual(recognizer.handle(.key(repeated)), .init(disposition: .swallow, event: .type("e"), outcome: nil))
        XCTAssertEqual(recognizer.handle(.key(KeyEvent(.keyUp, keyCode: 0x0E, modifiers: .option))).disposition, .swallow)
        _ = recognizer.handle(.key(down(KeyCode.delete, .option)))
        let deleteRepeat = KeyEvent(.keyDown, keyCode: KeyCode.delete, modifiers: .option, isRepeat: true)
        XCTAssertEqual(recognizer.handle(.key(deleteRepeat)).event, .deleteBackward)
    }

    func testALetterHeldFromBeforeTheSwitchNeverTypes() {
        var recognizer = ShortcutRecognizer(shortcut: .default, sameAppShortcut: .sameAppDefault)
        XCTAssertEqual(recognizer.handle(.key(down(0x0E, [], text: "e"))).disposition, .pass)
        _ = recognizer.handle(.key(down(KeyCode.tab, .option)))
        let repeated = KeyEvent(.keyDown, keyCode: 0x0E, modifiers: .option, isRepeat: true, text: "e")
        XCTAssertEqual(recognizer.handle(.key(repeated)), .init(disposition: .pass, outcome: nil))
    }
}
