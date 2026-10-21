import Foundation

/// What the matcher reads besides the tree. Tests inject each part; `live(home:)` reads this Mac's.
public struct ReclaimContext: Sendable {
    /// The home folder's real path, as the scanner reports paths.
    public var home: String
    /// The time ages are measured from.
    public var now: Date
    public var installedApps: InstalledApps
    public var simulatorRuntimes: SimulatorRuntimes
    /// `docker system df`'s image space; `nil` when the CLI was not asked, which leaves the Docker rule out.
    public var dockerImages: DockerImageUsage?

    public init(home: String, now: Date = Date(), installedApps: InstalledApps, simulatorRuntimes: SimulatorRuntimes,
                dockerImages: DockerImageUsage? = nil) {
        self.home = home
        self.now = now
        self.installedApps = installedApps
        self.simulatorRuntimes = simulatorRuntimes
        self.dockerImages = dockerImages
    }

    /// This Mac's home folder (its real path), installed apps, and simulator runtimes, with the Docker image space
    /// given. Reading apps checks each app's signature, so this runs off the main thread.
    public static func live(home: String = NSHomeDirectory(), dockerImages: DockerImageUsage? = nil) -> ReclaimContext {
        let real = realpath(home, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        } ?? home
        return ReclaimContext(home: real, installedApps: .read(folders: InstalledApps.defaultFolders(home: home)),
                              simulatorRuntimes: .read(), dockerImages: dockerImages)
    }
}

/// One item a match measured, which a Trash cleanup would move.
public struct ReclaimItem: Equatable, Sendable {
    public let path: String
    /// The item's index in the scan's tree.
    public let index: Int
    /// The rule's folder that holds the item (DerivedData, Downloads, a project folder), which a cleanup never removes.
    public let root: String
    /// `nil` when the item could not be read.
    public let sizes: DiskSizes?
    public let flags: DiskItemFlags
    public let touched: Date?
}

/// The bytes a match reports.
public enum ReclaimBytes: Equatable, Sendable {
    /// Summed from the scan over the items. `private` is at least what removing them all frees (the private size of
    /// each), `allocated` the space they use. `complete` is false when an item's size is unknown or a lower bound,
    /// which makes both sums lower bounds.
    case scanned(private: UInt64, allocated: UInt64, complete: Bool)
    /// The image space `docker system df` reports as reclaimable inside the VM and the space all images use.
    /// `docker image prune -f` removes only dangling images, so it may free less than `reclaimable`.
    case dockerReclaimable(UInt64, total: UInt64?)
    case unavailable(String)

    /// The bytes shown for the match: the private sum, or Docker's reclaimable figure.
    public var bytes: UInt64? {
        switch self {
        case let .scanned(privateBytes, _, _): privateBytes
        case let .dockerReclaimable(bytes, _): bytes
        case .unavailable: nil
        }
    }
}

/// One rule's match: what it found, how much space that is, and the rule's risk, explanation, and cleanup.
public struct ReclaimMatch: Equatable, Sendable {
    public let rule: ReclaimRule
    /// The installed app whose caches these are (App caches).
    public let app: InstalledApp?
    /// The identifier the leftovers are named for (App leftovers).
    public let identifier: String?
    /// In path order.
    public let items: [ReclaimItem]
    public let bytes: ReclaimBytes

    public var risk: ReclaimRisk { rule.risk }
    public var cleanup: ReclaimCleanup { rule.cleanup }
}

/// Applies the catalog to one scan's tree. Rules only describe: nothing is deleted, moved, or run, and the only files
/// read besides the tree are simulator devices' `device.plist`.
public enum ReclaimMatcher {
    /// Flags that make an item's sizes unknown or a lower bound.
    static let lowerBoundFlags: DiskItemFlags = [.unreadable, .partial, .incomplete]

