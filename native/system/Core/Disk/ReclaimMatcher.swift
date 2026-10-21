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
    /// Summed from the scan over the items: their usage. `private` is the sum of each item's private size, which
    /// deleting them all frees at least, `allocated` the space they use, a hard-linked file's once. Whether and when
    /// the rule's cleanup frees it is the rule's `yield` (`ReclaimMatch.freedAtLeast`, `ReclaimMatch.movedToTrash`).
    /// `complete` is false when an item's size is unknown or a lower bound, or another link counts an item's blocks,
    /// which makes both sums lower bounds.
    /// `allocatedUpperBound` is true when an item's allocated size may count blocks clones share more than once
    /// (`DiskItemFlags.allocatedUpperBound`), or two or more items may hold clones, whose shared blocks each item
    /// counts (`DiskTree.sum`), so the allocated sum may be more than the items use.
    case scanned(private: UInt64, allocated: UInt64, complete: Bool, allocatedUpperBound: Bool)
    /// The image space `docker system df` reports as reclaimable inside the VM and the space all images use. It
    /// counts every image no container uses, while `docker image prune -f` removes only dangling ones, so it is an
    /// upper bound of what the rule's cleanup frees, never that amount.
    case dockerReclaimable(upTo: UInt64, total: UInt64?)
    case unavailable(String)

    /// The measured private sum: what deleting every item frees at least. `nil` when unknown or known only as an
    /// upper bound (Docker's, in `upperBound`).
    public var bytes: UInt64? {
        switch self {
        case let .scanned(privateBytes, _, _, _): privateBytes
        case .dockerReclaimable, .unavailable: nil
        }
    }

    /// The most the cleanup may free, when only that is known (Docker's reclaimable image space).
    public var upperBound: UInt64? {
        if case let .dockerReclaimable(bytes, _) = self { return bytes }
        return nil
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

    /// What running the rule's cleanup frees at least, at once: the private sum when its command deletes every item
    /// (`ReclaimYield.deletesAllMeasured`: npm and Yarn caches). `nil` when no such amount is guaranteed: the cleanup
    /// moves the items to the Trash (see `movedToTrash`), keeps part of what was measured (`pnpm store prune`,
    /// `brew cleanup`), decides itself what it deletes (`simctl delete unavailable`), only an upper bound is known
    /// (Docker's, in `bytes.upperBound`), or no cleanup is offered (the Trash).
    public var freedAtLeast: UInt64? {
        rule.yield == .deletesAllMeasured ? bytes.bytes : nil
    }

    /// What the rule's cleanup moves to the Trash: the private sum when it moves every item there
    /// (`ReclaimYield.movesAllMeasuredToTrash`). That frees nothing until the Trash is emptied, which System never
    /// does; emptying it afterwards frees at least this much. `nil` for every other yield.
    public var movedToTrash: UInt64? {
        rule.yield == .movesAllMeasuredToTrash ? bytes.bytes : nil
    }
}

/// Applies the catalog to one scan's tree. Rules only describe: nothing is deleted, moved, or run, and the only files
/// read besides the tree are simulator devices' `device.plist`.
public enum ReclaimMatcher {
    /// Flags that make an item's sizes unknown or a lower bound.
    static let lowerBoundFlags: DiskItemFlags = [.unreadable, .partial, .incomplete]

    /// Every match in catalog order. A rule whose folders the tree does not hold, under folders it read in full, has
    /// none. Every folder a rule searches must have been read in full, and so must the folders above a rule folder it
    /// did not find, since only then is it absent; a found rule folder is judged by its own listing. Otherwise
    /// (unreadable, cancelled, replaced, another volume, not downloaded, a link), or when an entry in a searched folder
    /// could not be read and its type is unknown (`DiskTree.searched`), what the rule found is incomplete, and with
    /// nothing found the match has unavailable bytes and no items. `origins` are the Library entries
    /// `DiskOrigins.entries` attributed, which the App caches and App leftovers rules use.
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
                // A cache of an app that could not be read is not judged, so the caches found are not all there are.
                matcher.entries(rule, caches, by: { $0.app!.path }, app: { $0.app }, unjudged: DiskOrigins.unprovenLeftovers(
                    origins.filter { $0.folder == .caches }, apps: context.installedApps).map { [$0] } ?? [])
            case .appLeftovers:
                let leftovers = origins.filter { $0.rule == .leftover }
                // A bundle ID names one app in every folder; a group container's other name only within its team.
                // Possible leftovers are not judged, so the leftovers found are not all there are.
                matcher.entries(rule, leftovers, by: { entry in
                    (DiskOrigins.isBundleID(entry.identifier) ? "" : (entry.teamID ?? "") + ".") + entry.identifier.lowercased()
                }, identifier: { $0.identifier },
                   unjudged: DiskOrigins.unprovenLeftovers(origins, apps: context.installedApps).map { [$0] } ?? [])
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

