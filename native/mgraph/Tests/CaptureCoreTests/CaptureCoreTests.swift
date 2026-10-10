@testable import CaptureCore
import ApplicationServices
import XCTest

private final class DeliveryCount: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    /// Counts worker reads or deliveries safely across test queues.
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        value += 1
        return value
    }
    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ForegroundFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var current: CaptureCollector.Foreground
    private var permission = true

    init(_ initial: CaptureCollector.Foreground) { current = initial }

    /// Returns a synchronized foreground identity for admission fixtures.
    func snapshot() -> CaptureCollector.Foreground {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    /// Returns the fixture permission state without relying on system TCC.
    func isTrusted() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return permission
    }

    /// Changes foreground identity and permission as one synchronized event.
    func update(_ foreground: CaptureCollector.Foreground, trusted: Bool = true) {
        lock.lock()
        current = foreground
        permission = trusted
        lock.unlock()
    }
}

private final class DeferredAdmission: @unchecked Sendable {
    private let lock = NSLock()
    private let stored = DispatchSemaphore(value: 0)
    private var callback: (@MainActor @Sendable () -> Void)?

    /// Holds a main-actor admission callback to simulate a deferred modal loop.
    func schedule(_ callback: @escaping @MainActor @Sendable () -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
        stored.signal()
    }

    /// Waits until the automatic request has requested actor admission.
    func waitUntilScheduled() -> Bool { stored.wait(timeout: .now() + 1) == .success }

    /// Releases one deferred admission callback on the main actor.
    @MainActor func resume() {
        lock.lock()
        let pending = callback
        callback = nil
        lock.unlock()
        pending?()
    }
}

/// Asserts that replacement work starts only after the cancelled AX worker exits.
@MainActor private func verifyWorkerDrain(workerFinished: DeliveryCount, drained: XCTestExpectation) {
    CaptureCollector.afterCaptureWorkerDrains {
        XCTAssertEqual(workerFinished.increment(), 2,
                       "Capture must stay disabled until the old AX work exits")
        drained.fulfill()
    }
}

final class CaptureCoreTests: XCTestCase {
    /// Checks request tokens fence late menu results without rejecting the replacement.
    @MainActor func testCancelledMenuCaptureCannotPresentLateResultOrReplaceNewCapture() {
        let requests = CaptureRequestGate()
        let cancelled = requests.begin()
        requests.cancel() // Request Accessibility Access interrupts the worker.
        let replacement = requests.begin()
        XCTAssertFalse(requests.finish(cancelled))
        XCTAssertTrue(requests.finish(replacement))
        XCTAssertFalse(requests.finish(replacement))
    }

    /// Proves secure AX roles are skipped before their values can be read.
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

    /// Checks fixture text cannot appear after the expected window changes.
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

    /// Checks normalized output stays within the character budget.
    func testTextNormalizationHasStrictLimit() {
        XCTAssertEqual(CaptureCollector.normalize("  Hello\n\tworld  ", remaining: 8), "Hello wo")
        XCTAssertEqual(CaptureCollector.normalize("secret", remaining: 0), "")
        XCTAssertEqual(CaptureCollector.normalize(String(repeating: "x", count: 1_000_000), remaining: 3), "xxx")
    }

    /// Rejects oversized AX child arrays before their elements are traversed.
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

    /// Checks a slow one-shot read cannot publish text after its deadline.
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

    /// Checks empty AX content reports an unsupported source.
    func testEmptyTreeIsUnsupported() {
        XCTAssertEqual(CaptureCollector.stateForText(""), .unsupportedApplication)
        XCTAssertEqual(CaptureCollector.stateForText("fixture body"), .available)
    }

    /// Separates missing user consent from missing foreground availability.
    func testCliConsentAndForegroundOutcomesAreDistinct() {
        XCTAssertEqual(CaptureCollector.cliConsentFailure(approved: false, foregroundAvailable: false)?.state,
                       .readFailed)
        XCTAssertEqual(CaptureCollector.cliConsentFailure(approved: true, foregroundAvailable: false)?.state,
                       .noForegroundApplication)
        XCTAssertNil(CaptureCollector.cliConsentFailure(approved: true, foregroundAvailable: true))
    }

    /// Fences text when the AX source changes inside the same process.
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

    /// Rejects old page text when navigation changes source identity.
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

    /// Rechecks the source after the last text read before publishing it.
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

