import Combine
import Foundation

/// One feed app as the main window lists it.
public struct AppRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var summary: String
    public var appName: String
    /// The installed copies, in /Applications then ~/Applications; empty when it is not installed.
    public var installed: [InstalledCopy]
    /// The newest live version, or nil when the app has no live release.
    public var live: String?
    /// The newest beta (0.1.1-beta.4), or nil when betas are not shown or the app has none.
    public var beta: String?
    /// The release the Update available badge offers (0.1.1, or 0.1.1-beta.4 with betas shown), or nil for no badge.
    public var update: String?
    /// The release Install puts in place (the newest live release, or with betas shown the newer of it and the beta), or
    /// nil when there is none to install.
    public var install: String?

    public var updateAvailable: Bool { update != nil }
}

/// Where the catalog the window shows stands.
public enum CatalogStatus: Equatable, Sendable {
    /// The first load has not finished.
    case loading
    /// The catalog was fetched, or cached less than 5 minutes ago.
    case current
    /// The feed could not be fetched; a copy cached less than 7 days ago is shown, with this warning.
    case offline(String)
    /// The catalog cannot be loaded, for this reason. A catalog loaded earlier stays shown while it is younger than
    /// 7 days.
    case failed(String)
}

/// The main window's and the menu's view of the catalog: every feed app with what is installed, the newest live
/// release, the newest beta when **Show betas** is on, and whether an update is available. It refreshes when the app
/// launches, when the window opens and every 6 hours; a refresh within 5 minutes of a fetch uses the cache.
@MainActor
public final class AppListModel: ObservableObject {
    public static let showBetasKey = "ShowBetas"
    public static let refreshInterval: Duration = .seconds(6 * 60 * 60)

    @Published public private(set) var catalog: Catalog?
    @Published public private(set) var fetchedAt: Date?
    @Published public private(set) var installed: [String: [InstalledCopy]] = [:]
    @Published public private(set) var status: CatalogStatus = .loading
    @Published public private(set) var isRefreshing = false
    /// Whether betas are listed and offered; off unless the user turns it on, and remembered.
    @Published public var showBetas: Bool {
        didSet { defaults.set(showBetas, forKey: Self.showBetasKey) }
    }

