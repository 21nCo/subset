import Foundation

/// The catalog feed, `subset.catalog@1` (`packages/catalog/README.md`): the Mac apps Subset ships, by channel, and its
/// command-line tools. `Catalog.parse` applies the reader rules the `subset` command applies, so both readers accept and
/// refuse the same documents (`CatalogFeedTests` runs both against `packages/catalog/feed/fixtures`).
public struct Catalog: Equatable, Sendable {
    public static let schema = "subset.catalog@1"
    /// The largest feed a reader accepts, as received (256 KiB).
    public static let maxBytes = 256 * 1024

    public var generatedAt: String
    public var apps: [CatalogApp]
    public var tools: [CatalogTool]

    public init(generatedAt: String, apps: [CatalogApp], tools: [CatalogTool]) {
        self.generatedAt = generatedAt
        self.apps = apps
        self.tools = tools
    }

    /// The feed in `data`, or the problems that refuse it, whole: more than 256 KiB (checked before parsing), not UTF-8
    /// JSON, invalid against the closed schema, or a duplicate app ID, bundle ID, helper command or tool ID.
    public static func parse(_ data: Data) -> Result<Catalog, FeedRefusal> {
        if data.count > maxBytes { return .failure(FeedRefusal(["the feed is larger than \(maxBytes) bytes"])) }
        let json: Any
        switch JSONChecker.parse(data) {
        case .success(let value): json = value
        case .failure(let refusal): return .failure(refusal)
        }
        var checker = JSONChecker()
        let catalog = decode(json, &checker)
        guard let catalog, checker.problems.isEmpty else { return .failure(FeedRefusal(checker.problems)) }
        let duplicates = catalog.duplicateProblems()
        return duplicates.isEmpty ? .success(catalog) : .failure(FeedRefusal(duplicates))
    }

    private static func decode(_ json: Any, _ checker: inout JSONChecker) -> Catalog? {
        guard let root = checker.object(json, "", required: ["schema", "generatedAt", "apps", "tools"]) else { return nil }
        let schemaOK = checker.constant(root["schema"], "/schema", schema)
        let generatedAt = checker.string(root["generatedAt"], "/generatedAt", pattern: .utcTimestamp)
        let apps = checker.array(root["apps"], "/apps")?.enumerated().map { CatalogApp.decode($1, "/apps/\($0)", &checker) }
        let tools = checker.array(root["tools"], "/tools")?.enumerated().map { CatalogTool.decode($1, "/tools/\($0)", &checker) }
        guard schemaOK, let generatedAt, let apps, let tools else { return nil }
        let validApps = apps.compactMap { $0 }
        let validTools = tools.compactMap { $0 }
        guard validApps.count == apps.count, validTools.count == tools.count else { return nil }
        return Catalog(generatedAt: generatedAt, apps: validApps, tools: validTools)
    }

    // Values the schema cannot keep unique (reader rule 4).
    private func duplicateProblems() -> [String] {
        var problems: [String] = []
        func unique(_ label: String, _ values: [String]) {
            var seen = Set<String>()
            for value in values where !seen.insert(value).inserted {
                problems.append("\(label) \(JSONChecker.quoted(value)) appears more than once")
            }
        }
        unique("app id", apps.map(\.id))
        unique("bundleId", apps.map(\.bundleID))
        unique("helper command", apps.flatMap { $0.helpers.map(\.command) })
        unique("tool id", tools.map(\.id))
        return problems
    }
}

/// Why a feed or receipt was refused: one line per problem.
public struct FeedRefusal: Error, Equatable, Sendable {
    public var problems: [String]

    public init(_ problems: [String]) {
        self.problems = problems
    }
}