    /// Avoids reading background content when no focused window exists.
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

    /// Checks the menu callback arrives by its deadline and only once.
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

    /// Discards a finished worker result if a modal main loop defers delivery past its budget.
    @MainActor func testManualResultExpiresWhileMainActorDefersDelivery() {
        let completed = expectation(description: "expired manual result is delivered without text")
        let workerStarted = DispatchSemaphore(value: 0)
        let deadline = CaptureCollector.Deadline(seconds: 0.05, startWhenWorkerBegins: true)
        CaptureCollector.runAsync(deadline: deadline, seconds: 0.05, work: {
            workerStarted.signal()
            return CaptureResult(state: .available, text: "private text")
        }) { result in
            XCTAssertNil(result)
            completed.fulfill()
        }
        XCTAssertEqual(workerStarted.wait(timeout: .now() + 1), .success)
        Thread.sleep(forTimeInterval: 0.12)
        XCTAssertTrue(deadline.expired)
        wait(for: [completed], timeout: 1)
    }

    /// Checks worker drain orders replacement after cancellation.
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

    /// Starts the manual budget when its queued AX worker actually begins.
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

    /// Checks manual contention and invalidation cannot bypass capture throttling.
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

    /// Measures the next automatic AX start against the previous worker start.
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

    /// Ensures a paused queued request skips AX while subsequent manual work runs.
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

