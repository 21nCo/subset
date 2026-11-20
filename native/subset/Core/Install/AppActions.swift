import Combine
import Foundation

/// What a row shows about its app's install, update or move to the Trash.
public enum AppActivity: Equatable, Sendable {
    /// Running: what it is doing, and the download's fraction when known.
    case working(String, fraction: Double?)
    case succeeded(String)
    case failed(String)
}

/// An operation waiting for the user to agree that the running app may be quit.
public struct QuitRequest: Identifiable, Equatable, Sendable {
    public enum Kind: Sendable { case update, moveToTrash }
    public var id: String { appID }
    public var appID: String
    public var appName: String
    public var kind: Kind

    public var title: String { "Quit \(appName)?" }
    public var message: String {
        switch kind {
        case .update: return "\(appName) is running. Subset asks it to quit before the new version is put in place, and opens it again afterwards."
        case .moveToTrash: return "\(appName) is running. Subset asks it to quit before moving it to the Trash."
        }
    }
}

/// The Install, Update and Move to Trash buttons of the main window: one operation per app at a time, its progress and
/// a plain message when it ends. A running app is quit only after the user agrees (`quitRequest`, then `confirmQuit`).
@MainActor
public final class AppActions: ObservableObject {
    @Published public private(set) var activities: [String: AppActivity] = [:]
    /// Set when an update or move to the Trash needs the user to agree to quit the app.
    @Published public var quitRequest: QuitRequest?

    private let installer: AppInstaller
    private let model: AppListModel
    /// Each app's operation until its row is enabled again (after the installed apps were looked for again).
    @Published private var tasks: [String: Task<Void, Never>] = [:]
    /// Each app's install, update or move to the Trash itself, which ends with its message once it has cleaned up.
    @Published private var operations: [String: Task<AppActivity, Never>] = [:]
    /// Set once Subset is quitting: no operation starts any more.
    private var closed = false
    /// How long a row waits, after its operation, for what is installed to be looked for again and shown.
    var listWait: Duration = .seconds(30)

    public init(installer: AppInstaller, model: AppListModel) {
        self.installer = installer
        self.model = model
    }

    /// Whether an operation on the app is running, or has ended and its app is being looked for again: its buttons wait.
    public func isBusy(_ appID: String) -> Bool { tasks[appID] != nil }

    /// Whether the app's install, update or move to the Trash itself still runs, so Cancel can stop it.
    public func canCancel(_ appID: String) -> Bool { operations[appID] != nil }

    public func install(_ appID: String) { start(appID, kind: nil, quitAllowed: false) }
    public func update(_ appID: String) { start(appID, kind: .update, quitAllowed: false) }
    public func moveToTrash(_ appID: String) { start(appID, kind: .moveToTrash, quitAllowed: false) }

    /// The user agreed to quit the app in `request`, the one the alert presented: its operation starts. It does not
    /// read `quitRequest`, which the alert may already have cleared when it was dismissed.
    public func confirmQuit(_ request: QuitRequest) {
        if quitRequest == request { quitRequest = nil }
        start(request.appID, kind: request.kind, quitAllowed: true)
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

    private func start(_ appID: String, kind: QuitRequest.Kind?, quitAllowed: Bool) {
        guard !closed, tasks[appID] == nil, let app = model.catalog?.apps.first(where: { $0.id == appID }) else { return }
        let copies = model.installed[appID] ?? []
        let release: ChosenRelease?
        switch kind {
        case nil: release = AppListModel.installRelease(app, showBetas: model.showBetas)
        case .update: release = AppListModel.offeredRelease(app, copies, showBetas: model.showBetas)
        case .moveToTrash: release = nil
        }
        if kind != .moveToTrash, release == nil { return }
        let installer = installer
        // When whether it runs cannot be read, the operation starts without leave to quit and refuses with that reason.
        if let kind, !quitAllowed, (try? installer.isRunning(app)) == true {
            quitRequest = QuitRequest(appID: appID, appName: app.name, kind: kind)
            return
        }
        activities[appID] = .working("Starting…", fraction: nil)
        let progress: @Sendable (InstallProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.show(appID, step, release) }
        }
        let operation = Task { () -> AppActivity in
            let message: AppActivity
            do {
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
            await self?.finish(appID, await operation.value)
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

    /// The message shows once the operation has cleaned up; the row's buttons come back once a look for what is
    /// installed, begun after the operation ended, is shown (its own, or a refresh's), so its next action sees it, or
    /// after `listWait` at most, saying the list may not show it yet (each action checks the folders again anyway). Once
    /// Subset is quitting, the row is not used again, so nothing waits for that look.
    private func finish(_ appID: String, _ message: AppActivity) async {
        operations[appID] = nil
        guard tasks[appID] != nil else { return }
        activities[appID] = message
        if !closed, !(await model.reloadInstalled(within: listWait)), activities[appID] == message {
            activities[appID] = Self.adding(Self.listPending, to: message)
        }
        tasks[appID] = nil
    }

    static let listPending = "The list of installed apps is still being read and may not show this yet."

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
