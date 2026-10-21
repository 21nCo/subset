import HopCore
import XCTest

final class SwitchSessionTests: XCTestCase {
    private func active(_ direction: SwitchDirection = .forward) -> SwitchSession {
        var session = SwitchSession()
        XCTAssertEqual(session.handle(.trigger(direction)).accepted, true)
        return session
    }

    func testEitherTriggerStartsASession() {
        XCTAssertTrue(active(.forward).isActive)
        XCTAssertTrue(active(.backward).isActive)
    }

    func testIdleIgnoresEverythingButTheTrigger() {
        var session = SwitchSession()
        for event: SwitchSession.Event in [
            .step(.forward), .row(.down), .operation(.close), .modifierReleased, .escape, .interrupted,
        ] {
            XCTAssertEqual(session.handle(event).accepted, false, "\(event)")
            XCTAssertNil(session.handle(event).outcome)
        }
        XCTAssertEqual(session.state, .idle)
    }

    func testMovesAndOperationsKeepTheSessionActive() {
        var session = active()
        for event: SwitchSession.Event in [.step(.backward), .row(.up), .operation(.minimize), .trigger(.forward)] {
            XCTAssertEqual(session.handle(event).accepted, true, "\(event)")
            XCTAssertTrue(session.isActive)
        }
    }

    func testReleasingTheModifierCommits() {
        var session = active()
        XCTAssertEqual(session.handle(.modifierReleased).outcome, .commit)
        XCTAssertEqual(session.state, .idle)
        XCTAssertNil(session.handle(.modifierReleased).outcome, "a second release has no session to end")
    }

    func testEscapeAndInterruptionCancel() {
        var escaped = active()
        XCTAssertEqual(escaped.handle(.escape).outcome, .cancel)
        XCTAssertNil(escaped.handle(.modifierReleased).outcome, "the release after Esc commits nothing")
        var interrupted = active()
        XCTAssertEqual(interrupted.handle(.interrupted).outcome, .cancel)
        XCTAssertEqual(interrupted.state, .idle)
    }

    func testEndingTheSessionMakesTheReleaseCommitNothing() {
        // A click chose a window while the modifier was still held.
        var session = active()
        XCTAssertTrue(session.end())
        XCTAssertNil(session.handle(.modifierReleased).outcome)
        XCTAssertFalse(session.end())
    }
}
