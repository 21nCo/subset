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
    /// A group container an installed app's signature declares as one of its app groups
    /// (`com.apple.security.application-groups`), whatever it is called (`group.is.workflow.my.app` is Shortcuts').
    /// With several apps declaring it, only their vendor when they share one; with several vendors it is not
    /// attributed.
    case appGroup
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
    /// A bundle ID, or a group container's Team ID, that no installed app has, and in Group Containers no installed
    /// app declares, with every app in the app folders read (`InstalledApps.isComplete`), and in Group Containers
    /// every signature too.
    case leftover
    /// What would be a leftover, while an app, or in Group Containers an app's signature, could not be read
    /// (`InstalledApps.unread`, `unreadSigning`): it may be that app's, so it is not attributed, and the leftovers it
    /// may be are unknown.
    case possibleLeftover
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
    /// The installed app, for `bundleID`, `appName`, and an `appGroup` or a `teamID` with one app.
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
    /// Entries nothing attributed, possible leftovers included.
    case unattributed
}

/// Tree items summed under one origin. Items are distinct entries of the tree, none inside another.
public struct DiskOriginGroup: Equatable, Sendable, Identifiable {
    public let id: DiskOriginGroupKey
    public let name: String
    /// The tree indices of the items summed.
    public let items: [Int]
    /// Summed allocated sizes, a hard-linked file's once. Blocks two items' clones share count once in each, which
    /// `allocatedUpperBound` then says.
    public let allocated: UInt64
    /// An item's allocated size may count blocks clones share more than once (`DiskItemFlags.allocatedUpperBound`), or
    /// two or more items may hold clones (`DiskTree.sum`), so `allocated` may be more than the items use.
    public let allocatedUpperBound: Bool
    /// Summed private sizes: at least what deleting every item would free.
    public let `private`: UInt64
    /// An item's size is unknown or a lower bound, another link counts an item's blocks, or the group may have items the
    /// scan did not list, so both sums are lower bounds.
    public let isLowerBound: Bool
}

