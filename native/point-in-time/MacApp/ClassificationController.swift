import AppKit
import Network
import PointInTimeCore

/// The user's classification choices, persisted in the app's defaults. Nothing is sent until a provider is chosen. The
/// OpenRouter key is not here: it lives in the Keychain.
@MainActor
final class ClassificationSettings {
    private let defaults: UserDefaults
    /// Called with true when the change is to who sends (provider or model), false for what is sent.
    var onChange: ((_ providerChanged: Bool) -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var provider: ProviderChoice {
        get { StoredSettings { [defaults] in defaults.object(forKey: $0) }.provider }
        set { defaults.set(newValue.rawValue, forKey: StoredSettings.Key.classificationProvider); onChange?(true) }
    }

    var sendWindowTitles: Bool {
        get { defaults.bool(forKey: StoredSettings.Key.sendWindowTitles) }
        set { defaults.set(newValue, forKey: StoredSettings.Key.sendWindowTitles); onChange?(false) }
    }

    var openRouterModel: String {
        get { defaults.string(forKey: StoredSettings.Key.openRouterModel) ?? OpenRouterClient.defaultModel }
        set { defaults.set(newValue, forKey: StoredSettings.Key.openRouterModel); onChange?(true) }
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
    private let pathMonitor = NWPathMonitor()
    private var connectivity = ConnectivityTracker()
    private var lastOptions: ClassificationOptions?
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
        runner = store.map {
            ClassificationRunner(store: $0, memory: {
                guard let memory else { throw ProviderError.notConfigured("Memory.md has no support folder, so nothing was sent.") }
                return try memory.read()
            }, deletionPending: deletionPending)
        }
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
        // Only the network returning resumes early; an interface, VPN, or roaming change while connected does not.
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let available = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.connectivity.update(available: available) else { return }
                self.resume()
            }
        }
        pathMonitor.start(queue: .main)
        lastOptions = options
        kick()
    }

    /// Retries now instead of waiting out the backoff, but not a provider's Retry-After unless `providerChanged`.
    func resume(providerChanged: Bool = false) {
        runner?.resume(providerChanged: providerChanged)
        kick()
    }

    /// A classification setting or the key changed: a request being set up under the old ones is not sent.
    /// `providerChanged` is true for a change of provider, model, or key.
    func settingsChanged(providerChanged: Bool) {
        generation += 1
        lastOptions = options
        resume(providerChanged: providerChanged)
    }

    /// A capture setting changed. Only a change to the excluded apps affects classification; pausing, say, does not.
    func captureSettingsChanged() {
        guard options != lastOptions else { return }
        settingsChanged(providerChanged: false)
    }

    /// Recounts pending and failed blocks without sending anything, after a correction.
    func refreshStatus() {
        runner?.refreshStatus(options: options)
    }

    func retryFailed() {
        runner?.retryFailed()
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
                let provider = currentProvider()
                guard await runner.runOnce(provider: provider, options: generation == self.generation ? options : nil),
                      provider != nil else { break }
            }
            running = false
            onChange?()
            if kickAgain { kick() }
        }
    }

    /// The configured provider, nil when none is chosen.
    func currentProvider() -> (any ClassificationProvider)? {
        switch settings.provider {
        case .off: return nil
        case .openRouter:
            // The key is read only when a batch is sent, not on every tick.
            return OpenRouterClient(keychain: .openRouterKey, model: settings.openRouterModel)
        }
    }
}
