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

    func testExtraModifiersDoNotStepOrCancelWhileActive() {
        // Only the holding modifier, optionally with ⇧, steps or cancels; these chords belong to other shortcuts.
        for modifiers: ModifierMask in [[.option, .command], [.option, .control], [.option, .shift, .command]] {
            XCTAssertEqual(classify(down(KeyCode.tab, modifiers), active), .pass, "Tab with \(modifiers)")
        }
        XCTAssertEqual(classify(down(KeyCode.rightArrow, [.option, .command]), active), .pass)
        XCTAssertEqual(classify(down(KeyCode.leftArrow, [.option, .control]), active), .pass)
        XCTAssertEqual(classify(down(KeyCode.escape, [.option, .command]), active), .pass)
        // ⇧ with an arrow or Esc keeps their meaning.
        XCTAssertEqual(classify(down(KeyCode.rightArrow, [.option, .shift]), active), Classification(.swallow, .step(.forward)))
        XCTAssertEqual(classify(down(KeyCode.escape, [.option, .shift]), active), Classification(.swallow, .escape))
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

    private func repeating(_ code: UInt16, _ modifiers: ModifierMask = []) -> TapInput {
        .key(KeyEvent(.keyDown, keyCode: code, modifiers: modifiers, isRepeat: true))
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

    func testAnArrowHeldFromBeforeTheSwitchKeepsRepeatingInItsApp() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.rightArrow)).disposition, .pass)
        _ = recognizer.handle(optionDown)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        // The → repeats now carry ⌥, but the app saw → go down, so they are its and step nothing.
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.rightArrow, .option)), .init(disposition: .pass, outcome: nil))
        XCTAssertEqual(recognizer.session.state, .active(selection: 1))
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.rightArrow, .option)).disposition, .pass)
        XCTAssertEqual(recognizer.handle(optionUp), .init(disposition: .pass, outcome: .commit(index: 1)))
    }

    func testEscapeHeldFromBeforeTheSwitchDoesNotCancelIt() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.escape)).disposition, .pass)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.escape, .option)), .init(disposition: .pass, outcome: nil))
        XCTAssertTrue(recognizer.session.isActive)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.escape, .option)).disposition, .pass)
    }

    func testTabHeldPastTheReleaseStaysSwallowedUntilItsKeyUp() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        // Holding Tab keeps stepping, as each repeat belongs to the switch.
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.tab, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.session.state, .active(selection: 2))
        XCTAssertEqual(recognizer.handle(optionUp).outcome, .commit(index: 2))
        // The press began as the shortcut, so its later repeats and key-up never reach the app.
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.tab)), .init(disposition: .swallow, outcome: nil))
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.tab)).disposition, .pass)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.tab)).disposition, .pass)
    }

    func testARepeatNeverStartsASwitch() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        _ = recognizer.handle(optionUp)
        // ⌥ goes down again while the swallowed Tab still repeats: a new switch needs a new press.
        _ = recognizer.handle(optionDown)
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.tab, .option)), .init(disposition: .swallow, outcome: nil))
        XCTAssertFalse(recognizer.session.isActive)
        // A repeat of a key pressed before the tap existed passes.
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.leftArrow)).disposition, .pass)
    }

    func testAnArrowHeldPastTheReleaseStaysSwallowed() {
        var recognizer = ShortcutRecognizer(shortcut: .default, windowCount: 3)
        _ = recognizer.handle(key(.keyDown, KeyCode.tab, .option))
        _ = recognizer.handle(key(.keyUp, KeyCode.tab, .option))
        XCTAssertEqual(recognizer.handle(key(.keyDown, KeyCode.rightArrow, .option)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(optionUp).outcome, .commit(index: 2))
        XCTAssertEqual(recognizer.handle(repeating(KeyCode.rightArrow)).disposition, .swallow)
        XCTAssertEqual(recognizer.handle(key(.keyUp, KeyCode.rightArrow)).disposition, .swallow)
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
