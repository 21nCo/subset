import AppKit
import Network
import PointInTimeCore

enum ProviderChoice: String, CaseIterable {
    case off, codex, openRouter
}

/// The user's classification choices, persisted in the app's defaults. Nothing is sent until a provider is chosen. The
/// OpenRouter key is not here: it lives in the Keychain.
@MainActor
final class ClassificationSettings {
    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var provider: ProviderChoice {
        get { defaults.string(forKey: "classificationProvider").flatMap(ProviderChoice.init) ?? .off }
        set { defaults.set(newValue.rawValue, forKey: "classificationProvider"); onChange?() }
    }

    var sendWindowTitles: Bool {
        get { defaults.bool(forKey: "sendWindowTitles") }
        set { defaults.set(newValue, forKey: "sendWindowTitles"); onChange?() }
    }

    /// A `codex` binary the user chose; nil means the one found through the login shell's `PATH`.
    var codexPath: String? {
        get { defaults.string(forKey: "codexPath") }
        set { defaults.set(newValue, forKey: "codexPath"); onChange?() }
    }

    var openRouterModel: String {
        get { defaults.string(forKey: "openRouterModel") ?? OpenRouterClient.defaultModel }
        set { defaults.set(newValue, forKey: "openRouterModel"); onChange?() }
    }
}

/// Runs the classification queue: every minute, after a wake, when the network returns, and when settings change.
@MainActor
final class ClassificationController {
    static let interval: TimeInterval = 60

    let settings: ClassificationSettings
    let memory: MemoryProfile?
    private let capture: CaptureSettings
    private let store: ActivityStore?
    private let runner: ClassificationRunner?
    private var running = false
    private var kickAgain = false
    /// Changes with every classification setting, excluded app, or key change; a request is sent only under the
    /// generation its provider was set up with.
    private var generation = 0
    private var timer: Timer?
    private var loginPATH: String?
    private let pathMonitor = NWPathMonitor()
    private var wakeObserver: NSObjectProtocol?
    var onChange: (() -> Void)?

    var status: ClassificationStatus { runner?.status ?? ClassificationStatus() }

    /// `deletionPending` reports a deletion or idle retraction capture has queued but not applied; nothing is sent meanwhile.
    init(settings: ClassificationSettings, capture: CaptureSettings, store: ActivityStore?, deletionPending: @escaping @MainActor () -> Bool) {
        self.settings = settings
        self.capture = capture
        self.store = store
        let memory = (try? ActivityStore.defaultDirectory()).map(MemoryProfile.init(directory:))
        self.memory = memory
        runner = store.map { ClassificationRunner(store: $0, memory: { memory?.read() ?? "" }, deletionPending: deletionPending) }
    }

    var options: ClassificationOptions {
        ClassificationOptions(includeWindowTitles: settings.sendWindowTitles, excludedBundleIDs: Set(capture.excludedApps.keys))
    }

    func start() {
        runner?.onChange = { [weak self] in self?.onChange?() }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            // A tick during a run is dropped; only a wake, the network, or a settings change queues another run.
            MainActor.assumeIsolated { if self?.running == false { self?.kick() } }
        }
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.resume() }
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard path.status == .satisfied else { return }
            Task { @MainActor in self?.resume() }
        }
        pathMonitor.start(queue: .main)
        kick()
    }

    /// Retries now instead of waiting out the backoff.
    func resume() {
        runner?.resume()
        kick()
    }

    /// A setting, the excluded apps, or the key changed: a request being set up under the old ones is not sent.
    func settingsChanged() {
        generation += 1
        resume()
    }

    func retryFailed() {
        try? store?.requeueFailed()
        resume()
    }

    /// Sends batches until none is left, a request fails, or the provider is turned off. A kick during a run starts
    /// another run when it ends, so a settings change is never missed.
    func kick() {
        guard let runner else { return }
        guard !running else { kickAgain = true; return }
        running = true
        kickAgain = false
        Task {
            while true {
                let generation = self.generation
                let provider = await currentProvider()
                guard await runner.runOnce(provider: provider, options: generation == self.generation ? options : nil),
                      provider != nil else { break }
            }
            running = false
            onChange?()
            if kickAgain { kick() }
        }
    }

    /// The configured provider, nil when none is chosen. One that cannot be set up fails every request with the reason,
    /// so the queue backs off and the settings window shows it.
    func currentProvider() async -> (any ClassificationProvider)? {
        switch settings.provider {
        case .off: return nil
        case .codex:
            return await codex() ?? Unavailable(reason: "No codex binary was found in the login shell’s PATH. Choose one in Classification settings.")
        case .openRouter:
            guard let key = try? KeychainSecret.openRouterKey.read(), !key.isEmpty else {
                return Unavailable(reason: "No OpenRouter key is saved in the Keychain.")
            }
            return OpenRouterClient(key: key, model: settings.openRouterModel)
        }
    }

    /// `refresh` probes the login shell's `PATH` again (Check Again); a failed probe is retried on the next call.
    func codex(refresh: Bool = false) async -> CodexCLI? {
        if loginPATH == nil || refresh { loginPATH = await CodexCLI.loginShellPATH() }
        let path = loginPATH
        let executable = settings.codexPath.map { URL(fileURLWithPath: $0) } ?? path.flatMap(CodexCLI.locate(in:))
        return executable.map { CodexCLI(executable: $0, searchPath: path) }
    }
}

private struct Unavailable: ClassificationProvider {
    let name = "unavailable"
    let model = ""
    let reason: String

    func complete(prompt: String, schema: String) async throws -> String {
        throw ProviderError.notConfigured(reason)
    }
}
