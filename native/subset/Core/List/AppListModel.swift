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
    /// does nothing. A refresh whose task is cancelled (`stopAutoRefresh`, or the caller's task) changes nothing, even
    /// when the cancel comes during detection: a fetch cut short is not a feed failure.
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
        var found: [String: [InstalledCopy]] = [:]
        if let apps = nextCatalog?.apps {
            let finder = finder
            found = await Task.detached { finder.detect(apps) }.value
            if Task.isCancelled { return }
        }
        catalog = nextCatalog
        fetchedAt = nextFetchedAt
        status = nextStatus
        installed = found
    }

    /// Looks for the installed apps again (after an install, update or move to the Trash), keeping the catalog.
    public func reloadInstalled() async {
        guard let apps = catalog?.apps else { return }
        let finder = finder
        let found = await Task.detached { finder.detect(apps) }.value
        installed = found
    }

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
