import Combine
import Foundation

/// What a row shows about its app's install, update or move to the Trash.
public enum AppActivity: Equatable, Sendable {
    /// Running: what it is doing, and the download's fraction when known.
    case working(String, fraction: Double?)
    case succeeded(String)
    case failed(String)
}

/// An operation waiting for the user to agree that the running app may be quit. The answer holds only for the app it
/// names (`appName`, `bundleID`, and `bundleName`, the `<bundleName>.app` it is installed as): when the row then lists
/// another app, or the same one under another bundle name, nothing is quit.
///
/// Each request is one question (`id`), and two requests are equal only when they are the same question: a row asked
/// again gets another one, so a late answer to the earlier question never clears it.
public struct QuitRequest: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case update, moveToTrash }
    public let id = UUID()
    public var appID: String
    public var appName: String
    public var bundleID: String
    public var bundleName: String
    public var kind: Kind

    init(appID: String, _ app: CatalogApp, kind: Kind) {
        self.appID = appID
        appName = app.name
        bundleID = app.bundleID
        bundleName = app.appName
        self.kind = kind
    }

    public static func == (lhs: QuitRequest, rhs: QuitRequest) -> Bool { lhs.id == rhs.id }

    /// Whether `app` is the app this request named.
    func names(_ app: CatalogApp) -> Bool { app.name == appName && app.bundleID == bundleID && app.appName == bundleName }

    /// Whether this asks to quit `app`, shown in row `appID`, for `kind`.
    func asks(_ appID: String, _ app: CatalogApp, kind: Kind) -> Bool { self.appID == appID && names(app) && self.kind == kind }

    public var title: String { "Quit \(appName)?" }
    public var message: String {
        switch kind {
        case .update: return "\(appName) is running. Subset asks it to quit before the new version is put in place; open it again once the update ends."
        case .moveToTrash: return "\(appName) is running. Subset asks it to quit before moving it to the Trash."
        }
    }
}

/// The Install, Update and Move to Trash buttons of the main window: one operation per app at a time, its progress and
/// a plain message when it ends. A running app is quit only after the user agrees (`quitRequest`, then `confirmQuit`).
@MainActor
public final class AppActions: ObservableObject {
    @Published public private(set) var activities: [String: AppActivity] = [:]
    /// Set when an update or move to the Trash needs the user to agree to quit the app. It is cleared by an answer to
    /// that very request (`confirmQuit`, `dismissQuit`), so an alert that reports its answer twice clears it once, or
    /// withdrawn, with a message on its row, once the list no longer offers that action for that app.
    @Published public private(set) var quitRequest: QuitRequest? {
        didSet { if let quitRequest { answerable[quitRequest.appID] = quitRequest.id } }
    }
    /// The question last presented for each row, which its Quit button may still confirm (its alert's binding can clear
    /// `quitRequest` first): not once it is confirmed or withdrawn, nor once the row has been asked again or started
    /// another operation.
    private var answerable: [String: UUID] = [:]
    /// What the window says about a row the list no longer shows (whose question was withdrawn or no longer applies).
    @Published public private(set) var notice: String?
    /// Requests of other rows that came while one was presented, in the order they came; the next one the list still
    /// offers is presented on a later turn of the main actor once the presented one is answered, after its alert has gone.
    private var waitingRequests: [QuitRequest] = []
    /// Each row's read of whether its app runs, one at a time per row and `maxRunningReads` at most across rows: an
    /// attempt for the same app made while it is held up waits for it too.
    private var runningReads: [String: (app: String, read: RunningRead)] = [:]
    static let maxRunningReads = 4
    private var revalidationScheduled = false

    private let installer: AppInstaller
    private let model: AppListModel
    /// Each app's operation until its row is enabled again (after the installed apps were looked for again).
    @Published private var tasks: [String: Task<Void, Never>] = [:]
    /// Each app's install, update or move to the Trash itself, which ends with its message once it has cleaned up, or
    /// with nil when the app runs and the user is to be asked first.
    @Published private var operations: [String: Task<AppActivity?, Never>] = [:]
    /// Set once Subset is quitting: no operation starts any more.
    private var closed = false
    /// How long after its operation a row still waiting for what is installed to be looked for again says so.
    var listNoteDelay: Duration = .seconds(10)