    private let loader: any CatalogLoading
    private let finder: any InstalledAppDetecting
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private var refreshLoop: Task<Void, Never>?
    /// Looks for installed apps run one at a time, each on a thread of its own from Dispatch, never Swift's shared pool
    /// (which a stalled folder would hold). Looks asked for while one runs are merged into one look, begun once it ends,
    /// of every description of an app asked for. Looks are published in the order they began, app description by app
    /// description (`observed`, keyed by what detection reads: ID, bundle ID and app name), so what is shown never goes
    /// back to an older state. A look still running after `scanStall` is given up and the next begins at once (with its
    /// apps too); a given-up look is still published if it ends before a later one is. At most `maxStalled` given-up
    /// looks may still hold a thread; beyond that nothing more begins until one ends. A refresh waits for its look
    /// `refreshWait` at most, then shows the catalog anyway: an app whose description has no published look is not
    /// known (`knowsInstalled`), and the window's actions for it wait.
    private var current: (number: Int, apps: [CatalogApp])?
    private var stalled: Set<Int> = []
    var scanStall: Duration = .seconds(10)
    var refreshWait: Duration = .seconds(15)
    let maxStalled = 2
    /// The apps of the look to begin once one may, when one was asked for meanwhile.
    private var pendingApps: [CatalogApp]?
    /// How many looks have begun, and the number of the last one published.
    private var begunScans = 0
    private var publishedScans = 0
    private var observed: [String: (scan: Int, copies: [InstalledCopy])] = [:]
    /// Callers waiting until the look of a given number, or a later one, is published.
    private var scanWaiters: [Int: (scan: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextWaiter = 0

    public init(
        loader: any CatalogLoading, finder: any InstalledAppDetecting, defaults: UserDefaults = .standard,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.loader = loader
        self.finder = finder
        self.defaults = defaults
        self.now = now
        showBetas = defaults.bool(forKey: Self.showBetasKey)
    }

    /// Every feed app, in feed order.
    public var rows: [AppRow] {
        (catalog?.apps ?? []).map { app in
            let copies = installed[app.id] ?? []
            return AppRow(
                id: app.id, name: app.name, summary: app.summary, appName: app.appName, installed: copies,
                live: app.live?.version, beta: showBetas ? app.beta?.label : nil,
                update: Self.offeredRelease(app, copies, showBetas: showBetas)?.label,
                install: Self.installRelease(app, showBetas: showBetas)?.label
            )
        }
    }

    /// How many apps have an update available.
    public var updateCount: Int { rows.filter(\.updateAvailable).count }

    /// The menu's line about updates.
    public var updatesMenuTitle: String {
        if catalog == nil {
            if case .failed = status { return "Updates unavailable" }
            return "Checking for updates…"
        }
        switch updateCount {
        case 0: return "No updates available"
        case 1: return "1 update available"
        case let count: return "\(count) updates available"
        }
    }

    /// Refreshes now, then every 6 hours until `stopAutoRefresh`, and returns true. Calling it again while it runs does
    /// nothing. A zero or negative `interval` is refused: nothing starts and it returns false, since the loop would
    /// otherwise refresh back to back.
    @discardableResult
    public func startAutoRefresh(every interval: Duration = refreshInterval) -> Bool {
        guard interval > .zero else { return false }
        guard refreshLoop == nil else { return true }
        refreshLoop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: interval)
            }
        }
        return true
    }

    public func stopAutoRefresh() {
        refreshLoop?.cancel()
        refreshLoop = nil
    }

    /// Loads the catalog (from the cache when it is younger than 5 minutes, unless `force`) and looks for the installed
    /// apps again, then publishes the catalog, its status and the installed apps together. A refresh while another runs
    /// does nothing. A refresh whose task is cancelled (`stopAutoRefresh`, or the caller's task) changes neither the
    /// catalog nor its status, even when the cancel comes during detection (a fetch cut short is not a feed failure);
    /// its look, like every look, is still published for the apps of the catalog shown.
    public func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let result = await loader.load(refresh: force)
        if Task.isCancelled { return }
        var nextCatalog = catalog
        var nextFetchedAt = fetchedAt
        let nextStatus: CatalogStatus
        switch result {
        case .success(let loaded):
            nextCatalog = loaded.catalog
            nextFetchedAt = loaded.fetchedAt
            nextStatus = loaded.warning.map(CatalogStatus.offline) ?? .current
        case .failure(let error):
            nextStatus = .failed(error.message)
            // What was shown stays (the reader rules keep the previous feed) while it is younger than 7 days.
            if let shown = nextFetchedAt, now().timeIntervalSince(shown) >= CatalogLoader.staleLimit {
                nextCatalog = nil
                nextFetchedAt = nil
            }
        }
        // The installed apps are looked for with the new catalog's apps before it is shown, for `refreshWait` at most.
        if let apps = nextCatalog?.apps {
            await waitForScan(requestScan(apps), within: refreshWait)
            if Task.isCancelled { return }
        }
        catalog = nextCatalog
        fetchedAt = nextFetchedAt
        status = nextStatus
        // Looks of descriptions the catalog shown no longer has are dropped: one shown again needs a look of its own.
        let shownKeys = Set((nextCatalog?.apps ?? []).map(Self.key))
        observed = observed.filter { shownKeys.contains($0.key) }
        publishInstalled()
    }

    /// Whether what is installed of the app is known: its description in the catalog shown has a published look.
    public func knowsInstalled(_ appID: String) -> Bool {
        guard let app = catalog?.apps.first(where: { $0.id == appID }) else { return false }
        return observed[Self.key(app)] != nil
    }

    /// Looks for the installed apps again (after an install, update or move to the Trash), keeping the catalog, and
    /// returns once every app of the catalog shown then has a published look begun after this call, whoever asked for
    /// it (looks asked for while one runs are one look), looking again when the catalog changed meanwhile; at once when
    /// no catalog is shown, or when the caller's task is cancelled. It has no time limit: a row waits for it.
    public func reloadInstalled() async {
        let after = begunScans
        while !Task.isCancelled, let apps = catalog?.apps, apps.contains(where: { (observed[Self.key($0)]?.scan ?? 0) <= after }) {
            await waitForScan(requestScan(apps))
        }
    }

    /// Asks for a look at `apps` begun after now and returns its number: begun at once when one may begin, otherwise
    /// the one that begins next, which then covers these apps too.
    private func requestScan(_ apps: [CatalogApp]) -> Int {
        pendingApps = Self.merging(pendingApps ?? [], apps)
        startPendingIfIdle()
        return pendingApps == nil ? begunScans : begunScans + 1
    }

    /// Every description in `first`, then those of `second` not in it (two catalogs may describe one app ID differently).
    private static func merging(_ first: [CatalogApp], _ second: [CatalogApp]) -> [CatalogApp] {
        var merged = first
        for app in second where !merged.contains(where: { key($0) == key(app) }) { merged.append(app) }
        return merged
    }

    private func startPendingIfIdle() {
        guard current == nil, stalled.count < maxStalled, let apps = pendingApps else { return }
        pendingApps = nil
        begunScans += 1
        let number = begunScans
        current = (number, apps)
        let finder = finder
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            // Detection reports by app ID, so descriptions sharing an ID are looked for in passes of their own.
            var found: [String: [InstalledCopy]] = [:]
            var rest = apps
            while !rest.isEmpty {
                var pass: [CatalogApp] = []
                rest.removeAll { app in
                    guard !pass.contains(where: { $0.id == app.id }) else { return false }
                    pass.append(app)
                    return true
                }
                let copies = finder.detect(pass)
                for app in pass { found[Self.key(app)] = copies[app.id] ?? [] }
            }
            Task { @MainActor [found] in self?.scanEnded(number, found) }
        }
        scheduleGiveUp(number)
    }

    private func scheduleGiveUp(_ number: Int) {
        let stall = scanStall
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: stall)
            self?.giveUp(number)
        }
    }

    /// Look `number` is still running after `scanStall`: given up, so the next look (with its apps) begins, unless
    /// `maxStalled` looks already hold a thread; then it is tried again later.
    private func giveUp(_ number: Int) {
        guard let running = current, running.number == number else { return }
        guard stalled.count < maxStalled else { return scheduleGiveUp(number) }
        stalled.insert(number)
        current = nil
        pendingApps = Self.merging(running.apps, pendingApps ?? [])
        startPendingIfIdle()
    }

    /// Publishes look `number` unless a later one was published first (then it is older), begins the merged look asked
    /// for meanwhile, if any, and resumes the callers waiting for what is now published.
    private func scanEnded(_ number: Int, _ found: [String: [InstalledCopy]]) {
        if stalled.remove(number) == nil, current?.number == number { current = nil }
        if number > publishedScans {
            for (key, copies) in found { observed[key] = (number, copies) }
            publishedScans = number
            publishInstalled()
        }
        startPendingIfIdle()
        for (id, waiter) in scanWaiters where waiter.scan <= publishedScans {
            scanWaiters[id] = nil
            waiter.continuation.resume()
        }
    }

    /// Returns once look `number` or a later one is published, the caller's task is cancelled, or `limit` has passed.
    private func waitForScan(_ number: Int, within limit: Duration? = nil) async {
        guard publishedScans < number, !Task.isCancelled else { return }
        let id = nextWaiter
        nextWaiter += 1
        if let limit {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: limit)
                self?.endWait(id)
            }
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled { continuation.resume() } else { scanWaiters[id] = (number, continuation) }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.endWait(id) }
        }
    }

    private func endWait(_ id: Int) {
        scanWaiters.removeValue(forKey: id)?.continuation.resume()
    }

    /// `installed`: what the published looks saw of the apps of the catalog shown (nothing without a catalog).
    private func publishInstalled() {
        let apps = catalog?.apps ?? []
        let shown = Dictionary(apps.compactMap { app in observed[Self.key(app)].map { (app.id, $0.copies) } }, uniquingKeysWith: { first, _ in first })
        if shown != installed { installed = shown }
    }

    /// What detection reads of an app (InstalledAppFinder.copies(of:)).
    private nonisolated static func key(_ app: CatalogApp) -> String { "\(app.id)\u{0}\(app.bundleID)\u{0}\(app.appName)" }

    /// The newest release that is an update for some installed copy: from the live channel, or the live or beta channel
    /// when betas are shown.
    public static func offeredRelease(_ app: CatalogApp, _ copies: [InstalledCopy], showBetas: Bool) -> ChosenRelease? {
        let updates = { (channel: ReleaseChannel) in
            copies.contains { UpdateRule.decide($0, app, channel: channel) == .update }
        }
        let live = updates(.live) ? ChosenRelease(app, channel: .live) : nil
        let beta = showBetas && updates(.beta) ? ChosenRelease(app, channel: .beta) : nil
        return newer(live, beta)
    }

    /// The release Install offers: the live release, or with betas shown the newer of it and the beta.
    public static func installRelease(_ app: CatalogApp, showBetas: Bool) -> ChosenRelease? {
        newer(ChosenRelease(app, channel: .live), showBetas ? ChosenRelease(app, channel: .beta) : nil)
    }

    // At the same version the release is newer than its betas.
    private static func newer(_ live: ChosenRelease?, _ beta: ChosenRelease?) -> ChosenRelease? {
        guard let live, let beta else { return live ?? beta }
        return UpdateRule.compareVersions(beta.version, live.version) > 0 ? beta : live
    }
}
