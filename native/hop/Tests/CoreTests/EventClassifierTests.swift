import HopCore
import XCTest

final class EventClassifierTests: XCTestCase {
    private let shortcut = Shortcut.default
    private let idle = SwitchSession(count: 3)
    private var active: SwitchSession {
        var session = idle
        session.handle(.trigger(.forward))
        return session
    }

    private func classify(_ input: TapInput, _ session: SwitchSession) -> Classification {
        EventClassifier.classify(input, session: session, shortcut: shortcut)
    }

    private func down(_ code: UInt16, _ modifiers: ModifierMask = []) -> TapInput {
        .key(KeyEvent(.keyDown, keyCode: code, modifiers: modifiers))
    }

    func testOptionTabStartsAForwardSwitch() {
        XCTAssertEqual(classify(down(KeyCode.tab, .option), idle), Classification(.swallow, .trigger(.forward)))
    }

    func testOptionShiftTabStartsABackwardSwitch() {
        XCTAssertEqual(classify(down(KeyCode.tab, [.option, .shift]), idle), Classification(.swallow, .trigger(.backward)))
    }

    func testTabWithoutAModifierPasses() {
        XCTAssertEqual(classify(down(KeyCode.tab), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.tab, .shift), idle), .pass)
    }

    func testOptionWithAnotherKeyPassesWhileIdle() {
        XCTAssertEqual(classify(down(0x00 /* A */, .option), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.rightArrow, .option), idle), .pass)
        XCTAssertEqual(classify(.key(KeyEvent(.flagsChanged, keyCode: 0x3A, modifiers: .option)), idle), .pass)
    }

    func testEscapePassesWhileIdleAndCancelsWhileActive() {
        XCTAssertEqual(classify(down(KeyCode.escape), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.escape, .option), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.escape, .option), active), Classification(.swallow, .escape))
    }

    func testControlTabPassesWithTheDefaultShortcut() {
        XCTAssertEqual(classify(down(KeyCode.tab, .control), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.tab, [.control, .shift]), idle), .pass)
    }

    func testExtraModifiersDoNotStartASwitch() {
        // ⌘⌥Tab and ⌃⌥Tab belong to other shortcuts.
        XCTAssertEqual(classify(down(KeyCode.tab, [.option, .command]), idle), .pass)
        XCTAssertEqual(classify(down(KeyCode.tab, [.option, .control]), idle), .pass)
    }

    func testTheShortcutPassesWhenThereIsNothingToSwitchTo() {
        XCTAssertEqual(classify(down(KeyCode.tab, .option), SwitchSession(count: 0)), .pass)
    }

    func testAControlShortcutMatchesControlNotOption() throws {
        let control = try Shortcut(holdModifier: .control, keyCode: KeyCode.tab)
        XCTAssertEqual(EventClassifier.classify(down(KeyCode.tab, .control), session: idle, shortcut: control),
                       Classification(.swallow, .trigger(.forward)))
        XCTAssertEqual(EventClassifier.classify(down(KeyCode.tab, .option), session: idle, shortcut: control), .pass)
    }

    func testTabArrowsAndShiftStepWhileActive() {
        XCTAssertEqual(classify(down(KeyCode.tab, .option), active), Classification(.swallow, .step(.forward)))
        XCTAssertEqual(classify(down(KeyCode.tab, [.option, .shift]), active), Classification(.swallow, .step(.backward)))
        XCTAssertEqual(classify(down(KeyCode.rightArrow, .option), active), Classification(.swallow, .step(.forward)))
        XCTAssertEqual(classify(down(KeyCode.leftArrow, .option), active), Classification(.swallow, .step(.backward)))
    }

    func testOtherKeysPassWhileActive() {
        XCTAssertEqual(classify(down(0x00 /* A */, .option), active), .pass)
        XCTAssertEqual(classify(.key(KeyEvent(.keyUp, keyCode: KeyCode.tab, modifiers: .option)), active), .pass)
    }

    func testReleasingTheHoldingModifierCommitsAndTheFlagsEventPasses() {
        let release = TapInput.key(KeyEvent(.flagsChanged, keyCode: 0x3A, modifiers: []))
        XCTAssertEqual(classify(release, active), Classification(.pass, .modifierReleased))
        // Pressing or releasing Shift while ⌥ stays down changes nothing.
        let shift = TapInput.key(KeyEvent(.flagsChanged, keyCode: 0x38, modifiers: [.option, .shift]))
        XCTAssertEqual(classify(shift, active), .pass)
    }

    func testAKeyWithoutTheHoldingModifierEndsAMissedRelease() {
        // The flags event for the release was never seen; the next keystroke shows ⌥ is up and goes to its app.
        XCTAssertEqual(classify(down(KeyCode.tab), active), Classification(.pass, .modifierReleased))
    }

    func testATimeoutDisableCancelsAnActiveSwitch() {
        XCTAssertEqual(classify(.tapDisabled, active), Classification(.pass, .interrupted))
        XCTAssertEqual(classify(.tapDisabled, idle), .pass)
    }
}

final class ShortcutRecognizerTests: XCTestCase {
    private func key(_ kind: KeyEvent.Kind, _ code: UInt16, _ modifiers: ModifierMask = []) -> TapInput {
        .key(KeyEvent(kind, keyCode: code, modifiers: modifiers))
    }

    private let optionDown = TapInput.key(KeyEvent(.flagsChanged, keyCode: 0x3A, modifiers: .option))
    private let optionUp = TapInput.key(KeyEvent(.flagsChanged, keyCode: 0x3A, modifiers: []))

    func testAFullSwitchSwallowsOnlyItsKeysAndCommits() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 4)
        XCTAssertEqual(recognizer.handle(optionDown).disposition, .pass)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.session.state, .active(selection: 2))
        let release = recognizer.handle(optionUp)
        XCTAssertEqual(release, .init(disposition: .pass, outcome: .commit(index: 2)))
        // Tab was let go after ⌥: its key-up still belongs to the switch.
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .swallow)
        // Afterwards Tab is an ordinary key again.
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab)).disposition, .pass)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .pass)
    }

    func testAKeyHeldFromBeforeTheSwitchIsReleasedToItsApp() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.rightArrow)).disposition, .pass)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        XCTAssertTrue(recognizer.session.isActive)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.rightArrow, .option)).disposition, .pass)
    }

    func testEscapeCancelsAndItsKeyUpIsSwallowed() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.escape, .option)), .init(disposition: .swallow, outcome: .cancel))
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.escape, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(optionUp), .init(disposition: .pass, outcome: nil))
    }

    func testTapDisabledCancelsAndForgetsPendingKeyUps() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        XCTAssertEqual(recognizer.handle(.tapDisabled), .init(disposition: .pass, outcome: .cancel))
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .pass)
    }

    func testResetCancelsAnActiveSwitch() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        XCTAssertEqual(recognizer.reset(), .cancel)
        XCTAssertFalse(recognizer.session.isActive)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .pass)
        XCTAssertNil(recognizer.reset())
    }

    func testAnEmptyListLetsTheShortcutThrough() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 0)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab, .option)).disposition, .pass)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab, .option)).disposition, .pass)
        XCTAssertNil(recognizer.listChanged(count: 2))
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.listChanged(count: 0), .cancel)
    }
}
