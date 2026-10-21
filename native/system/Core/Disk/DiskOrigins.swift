import Foundation

/// The Library folders whose entries are attributed to apps. Each entry directly inside one is named for the app it
/// belongs to, by bundle ID or by name.
public enum LibraryFolder: String, CaseIterable, Sendable {
    case applicationSupport = "Application Support"
    case caches = "Caches"
    case containers = "Containers"
    case groupContainers = "Group Containers"
    case preferences = "Preferences"
    case logs = "Logs"
    case httpStorages = "HTTPStorages"

    /// The folder's path relative to the home folder.
    public var homePath: String { "Library/" + rawValue }

    /// The suffix a file name adds to the identifier in this folder (`com.example.app.plist`).
    var suffixes: [String] {
        switch self {
        case .preferences: [".plist"]
        case .httpStorages: [".binarycookies"]
        default: []
        }
    }
}

/// How an entry was attributed, in the order tried.
public enum DiskOriginRule: Equatable, Sendable {
    /// The entry is a folder a developer tool's reclaim rule names (`~/Library/Caches/Homebrew`).
    case developerTool
    /// The identifier is the app's bundle ID or extends it component by component (`com.example.app.helper`), or, in
    /// Group Containers, an app's bundle ID extends it (`group.com.example` for `com.example.app`).
    case bundleID
    /// A group container named by a Team ID (`ABCDE12345.shared`) that installed apps share. With one installed app
    /// signed by that team it is that app's; with several, only their vendor's.
    case teamID
    /// An Apple identifier (`com.apple.…`) no installed app has: macOS's own data, never a leftover.
    case appleIdentifier
    /// The entry's name is the one installed app's name (its file name, `CFBundleName`, or `CFBundleDisplayName`).
    case appName
    /// A bundle ID, or a group container's Team ID, that no installed app has.
    case leftover
    /// Nothing matched: a name that is neither a bundle ID nor an installed app's name.
    case unattributed
}

/// One entry of a Library folder and where it was placed.
public struct DiskOriginEntry: Equatable, Sendable {
    /// The entry's index in the scan's tree.
    public let index: Int
    public let path: String
    public let folder: LibraryFolder
    /// The identifier matched: the name without a folder's suffix, and in Group Containers without the Team ID or
    /// `group.` prefix.
    public let identifier: String
    /// A group container's Team ID prefix.
    public let teamID: String?
    public let rule: DiskOriginRule
    /// The installed app, for `bundleID`, `appName`, and a `teamID` with one app.
    public let app: InstalledApp?
    /// The App layer origin: the app's bundle (`Origin.app`), or `Origin.macOS` for an Apple identifier.
    public let appOrigin: Origin?
    /// The Vendor layer origin: the app's (`InstalledApp.vendor`), Apple for an Apple identifier, or a group
    /// container's Team ID.
    public let vendor: Origin?
    /// The developer tool of the reclaim rule that names this folder.
    public let developerTool: String?
    /// `nil` when the entry could not be read.
    public let sizes: DiskSizes?
    public let flags: DiskItemFlags

    /// Leftovers are reviewed item by item before any cleanup.
    public var risk: ReclaimRisk? { rule == .leftover ? .review : nil }
}

/// What a By origin group stands for.
public enum DiskOriginGroupKey: Hashable, Sendable {
    /// An App layer origin (an app or macOS) or a Vendor layer origin, SET-42's types.
    case origin(Origin)
    case developerTool(String)
    /// Entries named for apps that are not installed.
    case leftovers
    /// Entries nothing attributed.
    case unattributed
}

/// Tree items summed under one origin. Items are distinct entries of the tree, none inside another.
public struct DiskOriginGroup: Equatable, Sendable, Identifiable {
    public let id: DiskOriginGroupKey
    public let name: String
    /// The tree indices of the items summed.
    public let items: [Int]
    /// Summed allocated sizes. Blocks two items' clones share count once in each.
    public let allocated: UInt64
    /// Summed private sizes: at least what deleting every item would free.
    public let `private`: UInt64
    /// An item's size is unknown or a lower bound, so both sums are lower bounds.
    public let isLowerBound: Bool
}

/// Disk usage by origin: every entry of the Library folders, attributed, and grouped by app, vendor, developer tool,
/// and leftovers.
public struct DiskOriginReport: Equatable, Sendable {
    public let entries: [DiskOriginEntry]
    /// By app, with macOS for Apple identifiers.
    public let apps: [DiskOriginGroup]
    public let vendors: [DiskOriginGroup]
    /// By the developer tool of each reclaim match's items (Xcode, npm, Homebrew…).
    public let developerTools: [DiskOriginGroup]
    public let leftovers: DiskOriginGroup?
    public let unattributed: DiskOriginGroup?
}