/// A Mac app in the feed, with its live and beta releases (at least one of them).
public struct CatalogApp: Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    /// The app bundle's name without `.app`, as installed in /Applications.
    public var appName: String
    /// The app's CFBundleIdentifier.
    public var bundleID: String
    public var helpers: [CatalogHelper]
    public var live: LiveRelease?
    public var beta: BetaRelease?

    public init(
        id: String, name: String, summary: String, appName: String, bundleID: String, helpers: [CatalogHelper] = [],
        live: LiveRelease?, beta: BetaRelease?
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.appName = appName
        self.bundleID = bundleID
        self.helpers = helpers
        self.live = live
        self.beta = beta
    }

    static func decode(_ json: Any, _ pointer: String, _ checker: inout JSONChecker) -> CatalogApp? {
        let keys = ["id", "name", "summary", "appName", "bundleId", "helpers", "channels"]
        guard let app = checker.object(json, pointer, required: keys) else { return nil }
        let id = checker.string(app["id"], "\(pointer)/id", pattern: .id, maxLength: 64)
        let name = checker.string(app["name"], "\(pointer)/name", minLength: 1, maxLength: 100)
        let summary = checker.string(app["summary"], "\(pointer)/summary", minLength: 1, maxLength: 500)
        let appName = checker.string(app["appName"], "\(pointer)/appName", pattern: .appName, maxLength: 100)
        let bundleID = checker.string(app["bundleId"], "\(pointer)/bundleId", pattern: .bundleID, maxLength: 255)
        let helpers = checker.array(app["helpers"], "\(pointer)/helpers")?.enumerated().map {
            CatalogHelper.decode($1, "\(pointer)/helpers/\($0)", &checker)
        }
        var live: LiveRelease?
        var beta: BetaRelease?
        var channelsOK = false
        if let channels = checker.object(app["channels"], "\(pointer)/channels", required: [], optional: ["live", "beta"]) {
            if channels.isEmpty { checker.fail("\(pointer)/channels", "must have at least 1 property") }
            live = channels["live"].flatMap { LiveRelease.decode($0, "\(pointer)/channels/live", &checker) }
            beta = channels["beta"].flatMap { BetaRelease.decode($0, "\(pointer)/channels/beta", &checker) }
            channelsOK = !channels.isEmpty && (channels["live"] == nil || live != nil) && (channels["beta"] == nil || beta != nil)
        }
        guard let id, let name, let summary, let appName, let bundleID, let helpers, channelsOK else { return nil }
        let validHelpers = helpers.compactMap { $0 }
        guard validHelpers.count == helpers.count else { return nil }
        return CatalogApp(
            id: id, name: name, summary: summary, appName: appName, bundleID: bundleID, helpers: validHelpers, live: live,
            beta: beta
        )
    }
}

/// A command bundled in an app: `subset <command>` runs the file at `path` inside the installed app.
public struct CatalogHelper: Equatable, Sendable {
    public var command: String
    public var path: String
    public var kind: String

    static func decode(_ json: Any, _ pointer: String, _ checker: inout JSONChecker) -> CatalogHelper? {
        guard let helper = checker.object(json, pointer, required: ["command", "path", "kind"]) else { return nil }
        let command = checker.string(helper["command"], "\(pointer)/command", pattern: .id, maxLength: 64)
        var path = checker.string(helper["path"], "\(pointer)/path", pattern: .helperPath, maxLength: 255)
        let kind = checker.oneOf(helper["kind"], "\(pointer)/kind", ["native", "node"])
        if kind == "node", let value = path, !FeedPattern.nodeHelperPath.matches(value) {
            checker.fail("\(pointer)/path", "does not match \(FeedPattern.nodeHelperPath.rawValue)")
            path = nil
        }
        guard let command, let path, let kind else { return nil }
        return CatalogHelper(command: command, path: path, kind: kind)
    }
}

/// The live release of an app.
public struct LiveRelease: Equatable, Sendable {
    public var version: String
    public var url: String
    public var sha256: String
    public var releaseURL: String

    public init(version: String, url: String, sha256: String, releaseURL: String) {
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.releaseURL = releaseURL
    }

