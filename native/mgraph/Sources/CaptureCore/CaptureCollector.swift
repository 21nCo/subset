import AppKit
import ApplicationServices
import Foundation

/// Outcome of one bounded local Accessibility capture.
public enum CaptureState: String, Codable, Sendable {
    case available
    case permissionRequired
    case noForegroundApplication
    case unsupportedApplication
    case readFailed
}

/// Timestamped capture result with source identity and optional bounded text.
public struct CaptureResult: Codable, Sendable {
    /// Source metadata used to distinguish a capture from another app or window.
    public struct Source: Codable, Sendable {
        public let applicationName: String?
        public let bundleIdentifier: String?
        public let processIdentifier: Int32?
        public let windowTitle: String?
        public let documentURL: String?

        /// Builds source metadata; absent fields are retained as unknown rather than guessed.
        public init(applicationName: String? = nil, bundleIdentifier: String? = nil,
                    processIdentifier: Int32? = nil, windowTitle: String? = nil,
                    documentURL: String? = nil) {
            self.applicationName = applicationName
            self.bundleIdentifier = bundleIdentifier
            self.processIdentifier = processIdentifier
            self.windowTitle = windowTitle
            self.documentURL = documentURL
        }
    }
    public let state: CaptureState
    public let observedAt: Date
    public let applicationName: String?
    public let bundleIdentifier: String?
    public let processIdentifier: Int32?
    public let windowTitle: String?
    public let documentURL: String?
    public let text: String?
    public let error: String?

    /// Builds a result without inventing text for an unavailable or failed read.
    public init(state: CaptureState, observedAt: Date = Date(), source: Source = Source(),
                text: String? = nil, error: String? = nil) {
        self.state = state
        self.observedAt = observedAt
        self.applicationName = source.applicationName
        self.bundleIdentifier = source.bundleIdentifier
        self.processIdentifier = source.processIdentifier
        self.windowTitle = source.windowTitle
        self.documentURL = source.documentURL
        self.text = text
        self.error = error
    }
}

// The menu can cancel a worker without stopping an AX call already in progress.
// Only the most recent live request may present a result.
@MainActor public final class CaptureRequestGate {
    private var current: UUID?

    /// Starts with no live menu request.
    public init() {}

    /// Makes a new menu request current and returns its completion token.
    public func begin() -> UUID {
        let token = UUID()
        current = token
        return token
    }

    /// Prevents a cancelled worker from presenting a late result.
    public func cancel() { current = nil }

    /// Accepts only the current request's first completion.
    public func finish(_ token: UUID) -> Bool {
        guard current == token else { return false }
        current = nil
        return true
    }
}

public enum CaptureCollector {
    public static let captureTimeout: TimeInterval = 4
    private static let captureQueue = DispatchQueue(label: "dev.subset.mgraph.ax-capture", qos: .userInitiated)
    private static let workerRevision = WorkerRevision()
    typealias AdmissionScheduler = @Sendable (@escaping @MainActor @Sendable () -> Void) -> Void

    // A main-actor foreground snapshot must be repeated if another queued AX job
    // starts or finishes before the automatic job reaches the serial worker.
    private final class WorkerRevision: @unchecked Sendable {
        private let lock = NSLock()
        private var value: UInt64 = 0

        /// Returns the current serial worker activity revision.
        func snapshot() -> UInt64 { lock.lock(); defer { lock.unlock() }; return value }
        /// Marks an AX job's start or finish for admission freshness checks.
        func advance() { lock.lock(); value &+= 1; lock.unlock() }
    }

    /// Runs a menu callback after all previously queued AX work has exited.
    @MainActor public static func afterCaptureWorkerDrains(_ completion: @escaping @MainActor @Sendable () -> Void) {
        captureQueue.async { DispatchQueue.main.async(execute: completion) }
    }

    struct Foreground: Sendable {
        let pid: pid_t
        let name: String?
        let bundleID: String?
        let bundlePath: String?
    }

    struct CaptureTarget: Sendable {
        let pid: pid_t
        let bundleID: String
        let bundlePath: String

        /// Freezes the selected bundle's canonical identity at automatic dispatch.
        init(pid: pid_t, bundleID: String, bundleURL: URL) {
            self.pid = pid
            self.bundleID = bundleID
            bundlePath = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        }

        /// Requires the same process, bundle identifier, and resolved bundle path.
        func matches(_ app: Foreground?) -> Bool {
            guard let app else { return false }
            return app.pid == pid && app.bundleID == bundleID && app.bundlePath == bundlePath
        }
    }

