import Darwin
import Foundation

/// Why the catalog cannot be shown, with the message to show.
public enum CatalogError: Error, Equatable, Sendable {
    /// The feed URL is refused, or the fetched feed is refused by the reader rules: it is not used, and no cached copy
    /// stands in for it.
    case invalid(String)
    /// The feed could not be fetched (no network, a timeout, an HTTP error) and no cached copy younger than 7 days
    /// stands in for it.
    case unavailable(String)

    public var message: String {
        switch self {
        case .invalid(let message), .unavailable(let message): message
        }
    }
}

/// Where the feed is: `https://subset.21n.dev/catalog/v1.json`, unless the `SUBSET_CATALOG_URL` environment variable or
/// the hidden `SubsetCatalogURL` default (`defaults write dev.subset.manager SubsetCatalogURL <url>`) names another
/// https URL on an allowed host. Any other URL is refused rather than replaced by the default. An accepted URL is spelled
/// as the WHATWG URL parser spells it (`url.href` in `subset`): lowercase scheme and host, no `:443`, `/` for an empty
/// path, so both key the shared cache alike.
public enum CatalogLocation {
    public static let defaultURL = URL(string: "https://subset.21n.dev/catalog/v1.json")!
    public static let environmentVariable = "SUBSET_CATALOG_URL"
    public static let defaultsKey = "SubsetCatalogURL"
    /// The hosts a feed may be fetched from.
    public static let allowedHosts: Set<String> = ["subset.21n.dev"]

    /// The feed URL for this environment (which wins) and defaults value, or why it is refused.
    public static func resolve(environment: [String: String], defaultsValue: String?) -> Result<URL, CatalogError> {
        let source: String
        let text: String
        if let value = environment[environmentVariable], !value.isEmpty {
            (source, text) = (environmentVariable, value)
        } else if let value = defaultsValue, !value.isEmpty {
            (source, text) = ("The \(defaultsKey) default", value)
        } else {
            return .success(defaultURL)
        }
        guard let url = URL(string: text), let scheme = url.scheme else {
            return .failure(.invalid("\(source) is not a URL: \(text)"))
        }
        guard scheme.lowercased() == "https" else {
            return .failure(.invalid("\(source) must be an https URL, not \(scheme):"))
        }
        guard url.user == nil, url.password == nil else {
            return .failure(.invalid("\(source) must not contain a user name or password"))
        }
        guard let host = url.host?.lowercased(), allowedHosts.contains(host) else {
            let allowed = allowedHosts.sorted().joined(separator: ", ")
            return .failure(.invalid("\(source) names the host \(url.host ?? "(none)"), which is not one of \(allowed)"))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return .failure(.invalid("\(source) is not a URL: \(text)"))
        }
        components.scheme = "https"
        components.host = host
        if components.port == 443 { components.port = nil }
        if components.percentEncodedPath.isEmpty { components.percentEncodedPath = "/" }
        guard let canonical = components.url else { return .failure(.invalid("\(source) is not a URL: \(text)")) }
        return .success(canonical)
    }
}

/// Fetches the feed's bytes. Tests stand in recorded responses.
public protocol FeedTransport: Sendable {
    /// At most `limit + 1` bytes of the feed at `url`, so an oversized feed is known to be too large without keeping
    /// it. Throws a `FeedUnavailable` when it cannot be fetched.
    func fetch(_ url: URL, limit: Int) async throws -> Data
}

/// The feed could not be fetched, and why.
public struct FeedUnavailable: Error, Equatable, Sendable {
    public var reason: String

    public init(_ reason: String) {
        self.reason = reason
    }
}

/// The catalog as loaded.
public struct LoadedCatalog: Equatable, Sendable {
    public var catalog: Catalog
    public var url: URL
    public var fetchedAt: Date
    /// Whether it came from the cache rather than this fetch.
    public var cached: Bool
    /// Set when the feed could not be fetched and a cached copy younger than 7 days is used instead.
    public var warning: String?
}

/// Loads the catalog.
public protocol CatalogLoading: Sendable {
    func load(refresh: Bool) async -> Result<LoadedCatalog, CatalogError>
}

/// Loads the catalog by the rules `subset` uses: from the cache when it is younger than 5 minutes (unless `refresh`),
/// otherwise fetched, validated and cached. When it cannot be fetched, a cached copy younger than 7 days is used with a
/// warning, unless `refresh` (as `subset` does, a forced refresh never reads the cache, so it is an error; the view model
/// keeps the list it already shows). A refused feed is an error and does not replace the cached copy. The cache is
/// ~/Library/Caches/Subset/catalog.json, the file `subset` keeps, in its format.
public struct CatalogLoader: CatalogLoading {
    public static let freshFor: TimeInterval = 5 * 60
    public static let staleLimit: TimeInterval = 7 * 24 * 60 * 60
    static let cacheSchema = "subset.catalog-cache@1"
    // The cache holds the feed as a JSON string, whose escapes can make it several times longer than the feed.
    static let maxCacheBytes = 8 * Catalog.maxBytes

    public var location: Result<URL, CatalogError>
    public var cacheFile: URL
    public var transport: any FeedTransport
    public var now: @Sendable () -> Date

