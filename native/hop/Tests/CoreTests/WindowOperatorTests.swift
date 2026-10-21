import CoreGraphics
import Foundation
import HopCore
import XCTest

/// Every request the fakes receive, in one log, so the order across the Accessibility and app adapters is checked.
private enum Call: Equatable {
    case isMinimized, setMinimized(Bool), raise, makeMain, pressCloseButton, makeFrontmost, isFrontmost, isFocused, probe
    case lookUpApp, unhide, activate, hide, terminate
}

private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(call: Call, onMain: Bool)] = []

    var calls: [Call] { lock.withLock { entries.map(\.call) } }
    var anyOnMainThread: Bool { lock.withLock { entries.contains { $0.onMain } } }

    func record(_ call: Call) {
        lock.withLock { entries.append((call, Thread.isMainThread)) }
    }
}

/// A fake Accessibility adapter: answers each request as configured and logs it.
private final class FakeAccessibility: WindowAccessibility, @unchecked Sendable {
    let log: CallLog
    var trusted = true
    var minimized = false
    /// The read on which the window first reads back as focused (1 is the first read), or nil for never.
    var focusedFromRead: Int? = 1
    /// The read on which the app first reads back as frontmost, or nil for never.
    var frontmostFromRead: Int? = 1
    /// How many of the first focused-window reads fail as if the app were slow to answer.
    var slowFocusedReads = 0
    /// Failures by request; a request not listed succeeds.
    var failures: [Call: AccessibilityFailure] = [:]
    /// Runs inside the request before it answers, for example to make the app exit.
    var during: [Call: () -> Void] = [:]
    private var reads = 0
    private var frontmostReads = 0

    init(log: CallLog) {
        self.log = log
    }

    private func answer(_ call: Call) throws(AccessibilityFailure) {
        log.record(call)
        during[call]?()
        if let failure = failures[call] { throw failure }
    }

    func isTrusted() -> Bool { trusted }

    func isMinimized(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) -> Bool {
        try answer(.isMinimized)
        return minimized
    }

    func setMinimized(_ minimized: Bool, window _: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) {
        try answer(.setMinimized(minimized))
    }

    func raise(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) { try answer(.raise) }
    func makeMain(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) { try answer(.makeMain) }
    func pressCloseButton(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) { try answer(.pressCloseButton) }
    func makeFrontmost(pid _: pid_t) throws(AccessibilityFailure) { try answer(.makeFrontmost) }

    func isFrontmost(pid _: pid_t) throws(AccessibilityFailure) -> Bool {
        try answer(.isFrontmost)
        frontmostReads += 1
        return frontmostFromRead.map { frontmostReads >= $0 } ?? false
    }

    func isFocused(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) -> Bool {
        try answer(.isFocused)
        reads += 1
        if reads <= slowFocusedReads { throw .timedOut }
        return focusedFromRead.map { reads >= $0 } ?? false
    }

    func probe(_: HopCore.WindowRef, pid _: pid_t) throws(AccessibilityFailure) { try answer(.probe) }
}

extension Call: Hashable {}

/// A fake app adapter: one app, which can be hidden, refuse requests, or exit.
private final class FakeApps: AppControl, @unchecked Sendable {
    let log: CallLog
    private let lock = NSLock()
    private var state: RunningAppState?
    var delivers = true
    /// A request during which the app exits.
    var exitsDuring: Call?

    init(log: CallLog, state: RunningAppState?) {
        self.log = log
        self.state = state
    }

    /// The app exits: from now on it is not running.
    func exit() {
        lock.withLock { state = nil }
    }

    func app(_: pid_t) -> RunningAppState? {
        log.record(.lookUpApp)
        return lock.withLock { state }
    }

    func unhide(_: pid_t) -> Bool { request(.unhide) }
    func activate(_: pid_t) -> Bool { request(.activate) }
    func hide(_: pid_t) -> Bool { request(.hide) }
    func terminate(_: pid_t) -> Bool { request(.terminate) }

    private func request(_ call: Call) -> Bool {
        log.record(call)
        if call == exitsDuring { exit() }
        return delivers && lock.withLock { state != nil }
    }
}

