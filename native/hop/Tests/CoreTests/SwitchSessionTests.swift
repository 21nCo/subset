import HopCore
import XCTest

final class SwitchSessionTests: XCTestCase {
    private func session(count: Int, trigger direction: SwitchDirection = .forward) -> SwitchSession {
        var session = SwitchSession(count: count)
        XCTAssertNil(session.handle(.trigger(direction)))
        return session
    }

    func testForwardTriggerStartsOnThePreviousWindow() {
        XCTAssertEqual(session(count: 5).state, .active(selection: 1))
        XCTAssertEqual(session(count: 2).state, .active(selection: 1))
    }

    func testTriggerWithOneWindowSelectsIt() {
        XCTAssertEqual(session(count: 1).state, .active(selection: 0))
        XCTAssertEqual(session(count: 1, trigger: .backward).state, .active(selection: 0))
    }

    func testBackwardTriggerAlsoStartsOnThePreviousWindow() {
        XCTAssertEqual(session(count: 5, trigger: .backward).state, .active(selection: 1))
        XCTAssertEqual(session(count: 2, trigger: .backward).state, .active(selection: 1))
    }

    func testTriggerWithNoWindowsStaysIdle() {
        var empty = SwitchSession(count: 0)
        XCTAssertNil(empty.handle(.trigger(.forward)))
        XCTAssertNil(empty.handle(.trigger(.backward)))
        XCTAssertEqual(empty.state, .idle)
        // Nothing that follows can commit a selection that never existed.
        XCTAssertNil(empty.handle(.step(.forward)))
        XCTAssertNil(empty.handle(.modifierReleased))
        XCTAssertEqual(empty.state, .idle)
    }

    func testStepsWrapAroundForward() {
        var session = session(count: 3)
        session.handle(.step(.forward))
        XCTAssertEqual(session.state, .active(selection: 2))
        session.handle(.step(.forward))
        XCTAssertEqual(session.state, .active(selection: 0))
        session.handle(.trigger(.forward))
        XCTAssertEqual(session.state, .active(selection: 1), "a repeated trigger while active steps like Tab")
    }

    func testStepsWrapAroundBackward() {
        var session = session(count: 3)
        session.handle(.step(.backward))
        XCTAssertEqual(session.state, .active(selection: 0))
        session.handle(.step(.backward))
        XCTAssertEqual(session.state, .active(selection: 2))
    }

    func testReleasingTheModifierCommitsTheSelection() {
        var session = session(count: 4)
        session.handle(.step(.forward))
        XCTAssertEqual(session.handle(.modifierReleased), .commit(index: 2))
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.handle(.modifierReleased), "a second release has no session to end")
    }

    func testEscapeCancels() {
        var session = session(count: 4)
        XCTAssertEqual(session.handle(.escape), .cancel)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.handle(.modifierReleased), "the release after Esc commits nothing")
    }

    func testInterruptionCancels() {
        var session = session(count: 4)
        XCTAssertEqual(session.handle(.interrupted), .cancel)
        XCTAssertEqual(session.state, .idle)
    }

    func testListShrinkingBelowTheSelectionClampsIt() {
        var session = session(count: 5, trigger: .backward)
        session.handle(.step(.backward))
        session.handle(.step(.backward))
        XCTAssertEqual(session.state, .active(selection: 4))
        XCTAssertNil(session.handle(.listChanged(count: 3)))
        XCTAssertEqual(session.state, .active(selection: 2))
        session.handle(.step(.forward))
        XCTAssertEqual(session.state, .active(selection: 0), "steps wrap at the new count")
        XCTAssertEqual(session.handle(.modifierReleased), .commit(index: 0))
    }

    func testListGrowingKeepsTheSelection() {
        var session = session(count: 2)
        session.handle(.listChanged(count: 6))
        XCTAssertEqual(session.state, .active(selection: 1))
    }

    func testListEmptyingCancelsAnActiveSession() {
        var session = session(count: 2)
        XCTAssertEqual(session.handle(.listChanged(count: 0)), .cancel)
        XCTAssertEqual(session.state, .idle)
    }

    func testListChangesWhileIdleSetTheCountForTheNextTrigger() {
        var session = SwitchSession(count: 0)
        session.handle(.listChanged(count: 3))
        session.handle(.trigger(.backward))
        XCTAssertEqual(session.state, .active(selection: 1))
        var negative = SwitchSession(count: 3)
        negative.handle(.listChanged(count: -1))
        XCTAssertEqual(negative.count, 0)
        XCTAssertFalse(negative.canStart)
    }
}