    /// Forwards the model's changes: whether a row is busy also depends on what the model knows of its app.
    private var modelChanges: AnyCancellable?

    public init(installer: AppInstaller, model: AppListModel) {
        self.installer = installer
        self.model = model
        modelChanges = model.objectWillChange.sink { [weak self] _ in
            guard let self else { return }
            self.objectWillChange.send()
            MainActor.assumeIsolated { self.scheduleRevalidation() }
        }
    }

    /// Whether an operation on the app is running, or has ended and its app is being looked for again, or what is
    /// installed of it is not known yet (its look is held up): its buttons wait.
    public func isBusy(_ appID: String) -> Bool { tasks[appID] != nil || !model.knowsInstalled(appID) }

    /// Whether the app's install, update or move to the Trash itself still runs, so Cancel can stop it.
    public func canCancel(_ appID: String) -> Bool { operations[appID] != nil }

    public func install(_ appID: String) { start(appID, kind: nil) }
    public func update(_ appID: String) { start(appID, kind: .update) }
    public func moveToTrash(_ appID: String) { start(appID, kind: .moveToTrash) }

    /// The user agreed to quit the app in `request`, the one the alert presented: its operation starts, only while it is
    /// the row's question still to be answered (see `answerable`) and the row still lists that app (its bundle ID and
    /// name) and offers that action. Otherwise nothing is quit or changed and the row, or the window's notice once the row
    /// is gone, says why; a question since asked of the row, or its running operation, stays as it is. It does not read
    /// `quitRequest`, which the alert may already have cleared when it was dismissed. Once Subset is quitting, it does
    /// nothing.
    public func confirmQuit(_ request: QuitRequest) {
        let appID = request.appID
        let current = answerable[appID] == request.id
        dismissQuit(request)
        if current { answerable[appID] = nil }
        guard !closed else { return }
        guard current, tasks[appID] == nil, isValid(request) else {
            // The row's own state (an operation, or a question asked since) says what holds now.
            guard tasks[appID] == nil, quitRequest?.appID != appID, !waitingRequests.contains(where: { $0.appID == appID }) else { return }
            tell(request, "Nothing was quit or changed: the list changed while Subset asked to quit \(request.appName), so that answer no longer applies. Try again.")
            return
        }
        guard model.knowsInstalled(appID) else {
            activities[appID] = .failed("Nothing was quit or changed: the list of installed apps was still being read when \(request.appName) was to be quit. Try again once it shows \(request.appName).")
            return
        }
        start(appID, kind: request.kind, consent: request)
    }

    /// The user declined `request`, or its alert went away: it is no longer presented and nothing is quit. Only the
    /// request presented is cleared (any other, such as the next one already presented, stays), so this is safe to call
    /// more than once for one alert.
    public func dismissQuit(_ request: QuitRequest) {
        guard quitRequest == request else { return }
        quitRequest = nil
        scheduleNextQuestion()
    }