    /// Rejects an excluded foreground switch before any reader invocation.
    @MainActor func testAutomaticCaptureRejectsExcludedTargetBeforeAnyAXRead() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let excluded = CaptureCollector.Foreground(pid: 202, name: "Excluded",
            bundleID: "com.example.excluded", bundlePath: "/Applications/Excluded.app")
        let fixture = ForegroundFixture(allowed)
        let blockerStarted = DispatchSemaphore(value: 0)
        let releaseBlocker = DispatchSemaphore(value: 0)
        let axReads = DeliveryCount()
        let completed = expectation(description: "switched automatic capture was rejected")
        CaptureCollector.runAsync(deadline: .init(seconds: 0.05, startWhenWorkerBegins: true),
                                  seconds: 0.05, work: {
            blockerStarted.signal()
            _ = releaseBlocker.wait(timeout: .now() + 1)
            return CaptureResult(state: .readFailed)
        }) { _ in
            // The blocker only delays admission to the shared AX worker.
        }
        XCTAssertEqual(blockerStarted.wait(timeout: .now() + 1), .success)
        let target = CaptureCollector.CaptureTarget(pid: allowed.pid,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: {
                XCTAssertTrue(Thread.isMainThread, "AppKit foreground reads must remain on the menu actor")
                return fixture.snapshot()
            },
            read: { _, _ in
                _ = axReads.increment()
                return CaptureResult(state: .available, text: "unexpected text")
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) })) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(axReads.count, 0, "Excluded app must receive zero AX calls")
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        fixture.update(excluded)
        releaseBlocker.signal()
        wait(for: [completed], timeout: 2)
    }

    /// Rejects same-ID path substitution and permission loss.
    @MainActor func testAutomaticCaptureRejectsPathSubstitutionAndRevokedPermission() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let fixture = ForegroundFixture(allowed)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let axReads = DeliveryCount()
        let otherPath = expectation(description: "same bundle ID at another path is rejected")
        fixture.update(.init(pid: 101, name: "Substitute", bundleID: "com.example.allowed",
                             bundlePath: "/Other/Allowed.app"))
        let denied = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: { fixture.snapshot() },
            read: { _, _ in
                _ = axReads.increment()
                return CaptureResult(state: .available)
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) })) { result in
                XCTAssertEqual(result.state, .readFailed)
                otherPath.fulfill()
            }
        XCTAssertNil(denied)
        wait(for: [otherPath], timeout: 1)
        XCTAssertEqual(axReads.count, 0)

        fixture.update(allowed, trusted: false)
        let revoked = expectation(description: "revoked permission denies automatic capture")
        let permissionDenied = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: { fixture.snapshot() },
            read: { _, _ in
                _ = axReads.increment()
                return CaptureResult(state: .available)
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) })) { result in
                XCTAssertNotEqual(result.state, .available)
                revoked.fulfill()
            }
        XCTAssertNil(permissionDenied)
        wait(for: [revoked], timeout: 1)
        XCTAssertEqual(axReads.count, 0)
    }

    /// Allows exactly one read for an unchanged authorized app.
    @MainActor func testAutomaticCaptureReadsUnchangedAllowedTarget() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let fixture = ForegroundFixture(allowed)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let reads = DeliveryCount()
        let completed = expectation(description: "allowed target is read once")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: { fixture.snapshot() },
            read: { app, _ in
                _ = reads.increment()
                return CaptureResult(state: .available,
                    source: .init(bundleIdentifier: app.bundleID, processIdentifier: app.pid), text: "allowed")
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) })) { result in
                XCTAssertEqual(result.state, .available)
                XCTAssertEqual(result.text, "allowed")
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(reads.count, 1)
    }

    /// Keeps the serial worker moving while actor admission is deferred and reports timeout.
    @MainActor func testDeferredAutomaticAdmissionDoesNotBlockManualWorkerOrReadAfterDeadline() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let fixture = ForegroundFixture(allowed)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let deferred = DeferredAdmission()
        let axReads = DeliveryCount()
        let completions = DeliveryCount()
        let timedOut = expectation(description: "automatic request expires while actor admission is deferred")
        let manualFinished = expectation(description: "manual worker runs while admission is deferred")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: { fixture.snapshot() },
            read: { _, _ in
                _ = axReads.increment()
                return CaptureResult(state: .available, text: "unexpected")
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) },
            seconds: 0.1, scheduleAdmission: { deferred.schedule($0) })) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(result.error, "Accessibility capture deadline exceeded")
                _ = completions.increment()
                timedOut.fulfill()
            }
        XCTAssertNotNil(deadline)
        XCTAssertTrue(deferred.waitUntilScheduled())
        CaptureCollector.runAsync(deadline: .init(seconds: 0.2, startWhenWorkerBegins: true),
                                  seconds: 0.2, work: {
            manualFinished.fulfill()
            return CaptureResult(state: .readFailed)
        }) { _ in
            // The manual result is irrelevant; worker progress is the contract.
        }
        wait(for: [manualFinished, timedOut], timeout: 1)
        deferred.resume()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(completions.count, 1, "Late admission must not deliver a second outcome")
        XCTAssertEqual(axReads.count, 0, "Expired admission must never call AX")
    }

    /// Checks explicit cancellation has its own outcome and no late AX read.
    @MainActor func testCancelledAutomaticAdmissionMakesNoAXRead() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let foreground = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let deferred = DeferredAdmission()
        let reads = DeliveryCount()
        let completions = DeliveryCount()
        let completed = expectation(description: "cancelled admission finishes without AX")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { true }, foregroundProvider: { foreground },
            read: { _, _ in
                _ = reads.increment()
                return CaptureResult(state: .available, text: "unexpected")
            }, workerAuthorized: { target in target.matches(foreground) },
            seconds: 0.2, scheduleAdmission: { deferred.schedule($0) })) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(result.error, "Accessibility capture was cancelled")
                _ = completions.increment()
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        XCTAssertTrue(deferred.waitUntilScheduled())
        deadline?.cancel() // Pause, exclusion, sleep, and revocation fence this token.
        deferred.resume()
        wait(for: [completed], timeout: 1)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(completions.count, 1, "Later timer must not repeat cancellation delivery")
        XCTAssertEqual(reads.count, 0)
    }

    /// Reports a permission revocation during deferred admission without making an AX call.
    @MainActor func testRevokedPermissionDuringAdmissionHasDistinctOutcome() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let fixture = ForegroundFixture(allowed)
        let target = CaptureCollector.CaptureTarget(pid: allowed.pid,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let deferred = DeferredAdmission()
        let reads = DeliveryCount()
        let completed = expectation(description: "revocation during admission reports permission")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: { fixture.snapshot() },
                read: { _, _ in
                    _ = reads.increment()
                    return CaptureResult(state: .available, text: "unexpected")
                }, workerAuthorized: { target in target.matches(fixture.snapshot()) },
                seconds: 0.2, scheduleAdmission: { deferred.schedule($0) })) { result in
            XCTAssertEqual(result.state, .permissionRequired)
            XCTAssertEqual(result.error, "Accessibility permission is unavailable")
            completed.fulfill()
        }
        XCTAssertNotNil(deadline)
        XCTAssertTrue(deferred.waitUntilScheduled())
        fixture.update(allowed, trusted: false)
        deferred.resume()
        wait(for: [completed], timeout: 1)
        XCTAssertEqual(reads.count, 0)
    }

    /// Invalidates an actor snapshot when manual AX work intervenes.
    @MainActor func testManualWorkBetweenAdmissionAndAXRechecksForeground() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let excluded = CaptureCollector.Foreground(pid: 202, name: "Excluded",
            bundleID: "com.example.excluded", bundlePath: "/Applications/Excluded.app")
        let fixture = ForegroundFixture(allowed)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let snapshots = DeliveryCount()
        let reads = DeliveryCount()
        let releaseManual = DispatchSemaphore(value: 0)
        let manualStarted = expectation(description: "manual AX work begins after automatic admission")
        let completed = expectation(description: "foreground switch blocks automatic AX read")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: {
                if snapshots.increment() == 2 {
                    CaptureCollector.runAsync(deadline: .init(seconds: 0.2, startWhenWorkerBegins: true),
                                              seconds: 0.2, work: {
                        manualStarted.fulfill()
                        _ = releaseManual.wait(timeout: .now() + 1)
                        return CaptureResult(state: .readFailed)
                    }) { _ in
                        // The manual request occupies the serial worker after admission.
                    }
                }
                return fixture.snapshot()
            }, read: { _, _ in
                _ = reads.increment()
                return CaptureResult(state: .available, text: "unexpected")
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) })) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(result.error, "Allowed foreground application changed during AX read")
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        wait(for: [manualStarted], timeout: 1)
        fixture.update(excluded)
        releaseManual.signal()
        wait(for: [completed], timeout: 2)
        XCTAssertEqual(reads.count, 0, "Switch after admission must still produce zero AX calls")
    }

    /// Rechecks worker identity after an actor snapshot even without other work.
    @MainActor func testSwitchAfterActorSnapshotWithoutOtherWorkSkipsAX() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let excluded = CaptureCollector.Foreground(pid: 202, name: "Excluded",
            bundleID: "com.example.excluded", bundlePath: "/Applications/Excluded.app")
        let fixture = ForegroundFixture(allowed)
        let snapshots = DeliveryCount()
        let reads = DeliveryCount()
        let completions = DeliveryCount()
        let completed = expectation(description: "worker rejects a switch after the actor snapshot")
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { fixture.isTrusted() }, foregroundProvider: {
                let snapshot = fixture.snapshot()
                if snapshots.increment() == 2 { fixture.update(excluded) }
                return snapshot
            }, read: { _, _ in
                _ = reads.increment()
                return CaptureResult(state: .available, text: "unexpected")
            }, workerAuthorized: { target in target.matches(fixture.snapshot()) },
            seconds: 0.2)) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(result.error, "Allowed foreground application changed during AX read")
                _ = completions.increment()
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        wait(for: [completed], timeout: 2)
        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        XCTAssertEqual(completions.count, 1, "Later timeout must not replace switch outcome")
        XCTAssertEqual(reads.count, 0, "Worker must check the current target before AX")
    }

    /// Stops before AX when the identity recheck consumes the deadline.
    @MainActor func testExpiredWorkerIdentityCheckCannotStartAX() {
        let allowedURL = URL(fileURLWithPath: "/Applications/Allowed.app")
        let allowed = CaptureCollector.Foreground(pid: 101, name: "Allowed",
            bundleID: "com.example.allowed", bundlePath: allowedURL.path)
        let target = CaptureCollector.CaptureTarget(pid: 101,
            bundleID: "com.example.allowed", bundleURL: allowedURL)
        let reads = DeliveryCount()
        let completed = expectation(description: "deadline is reported during a slow identity check")
        let drained = expectation(description: "slow worker exits before final AX assertion")
        let deadline = CaptureCollector.captureAllowedForeground(target: target,
            environment: .init(trusted: { true }, foregroundProvider: { allowed },
            read: { _, _ in
                _ = reads.increment()
                return CaptureResult(state: .available, text: "unexpected")
            }, workerAuthorized: { _ in
                Thread.sleep(forTimeInterval: 0.08)
                return true
            }, seconds: 0.03)) { result in
                XCTAssertEqual(result.state, .readFailed)
                XCTAssertEqual(result.error, "Accessibility capture deadline exceeded")
                completed.fulfill()
            }
        XCTAssertNotNil(deadline)
        wait(for: [completed], timeout: 1)
        CaptureCollector.afterCaptureWorkerDrains { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertEqual(reads.count, 0)
    }
}
