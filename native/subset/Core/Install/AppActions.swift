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
public struct QuitRequest: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case update, moveToTrash }
    public var id: String { appID }
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

    /// Whether `app` is the app this request named.
    func names(_ app: CatalogApp) -> Bool { app.name == appName && app.bundleID == bundleID && app.appName == bundleName }

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
    /// Set when an update or move to the Trash needs the user to agree to quit the app. Once it is cleared (answered or
    /// dismissed), the next waiting request is presented.
    @Published public var quitRequest: QuitRequest? {
        didSet { if quitRequest == nil, !waitingRequests.isEmpty { quitRequest = waitingRequests.removeFirst() } }
    }
    /// Requests of other rows that came while one was presented, in the order they came.
    private var waitingRequests: [QuitRequest] = []

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
        modelChanges = model.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    /// Whether an operation on the app is running, or has ended and its app is being looked for again, or what is
    /// installed of it is not known yet (its look is held up): its buttons wait.
    public func isBusy(_ appID: String) -> Bool { tasks[appID] != nil || !model.knowsInstalled(appID) }

    /// Whether the app's install, update or move to the Trash itself still runs, so Cancel can stop it.
    public func canCancel(_ appID: String) -> Bool { operations[appID] != nil }

    public func install(_ appID: String) { start(appID, kind: nil) }
    public func update(_ appID: String) { start(appID, kind: .update) }
    public func moveToTrash(_ appID: String) { start(appID, kind: .moveToTrash) }

    /// The user agreed to quit the app in `request`, the one the alert presented: its operation starts, only while the
    /// row still lists that app (its bundle ID and name). It does not read `quitRequest`, which the alert may already
    /// have cleared when it was dismissed.
    public func confirmQuit(_ request: QuitRequest) {
        if quitRequest == request { quitRequest = nil }
        start(request.appID, kind: request.kind, consent: request)
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

    /// Starts the app's operation. An update or move to the Trash without the user's `consent` first reads, off the main
    /// actor and cancellably, whether the app runs; when it does, the row is freed and the user is asked (`quitRequest`).
    private func start(_ appID: String, kind: QuitRequest.Kind?, consent: QuitRequest? = nil) {
        guard !closed, !isBusy(appID), let app = model.catalog?.apps.first(where: { $0.id == appID }) else { return }
        // The answer was given for the app the alert named; a row that now lists another app quits nothing.
        if let consent, !consent.names(app) {
            activities[appID] = .failed("Nothing was quit or changed: the list changed while Subset asked to quit \(consent.appName), so that answer no longer applies. Try again.")
            return
        }
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
        activities[appID] = .working(check ? "Checking whether \(app.name) is running…" : "Starting…", fraction: nil)
        let progress: @Sendable (InstallProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.show(appID, step, release) }
        }
        let operation = Task { () -> AppActivity? in
            let message: AppActivity
            do {
                // When whether it runs cannot be read, the operation starts without leave to quit and refuses with that
                // reason.
                if check, try await Self.isRunning(installer, app) { return nil }
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
                let what: String
                switch kind {
                case nil: what = "\(app.name) was not installed"
                case .update: what = "\(app.name) was \(partly ? "only partly" : "not") updated to \(release!.label)"
                case .moveToTrash: what = "\(app.name) was \(partly ? "only partly" : "not") moved to the Trash"
                }
                message = .failed(Self.join("\(what): \(failure.explanation).", failure.notes))
            }
            return message
        }
        operations[appID] = operation
        tasks[appID] = Task { [weak self] in
            guard let message = await operation.value else {
                if let kind { self?.ask(appID, app, kind) }
                return
            }
            await self?.finish(appID, message)
        }
    }

    /// The app runs and the user has not agreed to quit it: its row is free again, nothing was changed, and the user is
    /// asked (unless Subset is quitting).
    private func ask(_ appID: String, _ app: CatalogApp, _ kind: QuitRequest.Kind) {
        operations[appID] = nil
        guard tasks[appID] != nil else { return }
        tasks[appID] = nil
        activities[appID] = nil
        guard !closed else { return }
        let request = QuitRequest(appID: appID, app, kind: kind)
        // One question at a time: another row's waits its turn, and a row asked again replaces its own waiting one.
        if quitRequest == nil {
            quitRequest = request
        } else if quitRequest?.appID != appID {
            waitingRequests.removeAll { $0.appID == appID }
            waitingRequests.append(request)
        } else {
            quitRequest = request
        }
    }

    /// Whether some installed copy of `app` runs, read on a thread of its own so a stalled folder or process list never
    /// holds up the window. A cancel ends the wait at once (the read, which cannot be stopped, ends on its own). An answer
    /// that cannot be read is false: the operation then starts without leave to quit and refuses with that reason.
    private nonisolated static func isRunning(_ installer: AppInstaller, _ app: CatalogApp) async throws -> Bool {
        let answer = OneAnswer()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard answer.wait(continuation) else { return }
                DispatchQueue.global(qos: .userInitiated).async {
                    answer.give(.success((try? installer.isRunning(app)) == true))
                }
            }
        } onCancel: {
            answer.give(.failure(InstallFailure(.interrupted, "it was cancelled before anything was changed")))
        }
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

/// The first of a read's answer or a cancel, given to one waiting continuation exactly once.
private final class OneAnswer: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, any Error>?
    private var result: Result<Bool, any Error>?

    /// Waits with `continuation`; returns false when the answer is already known (it is then resumed at once).
    func wait(_ continuation: CheckedContinuation<Bool, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
            return false
        }
        self.continuation = continuation
        lock.unlock()
        return true
    }

    /// Gives the answer; any later one is dropped.
    func give(_ answer: Result<Bool, any Error>) {
        lock.lock()
        guard result == nil else { return lock.unlock() }
        result = answer
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: answer)
    }
}