    /// Every match in catalog order. A rule whose folders the tree does not hold has none; a folder that could not be
    /// read gives a match with unavailable bytes. `origins` are the Library entries `DiskOrigins.entries` attributed,
    /// which the App caches and App leftovers rules use.
    public static func matches(in tree: DiskTree, origins: [DiskOriginEntry], context: ReclaimContext) -> [ReclaimMatch] {
        var matcher = Matching(tree: tree, context: context)
        for rule in ReclaimRules.all {
            switch rule.id {
            case .xcodeDerivedData, .simulatorCaches, .cargoRegistryCache, .gradleCaches, .pipCache:
                matcher.contents(of: rule.homePaths[0], rule: rule)
            case .xcodeDeviceSupport:
                matcher.deviceSupport(rule)
            case .unavailableSimulators:
                matcher.unavailableSimulators(rule)
            case .xcodeArchives:
                matcher.archives(rule)
            case .staleNodeModules:
                matcher.staleNodeModules(rule)
            case .npmCache, .pnpmStore, .yarnCache, .homebrewCache, .trash:
                matcher.folders(rule)
            case .dockerImages:
                matcher.docker(rule)
            case .appCaches:
                let caches = origins.filter { $0.folder == .caches && $0.rule == .bundleID && $0.app != nil }
                for group in Dictionary(grouping: caches, by: { $0.app!.path }).sorted(by: { $0.key < $1.key }) {
                    matcher.add(rule, items: group.value.map { matcher.item($0.index, path: $0.path, root: matcher.homePath($0.folder.homePath)) },
                                app: group.value[0].app)
                }
            case .appLeftovers:
                let leftovers = origins.filter { $0.rule == .leftover }
                for group in Dictionary(grouping: leftovers, by: { $0.identifier.lowercased() }).sorted(by: { $0.key < $1.key }) {
                    matcher.add(rule, items: group.value.map { matcher.item($0.index, path: $0.path, root: matcher.homePath($0.folder.homePath)) },
                                identifier: group.value[0].identifier)
                }
            case .deviceBackups:
                matcher.contents(of: rule.homePaths[0], rule: rule)
            case .oldInstallers:
                matcher.oldInstallers(rule)
            }
        }
        return matcher.matches
    }
}

private struct Matching {
    let tree: DiskTree
    let context: ReclaimContext
    var matches: [ReclaimMatch] = []

    init(tree: DiskTree, context: ReclaimContext) {
        self.tree = tree
        self.context = context
    }

    func homePath(_ relative: String) -> String {
        context.home + "/" + relative
    }

    func item(_ index: Int, path: String, root: String) -> ReclaimItem {
        let item = tree[index]
        return ReclaimItem(path: path, index: index, root: root, sizes: item.sizes, flags: item.flags, touched: item.touched)
    }

    func children(of index: Int, path: String) -> [ReclaimItem] {
        tree.children(of: index).map { item($0.index, path: path + "/" + $0.name, root: path) }
    }

    /// Adds a match for `items`, summing their scanned sizes; no items, no match. `complete` is false when something
    /// the rule would count could not be judged.
    mutating func add(_ rule: ReclaimRule, items: [ReclaimItem], app: InstalledApp? = nil, identifier: String? = nil,
                      complete judged: Bool = true) {
        guard !items.isEmpty else { return }
        let sorted = items.sorted { $0.path < $1.path }
        var privateBytes: UInt64 = 0
        var allocated: UInt64 = 0
        var complete = judged
        var measured = false
        for item in sorted {
            guard let sizes = item.sizes else {
                complete = false
                continue
            }
            measured = true
            privateBytes += sizes.private
            allocated += sizes.allocated
            if !item.flags.isDisjoint(with: ReclaimMatcher.lowerBoundFlags) { complete = false }
        }
        let bytes: ReclaimBytes = measured
            ? .scanned(private: privateBytes, allocated: allocated, complete: complete)
            : .unavailable(sorted.count == 1 ? "\(sorted[0].path) could not be read." : "None of the \(sorted.count) items could be read.")
        matches.append(ReclaimMatch(rule: rule, app: app, identifier: identifier, items: sorted, bytes: bytes))
    }