final class WindowOperatorTests: XCTestCase {
    private let log = CallLog()
    private lazy var accessibility = FakeAccessibility(log: log)
    private lazy var apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: false))

    private func entry(bundle: String? = "com.example.editor", appHidden: Bool = false) -> WindowEntry {
        WindowEntry(
            app: SourceApp(pid: 10, bundleIdentifier: bundle, name: "Editor", isHidden: appHidden),
            window: SourceWindow(ref: WindowRef(rawValue: 7), title: "Draft", subrole: "AXStandardWindow", frame: nil),
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            display: nil
        )
    }

    private func perform(
        _ operation: WindowOperation,
        on window: WindowEntry? = nil,
        readBackTimeout: Duration = AccessibilityWindowOperator.defaultReadBackTimeout
    ) async -> OperationResult {
        let windowOperator = AccessibilityWindowOperator(accessibility: accessibility, apps: apps, readBackTimeout: readBackTimeout)
        return await windowOperator.perform(operation, on: window ?? entry())
    }

    // MARK: - Focus

    func testFocusRaisesMakesMainActivatesThenConfirmsByReadingTheFocusedWindowBack() async {
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .isMinimized, .raise, .makeMain, .activate, .makeFrontmost, .isFrontmost, .isFocused])
    }

    func testFocusUnminimizesAMinimizedWindowBeforeRaisingIt() async {
        accessibility.minimized = true
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [
            .lookUpApp, .isMinimized, .setMinimized(false), .raise, .makeMain, .activate, .makeFrontmost, .isFrontmost, .isFocused,
        ])
    }

    func testFocusUnhidesAHiddenAppFirst() async {
        // The app was hidden after the list was built: the live state counts, not the entry's.
        apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: true))
        let result = await perform(.focus, on: entry(appHidden: false))
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .unhide, .isMinimized, .raise, .makeMain, .activate, .makeFrontmost, .isFrontmost, .isFocused])
    }

    func testFocusKeepsReadingBackUntilTheWindowHasFocus() async {
        accessibility.focusedFromRead = 3
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls.filter { $0 == .isFocused }.count, 3)
    }

    func testFocusIsRefusedWhenTheWindowDoesNotReadBackInTime() async {
        accessibility.focusedFromRead = nil
        let start = ContinuousClock.now
        let result = await perform(.focus, readBackTimeout: .milliseconds(300))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - start, .milliseconds(300))
        XCTAssertGreaterThan(log.calls.filter { $0 == .isFocused }.count, 1, "the focused window is read until the deadline")
        XCTAssertEqual(log.calls.suffix(2), [.probe, .lookUpApp], "the window is checked once before refusing")
    }

    func testFocusIsRefusedWhenTheAppDoesNotComeToTheFrontEvenIfItsFocusedWindowIsTheWindow() async {
        // Activation was not taken: the app stays in the background, where its focused window is already this one.
        apps.delivers = false
        accessibility.failures = [.makeFrontmost: .failed]
        accessibility.frontmostFromRead = nil
        let result = await perform(.focus, readBackTimeout: .milliseconds(300))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertTrue(log.calls.contains(.activate))
        XCTAssertGreaterThan(log.calls.filter { $0 == .isFrontmost }.count, 1, "frontmost is read until the deadline")
    }

    func testFocusWaitsForTheAppToComeToTheFront() async {
        accessibility.frontmostFromRead = 3
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls.filter { $0 == .isFrontmost }.count, 3)
        XCTAssertEqual(log.calls.last, .isFocused)
    }

    func testAReadBackThatTheAppIsSlowToAnswerIsRetried() async {
        accessibility.slowFocusedReads = 2
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls.filter { $0 == .isFocused }.count, 3)
    }

    func testAWindowThatClosesBeforeItReadsBackIsWindowGone() async {
        // The read-back fails, and the window itself no longer exists, while its app runs.
        accessibility.focusedFromRead = nil
        accessibility.failures = [.probe: .invalidElement]
        let result = await perform(.focus, readBackTimeout: .milliseconds(100))
        XCTAssertEqual(result, .windowGone)
        XCTAssertEqual(log.calls.suffix(2), [.probe, .lookUpApp])
    }

    func testAWindowThatStillExistsButNeverReadsBackIsRefused() async {
        accessibility.focusedFromRead = nil
        accessibility.failures = [.probe: .timedOut]
        let result = await perform(.focus, readBackTimeout: .milliseconds(100))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertTrue(log.calls.contains(.probe))
    }

    func testAConfirmationThatArrivesAfterTheDeadlineDoesNotCount() async {
        // The window is focused, but the app only says so after the read-back has run out.
        accessibility.during = [.isFocused: { Thread.sleep(forTimeInterval: 0.15) }]
        let result = await perform(.focus, readBackTimeout: .milliseconds(100))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertEqual(log.calls.filter { $0 == .isFocused }.count, 1)
    }

    func testNoReadStartsAfterTheDeadline() async {
        // Each read takes most of the read-back: by the time the first has answered and Hop has waited, none is left.
        accessibility.focusedFromRead = 2
        accessibility.during = [.isFocused: { Thread.sleep(forTimeInterval: 0.08) }]
        let result = await perform(.focus, readBackTimeout: .milliseconds(100))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertEqual(log.calls.filter { $0 == .isFocused }.count, 1)
    }

    func testTheReadBackWaitsHalfASecondByDefault() {
        XCTAssertEqual(AccessibilityWindowOperator.defaultReadBackTimeout, .milliseconds(500))
    }

    func testAFocusStepTheWindowDoesNotSupportIsSkippedAndTheReadBackDecides() async {
        accessibility.failures = [.raise: .unsupported, .makeMain: .failed]
        let result = await perform(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .isMinimized, .raise, .makeMain, .activate, .makeFrontmost, .isFrontmost, .isFocused])
    }

    func testAWindowWhoseMinimizedStateCannotBeReadIsFocusedAsNotMinimized() async {
        // A dialog may have no kAXMinimized at all; the rest of focus still runs.
        for failure in [AccessibilityFailure.unsupported, .failed] {
            let log = CallLog()
            let accessibility = FakeAccessibility(log: log)
            accessibility.failures = [.isMinimized: failure]
            let apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: false))
            let windowOperator = AccessibilityWindowOperator(accessibility: accessibility, apps: apps)
            let result = await windowOperator.perform(.focus, on: entry())
            XCTAssertEqual(result, .done, "\(failure)")
            XCTAssertEqual(log.calls, [.lookUpApp, .isMinimized, .raise, .makeMain, .activate, .makeFrontmost, .isFrontmost, .isFocused], "\(failure)")
        }
    }

    func testAnAppThatDoesNotAnswerEndsTheFocusAtOnce() async {
        accessibility.failures = [.raise: .timedOut]
        let result = await perform(.focus)
        XCTAssertEqual(result, .refused("not responding"))
        XCTAssertEqual(log.calls, [.lookUpApp, .isMinimized, .raise, .lookUpApp])
    }

    // MARK: - Window and app gone

    func testAWindowThatClosedIsWindowGoneForEveryWindowOperation() async {
        accessibility.failures = [.isMinimized: .invalidElement, .setMinimized(true): .invalidElement, .pressCloseButton: .invalidElement]
        for operation in [WindowOperation.focus, .minimize, .close] {
            let result = await perform(operation)
            XCTAssertEqual(result, .windowGone, "\(operation)")
        }
        XCTAssertFalse(log.calls.contains(.raise))
        XCTAssertFalse(log.calls.contains(.activate))
    }

    func testAnAppThatExitedBeforeTheOperationIsAppGoneWithNothingSent() async {
        apps.exit()
        for operation in WindowOperation.allCases {
            let result = await perform(operation)
            XCTAssertEqual(result, .appGone, "\(operation)")
        }
        XCTAssertEqual(Set(log.calls), [.lookUpApp])
    }

    func testAnAppThatExitsDuringTheOperationIsAppGone() async {
        // An app that has just quit answers like one that timed out, or its window like a closed one.
        let cases: [(WindowOperation, Call, AccessibilityFailure?)] = [
            (.focus, .raise, .timedOut),
            (.minimize, .setMinimized(true), .invalidElement),
            (.close, .pressCloseButton, .invalidElement),
            (.hideApp, .hide, nil),
            (.quitApp, .terminate, nil),
        ]
        for (operation, request, failure) in cases {
            let log = CallLog()
            let accessibility = FakeAccessibility(log: log)
            let apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: false))
            accessibility.failures = failure.map { [request: $0] } ?? [:]
            accessibility.during = [request: apps.exit]
            apps.exitsDuring = request
            let windowOperator = AccessibilityWindowOperator(accessibility: accessibility, apps: apps)
            let result = await windowOperator.perform(operation, on: entry())
            XCTAssertEqual(result, .appGone, "\(operation)")
            XCTAssertEqual(log.calls.suffix(2), [request, .lookUpApp], "\(operation) sent its request before the app exited")
        }
    }

    func testAnotherAppThatReusedThePidIsAppGone() async {
        let result = await perform(.quitApp, on: entry(bundle: "com.example.other"))
        XCTAssertEqual(result, .appGone)
        XCTAssertFalse(log.calls.contains(.terminate))
    }

    // MARK: - Permission

    func testWithoutAccessibilityEveryOperationIsNotPermittedAndSendsNothing() async {
        accessibility.trusted = false
        for operation in WindowOperation.allCases {
            let result = await perform(operation)
            XCTAssertEqual(result, .notPermitted, "\(operation)")
        }
        XCTAssertEqual(log.calls, [])
    }

    func testTrustLostDuringAnOperationIsNotPermitted() async {
        accessibility.failures = [.isMinimized: .notPermitted]
        let result = await perform(.focus)
        XCTAssertEqual(result, .notPermitted)
        XCTAssertFalse(log.calls.contains(.raise))
    }

    // MARK: - Minimize, close, hide, quit

    func testMinimizeSetsMinimizedOnly() async {
        let result = await perform(.minimize)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .setMinimized(true)])
    }

    func testAWindowThatCannotBeMinimizedIsRefused() async {
        accessibility.failures = [.setMinimized(true): .unsupported]
        let result = await perform(.minimize)
        XCTAssertEqual(result, .refused("can't be minimized"))
    }

    func testClosePressesTheCloseButtonAndDoesNotWaitForTheWindowToGo() async {
        // An app that asks to save keeps the window open behind its prompt; the close is still done.
        let result = await perform(.close)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .pressCloseButton])
    }

    func testAWindowWithoutACloseButtonIsRefused() async {
        accessibility.failures = [.pressCloseButton: .unsupported]
        let result = await perform(.close)
        XCTAssertEqual(result, .refused("can't be closed"))
    }

    func testHideAppHidesTheApp() async {
        let result = await perform(.hideApp)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .hide])
    }

    func testHidingAnAppThatIsAlreadyHiddenIsDone() async {
        apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: true))
        apps.delivers = false
        let result = await perform(.hideApp)
        XCTAssertEqual(result, .done)
    }

    func testAnAppThatDoesNotTakeTheHideRequestIsRefused() async {
        apps.delivers = false
        let result = await perform(.hideApp)
        XCTAssertEqual(result, .refused("did not hide"))
    }

    func testQuitAppAsksTheAppToQuitNormallyOnce() async {
        let result = await perform(.quitApp)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .terminate])
    }

    func testFinderIsNeverQuit() async {
        apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.apple.finder", isHidden: false))
        let result = await perform(.quitApp, on: entry(bundle: "com.apple.finder"))
        XCTAssertEqual(result, .refused("Finder can't be quit"))
        XCTAssertEqual(log.calls, [])
    }

    func testFinderCanStillBeHidden() async {
        apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.apple.finder", isHidden: false))
        let result = await perform(.hideApp, on: entry(bundle: "com.apple.finder"))
        XCTAssertEqual(result, .done)
    }

    /// The app adapter has no force-quit; this keeps the live code from calling one directly.
    func testNoSourceForceQuitsAnApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for folder in ["Core", "MacApp"] {
            let sources = try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent(folder),
                includingPropertiesForKeys: nil
            ).filter { $0.pathExtension == "swift" }
            XCTAssertFalse(sources.isEmpty, "found no sources in \(folder)")
            for source in sources {
                let text = try String(contentsOf: source, encoding: .utf8)
                XCTAssertFalse(text.contains("forceTerminate"), "\(source.lastPathComponent) force-quits an app")
            }
        }
    }

    // MARK: - Windowless apps

    private func performOnApp(
        _ operation: WindowOperation,
        bundle: String? = "com.example.editor",
        hidden: Bool = false,
        readBackTimeout: Duration = AccessibilityWindowOperator.defaultReadBackTimeout
    ) async -> OperationResult {
        let app = AppEntry(SourceApp(pid: 10, bundleIdentifier: bundle, name: "Editor", isHidden: hidden))
        let windowOperator = AccessibilityWindowOperator(accessibility: accessibility, apps: apps, readBackTimeout: readBackTimeout)
        return await windowOperator.perform(operation, onApp: app)
    }

    func testFocusOnAWindowlessAppActivatesItAndConfirmsItIsFrontmost() async {
        let result = await performOnApp(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .activate, .makeFrontmost, .isFrontmost], "no window is read or raised")
    }

    func testFocusOnAHiddenWindowlessAppUnhidesItFirst() async {
        apps = FakeApps(log: log, state: RunningAppState(bundleIdentifier: "com.example.editor", isHidden: true))
        let result = await performOnApp(.focus)
        XCTAssertEqual(result, .done)
        XCTAssertEqual(log.calls, [.lookUpApp, .unhide, .activate, .makeFrontmost, .isFrontmost])
    }

    func testAWindowlessAppThatDoesNotComeForwardIsRefused() async {
        accessibility.frontmostFromRead = nil
        let result = await performOnApp(.focus, readBackTimeout: .milliseconds(300))
        XCTAssertEqual(result, .refused("did not come to front"))
        XCTAssertGreaterThan(log.calls.filter { $0 == .isFrontmost }.count, 1, "frontmost is read until the deadline")
    }

    func testAnInvalidAppElementOfARunningWindowlessAppIsARefusalNotAClosedWindow() async {
        accessibility.failures = [.makeFrontmost: .invalidElement]
        let result = await performOnApp(.focus)
        XCTAssertEqual(result, .refused("did not come to front"))
    }

    func testAWindowlessAppHasNoWindowToMinimizeOrClose() async {
        for operation in [WindowOperation.minimize, .close] {
            let result = await performOnApp(operation)
            XCTAssertEqual(result, .refused("has no window"), "\(operation)")
        }
        XCTAssertEqual(Set(log.calls), [.lookUpApp], "no request is sent")
    }

    func testAWindowlessAppCanBeHiddenAndQuitButFinderIsNeverQuit() async {
        let hidden = await performOnApp(.hideApp)
        let quit = await performOnApp(.quitApp)
        XCTAssertEqual([hidden, quit], [.done, .done])
        XCTAssertEqual(log.calls, [.lookUpApp, .hide, .lookUpApp, .terminate])
        let finder = await performOnApp(.quitApp, bundle: "com.apple.finder")
        XCTAssertEqual(finder, .refused("Finder can't be quit"))
    }

    func testAWindowlessAppThatExitedOrWasReplacedIsGoneAndUntrustedHopAsksNothing() async {
        let replaced = await performOnApp(.focus, bundle: "com.example.other")
        XCTAssertEqual(replaced, .appGone, "another app now has the pid")
        accessibility.trusted = false
        let untrusted = await performOnApp(.focus)
        XCTAssertEqual(untrusted, .notPermitted)
        XCTAssertEqual(log.calls, [.lookUpApp])
    }

    // MARK: - Threads

    @MainActor
    func testOperationsRunOffTheMainThreadWithoutBlockingIt() async {
        let entered = expectation(description: "the raise request started")
        let release = DispatchSemaphore(value: 0)
        accessibility.during = [.raise: {
            entered.fulfill()
            release.wait()
        }]
        let windowOperator = AccessibilityWindowOperator(accessibility: accessibility, apps: apps)
        let window = entry()
        let task = Task { @MainActor in await windowOperator.perform(.focus, on: window) }
        // The main actor is free while the app is answering: this wait could not finish if the request held it.
        await fulfillment(of: [entered], timeout: 5)
        release.signal()
        let result = await task.value
        XCTAssertEqual(result, .done)
        XCTAssertFalse(log.anyOnMainThread)
    }

    // MARK: - Recording fake

    func testTheRecordingOperatorRecordsEachOperationAndAnswersAsSet() async throws {
        let recording = RecordingWindowOperator(results: [.close: .windowGone])
        let window = entry()
        let closed = await recording.perform(.close, on: window)
        recording.setResult(.refused("Finder can't be quit"), for: .quitApp)
        let quit = await recording.perform(.quitApp, on: window)
        let focused = await recording.perform(.focus, on: window)
        XCTAssertEqual([closed, quit, focused], [.windowGone, .refused("Finder can't be quit"), .done])
        XCTAssertEqual(recording.calls.map(\.operation), [.close, .quitApp, .focus])
        XCTAssertEqual(Set(recording.calls.map(\.window)), [WindowRef(rawValue: 7)])
        _ = await recording.perform(.focus, onApp: AppEntry(SourceApp(pid: 12, bundleIdentifier: nil, name: "Notes")))
        let last = try XCTUnwrap(recording.calls.last)
        XCTAssertEqual([last.operation], [.focus])
        XCTAssertNil(last.window, "an app cell has no window")
        XCTAssertEqual(last.pid, 12)
    }
}
