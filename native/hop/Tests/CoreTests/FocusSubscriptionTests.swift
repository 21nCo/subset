import CoreGraphics
import Foundation
import HopCore
import XCTest

final class FocusSubscriptionTests: XCTestCase {
    private let focused = "AXFocusedWindowChanged"
    private let main = "AXMainWindowChanged"

    func testANotificationTheAppDidNotAnswerIsRetriedAndTheAcceptedOneIsKept() {
        var subscription = FocusSubscription([focused, main])
        var asked: [String] = []
        subscription.register { notification in
            asked.append(notification)
            return notification == focused ? .registered : .unanswered
        }
        XCTAssertEqual(subscription.registered, [focused])
        XCTAssertEqual(subscription.pending, [main])
        XCTAssertFalse(subscription.isComplete)

        asked = []
        subscription.register { asked.append($0); return .registered }
        XCTAssertEqual(asked, [main], "only the missing subscription is asked for again")
        XCTAssertEqual(subscription.registered, [focused, main])
        XCTAssertTrue(subscription.isComplete)

        asked = []
        subscription.register { asked.append($0); return .registered }
        XCTAssertEqual(asked, [], "a complete subscription makes no requests")
    }

    func testAnAppThatDoesNotAnswerIsAskedOncePerAttempt() {
        var subscription = FocusSubscription([focused, main])
        var asked: [String] = []
        subscription.register { asked.append($0); return .unanswered }
        XCTAssertEqual(asked, [focused], "the second notification is not tried after the first went unanswered")
        XCTAssertEqual(subscription.registered, [])
        XCTAssertEqual(subscription.pending, [focused, main])
    }

    func testAnUnsupportedNotificationIsNotRetried() {
        var subscription = FocusSubscription([focused, main])
        subscription.register { $0 == focused ? .unsupported : .registered }
        XCTAssertEqual(subscription.registered, [main])
        XCTAssertTrue(subscription.isComplete)
    }
}

final class FocusObserversTests: XCTestCase {
    private final class Observer: @unchecked Sendable {}

    private let focused = "AXFocusedWindowChanged"
    private let main = "AXMainWindowChanged"
    private let pid: pid_t = 10

    func testOneRoundAtATimeAndOnlyTheFirstKeptRegistrationSchedulesTheSource() throws {
        var observers = FocusObservers<Observer>([focused, main])
        var round = try XCTUnwrap(observers.begin(pid: pid) { Observer() })
        XCTAssertNil(observers.begin(pid: pid) { Observer() }, "no second round while one is under way")
        round.subscription.register { $0 == self.focused ? .registered : .unanswered }
        guard case .kept(firstScheduled: true) = observers.finish(round) else { return XCTFail("first registration") }

        var retry = try XCTUnwrap(observers.begin(pid: pid) { XCTFail("the observer is reused"); return nil })
        XCTAssertTrue(retry.observer === round.observer)
        XCTAssertEqual(retry.subscription.pending, [main])
        retry.subscription.register { _ in .registered }
        guard case .kept(firstScheduled: false) = observers.finish(retry) else { return XCTFail("already scheduled") }
        XCTAssertNil(observers.begin(pid: pid) { Observer() }, "every notification was answered")
    }

    func testARoundThatFinishesAfterTrackingStoppedIsDiscarded() throws {
        var observers = FocusObservers<Observer>([focused, main])
        var late = try XCTUnwrap(observers.begin(pid: pid) { Observer() })
        XCTAssertEqual(observers.removeAll().map(\.pid), [pid])
        let restarted = try XCTUnwrap(observers.begin(pid: pid) { Observer() })
        XCTAssertFalse(restarted.observer === late.observer, "a restart creates a new observer")

        late.subscription.register { _ in .registered }
        guard case let .discarded(removed) = observers.finish(late) else { return XCTFail("stopped tracking revived") }
        XCTAssertTrue(removed.observer === late.observer)
        XCTAssertEqual(removed.notifications, [focused, main], "what the late round added is removed again")
        XCTAssertFalse(removed.isScheduled)
    }

