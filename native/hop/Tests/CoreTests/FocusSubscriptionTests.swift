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