    /// A folder the tree holds but could not read, so its contents are unknown.
    mutating func unreadable(_ rule: ReclaimRule, path: String) {
        matches.append(ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [],
                                    bytes: .unavailable("\(path) could not be read.")))
    }

    /// The folder's contents, each an item; the folder itself stays.
    mutating func contents(of relative: String, rule: ReclaimRule) {
        let path = homePath(relative)
        guard let index = tree.index(atPath: path) else { return }
        if tree[index].sizes == nil { return unreadable(rule, path: path) }
        add(rule, items: children(of: index, path: path))
    }

    /// The rule's folders themselves, for a tool command that cleans them or for information.
    mutating func folders(_ rule: ReclaimRule) {
        var items: [ReclaimItem] = []
        for relative in rule.homePaths {
            let path = homePath(relative)
            guard let index = tree.index(atPath: path) else { continue }
            items.append(item(index, path: path, root: (path as NSString).deletingLastPathComponent))
        }
        add(rule, items: items)
    }

    /// The contents of each `* DeviceSupport` folder in `~/Library/Developer/Xcode`, one OS version each.
    mutating func deviceSupport(_ rule: ReclaimRule) {
        let xcode = homePath(rule.homePaths[0])
        guard let index = tree.index(atPath: xcode) else { return }
        var items: [ReclaimItem] = []
        for child in tree.children(of: index) where child.kind == .directory && child.name.hasSuffix(" DeviceSupport") {
            let path = xcode + "/" + child.name
            if child.sizes == nil { unreadable(rule, path: path); continue }
            items += children(of: child.index, path: path)
        }
        add(rule, items: items)
    }

    /// Simulator device folders whose `device.plist` names a runtime that is not installed. A device whose plist cannot
    /// be read is not counted and makes the sum incomplete; an unknown runtime list measures nothing.
    mutating func unavailableSimulators(_ rule: ReclaimRule) {
        let path = homePath(rule.homePaths[0])
        guard let index = tree.index(atPath: path) else { return }
        if tree[index].sizes == nil { return unreadable(rule, path: path) }
        let devices = tree.children(of: index).filter { $0.kind == .directory }
        guard !devices.isEmpty else { return }
        let installed: Set<String>
        switch context.simulatorRuntimes {
        case let .installed(found): installed = found
        case let .unknown(reason):
            matches.append(ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [], bytes: .unavailable(reason)))
            return
        }
        var items: [ReclaimItem] = []
        var unknownDevices = 0
        for device in devices {
            let devicePath = path + "/" + device.name
            guard let runtime = SimulatorRuntimes.runtime(ofDevice: devicePath) else {
                unknownDevices += 1
                continue
            }
            if !installed.contains(runtime) { items.append(item(device.index, path: devicePath, root: path)) }
        }
        add(rule, items: items, complete: unknownDevices == 0)
    }

    /// Each `.xcarchive` in Archives, directly or in a date folder.
    mutating func archives(_ rule: ReclaimRule) {
        let path = homePath(rule.homePaths[0])
        guard let index = tree.index(atPath: path) else { return }
        if tree[index].sizes == nil { return unreadable(rule, path: path) }
        var items: [ReclaimItem] = []
        for child in tree.children(of: index) {
            let childPath = path + "/" + child.name
            if child.name.hasSuffix(".xcarchive") {
                items.append(item(child.index, path: childPath, root: path))
            } else if child.kind == .directory {
                for inner in tree.children(of: child.index) where inner.name.hasSuffix(".xcarchive") {
                    items.append(item(inner.index, path: childPath + "/" + inner.name, root: path))
                }
            }
        }
        add(rule, items: items)
    }

    /// `node_modules` folders in project folders (one holding `package.json`) under the home folder, outside
    /// `~/Library` and hidden folders (`~/.vscode/extensions`, `~/.nvm`, the Trash), whose project has not been
    /// touched for longer than `ReclaimRules.staleNodeModulesAge`. Only the outermost `node_modules` of a path counts.
    mutating func staleNodeModules(_ rule: ReclaimRule) {
        guard let (start, startPath) = homeWalkStart() else { return }
        var items: [ReclaimItem] = []
        var stack = [(start, startPath)]
        while let (index, path) = stack.popLast() {
            let children = tree.children(of: index)
            for child in children where child.kind == .directory {
                let childPath = path + "/" + child.name
                if child.name.hasPrefix(".") || childPath == homePath("Library") { continue }
                if child.name == "node_modules" {
                    if children.contains(where: { $0.name == "package.json" && $0.kind == .file }),
                       let newest = newestTouch(inProject: index),
                       context.now.timeIntervalSince(newest) > ReclaimRules.staleNodeModulesAge {
                        items.append(item(child.index, path: childPath, root: path))
                    }
                    continue
                }
                stack.append((child.index, childPath))
            }
        }
        add(rule, items: items)
    }

    /// The tree item to search from for data under the home folder, and its path: the home folder, or the scanned root
    /// when it is inside the home folder, outside `~/Library` and hidden folders.
    func homeWalkStart() -> (Int, String)? {
        if let index = tree.index(atPath: context.home) { return (index, context.home) }
        let prefix = context.home + "/"
        guard tree.rootPath.hasPrefix(prefix) else { return nil }
        let relative = tree.rootPath.dropFirst(prefix.count).split(separator: "/")
        guard relative.first != "Library", !relative.contains(where: { $0.hasPrefix(".") }) else { return nil }
        return (0, tree.rootPath)
    }

    /// The latest touch of the project folder and everything in it outside `node_modules` folders, or `nil` when
    /// any of it has no time or was not read in full, so it may hold something newer.
    func newestTouch(inProject project: Int) -> Date? {
        var newest = Date.distantPast
        var stack = [project]
        while let index = stack.popLast() {
            let item = tree[index]
            guard let touched = item.touched, !item.flags.contains(.unreadable), !item.flags.contains(.partial) else {
                return nil
            }
            // A folder that is incomplete without listed children was not read at all.
            if item.kind == .directory, item.flags.contains(.incomplete), item.children.isEmpty { return nil }
            newest = max(newest, touched)
            for child in item.children where !(tree[child].name == "node_modules" && tree[child].kind == .directory) {
                stack.append(child)
            }
        }
        return newest
    }

    /// `.dmg` and `.pkg` files and packages anywhere in Downloads untouched for longer than
    /// `ReclaimRules.oldInstallerAge`. One whose time is unknown is left out.
    mutating func oldInstallers(_ rule: ReclaimRule) {
        let root = homePath(rule.homePaths[0])
        guard let start = tree.index(atPath: root) else { return }
        if tree[start].sizes == nil { return unreadable(rule, path: root) }
        var items: [ReclaimItem] = []
        var stack = [(start, root)]
        while let (index, path) = stack.popLast() {
            for child in tree.children(of: index) {
                let childPath = path + "/" + child.name
                let suffix = (child.name as NSString).pathExtension.lowercased()
                if child.kind == .file || child.kind == .package, suffix == "dmg" || suffix == "pkg" {
                    if let touched = child.touched, context.now.timeIntervalSince(touched) > ReclaimRules.oldInstallerAge {
                        items.append(item(child.index, path: childPath, root: root))
                    }
                } else if child.kind == .directory {
                    stack.append((child.index, childPath))
                }
            }
        }
        add(rule, items: items)
    }

    mutating func docker(_ rule: ReclaimRule) {
        guard let usage = context.dockerImages else { return }
        let bytes: ReclaimBytes
        switch usage {
        case let .reported(space, _):
            bytes = space.reclaimable.map { .dockerReclaimable($0, total: space.size) }
                ?? .unavailable("docker system df did not report reclaimable image space.")
        case let .unavailable(reason):
            bytes = .unavailable(reason.reason)
        }
        matches.append(ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [], bytes: bytes))
    }
}
