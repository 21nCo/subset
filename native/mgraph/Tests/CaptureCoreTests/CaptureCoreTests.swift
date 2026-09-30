@testable import CaptureCore
import ApplicationServices
import XCTest

private final class DeliveryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
}

final class CaptureCoreTests: XCTestCase {
    func testProtectedRolesAreExcluded() {
        XCTAssertTrue(CaptureCollector.shouldSkip(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(CaptureCollector.shouldSkip(role: "AXPasswordField", subrole: ""))
        XCTAssertFalse(CaptureCollector.shouldSkip(role: "AXTextArea", subrole: ""))
    }

    func testTextNormalizationHasStrictLimit() {
        XCTAssertEqual(CaptureCollector.normalize("  Hello\n\tworld  ", remaining: 8), "Hello wo")
        XCTAssertEqual(CaptureCollector.normalize("secret", remaining: 0), "")
    }

    func testSlowCaptureIsBoundedAndLateTextIsDiscarded() {
        let deadline = CaptureCollector.Deadline(seconds: 0.03)
        let start = Date()
        let result = CaptureCollector.runBounded(deadline: deadline, seconds: 0.03) {
            Thread.sleep(forTimeInterval: 0.5)
            return CaptureResult(state: .available, text: "late private text")
        }
        XCTAssertNil(result)
        XCTAssertTrue(deadline.expired)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
    }

    func testEmptyTreeIsUnsupported() {
        XCTAssertEqual(CaptureCollector.stateForText(""), .unsupportedApplication)
        XCTAssertEqual(CaptureCollector.stateForText("fixture body"), .available)
    }

    func testSameProcessWindowAndTabChangesDiscardCapturedText() {
        let original = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                       document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [90])
        let text = CaptureResult(state: .available, applicationName: "Browser", bundleIdentifier: "example.browser",
                                 processIdentifier: 42, windowTitle: "Same title", text: "prior tab private text")
        let changedWindow = CaptureCollector.SourceIdentity(pid: 42, window: 11, title: "Same title",
                                                            document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [90])
        let changedTab = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                         document: nil, focusedElement: 50, selectedTabs: [71], webAreas: [90])
        let changedPage = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                          document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [91])
        let addedDocument = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                            document: "file:///fixture", focusedElement: 50,
                                                            selectedTabs: [70], webAreas: [90])
        for current in [changedWindow, changedTab, changedPage, addedDocument] {
            let result = CaptureCollector.checkedSource(text, initial: original, current: current)
            XCTAssertEqual(result.state, .readFailed)
            XCTAssertNil(result.text)
            XCTAssertNil(result.windowTitle)
        }
        let missingFocus = CaptureCollector.checkedSource(text, initial: original, current: nil)
        XCTAssertEqual(missingFocus.state, .readFailed)
        XCTAssertNil(missingFocus.text)
        XCTAssertNil(missingFocus.windowTitle)
        let lostDocument = CaptureCollector.checkedSource(text, initial: addedDocument, current: original)
        XCTAssertEqual(lostDocument.state, .readFailed)
        XCTAssertNil(lostDocument.text)
        XCTAssertEqual(CaptureCollector.checkedSource(text, initial: original, current: original).text,
                       "prior tab private text")
    }

    func testUnavailableFocusedWindowNeverFallsBackToBackgroundWindowsOrApplicationRoot() {
        let background = AXUIElementCreateApplication(43)
        let otherBackground = AXUIElementCreateApplication(44)
        let windows: CFArray = [background, otherBackground] as CFArray
        var requestedWindows = false
        let unavailable = CaptureCollector.verifiedFocusedWindow { name in
            if name == (kAXWindowsAttribute as String) {
                requestedWindows = true
                return windows
            }
            return nil
        }
        XCTAssertNil(unavailable)
        XCTAssertFalse(requestedWindows)

        let invalid = CaptureCollector.verifiedFocusedWindow { name in
            name == (kAXFocusedWindowAttribute as String) ? "not an AX window" as CFString : nil
        }
        XCTAssertNil(invalid)
        let focused = CaptureCollector.verifiedFocusedWindow { name in
            name == (kAXFocusedWindowAttribute as String) ? background : nil
        }
        XCTAssertNotNil(focused)
        XCTAssertEqual(CFHash(focused!), CFHash(background))
    }

    func testMenuRunnerReturnsOnDeadlineWithoutPublishingLateText() {
        let done = expectation(description: "asynchronous capture finishes")
        let noSecondDelivery = expectation(description: "late worker does not deliver again")
        noSecondDelivery.isInverted = true
        let deliveries = DeliveryCount()
        let deadline = CaptureCollector.Deadline(seconds: 0.03)
        let start = Date()
        DispatchQueue.main.async {
            CaptureCollector.runAsync(deadline: deadline, seconds: 0.03, work: {
                Thread.sleep(forTimeInterval: 0.5)
                return CaptureResult(state: .available, text: "late private text")
            }) { result in
                XCTAssertNil(result)
                XCTAssertLessThan(Date().timeIntervalSince(start), 0.35)
                if deliveries.increment() == 1 { done.fulfill() } else { noSecondDelivery.fulfill() }
            }
        }
        wait(for: [done], timeout: 1)
        wait(for: [noSecondDelivery], timeout: 0.65)
    }
}
