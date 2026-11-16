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
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(installer: AppInstaller, model: AppListModel) {
        self.installer = installer
        self.model = model
    }

    /// Whether an operation on the app is running.
    public func isBusy(_ appID: String) -> Bool { tasks[appID] != nil }

    public func install(_ appID: String) { start(appID, kind: nil, quitAllowed: false) }
    public func update(_ appID: String) { start(appID, kind: .update, quitAllowed: false) }
    public func moveToTrash(_ appID: String) { start(appID, kind: .moveToTrash, quitAllowed: false) }

    /// The user agreed to quit the app: the waiting operation starts.
    public func confirmQuit() {
        guard let request = quitRequest else { return }
        quitRequest = nil
        start(request.appID, kind: request.kind, quitAllowed: true)
    }

    /// Stops a running operation; before its last step nothing is changed.
    public func cancel(_ appID: String) { tasks[appID]?.cancel() }

    /// Hides a finished operation's message.
    public func dismiss(_ appID: String) {
        if tasks[appID] == nil { activities[appID] = nil }
    }

    /// Whether any operation is running.
    public var isWorking: Bool { !tasks.isEmpty }

    /// Cancels every running operation and waits until each has cleaned up (when Subset quits): before its last step
    /// nothing is changed, and after it the app is in place.
    public func cancelAll() async {
        let running = Array(tasks.values)
        for task in running { task.cancel() }
        for task in running { await task.value }
    }

    /// Waits for the app's running operation, if any (tests).
    public func wait(_ appID: String) async { await tasks[appID]?.value }

    private func start(_ appID: String, kind: QuitRequest.Kind?, quitAllowed: Bool) {
        guard tasks[appID] == nil, let app = model.catalog?.apps.first(where: { $0.id == appID }) else { return }
        let copies = model.installed[appID] ?? []
        let release: ChosenRelease?
        switch kind {
        case nil: release = AppListModel.installRelease(app, showBetas: model.showBetas)
        case .update: release = AppListModel.offeredRelease(app, copies, showBetas: model.showBetas)
        case .moveToTrash: release = nil
        }
        if kind != .moveToTrash, release == nil { return }
        let installer = installer
        if let kind, !quitAllowed, installer.isRunning(app) {
            quitRequest = QuitRequest(appID: appID, appName: app.name, kind: kind)
            return
        }
        activities[appID] = .working("Starting…", fraction: nil)
        let progress: @Sendable (InstallProgress) -> Void = { [weak self] step in
            Task { @MainActor in self?.show(appID, step, release) }
        }
        tasks[appID] = Task { [weak self] in
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
                let what: String
                switch kind {
                case nil: what = "\(app.name) was not installed"
                case .update: what = "\(app.name) was not updated to \(release!.label)"
                case .moveToTrash: what = "\(app.name) was not moved to the Trash"
                }
                message = .failed("\(what): \(failure.explanation).")
            }
            await self?.finish(appID, message)
        }
    }

    private func show(_ appID: String, _ step: InstallProgress, _ release: ChosenRelease?) {
        guard tasks[appID] != nil else { return }
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

    private func finish(_ appID: String, _ message: AppActivity) async {
        tasks[appID] = nil
        activities[appID] = message
        await model.reloadInstalled()
    }

    private nonisolated static func join(_ first: String, _ notes: [String]) -> String {
        ([first] + notes).joined(separator: " ")
    }
}