    static func decode(_ json: Any, _ pointer: String, _ checker: inout JSONChecker) -> LiveRelease? {
        guard let release = checker.object(json, pointer, required: ["version", "url", "sha256", "releaseUrl"]) else { return nil }
        let version = checker.string(release["version"], "\(pointer)/version", pattern: .version)
        let url = checker.string(release["url"], "\(pointer)/url", pattern: .dmgURL, maxLength: 512)
        let sha256 = checker.string(release["sha256"], "\(pointer)/sha256", pattern: .sha256)
        let releaseURL = checker.string(release["releaseUrl"], "\(pointer)/releaseUrl", pattern: .releaseURL, maxLength: 512)
        guard let version, let url, let sha256, let releaseURL else { return nil }
        return LiveRelease(version: version, url: url, sha256: sha256, releaseURL: releaseURL)
    }
}

/// Beta build `build` of `version`: the app's CFBundleShortVersionString is `version` and its CFBundleVersion `build`.
public struct BetaRelease: Equatable, Sendable {
    public var version: String
    public var build: Int
    public var url: String
    public var sha256: String
    public var releaseURL: String

    public init(version: String, build: Int, url: String, sha256: String, releaseURL: String) {
        self.version = version
        self.build = build
        self.url = url
        self.sha256 = sha256
        self.releaseURL = releaseURL
    }

    /// The beta as `subset list` shows it: 0.1.1-beta.4.
    public var label: String { "\(version)-beta.\(build)" }

    static func decode(_ json: Any, _ pointer: String, _ checker: inout JSONChecker) -> BetaRelease? {
        let keys = ["version", "build", "url", "sha256", "releaseUrl"]
        guard let release = checker.object(json, pointer, required: keys) else { return nil }
        let version = checker.string(release["version"], "\(pointer)/version", pattern: .version)
        let build = checker.integer(release["build"], "\(pointer)/build", in: 1...999_999_999)
        let url = checker.string(release["url"], "\(pointer)/url", pattern: .dmgURL, maxLength: 512)
        let sha256 = checker.string(release["sha256"], "\(pointer)/sha256", pattern: .sha256)
        let releaseURL = checker.string(release["releaseUrl"], "\(pointer)/releaseUrl", pattern: .releaseURL, maxLength: 512)
        guard let version, let build, let url, let sha256, let releaseURL else { return nil }
        return BetaRelease(version: version, build: build, url: url, sha256: sha256, releaseURL: releaseURL)
    }
}

/// An npm command-line tool in the feed. The app does not list tools; they are decoded because the feed is closed.
public struct CatalogTool: Equatable, Sendable {
    public var id: String
    public var package: String
    public var bin: String
    public var latest: String?
    public var beta: String?

    static func decode(_ json: Any, _ pointer: String, _ checker: inout JSONChecker) -> CatalogTool? {
        guard let tool = checker.object(json, pointer, required: ["id", "package", "bin", "distTags"]) else { return nil }
        let id = checker.string(tool["id"], "\(pointer)/id", pattern: .id, maxLength: 64)
        let package = checker.string(tool["package"], "\(pointer)/package", pattern: .toolPackage, maxLength: 214)
        let bin = checker.string(tool["bin"], "\(pointer)/bin", pattern: .toolBin, maxLength: 100)
        var tagsOK = false
        var latest: String?
        var beta: String?
        let tagsPointer = "\(pointer)/distTags"
        if let tags = checker.object(tool["distTags"], tagsPointer, required: [], optional: ["latest", "beta"]) {
            if tags.isEmpty { checker.fail(tagsPointer, "must have at least 1 property") }
            latest = tags["latest"].flatMap { checker.string($0, "\(tagsPointer)/latest", pattern: .version) }
            beta = tags["beta"].flatMap { checker.string($0, "\(tagsPointer)/beta", pattern: .betaDistTag) }
            tagsOK = !tags.isEmpty && (tags["latest"] == nil || latest != nil) && (tags["beta"] == nil || beta != nil)
        }
        guard let id, let package, let bin, tagsOK else { return nil }
        return CatalogTool(id: id, package: package, bin: bin, latest: latest, beta: beta)
    }
}
