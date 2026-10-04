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

@MainActor private func verifyWorkerDrain(workerFinished: DeliveryCount, drained: XCTestExpectation) {
    CaptureCollector.afterCaptureWorkerDrains {
        XCTAssertEqual(workerFinished.increment(), 2,
                       "Capture must stay disabled until the old AX work exits")
        drained.fulfill()
    }
}

final class CaptureCoreTests: XCTestCase {
    @MainActor func testCancelledMenuCaptureCannotPresentLateResultOrReplaceNewCapture() {
        let requests = CaptureRequestGate()
        let cancelled = requests.begin()
        requests.cancel() // Request Accessibility Access interrupts the worker.
        let replacement = requests.begin()
        XCTAssertFalse(requests.finish(cancelled))
        XCTAssertTrue(requests.finish(replacement))
        XCTAssertFalse(requests.finish(replacement))
    }

    func testProtectedRolesAreExcluded() {
        XCTAssertTrue(CaptureCollector.shouldSkip(role: "AXTextField", subrole: "AXSecureTextField"))
        XCTAssertTrue(CaptureCollector.shouldSkip(role: "AXPasswordField", subrole: ""))
        XCTAssertFalse(CaptureCollector.shouldSkip(role: "AXTextArea", subrole: ""))
        let root = AXUIElementCreateApplication(42)
        for failedKey in [kAXRoleAttribute as String, kAXSubroleAttribute as String] {
            var sensitiveReads: [String] = []
            let result = CaptureCollector.extractText(from: root, deadline: .init(seconds: 1),
                readMetadata: { _, key, _ in
                    if key == failedKey { return (.cannotComplete, nil) }
                    return key == (kAXRoleAttribute as String) ? (.success, "AXTextField") : (.success, "AXSecureTextField")
                }, readString: { _, key, _ in sensitiveReads.append(key); return "secret" },
                readValue: { _, _, _ in sensitiveReads.append(kAXValueAttribute as String); return "secret" },
                checkTrust: { true },
                readChildren: { _, _, _ in [] })
            XCTAssertEqual(result?.text, "")
            XCTAssertTrue(sensitiveReads.isEmpty, "Failed \(failedKey) requested protected text")
        }
        let ordinary = CaptureCollector.extractText(from: root, deadline: .init(seconds: 1),
            readMetadata: { _, key, _ in
                key == (kAXRoleAttribute as String) ? (.success, "AXTextArea") : (.attributeUnsupported, nil)
            }, readString: { _, key, _ in key == (kAXTitleAttribute as String) ? "ordinary" : nil },
            readValue: { _, _, _ in nil }, checkTrust: { true }, readChildren: { _, _, _ in [] })
        XCTAssertEqual(ordinary?.text, "ordinary")
    }

    func testMenuFixtureBindingMasksForegroundSwitchBeforeAlert() {
        let fixture = "MGraph Menu Fixture abcdef12.txt"
        let expected = CaptureResult(state: .available,
            source: .init(bundleIdentifier: "com.apple.TextEdit", windowTitle: fixture), text: "fixture body")
        XCTAssertEqual(CaptureCollector.bindFixture(expected, bundleIdentifier: "com.apple.TextEdit",
                                                  windowTitle: fixture).text, "fixture body")
        let switched = CaptureResult(state: .available,
            source: .init(bundleIdentifier: "com.apple.Safari", windowTitle: "Unrelated"), text: "private body")
        let rejected = CaptureCollector.bindFixture(switched, bundleIdentifier: "com.apple.TextEdit",
                                                    windowTitle: fixture)
        XCTAssertEqual(rejected.state, .readFailed)
        XCTAssertNil(rejected.text)
        XCTAssertNil(rejected.windowTitle)
        let sameAppWrongWindow = CaptureResult(state: .available,
            source: .init(bundleIdentifier: "com.apple.TextEdit", windowTitle: "Other document"), text: "private body")
        let sameAppRejected = CaptureCollector.bindFixture(sameAppWrongWindow,
            bundleIdentifier: "com.apple.TextEdit", windowTitle: fixture)
        XCTAssertEqual(sameAppRejected.state, .readFailed)
        XCTAssertNil(sameAppRejected.windowTitle)
        XCTAssertNil(sameAppRejected.text)
        let missingExtension = CaptureResult(state: .available,
            source: .init(bundleIdentifier: "com.apple.TextEdit", windowTitle: "MGraph Menu Fixture abcdef12"),
            text: "private body")
        let missingExtensionResult = CaptureCollector.bindFixture(missingExtension,
            bundleIdentifier: "com.apple.TextEdit", windowTitle: fixture)
        XCTAssertEqual(missingExtensionResult.state, .readFailed)
        XCTAssertNil(missingExtensionResult.text)
        for wrongTitle in ["Prefix " + fixture, fixture + " suffix"] {
            let wrong = CaptureResult(state: .available,
                source: .init(bundleIdentifier: "com.apple.TextEdit", windowTitle: wrongTitle),
                text: "private body")
            let masked = CaptureCollector.bindFixture(wrong, bundleIdentifier: "com.apple.TextEdit",
                                                      windowTitle: fixture)
            XCTAssertEqual(masked.state, .readFailed)
            XCTAssertNil(masked.windowTitle)
            XCTAssertNil(masked.text)
        }
    }