public enum DiskOrigins {
    /// Attributes every entry directly inside the Library folders under `home` that the tree holds.
    public static func entries(in tree: DiskTree, home: String, apps: InstalledApps) -> [DiskOriginEntry] {
        let tools = Dictionary(ReclaimRules.all.flatMap { rule in
            rule.developerTool.map { tool in rule.homePaths.map { ($0, tool) } } ?? []
        }, uniquingKeysWith: { first, _ in first })
        var entries: [DiskOriginEntry] = []
        for folder in LibraryFolder.allCases {
            let folderPath = home + "/" + folder.homePath
            guard let index = tree.index(atPath: folderPath) else { continue }
            for child in tree.children(of: index) {
                entries.append(entry(child, folder: folder, path: folderPath + "/" + child.name,
                                     tool: tools[folder.homePath + "/" + child.name], apps: apps))
            }
        }
        return entries
    }

    /// Groups the entries by app, vendor, leftovers, and unattributed, and the reclaim matches' items by developer
    /// tool. Groups are ordered by allocated size, largest first, then by name.
    public static func report(entries: [DiskOriginEntry], matches: [ReclaimMatch], tree: DiskTree,
                              apps: InstalledApps) -> DiskOriginReport {
        var byApp: [Origin: (name: String, items: [Int])] = [:]
        var byVendor: [Origin: [Int]] = [:]
        var leftovers: [Int] = []
        var unattributed: [Int] = []
        for entry in entries {
            if let origin = entry.appOrigin {
                byApp[origin, default: (entry.app?.name ?? "macOS", [])].items.append(entry.index)
            }
            if let vendor = entry.vendor { byVendor[vendor, default: []].append(entry.index) }
            switch entry.rule {
            case .leftover: leftovers.append(entry.index)
            case .unattributed: unattributed.append(entry.index)
            default: break
            }
        }
        var byTool: [String: [Int]] = [:]
        for match in matches {
            guard let tool = match.rule.developerTool else { continue }
            byTool[tool, default: []].append(contentsOf: match.items.map(\.index))
        }
        func ordered(_ groups: [DiskOriginGroup]) -> [DiskOriginGroup] {
            groups.sorted { ($1.allocated, $0.name) < ($0.allocated, $1.name) }
        }
        return DiskOriginReport(
            entries: entries,
            apps: ordered(byApp.map { group(.origin($0.key), name: $0.value.name, items: $0.value.items, tree: tree) }),
            vendors: ordered(byVendor.map { group(.origin($0.key), name: vendorName($0.key, apps: apps), items: $0.value, tree: tree) }),
            developerTools: ordered(byTool.map { group(.developerTool($0.key), name: $0.key, items: $0.value, tree: tree) }),
            leftovers: leftovers.isEmpty ? nil : group(.leftovers, name: "Leftovers", items: leftovers, tree: tree),
            unattributed: unattributed.isEmpty ? nil : group(.unattributed, name: "Not attributed", items: unattributed, tree: tree))
    }

    static func group(_ key: DiskOriginGroupKey, name: String, items: [Int], tree: DiskTree) -> DiskOriginGroup {
        let unique = Array(Set(items)).sorted()
        var allocated: UInt64 = 0
        var privateBytes: UInt64 = 0
        var lowerBound = false
        for index in unique {
            let item = tree[index]
            guard let sizes = item.sizes else {
                lowerBound = true
                continue
            }
            allocated += sizes.allocated
            privateBytes += sizes.private
            if !item.flags.isDisjoint(with: ReclaimMatcher.lowerBoundFlags) { lowerBound = true }
        }
        return DiskOriginGroup(id: key, name: name, items: unique, allocated: allocated, private: privateBytes,
                               isLowerBound: lowerBound)
    }

    static func vendorName(_ vendor: Origin, apps: InstalledApps) -> String {
        switch vendor {
        case .apple: "Apple"
        case .unsigned: "Unsigned"
        case .signatureUnavailable: "Signature unavailable"
        case let .vendor(team): apps.apps(team: team).lazy.compactMap(\.signature?.teamName).first ?? "Team \(team)"
        default: "\(vendor)"
        }
    }