    // AX window elements identify separate windows even when their titles match.
    // Selected tabs and focused elements distinguish sources inside one window.
    struct SourceIdentity: Equatable {
        let pid: pid_t
        let window: CFHashCode
        let title: String?
        let document: String?
        let focusedElement: CFHashCode?
        let selectedTabs: [CFHashCode]
        let webAreas: [CFHashCode]
    }

    // The lock also prevents a late AX reply from publishing text after a deadline.
    public final class Deadline: @unchecked Sendable {
        private let lock = NSLock()
        private let duration: UInt64
        private var end: UInt64?
        private var cancelled = false

        /// Creates a cancellable deadline, optionally deferring its budget until worker admission.
        public init(seconds: TimeInterval, startWhenWorkerBegins: Bool = false) {
            duration = UInt64(max(0, seconds) * 1_000_000_000)
            end = startWhenWorkerBegins ? nil : DispatchTime.now().uptimeNanoseconds + duration
        }

        /// Returns true after cancellation or the elapsed monotonic deadline.
        public var expired: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled || (end.map { DispatchTime.now().uptimeNanoseconds >= $0 } ?? false)
        }

        /// Distinguishes a caller's explicit invalidation from an elapsed budget.
        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// Starts the budget on first worker admission and rejects cancelled or expired work.
        /// A second call checks the same budget without resetting it.
        func beginWorker() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { return false }
            if end == nil { end = DispatchTime.now().uptimeNanoseconds + duration }
            guard let end else { return false }
            return DispatchTime.now().uptimeNanoseconds < end
        }

        /// Fences late AX replies and queued work from yielding a result.
        public func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
    }

    /// Takes one foreground snapshot with its canonical bundle path.
    private static func foreground() -> Foreground? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return Foreground(pid: app.processIdentifier, name: app.localizedName,
                          bundleID: app.bundleIdentifier,
                          bundlePath: app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path)
    }

    /// Reports a failed read with source metadata but no captured text.
    private static func failed(_ app: Foreground?, _ message: String) -> CaptureResult {
        CaptureResult(state: .readFailed, source: .init(applicationName: app?.name,
                      bundleIdentifier: app?.bundleID, processIdentifier: app?.pid), error: message)
    }

    /// Rejects a one-shot result after trust loss, deadline expiry, or PID switch.
    private static func validate(_ result: CaptureResult, app: Foreground?, deadline: Deadline) -> CaptureResult {
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        if NSWorkspace.shared.frontmostApplication?.processIdentifier != app?.pid {
            return failed(app, "Foreground application changed during capture")
        }
        return result
    }

    // Called on the main thread by both entry points. AX work never occupies the menu loop.
    @discardableResult
    /// Runs the explicit one-shot menu capture without an automatic-recording allowlist.
    @MainActor public static func captureForeground(
        onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (CaptureResult) -> Void
    ) -> Deadline? {
        guard isTrusted() else { completion(status()); return nil }
        guard let app = foreground() else {
            completion(CaptureResult(state: .noForegroundApplication, error: "No foreground application"))
            return nil
        }
        let deadline = Deadline(seconds: captureTimeout, startWhenWorkerBegins: true)
        runAsync(deadline: deadline, seconds: captureTimeout, onWorkerStart: onWorkerStart, work: {
            performCapture(app, deadline: deadline)
        }) { result in
            completion(validate(result ?? failed(app, "Accessibility capture deadline exceeded"),
                                app: app, deadline: deadline))
        }
        return deadline
    }

    /// Automatically reads only the PID and canonical app bundle authorized by the controller.
    /// A queued foreground switch is rejected on worker admission before any remote AX call.
    @discardableResult
    @MainActor public static func captureAllowedForeground(
        pid: pid_t, bundleIdentifier: String, bundleURL: URL,
        onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (CaptureResult) -> Void
    ) -> Deadline? {
        captureAllowedForeground(target: .init(pid: pid, bundleID: bundleIdentifier, bundleURL: bundleURL),
                                 environment: .init(trusted: { isTrusted() }, foregroundProvider: { foreground() },
                                                    read: { app, deadline in performCapture(app, deadline: deadline) },
                                                    workerAuthorized: { activeTargetMatches($0) }),
                                 onWorkerStart: onWorkerStart, completion: completion)
    }

    /// Rechecks active process and fixed bundle identity from the serial worker before AX.
    /// NSRunningApplication properties are atomic across threads; a later switch is fenced on completion.
    private static func activeTargetMatches(_ target: CaptureTarget) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: target.pid), app.isActive else { return false }
        return app.bundleIdentifier == target.bundleID &&
            app.bundleURL?.standardizedFileURL.resolvingSymlinksInPath().path == target.bundlePath
    }

    /// Inputs that can change while an automatic request waits for actor and worker admission.
    struct AllowedCaptureEnvironment: Sendable {
        let trusted: @Sendable () -> Bool
        let foregroundProvider: @MainActor @Sendable () -> Foreground?
        let read: @Sendable (Foreground, Deadline) -> CaptureResult
        let workerAuthorized: @Sendable (CaptureTarget) -> Bool
        var seconds: TimeInterval = captureTimeout
        var scheduleAdmission: AdmissionScheduler = { DispatchQueue.main.async(execute: $0) }
    }

    private enum AllowedOutcome: Sendable {
        case result(CaptureResult)
        case targetChanged
        case permissionRequired
        case deadlineExceeded
        case cancelled

        /// Indicates that a caller or queued worker invalidated this request.
        var isCancellation: Bool { if case .cancelled = self { return true }; return false }
        /// Indicates trust was revoked before a remote Accessibility read.
        var isPermissionFailure: Bool { if case .permissionRequired = self { return true }; return false }
        /// Indicates that the elapsed budget won the completion race.
        var isTimeout: Bool { if case .deadlineExceeded = self { return true }; return false }
        /// Indicates that the authorized application identity changed before delivery.
        var isTargetChange: Bool { if case .targetChanged = self { return true }; return false }
    }

    /// Owns one automatic request from queue admission through its single main-actor delivery.
    private final class AllowedAttempt: @unchecked Sendable {
        let target: CaptureTarget
        let environment: AllowedCaptureEnvironment
        let deadline: Deadline
        let onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)?
        let completion: @MainActor @Sendable (CaptureResult) -> Void
        let delivery = Delivery()

        /// Freezes the authorized target and one set of callbacks for this request.
        init(target: CaptureTarget, environment: AllowedCaptureEnvironment, deadline: Deadline,
             onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)?,
             completion: @escaping @MainActor @Sendable (CaptureResult) -> Void) {
            self.target = target
            self.environment = environment
            self.deadline = deadline
            self.onWorkerStart = onWorkerStart
            self.completion = completion
        }

        /// Starts the deadline only when the serial worker first admits this request.
        func beginOnWorker() {
            workerRevision.advance()
            guard deadline.beginWorker() else { dispatch(stoppedOutcome()); return }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + environment.seconds) {
                self.dispatch(.deadlineExceeded)
            }
            requestAdmission()
        }

        /// Hops to AppKit's actor without occupying the serial AX worker.
        func requestAdmission() {
            environment.scheduleAdmission { self.admitOnMain() }
        }

        /// Captures a main-actor foreground identity and the worker activity revision.
        @MainActor func admitOnMain() {
            guard environment.trusted() else { finish(.permissionRequired); return }
            guard !deadline.expired else { finish(.deadlineExceeded); return }
            guard let app = environment.foregroundProvider(), target.matches(app) else {
                finish(.targetChanged)
                return
            }
            let revision = workerRevision.snapshot()
            captureQueue.async { self.admitOnWorker(app: app, revision: revision) }
        }

        /// Rejects a stale actor snapshot or changed PID, bundle ID, and path before AX reads.
        func admitOnWorker(app: Foreground, revision: UInt64) {
            guard deadline.beginWorker() else { dispatch(stoppedOutcome()); return }
            guard environment.trusted() else { dispatch(.permissionRequired); return }
            if workerRevision.snapshot() != revision { requestAdmission(); return }
            guard environment.workerAuthorized(target) else { dispatch(.targetChanged); return }
            guard environment.trusted() else { dispatch(.permissionRequired); return }
            guard !deadline.expired else { dispatch(.deadlineExceeded); return }
            workerRevision.advance()
            let startedAt = ProcessInfo.processInfo.systemUptime
            if let onWorkerStart { DispatchQueue.main.async { onWorkerStart(startedAt) } }
            let result = environment.read(app, deadline)
            workerRevision.advance()
            dispatch(.result(result))
        }

        /// Preserves whether a failed worker admission was cancelled or timed out.
        func stoppedOutcome() -> AllowedOutcome {
            deadline.wasCancelled ? .cancelled : .deadlineExceeded
        }

        /// Moves a worker or timer outcome to the actor without waiting on a modal main loop.
        func dispatch(_ outcome: AllowedOutcome) {
            DispatchQueue.main.async { self.finish(outcome) }
        }

        /// Applies terminal priority and delivers at most once, including late worker replies.
        @MainActor func finish(_ outcome: AllowedOutcome) {
            delivery.once {
                let result: CaptureResult
                if !environment.trusted() || outcome.isPermissionFailure {
                    result = CaptureResult(state: .permissionRequired, error: "Accessibility permission is unavailable")
                } else if deadline.wasCancelled || outcome.isCancellation {
                    result = CaptureResult(state: .readFailed, error: "Accessibility capture was cancelled")
                } else if outcome.isTargetChange {
                    result = CaptureResult(state: .readFailed,
                                           error: "Allowed foreground application changed during AX read")
                } else if deadline.expired || outcome.isTimeout {
                    result = CaptureResult(state: .readFailed, error: "Accessibility capture deadline exceeded")
                } else if !target.matches(environment.foregroundProvider()) {
                    result = CaptureResult(state: .readFailed,
                                           error: "Allowed foreground application changed during AX read")
                } else if case .result(let captured) = outcome {
                    result = captured
                } else {
                    result = CaptureResult(state: .readFailed, error: "Accessibility capture failed")
                }
                completion(result)
            }
        }
    }

    /// Admits an automatic read after an actor-bound identity check without parking the AX worker.
    /// The scheduler is injectable to prove that a modal main-loop delay cannot block other work.
    @discardableResult
    @MainActor static func captureAllowedForeground(
        target: CaptureTarget, environment: AllowedCaptureEnvironment,
        onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)? = nil,
        completion: @escaping @MainActor @Sendable (CaptureResult) -> Void
    ) -> Deadline? {
        guard environment.trusted() else {
            completion(CaptureResult(state: .permissionRequired, error: "Accessibility permission is unavailable"))
            return nil
        }
        guard target.matches(environment.foregroundProvider()) else {
            completion(CaptureResult(state: .readFailed, error: "Allowed foreground application changed"))
            return nil
        }
        let deadline = Deadline(seconds: environment.seconds, startWhenWorkerBegins: true)
        let attempt = AllowedAttempt(target: target, environment: environment, deadline: deadline,
                                     onWorkerStart: onWorkerStart, completion: completion)
        captureQueue.async { attempt.beginOnWorker() }
        return deadline
    }

    /// Serializes AX work and gives a queued request its budget when admitted to the worker.
    @MainActor static func runAsync(deadline: Deadline, seconds: TimeInterval,
                                    onWorkerStart: (@MainActor @Sendable (TimeInterval) -> Void)? = nil,
                                    work: @escaping @Sendable () -> CaptureResult,
                                    completion: @escaping @MainActor @Sendable (CaptureResult?) -> Void) {
        let delivery = Delivery()
        captureQueue.async {
            workerRevision.advance()
            defer { workerRevision.advance() }
            guard deadline.beginWorker() else {
                DispatchQueue.main.async { delivery.deliver(nil, to: completion) }
                return
            }
            let startedAt = ProcessInfo.processInfo.systemUptime
            if let onWorkerStart {
                DispatchQueue.main.async { onWorkerStart(startedAt) }
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + seconds) {
                deadline.cancel()
                DispatchQueue.main.async { delivery.deliver(nil, to: completion) }
            }
            let result = work()
            DispatchQueue.main.async { delivery.deliver(deadline.expired ? nil : result, to: completion) }
        }
    }

    private final class Delivery: @unchecked Sendable {
        private var delivered = false
        private let lock = NSLock()
        /// Claims the one completion slot across the timer, worker, and admission callbacks.
        func once(_ body: () -> Void) {
            lock.lock()
            let shouldDeliver = !delivered
            delivered = true
            lock.unlock()
            if shouldDeliver { body() }
        }
        /// Delivers a result on the menu actor at most once.
        @MainActor func deliver(_ result: CaptureResult?,
                                to completion: @escaping @MainActor @Sendable (CaptureResult?) -> Void) {
            once { completion(result) }
        }
    }
    /// Reads the current macOS Accessibility trust state without prompting.
    public static func isTrusted() -> Bool { AXIsProcessTrusted() }

    /// Requests Accessibility access through the operating system prompt.
    @discardableResult
    public static func requestAccess() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Returns current permission status with no foreground content.
    public static func status() -> CaptureResult {
        let trusted = isTrusted()
        return CaptureResult(state: trusted ? .available : .permissionRequired,
                             error: trusted ? nil : "Grant Accessibility access in System Settings > Privacy & Security > Accessibility.")
    }

    /// Converts explicit CLI consent and foreground availability into a failure before AX work.
    public static func cliConsentFailure(approved: Bool, foregroundAvailable: Bool) -> CaptureResult? {
        if !approved { return CaptureResult(state: .readFailed, error: "Command capture was not approved") }
        if !foregroundAvailable {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        return nil
    }

    // The native menu check may inspect alert text only for its own fixture.
    // Reject a foreground switch before the alert receives any captured body.
    /// Suppresses fixture text if its expected app or exact window title changed before display.
    public static func bindFixture(_ result: CaptureResult, bundleIdentifier: String,
                                   windowTitle: String) -> CaptureResult {
        guard result.state == .available else { return result }
        guard result.bundleIdentifier == bundleIdentifier,
              result.windowTitle == windowTitle else {
            return CaptureResult(state: .readFailed, error: "Foreground fixture changed before alert")
        }
        return result
    }

    /// Runs the confirmed CLI one-shot read, optionally bound to the pre-consent PID.
    public static func captureForeground(expectedProcessIdentifier: pid_t? = nil) -> CaptureResult {
        guard isTrusted() else { return status() }
        guard let app = foreground() else {
            return CaptureResult(state: .noForegroundApplication, error: "No foreground application")
        }
        if let expectedProcessIdentifier, app.pid != expectedProcessIdentifier {
            return failed(app, "Foreground application changed before capture")
        }
        let deadline = Deadline(seconds: captureTimeout)
        let result = runBounded(deadline: deadline, seconds: captureTimeout) {
            performCapture(app, deadline: deadline)
        }
        return validate(result ?? failed(app, "Accessibility capture deadline exceeded"), app: app,
                        deadline: deadline)
    }

    // The bounded runner is also exercised with a deliberately slow fake tree.
    /// Waits at most the requested duration for serial AX work and discards a late result.
    static func runBounded(deadline: Deadline, seconds: TimeInterval,
                           work: @escaping @Sendable () -> CaptureResult) -> CaptureResult? {
        let semaphore = DispatchSemaphore(value: 0)
        let box = ResultBox()
        captureQueue.async {
            workerRevision.advance()
            defer { workerRevision.advance() }
            box.result = work()
            semaphore.signal()
        }
        if semaphore.wait(timeout: .now() + seconds) == .timedOut { deadline.cancel(); return nil }
        return deadline.expired ? nil : box.result
    }

    private final class ResultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CaptureResult?
        var result: CaptureResult? {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); stored = newValue; lock.unlock() }
        }
    }

    /// Reads only the supplied PID's focused AX window and verifies its source again afterward.
    private static func performCapture(_ app: Foreground, deadline: Deadline) -> CaptureResult {
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let root = AXUIElementCreateApplication(app.pid)
        AXUIElementSetMessagingTimeout(root, 0.25)
        var roleValue: CFTypeRef?
        let rootError = AXUIElementCopyAttributeValue(root, kAXRoleAttribute as CFString, &roleValue)
        if rootError == .apiDisabled { return status() }
        if rootError == .cannotComplete {
            return failed(app, "Accessibility request timed out")
        }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        guard let target = captureWindow(root, deadline: deadline) else {
            return failed(app, "Focused Accessibility window unavailable")
        }
        let title = stringAttribute(target, kAXTitleAttribute as String, deadline: deadline)
        let document = stringAttribute(target, kAXDocumentAttribute as String, deadline: deadline)
        let source = sourceIdentity(root: root, target: target, app: app, title: title,
                                    document: document, deadline: deadline)
        guard let source, let extraction = extractText(from: target, deadline: deadline) else {
            return failed(app, "Accessibility tree exceeded the capture limit")
        }
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let currentWindow = captureWindow(root, deadline: deadline)
        let current = currentWindow.flatMap { window in
            sourceIdentity(root: root, target: window, app: app,
                           title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                           document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                           deadline: deadline)
        }
        // AX can reuse a window, tab, and web-area element across a navigation.
        // Read the current focused window again so missing source attributes cannot
        // make text from the preceding page look current.
        let confirmation = currentWindow.flatMap { extractText(from: $0, deadline: deadline)?.text }
        let finalWindow = captureWindow(root, deadline: deadline)
        let finalRead = confirmAfterFinalText(
            readText: { finalWindow.flatMap { extractText(from: $0, deadline: deadline)?.text } },
            readSource: { focusedSource(root: root, app: app, deadline: deadline) })
        if !isTrusted() { return status() }
        if deadline.expired { return failed(app, "Accessibility capture deadline exceeded") }
        let state = stateForText(extraction.text)
        let result = CaptureResult(state: state, source: .init(applicationName: app.name,
                                   bundleIdentifier: app.bundleID, processIdentifier: app.pid,
                                   windowTitle: title, documentURL: document),
                                   text: extraction.text.isEmpty ? nil : extraction.text,
                                   error: extraction.text.isEmpty ? "No readable text in the Accessibility tree" : nil)
        return checkedCapture(result, initial: source, current: current,
                              confirmation: confirmation, final: finalRead.source, finalText: finalRead.text)
    }

    /// Rebuilds focused source identity after extraction to detect window or tab changes.
    private static func focusedSource(root: AXUIElement, app: Foreground,
                                      deadline: Deadline) -> SourceIdentity? {
        guard let window = captureWindow(root, deadline: deadline) else { return nil }
        return sourceIdentity(root: root, target: window, app: app,
                              title: stringAttribute(window, kAXTitleAttribute as String, deadline: deadline),
                              document: stringAttribute(window, kAXDocumentAttribute as String, deadline: deadline),
                              deadline: deadline)
    }

    /// Reads final content before final source identity so navigation cannot reuse old text.
    static func confirmAfterFinalText(readText: () -> String?,
                                      readSource: () -> SourceIdentity?) -> (text: String?, source: SourceIdentity?) {
        let text = readText()
        return (text, readSource())
    }

    /// Publishes text only when every source and text observation agrees.
    static func checkedCapture(_ result: CaptureResult, initial: SourceIdentity,
                               current: SourceIdentity?, confirmation: String?,
                               final: SourceIdentity?, finalText: String?) -> CaptureResult {
        guard let current, let final, initial == current, initial == final,
              let confirmation, let finalText,
              result.text == (confirmation.isEmpty ? nil : confirmation),
              result.text == (finalText.isEmpty ? nil : finalText) else {
            return CaptureResult(state: .readFailed, source: .init(applicationName: result.applicationName,
                                 bundleIdentifier: result.bundleIdentifier, processIdentifier: result.processIdentifier),
                                 error: "Foreground source or content changed during capture")
        }
        return result
    }

    /// Distinguishes an empty readable tree from a usable observation.
    static func stateForText(_ text: String) -> CaptureState {
        text.isEmpty ? .unsupportedApplication : .available
    }

    /// Bounds one remote AX attribute reply by the active deadline.
    private static func attribute(_ element: AXUIElement, _ name: String, deadline: Deadline) -> CFTypeRef? {
        guard !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        guard !deadline.expired else { return nil }
        return result
    }

    /// Rejects an oversized scalar before copying or normalizing its content.
    private static func stringAttribute(_ element: AXUIElement, _ name: String, deadline: Deadline) -> String? {
        // AX has a range API for some text controls, but not for arbitrary
        // scalar attributes (notably Chrome static text). Check the length
        // immediately after the provider reply, before normalizing or copying.
        guard let raw = attribute(element, name, deadline: deadline) as? String else { return nil }
        if (raw as NSString).length > 6000 {
            deadline.cancel()
            return nil
        }
        return raw
    }

    /// Prefers a bounded AX range read and falls back only when the scalar remains bounded.
    private static func textValue(_ element: AXUIElement, remaining: Int, deadline: Deadline) -> String? {
        guard remaining > 0, !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var characterCount: CFTypeRef?
        let countError = AXUIElementCopyAttributeValue(element,
            kAXNumberOfCharactersAttribute as CFString, &characterCount)
        let reportedCount = countError == .success ? (characterCount as? NSNumber)?.intValue : nil
        // TextEdit can report a length; Safari and Firefox static text accept
        // a bounded range without one. Chrome static text currently supports
        // neither and requires the scalar fallback below.
        let requested = min(remaining, max(0, reportedCount ?? remaining))
        if requested > 0 {
            var range = CFRange(location: 0, length: requested)
            if let axRange = AXValueCreate(.cfRange, &range) {
                var value: CFTypeRef?
                if AXUIElementCopyParameterizedAttributeValue(element,
                    kAXStringForRangeParameterizedAttribute as CFString,
                    axRange, &value) == .success, !deadline.expired,
                    let text = value as? String, (text as NSString).length <= remaining {
                    return text
                }
            }
        }
        return stringAttribute(element, kAXValueAttribute as String, deadline: deadline)
    }

    /// Uses the focused window alone; background windows are outside the capture contract.
    private static func captureWindow(_ root: AXUIElement, deadline: Deadline) -> AXUIElement? {
        verifiedFocusedWindow { attribute(root, $0, deadline: deadline) }
    }

    // AXWindows contains background windows and its order does not identify the foreground source.
    /// Accepts only an AX element returned as the focused window.
    static func verifiedFocusedWindow(_ readAttribute: (String) -> CFTypeRef?) -> AXUIElement? {
        guard let focused = readAttribute(kAXFocusedWindowAttribute as String),
              CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        return (focused as! AXUIElement)
    }

    /// Captures window, focused element, tab, and web-area identity for later comparison.
    private static func sourceIdentity(root: AXUIElement, target: AXUIElement, app: Foreground,
                                       title: String?, document: String?, deadline: Deadline) -> SourceIdentity? {
        let focused = attribute(root, kAXFocusedUIElementAttribute as String, deadline: deadline)
        let focusedID = focused.flatMap { CFGetTypeID($0) == AXUIElementGetTypeID() ? CFHash($0) : nil }
        guard let content = activeContent(in: target, deadline: deadline) else { return nil }
        return SourceIdentity(pid: app.pid, window: CFHash(target), title: title, document: document,
                              focusedElement: focusedID, selectedTabs: content.tabs, webAreas: content.webAreas)
    }

    // AXUIElementCopyAttributeValue materializes an entire child array. Query its
    // count first, then request only a bounded range. An oversized array fails
    // closed because a source hidden after the range could invalidate identity.
    /// Reads a bounded AX element array without traversing an unbounded provider list.
    private static func elements(_ element: AXUIElement, _ name: String, maxCount: Int,
                                 deadline: Deadline) -> [AXUIElement]? {
        guard !deadline.expired else { return nil }
        AXUIElementSetMessagingTimeout(element, 0.25)
        return boundedElements(maxCount: maxCount, count: {
            var count: CFIndex = 0
            let error = AXUIElementGetAttributeValueCount(element, name as CFString, &count)
            if error == .attributeUnsupported || error == .noValue { return 0 }
            guard error == .success, !deadline.expired else { return nil }
            return count
        }, readRange: { requested in
            var values: CFArray?
            guard AXUIElementCopyAttributeValues(element, name as CFString, 0, requested, &values) == .success,
                  !deadline.expired, let values else { return nil }
            let array = values as [AnyObject]
            guard array.allSatisfy({ CFGetTypeID($0) == AXUIElementGetTypeID() }) else { return nil }
            return array.map { $0 as! AXUIElement }
        })
    }

    // The injected count/range seam proves that a large provider array is
    // rejected without invoking its potentially expensive range read.
    /// Rejects arrays whose provider-reported count exceeds the traversal budget.
    static func boundedElements<T>(maxCount: Int, count: () -> Int?,
                                   readRange: (Int) -> [T]?) -> [T]? {
        guard let length = count(), length >= 0, length <= maxCount else { return nil }
        guard length > 0 else { return [] }
        guard let result = readRange(length), result.count == length else { return nil }
        return result
    }

    /// Records selected tabs and active web areas for source-change detection.
    private static func activeContent(in root: AXUIElement, deadline: Deadline) -> (tabs: [CFHashCode], webAreas: [CFHashCode])? {
        var pending: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var seen = Set<CFHashCode>()
        var selected: [CFHashCode] = []
        var webAreas: [CFHashCode] = []
        while index < pending.count && index < 80 && !deadline.expired {
            let (element, depth) = pending[index]
            index += 1
            guard seen.insert(CFHash(element)).inserted else { continue }
            let role = stringAttribute(element, kAXRoleAttribute as String, deadline: deadline)
            if role == (kAXTabGroupRole as String) {
                guard let tabs = elements(element, kAXSelectedChildrenAttribute as String,
                                          maxCount: 30, deadline: deadline) else { return nil }
                selected.append(contentsOf: tabs.map(CFHash))
            }
            if role == "AXWebArea" { webAreas.append(CFHash(element)) }
            if depth < 5 {
                guard let children = elements(element, kAXChildrenAttribute as String,
                                              maxCount: min(30, 80 - pending.count), deadline: deadline) else { return nil }
                pending.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return (selected, webAreas)
    }

    typealias StringReader = (AXUIElement, String, Deadline) -> String?
    typealias MetadataReader = (AXUIElement, String, Deadline) -> (AXError, String?)
    typealias ValueReader = (AXUIElement, Int, Deadline) -> String?
    typealias ChildrenReader = (AXUIElement, Int, Deadline) -> [AXUIElement]?

    /// Reads AX role metadata without reading a sensitive field's value.
    private static func metadata(_ element: AXUIElement, _ key: String, _ deadline: Deadline) -> (AXError, String?) {
        guard !deadline.expired else { return (.cannotComplete, nil) }
        AXUIElementSetMessagingTimeout(element, 0.25)
        var raw: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, key as CFString, &raw)
        guard !deadline.expired else { return (.cannotComplete, nil) }
        return (error, raw as? String)
    }

    /// Fails closed when role or subrole cannot establish that an AX field is safe.
    static func safeRole(_ element: AXUIElement, deadline: Deadline,
                         read: MetadataReader) -> String? {
        let (roleError, role) = read(element, kAXRoleAttribute as String, deadline)
        guard roleError == .success, let role, !role.isEmpty else { return nil }
        let (subroleError, subrole) = read(element, kAXSubroleAttribute as String, deadline)
        guard subroleError == .success || subroleError == .attributeUnsupported || subroleError == .noValue else {
            return nil
        }
        if subroleError == .success && subrole == nil { return nil }
        return shouldSkip(role: role, subrole: subrole ?? "") ? nil : role
    }

    /// Traverses a bounded focused tree, skipping protected roles before value reads.
    static func extractText(from root: AXUIElement, deadline: Deadline,
                            readMetadata: MetadataReader = metadata,
                            readString: StringReader = stringAttribute,
                            readValue: ValueReader = textValue,
                            checkTrust: () -> Bool = { isTrusted() },
                            readChildren: ChildrenReader = { element, limit, deadline in
                                elements(element, kAXChildrenAttribute as String, maxCount: limit, deadline: deadline)
                            }) -> (text: String, visited: Int)? {
        var queue: [(AXUIElement, Int)] = [(root, 0)]
        var index = 0
        var visited = Set<CFHashCode>()
        var snippets: [String] = []
        var seenText = Set<String>()
        var count = 0
        var length = 0

        while index < queue.count && count < 600 && length < 6000 {
            if deadline.expired || !checkTrust() { break }
            let (element, depth) = queue[index]
            index += 1
            let identity = CFHash(element)
            guard visited.insert(identity).inserted else { continue }
            count += 1
            guard safeRole(element, deadline: deadline, read: readMetadata) != nil else { continue }

            for key in [kAXTitleAttribute as String, kAXDescriptionAttribute as String, kAXValueAttribute as String] {
                let raw = key == (kAXValueAttribute as String)
                    ? readValue(element, 6000 - length, deadline)
                    : readString(element, key, deadline)
                guard let raw else { continue }
                let snippet = normalize(raw, remaining: 6000 - length)
                if !snippet.isEmpty && seenText.insert(snippet).inserted {
                    snippets.append(snippet)
                    length += snippet.count
                }
            }
            if depth < 12 {
                guard let children = readChildren(element, min(100, 600 - queue.count), deadline) else { return nil }
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return (String(snippets.joined(separator: "\n").prefix(6000)), count)
    }

    /// Identifies secure or password roles whose content must never be requested.
    public static func shouldSkip(role: String, subrole: String) -> Bool {
        let combined = "\(role) \(subrole)".lowercased()
        return combined.contains("secure") || combined.contains("password")
    }

    /// Normalizes readable text within the remaining per-capture character budget.
    public static func normalize(_ raw: String, remaining: Int) -> String {
        guard remaining > 0 else { return "" }
        var compact = ""
        var count = 0
        var pendingSpace = false
        for character in raw {
            if character.isWhitespace {
                if !compact.isEmpty { pendingSpace = true }
                continue
            }
            if pendingSpace {
                if count == remaining { break }
                compact.append(" ")
                count += 1
                pendingSpace = false
            }
            if count == remaining { break }
            compact.append(character)
            count += 1
        }
        return compact
    }
}