    /// Adds a match for `items`, summing their scanned sizes. `unjudged` says what the rule could not search or judge
    /// (a folder not read in full, a device whose runtime is unknown), which makes the sums incomplete, and with no
    /// items gives a match with unavailable bytes; with neither, no match.
    mutating func add(_ rule: ReclaimRule, items: [ReclaimItem], unjudged: [String] = [], app: InstalledApp? = nil,
                      identifier: String? = nil) {
        if items.isEmpty {
            guard let first = unjudged.first else { return }
            let reason = unjudged.count == 1 ? first : "\(first) \(unjudged.count - 1) more places could not be searched in full."
            return append(rule, bytes: .unavailable(reason))
        }
        let sorted = items.sorted { $0.path < $1.path }
        let sum = tree.sum(sorted.map(\.index))
        let bytes: ReclaimBytes = sum.measured
            ? .scanned(private: sum.private, allocated: sum.allocated, complete: unjudged.isEmpty && !sum.lowerBound,
                       allocatedUpperBound: sum.allocatedUpperBound)
            : .unavailable(sorted.count == 1 ? "\(sorted[0].path) could not be read." : "None of the \(sorted.count) items could be read.")
        matches.append(ReclaimMatch(rule: rule, app: app, identifier: identifier, items: sorted, bytes: bytes))
    }

    mutating func append(_ rule: ReclaimRule, bytes: ReclaimBytes) {
        matches.append(ReclaimMatch(rule: rule, app: nil, identifier: nil, items: [], bytes: bytes))
    }

    /// One match per group of `entries` (an app's caches, one identifier's leftovers). The Library folders the
    /// entries come from must have been listed in full, and the entries not judged (`unjudged`) none: otherwise every
    /// match is incomplete, since any app may have had an entry there, and without one the rule's match is unavailable.
    mutating func entries(_ rule: ReclaimRule, _ entries: [DiskOriginEntry], by key: (DiskOriginEntry) -> String,
                          app: (DiskOriginEntry) -> InstalledApp? = { _ in nil },
                          identifier: (DiskOriginEntry) -> String? = { _ in nil }, unjudged: [String] = []) {
        var unjudged = unjudged
        for relative in rule.homePaths {
            switch tree.locate(homePath(relative)) {
            case let .found(index): if let reason = tree.libraryFolder(index) { unjudged.append(reason) }
            case let .unknown(reason): unjudged.append(reason)
            case .absent: break
            }
        }
        let groups = Dictionary(grouping: entries, by: key).sorted { $0.key < $1.key }
        if groups.isEmpty { return add(rule, items: [], unjudged: unjudged) }
        for group in groups {
            add(rule, items: group.value.map { item($0.index, path: $0.path, root: homePath($0.folder.homePath)) },
                unjudged: unjudged, app: app(group.value[0]), identifier: identifier(group.value[0]))
        }
    }

    /// The folder's contents, each an item; the folder itself stays.
    mutating func contents(of relative: String, rule: ReclaimRule) {
        let path = homePath(relative)
        switch tree.locate(path) {
        case .absent: return
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case let .found(index): add(rule, items: children(of: index, path: path), unjudged: tree.ruleFolder(index).map { [$0] } ?? [])
        }
    }