    private func scheduleNextQuestion() {
        guard !waitingRequests.isEmpty else { return }
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.presentNextQuestion()
        }
    }

    /// Presents the first waiting request the list still offers; those it no longer offers are withdrawn on the way.
    private func presentNextQuestion() {
        guard !closed, quitRequest == nil else { return }
        while !waitingRequests.isEmpty {
            let next = waitingRequests.removeFirst()
            guard isValid(next), tasks[next.appID] == nil else {
                withdraw(next)
                continue
            }
            quitRequest = next
            return
        }
    }

    /// Whether the list still shows `request`'s row with the app it names and still offers its action there: an update
    /// to offer, or a copy to move to the Trash.
    private func isValid(_ request: QuitRequest) -> Bool {
        guard let app = model.catalog?.apps.first(where: { $0.id == request.appID }), request.names(app) else { return false }
        let copies = model.installed[request.appID] ?? []
        switch request.kind {
        case .update: return AppListModel.offeredRelease(app, copies, showBetas: model.showBetas) != nil
        case .moveToTrash: return !copies.isEmpty
        }
    }

    /// `request` is not asked (any more), and cannot be confirmed: its row, unless it runs another operation, says
    /// nothing was quit or changed.
    private func withdraw(_ request: QuitRequest) {
        if answerable[request.appID] == request.id { answerable[request.appID] = nil }
        guard tasks[request.appID] == nil else { return }
        tell(request, "Nothing was quit or changed: the list changed before Subset could quit \(request.appName), so it no longer asks. Try again.")
    }

    /// Shows `text` on `request`'s row, or, once the list no longer shows that row, as the window's notice.
    private func tell(_ request: QuitRequest, _ text: String) {
        if model.catalog?.apps.contains(where: { $0.id == request.appID }) == true {
            activities[request.appID] = .failed(text)
        } else {
            notice = "\(text) (\(request.appName) is no longer listed.)"
        }
    }

    /// Hides the window's notice.
    public func dismissNotice() { notice = nil }

    /// Once the model has changed (on a later turn of the main actor, as its change is announced before it is made),
    /// withdraws the requests waiting or presented that the list no longer offers.
    private func scheduleRevalidation() {
        guard !revalidationScheduled, quitRequest != nil || !waitingRequests.isEmpty else { return }
        revalidationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.revalidationScheduled = false
            for request in self.waitingRequests where !self.isValid(request) { self.withdraw(request) }
            self.waitingRequests.removeAll { !self.isValid($0) }
            if let presented = self.quitRequest, !self.isValid(presented) {
                self.withdraw(presented)
                self.quitRequest = nil
                self.scheduleNextQuestion()
            }
        }
    }

    /// Stops a running operation; its message then says what it had already changed, if anything.
    public func cancel(_ appID: String) { operations[appID]?.cancel() }

    /// Hides a finished operation's message.
    public func dismiss(_ appID: String) {
        if operations[appID] == nil { activities[appID] = nil }
    }

    /// Whether any install, update or move to the Trash is running.
    public var isWorking: Bool { !operations.isEmpty }

    /// Stops new operations (and drops a pending quit question), cancels every running one and waits until each has
    /// cleaned up (when Subset quits): before its last step nothing is changed, and after it the app is in place. It does
    /// not wait for the installed apps to be looked for again, which a stalled folder could hold up.
    public func cancelAll() async {
        closed = true
        waitingRequests = []
        quitRequest = nil
        let running = operations
        for operation in running.values { operation.cancel() }
        for (appID, operation) in running {
            let message = await operation.value
            operations[appID] = nil
            tasks[appID] = nil
            activities[appID] = message
        }
    }

    /// Waits for the app's running operation, if any (tests).
    public func wait(_ appID: String) async { await tasks[appID]?.value }

    /// Starts the app's operation. An update or move to the Trash without the user's `consent` (which `confirmQuit` has
    /// checked against the row) first reads, off the main actor and cancellably, whether the app runs; when it does, the
    /// row is freed and the user is asked (`quitRequest`).
    private func start(_ appID: String, kind: QuitRequest.Kind?, consent: QuitRequest? = nil) {
        guard !closed, !isBusy(appID), let app = model.catalog?.apps.first(where: { $0.id == appID }) else { return }
        let quitAllowed = consent != nil
        let copies = model.installed[appID] ?? []
        let release: ChosenRelease?
        switch kind {
        case nil: release = AppListModel.installRelease(app, showBetas: model.showBetas)
        case .update: release = AppListModel.offeredRelease(app, copies, showBetas: model.showBetas)
        case .moveToTrash: release = nil
        }
        if kind != .moveToTrash, release == nil { return }
        let installer = installer
        let check = kind != nil && !quitAllowed
        let read = check ? runningRead(app) : nil
        if check, read == nil {
            activities[appID] = .failed("\(Self.notDone(kind, app, release, partly: false)): Subset is still waiting for an earlier check of which apps are running, which is held up. Nothing was quit or changed; try again in a moment.")
            return
        }
        // A question this row still had waiting or presented is for an attempt this one replaces.
        answerable[appID] = nil
        waitingRequests.removeAll { $0.appID == appID }
        if quitRequest?.appID == appID {
            quitRequest = nil
            scheduleNextQuestion()
        }
        activities[appID] = .working(check ? "Checking whether \(app.name) is running…" : "Starting…", fraction: nil)
        let progress: @Sendable (InstallProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.show(appID, step, release) }
        }
        let operation = Task { () -> AppActivity? in
            let message: AppActivity
            do {
                // When whether it runs cannot be read, the operation starts without leave to quit and refuses with that
                // reason.
                if let read, try await read.value(cancelled: Self.cancelledCheck) {
                    // Cancel pressed once the answer was in still ends the attempt: nothing is asked.
                    if Task.isCancelled { throw Self.cancelledCheck }
                    return nil
                }
                switch kind {
                case nil:
                    let outcome = try await installer.install(app, release!, progress: progress)
                    let folder = outcome.path.map { ($0 as NSString).deletingLastPathComponent } ?? ""
                    message = .succeeded(Self.join("Installed \(release!.label) in \(folder).", outcome.notes))
                case .update:
                    let outcome = try await installer.update(app, release!, quitAllowed: quitAllowed, progress: progress)
                    message = .succeeded(Self.join("Updated to \(release!.label).", outcome.notes))
                case .moveToTrash:
                    let outcome = try await installer.moveToTrash(app, quitAllowed: quitAllowed, progress: progress)
                    message = .succeeded(Self.join("Moved to the Trash.", outcome.notes))
                }
            } catch {
                let failure = error as? InstallFailure ?? InstallFailure(.install, error.localizedDescription)
                // What was already changed is said, not reported as nothing done; what an interrupted operation had
                // left and was put back is said in the notes, and the update or move itself did not run.
                let partly = failure.partial && !failure.onlyRecovered
                message = .failed(Self.join("\(Self.notDone(kind, app, release, partly: partly)): \(failure.explanation).", failure.notes))
            }
            return message
        }
        operations[appID] = operation
        tasks[appID] = Task { [weak self] in
            if let message = await operation.value {
                await self?.finish(appID, message)
            } else if let kind {
                // The app runs. Cancel pressed after the attempt ended, before this, still asks nothing.
                let cancelled = AppActivity.failed("\(Self.notDone(kind, app, release, partly: false)): \(Self.cancelledCheck.explanation).")
                self?.endCheck(appID, asking: operation.isCancelled ? nil : QuitRequest(appID: appID, app, kind: kind),
                               message: operation.isCancelled ? cancelled : nil)
            }
        }
    }

    fileprivate nonisolated static let cancelledCheck = InstallFailure(.interrupted, "it was cancelled before anything was changed")

    /// What a row says an operation did not do (or did only partly).
    private nonisolated static func notDone(_ kind: QuitRequest.Kind?, _ app: CatalogApp, _ release: ChosenRelease?, partly: Bool) -> String {
        switch kind {
        case nil: return "\(app.name) was not installed"
        case .update: return "\(app.name) was \(partly ? "only partly" : "not") updated to \(release?.label ?? "")"
        case .moveToTrash: return "\(app.name) was \(partly ? "only partly" : "not") moved to the Trash"
        }
    }

    /// The read of whether the app runs ended the attempt with nothing changed: its row is free again and shows
    /// `message`, and the user is asked `request` (unless Subset is quitting). One question at a time: another row's
    /// waits its turn, and a row asked again replaces its own question.
    private func endCheck(_ appID: String, asking request: QuitRequest?, message: AppActivity?) {
        operations[appID] = nil
        guard tasks[appID] != nil else { return }
        tasks[appID] = nil
        activities[appID] = message
        guard let request, !closed else { return }
        waitingRequests.removeAll { $0.appID == appID }
        // The list changed while the read ran: what it would ask is no longer offered for that app.
        guard isValid(request) else { return withdraw(request) }
        if quitRequest == nil || quitRequest?.appID == appID {
            quitRequest = request
        } else {
            waitingRequests.append(request)
        }
    }

    /// The read of whether some installed copy of `app` runs, on a thread of its own so a stalled folder or process list
    /// never holds up the window: at most one at a time per row and `maxRunningReads` across rows, as a read cannot be
    /// stopped and ends on its own. An attempt made while an earlier one's read of the same app is held up waits for that
    /// read (a cancel ends the wait at once, and the read answers only attempts still waiting); nil when the row's read is
    /// of another app (the list changed since) or too many are held up, so the attempt is refused. An answer that cannot
    /// be read is false: the operation then starts without leave to quit and refuses with that reason.
    private func runningRead(_ app: CatalogApp) -> RunningRead? {
        runningReads = runningReads.filter { !$0.value.read.isAnswered }
        let key = [app.id, app.bundleID, app.appName].joined(separator: "\n")
        if let held = runningReads[app.id] { return held.app == key ? held.read : nil }
        guard runningReads.count < Self.maxRunningReads else { return nil }
        let read = RunningRead()
        runningReads[app.id] = (key, read)
        let installer = installer
        DispatchQueue.global(qos: .userInitiated).async {
            read.give((try? installer.isRunning(app)) == true)
        }
        return read
    }

    private func show(_ appID: String, _ step: InstallProgress, _ release: ChosenRelease?) {
        guard operations[appID] != nil else { return }
        switch step {
        case let .downloading(received, total):
            let fraction = total.map { Double(received) / Double(max($0, 1)) }
            activities[appID] = .working("Downloading \(release?.label ?? "")…", fraction: fraction.map { min($0, 1) })
        case .verifying: activities[appID] = .working("Verifying…", fraction: nil)
        case .quitting: activities[appID] = .working("Quitting…", fraction: nil)
        case .installing: activities[appID] = .working("Installing…", fraction: nil)
        case .movingToTrash: activities[appID] = .working("Moving to the Trash…", fraction: nil)
        }
    }

    /// The message shows once the operation has cleaned up; the row's buttons come back only once a look for what is
    /// installed, begun after the operation ended, is published (its own, or a refresh's), so its next action is chosen
    /// from what the operation left, never from the state before it. A look that takes longer than `listNoteDelay` adds
    /// a note saying so while the row waits, removed when it ends. Once Subset is quitting, the row is not used again, so
    /// nothing waits for that look.
    private func finish(_ appID: String, _ message: AppActivity) async {
        operations[appID] = nil
        guard tasks[appID] != nil else { return }
        activities[appID] = message
        if !closed {
            let pending = Self.adding(Self.listPending, to: message)
            let delay = listNoteDelay
            let note = Task { [weak self] in
                try? await Task.sleep(for: delay)
                guard !Task.isCancelled, let self, self.activities[appID] == message else { return }
                self.activities[appID] = pending
            }
            await model.reloadInstalled()
            note.cancel()
            if activities[appID] == pending { activities[appID] = message }
        }
        tasks[appID] = nil
    }

    static let listPending = "The list of installed apps is still being read; this row's buttons come back once it shows this."

    private nonisolated static func adding(_ note: String, to message: AppActivity) -> AppActivity {
        switch message {
        case let .succeeded(text): return .succeeded(join(text, [note]))
        case let .failed(text): return .failed(join(text, [note]))
        case .working: return message
        }
    }

    private nonisolated static func join(_ first: String, _ notes: [String]) -> String {
        ([first] + notes).joined(separator: " ")
    }
}