/// Disk usage by origin: every entry of the Library folders, attributed, and grouped by app, vendor, developer tool,
/// and leftovers.
public struct DiskOriginReport: Equatable, Sendable {
    public let entries: [DiskOriginEntry]
    /// Why Library folders were not listed in full (unreadable, cancelled, a link) or an entry's name did not come back.
    /// Any origin may have had entries there, so every app, vendor, leftovers, and not attributed group is then a lower
    /// bound.
    public let unlistedFolders: [String]
    /// By app, with macOS for Apple identifiers.
    public let apps: [DiskOriginGroup]
    public let vendors: [DiskOriginGroup]
    /// By the developer tool of each reclaim match's items (Xcode, npm, Homebrew…).
    public let developerTools: [DiskOriginGroup]
    /// A lower bound, even when empty, with possible leftovers (`DiskOriginRule.possibleLeftover`).
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
    /// tool. A tool's group is a lower bound when one of its matches is incomplete or unavailable; Docker's image space
    /// is inside its VM, not in the tree, so it is not summed. Groups are ordered by allocated size, largest first,
    /// then by name.
    public static func report(entries: [DiskOriginEntry], matches: [ReclaimMatch], tree: DiskTree, home: String,
                              apps: InstalledApps) -> DiskOriginReport {
        let unlisted = LibraryFolder.allCases.compactMap { folder -> String? in
            switch tree.locate(home + "/" + folder.homePath) {
            case let .found(index): tree.libraryFolder(index)
            case let .unknown(reason): reason
            case .absent: nil
            }
        }
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
            case .unattributed, .possibleLeftover: unattributed.append(entry.index)
            // A group several vendors' apps declare is no one app's or vendor's.
            case .appGroup where entry.appOrigin == nil && entry.vendor == nil: unattributed.append(entry.index)
            default: break
            }
        }
        var byTool: [String: (items: [Int], incomplete: Bool)] = [:]
        for match in matches {
            guard let tool = match.rule.developerTool, match.rule.id != .dockerImages else { continue }
            let incomplete: Bool
            switch match.bytes {
            case let .scanned(_, _, complete, _): incomplete = !complete
            case .dockerReclaimable, .unavailable: incomplete = true
            }
            byTool[tool, default: ([], false)].items.append(contentsOf: match.items.map(\.index))
            if incomplete { byTool[tool]!.incomplete = true }
        }
        let entriesIncomplete = !unlisted.isEmpty
        let leftoversIncomplete = entriesIncomplete || entries.contains { $0.rule == .possibleLeftover }
        func ordered(_ groups: [DiskOriginGroup]) -> [DiskOriginGroup] {
            groups.sorted { ($1.allocated, $0.name) < ($0.allocated, $1.name) }
        }
        return DiskOriginReport(
            entries: entries,
            unlistedFolders: unlisted,
            apps: ordered(byApp.map {
                group(.origin($0.key), name: $0.value.name, items: $0.value.items, tree: tree, incomplete: entriesIncomplete)
            }),
            vendors: ordered(byVendor.map {
                group(.origin($0.key), name: vendorName($0.key, apps: apps), items: $0.value, tree: tree, incomplete: entriesIncomplete)
            }),
            developerTools: ordered(byTool.map {
                group(.developerTool($0.key), name: $0.key, items: $0.value.items, tree: tree, incomplete: $0.value.incomplete)
            }),
            leftovers: leftovers.isEmpty && !leftoversIncomplete ? nil
                : group(.leftovers, name: "Leftovers", items: leftovers, tree: tree, incomplete: leftoversIncomplete),
            unattributed: unattributed.isEmpty ? nil
                : group(.unattributed, name: "Not attributed", items: unattributed, tree: tree, incomplete: entriesIncomplete))
    }

    /// `incomplete`: the group may have items the tree does not list, so its sums are lower bounds.
    static func group(_ key: DiskOriginGroupKey, name: String, items: [Int], tree: DiskTree,
                      incomplete: Bool) -> DiskOriginGroup {
        let unique = Array(Set(items)).sorted()
        let sum = tree.sum(unique)
        return DiskOriginGroup(id: key, name: name, items: unique, allocated: sum.allocated,
                               allocatedUpperBound: sum.allocatedUpperBound, private: sum.private,
                               isLowerBound: incomplete || sum.lowerBound)
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
        // Installed apps' own evidence first: an app group a signature declares, then a bundle ID. A heuristic below
        // never makes an installed app's data a leftover.
        if folder == .groupContainers {
            // macOS can prefix the container of a declared group with the declaring app's Team ID
            // (`TEAMID.group.com.example` for `group.com.example`).
            var declaring = apps.apps(group: item.name)
            if let team, let dot = item.name.firstIndex(of: ".") {
                declaring += apps.apps(group: String(item.name[item.name.index(after: dot)...]))
                    .filter { $0.signature?.teamID == team }
            }
            if Set(declaring.map(\.path)).count == 1 { return make(.appGroup, app: declaring[0]) }
            if !declaring.isEmpty {
                let vendors = Set(declaring.map(\.vendor))
                return make(.appGroup, vendor: vendors.count == 1 ? vendors.first : nil)
            }
        }
        if identifier.contains("."), let app = apps.app(bundleID: identifier) { return make(.bundleID, app: app) }
        if identifier.lowercased().hasPrefix("com.apple.") { return make(.appleIdentifier, appOrigin: .macOS, vendor: .apple) }
        let shaped = isBundleID(identifier)
        if let team {
            let signed = apps.apps(team: team)
            if shaped, let app = signed.first(where: { related($0.bundleID, identifier) }) { return make(.bundleID, app: app) }
            if Set(signed.map(\.path)).count == 1 { return make(.teamID, app: signed[0]) }
            if !signed.isEmpty { return make(.teamID, vendor: .vendor(teamID: team)) }
        }
        // An app group is often its app's bundle ID shortened (`group.com.example` for `com.example.app`).
        if folder == .groupContainers, identifier.contains("."), let app = apps.uniqueApp(extending: identifier) {
            return make(.bundleID, app: app)
        }
        if let app = apps.app(named: identifier) { return make(.appName, app: app) }
        // The entry may be an app's that could not be read, or in Group Containers one whose signature or entitlements
        // could not be.
        let unproven = folder == .groupContainers ? !apps.signingComplete : !apps.isComplete
        if team != nil || shaped {
            return make(unproven ? .possibleLeftover : .leftover, vendor: team.map { .vendor(teamID: $0) })
        }
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

    /// Why the leftovers among `entries` are not all known: what was not read that makes its possible leftovers
    /// (`DiskOriginRule.possibleLeftover`) unproven; `nil` with none.
    static func unprovenLeftovers(_ entries: [DiskOriginEntry], apps: InstalledApps) -> String? {
        let possible = entries.filter { $0.rule == .possibleLeftover }
        guard let first = possible.first else { return nil }
        let unread = possible.contains { $0.folder == .groupContainers } ? apps.unreadSigning : apps.unread
        let named = possible.count == 1 ? first.path : "\(first.path) and \(possible.count - 1) more entries"
        let sources = unread.count > 1 ? "\(unread[0]) \(unread.count - 1) more apps or app folders could not be read." : unread.first ?? ""
        return "\(named) may be leftovers or an installed app's data: \(sources)"
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