    func testTextNormalizationHasStrictLimit() {
        XCTAssertEqual(CaptureCollector.normalize("  Hello\n\tworld  ", remaining: 8), "Hello wo")
        XCTAssertEqual(CaptureCollector.normalize("secret", remaining: 0), "")
        XCTAssertEqual(CaptureCollector.normalize(String(repeating: "x", count: 1_000_000), remaining: 3), "xxx")
    }

    func testOversizedAXArraysAreRejectedBeforeRangeRead() {
        for limit in [30, 100] { // Identity and text traversals.
            var read = false
            let result: [Int]? = CaptureCollector.boundedElements(maxCount: limit, count: { limit + 1 },
                                                                   readRange: { _ in read = true; return [1] })
            XCTAssertNil(result)
            XCTAssertFalse(read)
        }
        let shortRead: [Int]? = CaptureCollector.boundedElements(maxCount: 100, count: { 2 },
                                                                 readRange: { _ in [1] })
        XCTAssertNil(shortRead)
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

    func testCliConsentAndForegroundOutcomesAreDistinct() {
        XCTAssertEqual(CaptureCollector.cliConsentFailure(approved: false, foregroundAvailable: false)?.state,
                       .readFailed)
        XCTAssertEqual(CaptureCollector.cliConsentFailure(approved: true, foregroundAvailable: false)?.state,
                       .noForegroundApplication)
        XCTAssertNil(CaptureCollector.cliConsentFailure(approved: true, foregroundAvailable: true))
    }

    func testSameProcessWindowAndTabChangesDiscardCapturedText() {
        let fixtureDocument = FileManager.default.temporaryDirectory
            .appendingPathComponent("mgraph-source-\(UUID().uuidString)").absoluteString
        let original = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                       document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [90])
        let text = CaptureResult(state: .available, source: .init(applicationName: "Browser",
                                 bundleIdentifier: "example.browser", processIdentifier: 42,
                                 windowTitle: "Same title"), text: "prior tab private text")
        let changedWindow = CaptureCollector.SourceIdentity(pid: 42, window: 11, title: "Same title",
                                                            document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [90])
        let changedTab = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                         document: nil, focusedElement: 50, selectedTabs: [71], webAreas: [90])
        let changedPage = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                          document: nil, focusedElement: 50, selectedTabs: [70], webAreas: [91])
        let addedDocument = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "Same title",
                                                            document: fixtureDocument, focusedElement: 50,
                                                            selectedTabs: [70], webAreas: [90])
        for current in [changedWindow, changedTab, changedPage, addedDocument] {
            let result = CaptureCollector.checkedCapture(text, initial: original, current: current,
                                                         confirmation: text.text, final: current, finalText: text.text)
            XCTAssertEqual(result.state, .readFailed)
            XCTAssertNil(result.text)
            XCTAssertNil(result.windowTitle)
        }
        let missingFocus = CaptureCollector.checkedCapture(text, initial: original, current: nil,
                                                           confirmation: text.text, final: nil, finalText: text.text)
        XCTAssertEqual(missingFocus.state, .readFailed)
        XCTAssertNil(missingFocus.text)
        XCTAssertNil(missingFocus.windowTitle)
        let lostDocument = CaptureCollector.checkedCapture(text, initial: addedDocument, current: original,
                                                           confirmation: text.text, final: original, finalText: text.text)
        XCTAssertEqual(lostDocument.state, .readFailed)
        XCTAssertNil(lostDocument.text)
        XCTAssertEqual(CaptureCollector.checkedCapture(text, initial: original, current: original,
                                                       confirmation: text.text, final: original, finalText: text.text).text,
                       "prior tab private text")
        let changedFinalText = CaptureCollector.checkedCapture(text, initial: original, current: original,
                                                               confirmation: text.text, final: original,
                                                               finalText: "later private text")
        XCTAssertEqual(changedFinalText.state, .readFailed)
        XCTAssertNil(changedFinalText.text)
    }

    func testUnavailableMetadataSameWindowNavigationRejectsPriorPageText() {
        let sameOpaqueSource = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: nil,
                                                               document: nil, focusedElement: nil,
                                                               selectedTabs: [], webAreas: [])
        let priorPage = CaptureResult(state: .available, source: .init(applicationName: "Browser",
                                      bundleIdentifier: "example.browser", processIdentifier: 42),
                                      text: "prior page private text")
        let changed = CaptureCollector.checkedCapture(priorPage, initial: sameOpaqueSource,
                                                      current: sameOpaqueSource,
                                                      confirmation: "new page text", final: sameOpaqueSource,
                                                      finalText: priorPage.text)
        XCTAssertEqual(changed.state, .readFailed)
        XCTAssertNil(changed.text)
        XCTAssertNil(changed.windowTitle)

        let unreadable = CaptureCollector.checkedCapture(priorPage, initial: sameOpaqueSource,
                                                         current: sameOpaqueSource,
                                                         confirmation: nil, final: sameOpaqueSource,
                                                         finalText: priorPage.text)
        XCTAssertEqual(unreadable.state, .readFailed)
        XCTAssertNil(unreadable.text)
        XCTAssertEqual(CaptureCollector.checkedCapture(priorPage, initial: sameOpaqueSource,
                                                       current: sameOpaqueSource,
                                                       confirmation: priorPage.text, final: sameOpaqueSource,
                                                       finalText: priorPage.text).state,
                       .available)
    }

    func testSameProcessSwitchDuringLastTextReadRejectsPriorWindow() {
        let original = CaptureCollector.SourceIdentity(pid: 42, window: 10, title: "First",
                                                       document: nil, focusedElement: 50,
                                                       selectedTabs: [], webAreas: [])
        let switched = CaptureCollector.SourceIdentity(pid: 42, window: 11, title: "Second",
                                                       document: nil, focusedElement: 51,
                                                       selectedTabs: [], webAreas: [])
        let priorText = CaptureResult(state: .available,
                                      source: .init(processIdentifier: 42, windowTitle: "First"),
                                      text: "first window text")
        var focused = original
        let final = CaptureCollector.confirmAfterFinalText(readText: {
            focused = switched
            return priorText.text
        }, readSource: { focused })
        let result = CaptureCollector.checkedCapture(priorText, initial: original, current: original,
                                                     confirmation: priorText.text, final: final.source,
                                                     finalText: final.text)
        XCTAssertEqual(result.state, .readFailed)
        XCTAssertNil(result.text)
        XCTAssertNil(result.windowTitle)
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

    @MainActor func testMenuCannotStartReplacementUntilCancelledWorkerDrains() {
        let workerFinished = DeliveryCount()
        let drained = expectation(description: "serial AX worker drained")
        let deadline = CaptureCollector.Deadline(seconds: 0.03)
        CaptureCollector.runAsync(deadline: deadline, seconds: 0.03, work: {
            DispatchQueue.main.async {
                deadline.cancel()
                verifyWorkerDrain(workerFinished: workerFinished, drained: drained)
            }
            Thread.sleep(forTimeInterval: 0.2)
            _ = workerFinished.increment()
            return CaptureResult(state: .readFailed)
        }) { _ in
            // Delivery is intentionally ignored; only the worker drain orders the next request.
        }
        wait(for: [drained], timeout: 1)
    }

    func testManualCaptureGetsFullDeadlineAfterSlowAutomaticWorkerDrains() {
        let manualFinished = expectation(description: "manual capture inspects the new foreground source")
        let started = Date()
        DispatchQueue.main.async {
            CaptureCollector.runAsync(deadline: .init(seconds: 0.03), seconds: 0.03, work: {
                Thread.sleep(forTimeInterval: 0.18) // automatic AX work from the previous app
                return CaptureResult(state: .available, text: "old app")
            }) { _ in
                // The prior automatic result is irrelevant; only worker occupancy matters.
            }
            let manualDeadline = CaptureCollector.Deadline(seconds: 0.05, startWhenWorkerBegins: true)
            CaptureCollector.runAsync(deadline: manualDeadline, seconds: 0.05, work: {
                CaptureResult(state: .available, text: "new foreground app")
            }) { result in
                XCTAssertGreaterThan(Date().timeIntervalSince(started), 0.12)
                XCTAssertEqual(result?.text, "new foreground app")
                manualFinished.fulfill()
            }
        }
        wait(for: [manualFinished], timeout: 1)
    }

    @MainActor func testAutomaticAXStartsStayThreeSecondsApartAfterManualContentionAndSwitch() {
        let secondStarted = expectation(description: "second automatic AX worker starts after interval")
        let gate = RecordingGate()
        let queuedAt = ProcessInfo.processInfo.systemUptime
        // A cancelled manual request still occupies the serial AX worker until it returns.
        CaptureCollector.runAsync(deadline: .init(seconds: 0.05, startWhenWorkerBegins: true),
                                  seconds: 0.05, work: {
            Thread.sleep(forTimeInterval: 3.15)
            return CaptureResult(state: .readFailed)
        }) { _ in
            // The timed-out manual result is irrelevant; worker occupancy is measured below.
        }
        guard let firstToken = gate.begin(at: queuedAt) else {
            XCTFail("Fresh recording must admit its first request")
            return
        }
        var firstStart: TimeInterval?
        CaptureCollector.runAsync(deadline: .init(seconds: 0.2, startWhenWorkerBegins: true),
                                  seconds: 0.2, onWorkerStart: { startedAt in
            firstStart = startedAt
            gate.recordCaptureStart(at: startedAt)
        }, work: {
            CaptureResult(state: .available, text: "first allowed app")
        }) { _ in
            XCTAssertTrue(gate.finish(firstToken))
            guard let firstStart else {
                XCTFail("The first AX read must report its actual worker start")
                secondStarted.fulfill()
                return
            }
            XCTAssertGreaterThan(firstStart - queuedAt, 3,
                                 "The manual worker must expose the queue-delay regression")
            gate.invalidate() // App switch, pause/resume, sleep/wake, or exclusion.
            for _ in 0..<10 {
                XCTAssertNil(gate.begin(at: ProcessInfo.processInfo.systemUptime),
                             "Notification storms must not bypass the worker-start limit")
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.05) {
                self.startSecondAutomaticCapture(gate: gate, firstStart: firstStart, done: secondStarted)
            }
        }
        wait(for: [secondStarted], timeout: 8)
    }

    @MainActor private func startSecondAutomaticCapture(gate: RecordingGate, firstStart: TimeInterval,
                                                         done: XCTestExpectation) {
        guard let nextToken = gate.begin(at: ProcessInfo.processInfo.systemUptime) else {
            XCTFail("The next allowed app should become eligible after three seconds")
            done.fulfill()
            return
        }
        CaptureCollector.runAsync(deadline: .init(seconds: 0.2, startWhenWorkerBegins: true),
                                  seconds: 0.2, onWorkerStart: { startedAt in
            gate.recordCaptureStart(at: startedAt)
            XCTAssertGreaterThanOrEqual(startedAt - firstStart, 3,
                                        "Actual automatic AX starts must be bounded")
        }, work: {
            CaptureResult(state: .available, text: "second allowed app")
        }) { _ in
            XCTAssertTrue(gate.finish(nextToken))
            done.fulfill()
        }
    }

    func testPausedQueuedCaptureSkipsAXAndLaterManualCaptureRuns() {
        let pausedFinished = expectation(description: "paused request completes without AX")
        let manualFinished = expectation(description: "manual request runs after worker drain")
        let pausedReads = DeliveryCount()
        DispatchQueue.main.async {
            CaptureCollector.runAsync(deadline: .init(seconds: 0.03), seconds: 0.03, work: {
                Thread.sleep(forTimeInterval: 0.15)
                return CaptureResult(state: .available, text: "old app")
            }) { _ in
                // The earlier automatic result is irrelevant; cancellation and ordering matter.
            }
            let pausedDeadline = CaptureCollector.Deadline(seconds: 0.05, startWhenWorkerBegins: true)
            CaptureCollector.runAsync(deadline: pausedDeadline, seconds: 0.05, work: {
                _ = pausedReads.increment()
                return CaptureResult(state: .available, text: "paused content")
            }) { result in
                XCTAssertNil(result)
                pausedFinished.fulfill()
            }
            pausedDeadline.cancel() // pause or foreground switch before AX admission
            let manualDeadline = CaptureCollector.Deadline(seconds: 0.05, startWhenWorkerBegins: true)
            CaptureCollector.runAsync(deadline: manualDeadline, seconds: 0.05, work: {
                CaptureResult(state: .available, text: "fresh manual content")
            }) { result in
                XCTAssertEqual(result?.text, "fresh manual content")
                XCTAssertEqual(pausedReads.increment(), 1, "cancelled request must not enter AX")
                manualFinished.fulfill()
            }
        }
        wait(for: [pausedFinished, manualFinished], timeout: 1)
    }
}