    static func entry(_ item: DiskItem, folder: LibraryFolder, path: String, tool: String?,
                      apps: InstalledApps) -> DiskOriginEntry {
        var identifier = item.name
        if let suffix = folder.suffixes.first(where: { identifier.hasSuffix($0) && identifier.count > $0.count }) {
            identifier.removeLast(suffix.count)
        }
        var team: String?
        if folder == .groupContainers {
            if let dot = identifier.firstIndex(of: "."), isTeamID(identifier[..<dot]) {
                team = String(identifier[..<dot])
                identifier = String(identifier[identifier.index(after: dot)...])
            }
            for prefix in ["group.", "groups."] where identifier.hasPrefix(prefix) && identifier.count > prefix.count {
                identifier.removeFirst(prefix.count)
                break
            }
        }
        func make(_ rule: DiskOriginRule, app: InstalledApp? = nil, appOrigin: Origin? = nil,
                  vendor: Origin? = nil, tool: String? = nil) -> DiskOriginEntry {
            DiskOriginEntry(index: item.index, path: path, folder: folder, identifier: identifier, teamID: team,
                            rule: rule, app: app, appOrigin: appOrigin ?? app.map { .app(bundlePath: $0.path) },
                            vendor: vendor ?? app?.vendor, developerTool: tool, sizes: item.sizes, flags: item.flags)
        }

        if let tool { return make(.developerTool, tool: tool) }
        if identifier.lowercased().hasPrefix("com.apple.") {
            if let app = apps.app(bundleID: identifier) { return make(.bundleID, app: app) }
            return make(.appleIdentifier, appOrigin: .macOS, vendor: .apple)
        }
        let shaped = isBundleID(identifier)
        if let team {
            let signed = apps.apps(team: team)
            guard !signed.isEmpty else { return make(.leftover, vendor: .vendor(teamID: team)) }
            if shaped, let app = signed.first(where: { related($0.bundleID, identifier) }) { return make(.bundleID, app: app) }
            if Set(signed.map(\.path)).count == 1 { return make(.teamID, app: signed[0]) }
            return make(.teamID, vendor: .vendor(teamID: team))
        }
        // An app group is often its app's bundle ID shortened (`group.com.example` for `com.example.app`).
        if folder == .groupContainers, identifier.contains("."), let app = apps.uniqueApp(extending: identifier) {
            return make(.bundleID, app: app)
        }
        if shaped {
            if let app = apps.app(bundleID: identifier) { return make(.bundleID, app: app) }
            return make(.leftover)
        }
        if let app = apps.app(named: identifier) { return make(.appName, app: app) }
        return make(.unattributed)
    }

    /// A reverse-DNS bundle ID: at least three dot-separated components of letters, digits, `-`, and `_`, the first
    /// all lowercase ASCII letters (`com.example.app`, `at.studio.Aside`). `Adobe_CCXProcess.node`, a UUID, and an app
    /// name are not.
    public static func isBundleID(_ name: String) -> Bool {
        let components = name.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count >= 3, let first = components.first, first.count >= 2,
              first.allSatisfy({ $0.isASCII && $0.isLowercase && $0.isLetter }) else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// A Team ID: ten uppercase ASCII letters and digits.
    static func isTeamID(_ text: Substring) -> Bool {
        text.count == 10 && text.allSatisfy { $0.isASCII && ($0.isUppercase || $0.isNumber) }
    }

    /// One bundle ID is the other or extends it by whole components, compared without case.
    static func related(_ first: String, _ second: String) -> Bool {
        let a = first.lowercased(), b = second.lowercased()
        return a == b || a.hasPrefix(b + ".") || b.hasPrefix(a + ".")
    }
}

extension InstalledApps {
    /// The one app (by bundle) whose bundle ID extends `identifier` by whole components (`com.example.app` for a
    /// group named `com.example`); `nil` when none or several do.
    func uniqueApp(extending identifier: String) -> InstalledApp? {
        let prefix = identifier.lowercased() + "."
        let found = apps.filter { $0.bundleID.lowercased().hasPrefix(prefix) }
        return Set(found.map(\.path)).count == 1 ? found.first : nil
    }
}

extension DiskTree {
    /// The item at an absolute path inside the scanned root, the root included; `nil` when the tree does not hold it.
    public func index(atPath path: String) -> Int? {
        if path == rootPath { return 0 }
        let base = rootPath == "/" ? "/" : rootPath + "/"
        guard path.hasPrefix(base) else { return nil }
        return item(at: String(path.dropFirst(base.count)))?.index
    }
}