    /// The rule's folders themselves, for a tool command that cleans them or for information.
    mutating func folders(_ rule: ReclaimRule) {
        var items: [ReclaimItem] = []
        var unjudged: [String] = []
        for relative in rule.homePaths {
            let path = homePath(relative)
            switch tree.locate(path) {
            case .absent: continue
            case let .unknown(reason): unjudged.append(reason)
            case let .found(index):
                if let reason = tree.ruleFolder(index) { unjudged.append(reason) }
                if tree[index].kind == .directory { items.append(item(index, path: path, root: (path as NSString).deletingLastPathComponent)) }
            }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    /// The contents of each `* DeviceSupport` folder in `~/Library/Developer/Xcode`, one OS version each.
    mutating func deviceSupport(_ rule: ReclaimRule) {
        let xcode = homePath(rule.homePaths[0])
        let index: Int
        switch tree.locate(xcode) {
        case .absent: return
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case let .found(found): index = found
        }
        var items: [ReclaimItem] = []
        var unjudged = tree.ruleFolder(index).map { [$0] } ?? []
        for child in tree.children(of: index) {
            switch tree.searched(child.index) {
            case let .unknown(reason): unjudged.append(reason)
            case .folder, .item:
                guard child.name.hasSuffix(" DeviceSupport") else { continue }
                if let reason = tree.ruleFolder(child.index) { unjudged.append(reason) }
                items += children(of: child.index, path: xcode + "/" + child.name)
            }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    /// Simulator device folders whose `device.plist` names a runtime that is not installed. A device whose plist is
    /// missing, not downloaded, or cannot be read, or whose folder was not listed in full, is not counted and makes
    /// the sum incomplete; an unknown runtime list measures nothing.
    mutating func unavailableSimulators(_ rule: ReclaimRule) {
        let path = homePath(rule.homePaths[0])
        let index: Int
        switch tree.locate(path) {
        case .absent: return
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case let .found(found): index = found
        }
        var unjudged = tree.ruleFolder(index).map { [$0] } ?? []
        var devices: [DiskItem] = []
        for child in tree.children(of: index) {
            switch tree.searched(child.index) {
            case let .unknown(reason): unjudged.append(reason)
            // A dataless device's plist is not on this Mac, and reading it would download it.
            case .folder: if let reason = tree.unlisted(child.index) { unjudged.append(reason) } else { devices.append(child) }
            case .item: continue
            }
        }
        guard !devices.isEmpty else { return add(rule, items: [], unjudged: unjudged) }
        let installed: Set<String>
        switch context.simulatorRuntimes {
        case let .installed(found): installed = found
        case let .unknown(reason): return append(rule, bytes: .unavailable(reason))
        }
        var items: [ReclaimItem] = []
        for device in devices {
            let devicePath = path + "/" + device.name
            // Only a plist the scan found on this Mac is read.
            let plist = tree.children(of: device.index).first { $0.name == "device.plist" }
            guard let plist, plist.kind == .file, plist.flags.isDisjoint(with: [.dataless, .unreadable]) else {
                unjudged.append("\(devicePath)/device.plist " + (plist == nil ? "is missing." : "was not read."))
                continue
            }
            guard let runtime = SimulatorRuntimes.runtime(ofDevice: devicePath) else {
                unjudged.append("\(devicePath)/device.plist could not be read.")
                continue
            }
            if !installed.contains(runtime) { items.append(item(device.index, path: devicePath, root: path)) }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    /// Each `.xcarchive` in Archives, directly or in a date folder.
    mutating func archives(_ rule: ReclaimRule) {
        let path = homePath(rule.homePaths[0])
        let index: Int
        switch tree.locate(path) {
        case .absent: return
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case let .found(found): index = found
        }
        var items: [ReclaimItem] = []
        var unjudged = tree.ruleFolder(index).map { [$0] } ?? []
        for child in tree.children(of: index) {
            let childPath = path + "/" + child.name
            switch tree.searched(child.index) {
            case let .unknown(reason): unjudged.append(reason)
            case _ where child.name.hasSuffix(".xcarchive"): items.append(item(child.index, path: childPath, root: path))
            case .folder:
                if let reason = tree.unlisted(child.index) { unjudged.append(reason) }
                for inner in tree.children(of: child.index) {
                    switch tree.searched(inner.index) {
                    case let .unknown(reason): unjudged.append(reason)
                    case _ where inner.name.hasSuffix(".xcarchive"):
                        items.append(item(inner.index, path: childPath + "/" + inner.name, root: path))
                    case .folder, .item: continue
                    }
                }
            case .item: continue
            }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    /// `node_modules` folders in project folders (one holding `package.json`) under the home folder, outside
    /// `~/Library` and hidden folders (`~/.vscode/extensions`, `~/.nvm`, the Trash), whose project has not been
    /// touched for longer than `ReclaimRules.staleNodeModulesAge`. Only the outermost `node_modules` of a path counts.
    mutating func staleNodeModules(_ rule: ReclaimRule) {
        let start: Int, startPath: String
        switch tree.locate(context.home) {
        case let .found(index): (start, startPath) = (index, context.home)
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case .absent:
            guard rootInsideHome() else { return }
            (start, startPath) = (0, tree.rootPath)
        }
        var items: [ReclaimItem] = []
        var unjudged: [String] = []
        var stack = [(start, startPath)]
        while let (index, path) = stack.popLast() {
            if let reason = index == start ? tree.unread(index) : tree.unlisted(index) { unjudged.append(reason) }
            let children = tree.children(of: index)
            for child in children {
                let childPath = path + "/" + child.name
                if child.name.hasPrefix(".") || childPath == homePath("Library") { continue }
                switch tree.searched(child.index) {
                case let .unknown(reason):
                    // It may be a folder holding projects, a project's `package.json`, or its `node_modules`.
                    unjudged.append(reason)
                    continue
                case .item: continue
                case .folder: break
                }
                if child.name == "node_modules", child.kind == .directory {
                    guard children.contains(where: { $0.name == "package.json" && $0.kind == .file }) else { continue }
                    guard let newest = newestTouch(inProject: index) else {
                        unjudged.append("\(path) was not read in full, so its last change is unknown.")
                        continue
                    }
                    if context.now.timeIntervalSince(newest) > ReclaimRules.staleNodeModulesAge {
                        items.append(item(child.index, path: childPath, root: path))
                    }
                    continue
                }
                stack.append((child.index, childPath))
            }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    /// The scanned root is inside the home folder, outside `~/Library`, hidden folders, and `node_modules` folders,
    /// so the search starts there.
    func rootInsideHome() -> Bool {
        let prefix = context.home + "/"
        guard tree.rootPath.hasPrefix(prefix) else { return false }
        let relative = tree.rootPath.dropFirst(prefix.count).split(separator: "/")
        return relative.first != "Library" && !relative.contains { $0.hasPrefix(".") || $0 == "node_modules" }
    }

    /// The latest touch of the project folder and everything in it outside `node_modules` folders, a package's
    /// contents included (`DiskTree.newestTouch`), or `nil` when any of it has no time or was not read in full
    /// (`DiskTree.unlisted`, another volume included, or a package something inside of which was not read or is not
    /// downloaded), so it may hold something newer.
    func newestTouch(inProject project: Int) -> Date? {
        var newest = Date.distantPast
        var stack = [project]
        while let index = stack.popLast() {
            let item = tree[index]
            guard let touched = tree.newestTouch(index), tree.unlisted(index) == nil,
                  item.kind != .package || item.flags.isDisjoint(with: [.incomplete, .containsDataless]) else { return nil }
            newest = max(newest, touched)
            for child in item.children where !(tree[child].name == "node_modules" && tree[child].kind == .directory) {
                stack.append(child)
            }
        }
        return newest
    }

    /// `.dmg` and `.pkg` files and packages anywhere in Downloads untouched for longer than
    /// `ReclaimRules.oldInstallerAge`. One whose time is unknown is left out and makes the sum incomplete.
    mutating func oldInstallers(_ rule: ReclaimRule) {
        let root = homePath(rule.homePaths[0])
        let start: Int
        switch tree.locate(root) {
        case .absent: return
        case let .unknown(reason): return add(rule, items: [], unjudged: [reason])
        case let .found(found): start = found
        }
        var items: [ReclaimItem] = []
        var unjudged: [String] = []
        var stack = [(start, root)]
        while let (index, path) = stack.popLast() {
            if let reason = index == start ? tree.ruleFolder(index) : tree.unlisted(index) { unjudged.append(reason) }
            for child in tree.children(of: index) {
                let childPath = path + "/" + child.name
                let suffix = (child.name as NSString).pathExtension.lowercased()
                if case let .unknown(reason) = tree.searched(child.index) {
                    unjudged.append(reason)
                } else if child.kind == .file || child.kind == .package, suffix == "dmg" || suffix == "pkg" {
                    guard let touched = child.touched else {
                        unjudged.append("\(childPath) has no modification time.")
                        continue
                    }
                    if context.now.timeIntervalSince(touched) > ReclaimRules.oldInstallerAge {
                        items.append(item(child.index, path: childPath, root: root))
                    }
                } else if child.kind == .directory || child.kind == .mountPoint {
                    stack.append((child.index, childPath))
                }
            }
        }
        add(rule, items: items, unjudged: unjudged)
    }

    mutating func docker(_ rule: ReclaimRule) {
        guard let usage = context.dockerImages else { return }
        let bytes: ReclaimBytes
        switch usage {
        case let .reported(space, _):
            bytes = space.reclaimable.map { .dockerReclaimable(upTo: $0, total: space.size) }
                ?? .unavailable("docker system df did not report reclaimable image space.")
        case .unavailable(.cancelled):
            bytes = .unavailable("docker system df was stopped before it finished, so the images were not measured.")
        case let .unavailable(reason):
            bytes = .unavailable(reason.reason)
        }
        append(rule, bytes: bytes)
    }
}

/// The coverage every reclaim rule and the By origin groups share: whether a folder's entries are all listed, and what
/// each entry of a searched folder is.
extension DiskTree {
    /// Why the folder's listing is not complete, so that it may hold more than the tree lists; `nil` when it was read in
    /// full. Its contents' own sizes do not matter here, only whether every entry in it is listed.
    func unlisted(_ index: Int) -> String? {
        let item = self[index]
        var path: String { self.path(of: index) }
        if item.flags.contains(.unreadable) { return "\(path) could not be read." }
        if item.flags.contains(.partial) { return "\(path) was not read in full." }
        switch item.kind {
        case .directory:
            // An iCloud placeholder is not read, since that would download it.
            if item.flags.contains(.dataless) { return "\(path) is not downloaded, so it was not read." }
            // A folder reached a second way (a directory hard link) is read only where it was reached first.
            if item.flags.contains(.countedElsewhere) { return "\(path) was read at another path, not here." }
            // A folder is flagged incomplete when something inside could not be read, or when it was not read at all
            // (replaced before it was opened); only the latter lists nothing.
            return item.flags.contains(.incomplete) && item.children.isEmpty ? "\(path) was not read." : nil
        case .mountPoint:
            return "\(path) is another volume, which was not scanned."
        case .file, .package, .symlink, .other:
            return nil
        }
    }

    /// Why a folder the search must look in was not read: it was not listed in full (`unlisted`), or it is a link,
    /// which is not followed, to a folder elsewhere; `nil` when it was read, or is a file.
    func unread(_ index: Int) -> String? {
        if let reason = unlisted(index) { return reason }
        return self[index].kind == .symlink ? "\(path(of: index)) is a link, so it was not read." : nil
    }

    /// Why a Library folder whose entries are judged by name (App caches, App leftovers, the By origin groups) may hold
    /// more than is known: it was not read (`unread`), or an entry's name did not come back (`searched` cannot judge
    /// it), so it may be any app's; `nil` when every entry was judged.
    func libraryFolder(_ index: Int) -> String? {
        if let reason = unread(index) { return reason }
        for child in self[index].children where self[child].name.isEmpty {
            if case let .unknown(reason) = searched(child) { return reason }
        }
        return nil
    }

    /// Summed scanned sizes of distinct items, none inside another, with the bounds a match and a By origin group
    /// report.
    struct SizeSum {
        var `private`: UInt64 = 0
        var allocated: UInt64 = 0
        /// An item's size is unknown or a lower bound, or another link counts an item's blocks.
        var lowerBound = false
        /// `allocated` may count blocks clones share more than once: an item is flagged `allocatedUpperBound`, or two
        /// or more items may hold clones (`mayHoldClones`), whose shared blocks each item's own total counts.
        var allocatedUpperBound = false
        /// An item's sizes were read.
        var measured = false
    }

    /// Sums the items' sizes. Each item's total counts its own clones' blocks once, but the tree does not say which
    /// blocks two items share, so a sum over two items that may both hold clones is conservatively an upper bound.
    func sum(_ indices: [Int]) -> SizeSum {
        var sum = SizeSum()
        var holdingClones = 0
        for index in indices {
            let item = self[index]
            guard let sizes = item.sizes else {
                sum.lowerBound = true
                continue
            }
            sum.measured = true
            sum.private += sizes.private
            if !item.flags.isDisjoint(with: ReclaimMatcher.lowerBoundFlags) { sum.lowerBound = true }
            if item.flags.contains(.allocatedUpperBound) { sum.allocatedUpperBound = true }
            // Another hard link counts the file's blocks, so they are counted once, at most.
            if item.flags.contains(.countedElsewhere) {
                sum.lowerBound = true
                continue
            }
            sum.allocated += sizes.allocated
            if holdingClones < 2, mayHoldClones(index) { holdingClones += 1 }
        }
        if holdingClones >= 2 { sum.allocatedUpperBound = true }
        return sum
    }

    /// Whether the item may share blocks with a clone in another item: it is, or a folder below it lists, a file flagged
    /// `sharesBlocks`, or a package, whose contents are not listed, with a private size below its allocated size.
    func mayHoldClones(_ index: Int) -> Bool {
        var pending = [index]
        while let current = pending.popLast() {
            let node = nodes[current]
            switch node.kind {
            case .file: if node.flags.contains(.sharesBlocks) { return true }
            case .package: if node.sizes.private < node.sizes.allocated { return true }
            case .directory: pending.append(contentsOf: self[current].children)
            case .symlink, .other, .mountPoint: break
            }
        }
        return false
    }

    /// Why a rule's own folder cannot be searched: it was not read (`unread`), or it is not a folder; `nil` when it can
    /// be.
    func ruleFolder(_ index: Int) -> String? {
        if let reason = unread(index) { return reason }
        return self[index].kind == .directory ? nil : "\(path(of: index)) is not a folder."
    }

    /// What an entry of a folder a rule searches is, the same for every rule.
    enum SearchedEntry {
        /// A folder or another volume's mount point, which a search looks in only after `unlisted`.
        case folder
        /// A file, package, symbolic link, or special file, judged by its name and kind.
        case item
        /// An entry that could not be read and whose type or name did not come back: it may be anything a rule looks
        /// for (a folder, an installer, a `package.json`), so the search cannot judge it.
        case unknown(String)
    }

    func searched(_ index: Int) -> SearchedEntry {
        let item = self[index]
        if item.flags.contains(.unreadable), item.kind == .other || item.name.isEmpty {
            return .unknown("\(path(of: index)) could not be read, so what it is is unknown.")
        }
        return item.kind == .directory || item.kind == .mountPoint ? .folder : .item
    }

    enum Location {
        case found(Int)
        /// The tree holds the folders above it in full, without it, or the scan did not include it.
        case absent
        /// A folder above it was not read in full.
        case unknown(String)
    }

    /// Finds the item at `path`. A missing item is absent only when the folder that would hold it was read in full,
    /// or a file or package is there instead; below a link (`unread`) it is unknown.
    func locate(_ path: String) -> Location {
        let base = rootPath == "/" ? "/" : rootPath + "/"
        guard path == rootPath || path.hasPrefix(base) else { return .absent }
        var current = 0
        for component in path.dropFirst(min(path.count, base.count)).split(separator: "/") {
            if let next = self[current].children.first(where: { name(of: $0) == component }) {
                current = next
                continue
            }
            if case .item = searched(current), self[current].kind != .symlink { return .absent }
            return unread(current).map { .unknown($0) } ?? .absent
        }
        return .found(current)
    }
}