/// One read of whether an app runs, and the attempts waiting for its answer, each resumed exactly once: with the
/// answer, or at once with `cancelled` when its task is cancelled first.
private final class RunningRead: @unchecked Sendable {
    private let lock = NSLock()
    private var answer: Bool?
    private var waiting: [Int: CheckedContinuation<Bool, any Error>] = [:]
    private var attempts = 0

    var isAnswered: Bool { lock.withLock { answer != nil } }

    /// Gives the answer to every attempt waiting, and to any that waits later.
    func give(_ value: Bool) {
        let waiters = lock.withLock { () -> [CheckedContinuation<Bool, any Error>] in
            answer = value
            defer { waiting = [:] }
            return Array(waiting.values)
        }
        for waiter in waiters { waiter.resume(returning: value) }
    }

    func value(cancelled: InstallFailure) async throws -> Bool {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                if let answer {
                    lock.unlock()
                    return continuation.resume(returning: answer)
                }
                // Cancelled before it waits: the cancel handler, which runs after the task is marked, found nothing.
                if Task.isCancelled {
                    lock.unlock()
                    return continuation.resume(throwing: cancelled)
                }
                waiting[attempt] = continuation
                lock.unlock()
            }
        } onCancel: {
            let waiter = lock.withLock { waiting.removeValue(forKey: attempt) }
            waiter?.resume(throwing: cancelled)
        }
    }
}