    func testARoundThatFinishesAfterTheAppQuitIsDiscarded() throws {
        var observers = FocusObservers<Observer>([focused, main])
        var first = try XCTUnwrap(observers.begin(pid: pid) { Observer() })
        first.subscription.register { $0 == self.focused ? .registered : .unanswered }
        _ = observers.finish(first)
        var retry = try XCTUnwrap(observers.begin(pid: pid) { Observer() })

        let removed = try XCTUnwrap(observers.remove(pid: pid))
        XCTAssertEqual(removed.notifications, [focused])
        XCTAssertTrue(removed.isScheduled, "the scheduled source is taken off the run loop when the app quits")
        retry.subscription.register { _ in .registered }
        guard case let .discarded(late) = observers.finish(retry) else { return XCTFail("a quit app was revived") }
        XCTAssertEqual(late.notifications, [focused, main])
        XCTAssertFalse(late.isScheduled)
    }

    /// The owning thread hands every subscription to a worker, as `FocusTracker` does, so apps that never answer do
    /// not delay what it delivers meanwhile, and their late rounds after a stop are all discarded.
    func testUnansweredSubscriptionsDoNotHoldTheOwningThread() {
        let owner = DispatchQueue(label: "owner")
        let workers = DispatchQueue(label: "workers", attributes: .concurrent)
        let state = Box(FocusObservers<Observer>([focused, main]))
        let finished = DispatchGroup()
        let start = ContinuousClock.now
        owner.async {
            for pid in pid_t(100)..<120 {
                guard let round = state.value.begin(pid: pid, make: { Observer() }) else { continue }
                finished.enter()
                let pending = Box(round)
                workers.async {
                    // An app that does not answer holds each request for the messaging timeout.
                    pending.value.subscription.register { _ in Thread.sleep(forTimeInterval: 0.5); return .unanswered }
                    owner.async {
                        if case .kept = state.value.finish(pending.value) { XCTFail("a round finished after the stop") }
                        finished.leave()
                    }
                }
            }
        }
        let delivered = DispatchSemaphore(value: 0)
        owner.async { delivered.signal() }
        XCTAssertEqual(delivered.wait(timeout: .now() + 0.25), .success, "a callback waits behind the subscriptions")
        let stopped = DispatchSemaphore(value: 0)
        owner.async { _ = state.value.removeAll(); stopped.signal() }
        XCTAssertEqual(stopped.wait(timeout: .now() + 0.25), .success, "stopping waits behind the subscriptions")
        XCTAssertEqual(finished.wait(timeout: .now() + 5), .success)
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(3), "twenty unanswered apps are asked at once")
    }

    /// The launch scenario `FocusTracker` covers: the order is seeded with W1 in front, the user moved to W2 of the
    /// same, frontmost app before its observer was scheduled, so no notification reports it. The tracker reads the
    /// app's focused window when the observer is first scheduled, after the seed, and W2 comes first.
    func testAFocusChangeBeforeTheObserverWasScheduledIsReadWhenItIs() throws {
        let app = WindowFixture.app(pid, "Editor")
        let w1 = WindowFixture.window(1, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
        let w2 = WindowFixture.window(2, frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        var (lister, _) = WindowFixture.lister([.init(app, windows: [w1, w2])])
        var observers = FocusObservers<Observer>([focused, main])
        var round = try XCTUnwrap(observers.begin(pid: pid) { Observer() })
        let onScreen = [w1, w2].map { OnScreenWindow(pid: pid, frame: $0.frame!) }
        XCTAssertEqual(lister.seed(frontToBack: onScreen).windows.map(\.ref), [w1.ref, w2.ref])

        let focusedNow = w2.ref
        round.subscription.register { _ in .registered }
        guard case .kept(firstScheduled: true) = observers.finish(round) else { return XCTFail("first registration") }
        lister.noteFocused(focusedNow, pid: pid)
        XCTAssertEqual(lister.refresh().windows.map(\.ref), [w2.ref, w1.ref])
    }
}

private final class Box<Value>: @unchecked Sendable {
    var value: Value

    init(_ value: Value) {
        self.value = value
    }
}