    public init(
        location: Result<URL, CatalogError>, cacheFile: URL, transport: any FeedTransport,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.location = location
        self.cacheFile = cacheFile
        self.transport = transport
        self.now = now
    }

    /// The loader for this process: its environment, the standard defaults, the user's cache and URLSession.
    public static func standard() -> CatalogLoader {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return CatalogLoader(
            location: CatalogLocation.resolve(
                environment: ProcessInfo.processInfo.environment,
                defaultsValue: UserDefaults.standard.string(forKey: CatalogLocation.defaultsKey)
            ),
            cacheFile: home.appendingPathComponent("Library/Caches/Subset/catalog.json"),
            transport: URLSessionFeedTransport()
        )
    }

    public func load(refresh: Bool) async -> Result<LoadedCatalog, CatalogError> {
        let url: URL
        switch location {
        case .success(let value): url = value
        case .failure(let error): return .failure(error)
        }
        let start = now()
        let cached = refresh ? nil : readCache(url: url, now: start)
        if let cached, start.timeIntervalSince(cached.fetchedAt) < Self.freshFor {
            return .success(LoadedCatalog(catalog: cached.catalog, url: url, fetchedAt: cached.fetchedAt, cached: true))
        }
        let data: Data
        do {
            data = try await transport.fetch(url, limit: Catalog.maxBytes)
        } catch {
            let reason = "Could not fetch the catalog from \(url.absoluteString) (\((error as? FeedUnavailable)?.reason ?? "\(error)"))"
            let current = now()
            guard let cached else {
                return .failure(.unavailable("\(reason)\(refresh ? "" : ", and there is no cached copy")."))
            }
            let age = current.timeIntervalSince(cached.fetchedAt)
            guard age < Self.staleLimit else {
                return .failure(.unavailable("\(reason), and the cached copy is \(Self.describe(age)) old, more than 7 days."))
            }
            let warning = "\(reason); showing the copy cached \(Self.describe(age)) ago."
            return .success(LoadedCatalog(catalog: cached.catalog, url: url, fetchedAt: cached.fetchedAt, cached: true, warning: warning))
        }
        switch Catalog.parse(data) {
        case .failure(let refusal):
            let problems = refusal.problems.joined(separator: "\n")
            return .failure(.invalid("The catalog at \(url.absoluteString) is not a valid \(Catalog.schema) feed, so it is not used:\n\(problems)"))
        case .success(let catalog):
            let fetchedAt = now()
            writeCache(url: url, data: data, fetchedAt: fetchedAt)
            return .success(LoadedCatalog(catalog: catalog, url: url, fetchedAt: fetchedAt, cached: false))
        }
    }

    /// A duration as people say it: 42 seconds, 5 minutes, 3 hours, 2 days.
    public static func describe(_ interval: TimeInterval) -> String {
        let units: [(String, TimeInterval)] = [("day", 86_400), ("hour", 3_600), ("minute", 60), ("second", 1)]
        let (unit, size) = units.first { interval >= $0.1 } ?? units[units.count - 1]
        let count = Int(max(0, interval) / size)
        return "\(count) \(unit)\(count == 1 ? "" : "s")"
    }

    // The cached feed for `url`, or nil when there is none, it is for another URL, or it is unreadable, invalid or dated
    // in the future (it is then simply not used).
    func readCache(url: URL, now: Date) -> (catalog: Catalog, fetchedAt: Date)? {
        guard let data = BoundedFile.read(cacheFile.path, limit: Self.maxCacheBytes), data.count <= Self.maxCacheBytes,
              let entry = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              entry["schema"] as? String == Self.cacheSchema, entry["url"] as? String == url.absoluteString,
              let body = entry["body"] as? String, let stamp = entry["fetchedAt"] as? String,
              let fetchedAt = Self.parseDate(stamp), fetchedAt <= now,
              case .success(let catalog) = Catalog.parse(Data(body.utf8))
        else { return nil }
        return (catalog, fetchedAt)
    }

    // Replaces the cached copy atomically: a uniquely named temporary file renamed over it. The cache is best-effort:
    // when any step fails nothing is reported, the temporary file is removed, and the next load fetches again.
    func writeCache(url: URL, data: Data, fetchedAt: Date) {
        let folder = cacheFile.deletingLastPathComponent()
        let temporary = folder.appendingPathComponent(".\(cacheFile.lastPathComponent).\(getpid()).\(UUID().uuidString).tmp")
        let entry: [String: Any] = [
            "schema": Self.cacheSchema, "url": url.absoluteString, "fetchedAt": Self.formatDate(fetchedAt),
            "body": String(decoding: data, as: UTF8.self)
        ]
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: entry, options: [.withoutEscapingSlashes])
            guard FileManager.default.createFile(atPath: temporary.path, contents: json, attributes: [.posixPermissions: 0o600]),
                  rename(temporary.path, cacheFile.path) == 0
            else { throw CocoaError(.fileWriteUnknown) }
        } catch {
            try? FileManager.default.removeItem(at: temporary)
        }
    }

    // fetchedAt as JavaScript's toISOString writes it (2026-11-16T10:00:00.000Z), so `subset` reads the cache too.
    static func formatDate(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func parseDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
