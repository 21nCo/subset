/// Collects a scan's items and resolves its totals once reading stops. Not thread-safe; the scan holds its lock.
///
/// Totals use allocated sizes. A hard-linked file counts once, at its link with the smallest path, and its private
/// size counts at the closest folder holding every link. A file that shares blocks with a clone and whose physical
/// ranges were read adds nothing itself: each folder, package, and root counts the union of the ranges of every such
/// file beneath it, so blocks clones share count once however their clone IDs relate (a clone changed after cloning
/// gets its own ID, and a clone of it another, though most blocks are still common).
///
/// A clone whose ranges could not be read adds its private bytes, and its shared bytes count once per clone ID in
/// each folder: pure clones share an ID, so a folder holding a file and its clone counts their blocks once. APFS does
/// not say which blocks two clone IDs share, so such a total is exact only while its shared bytes come from one
/// source, either one clone ID every member of which shares all its blocks or the read ranges. A total with shared
/// bytes from two or more sources, or with an unread file that shares only some of its blocks, may count blocks more
/// than once, as `du` does; it and every total above it are flagged `allocatedUpperBound`.
struct TreeBuilder {
    struct LinkOccurrence {
        let node: Int32
        /// The occurrence is its own item; otherwise it is inside the package `node`.
        let isItem: Bool
        let key: FileKey
        let linkCount: UInt32
        let facts: EntryFacts
        let path: String
    }

    struct CloneOccurrence {
        let node: Int32
        let key: FileKey
        let shared: UInt64
    }

    struct ExtentOccurrence {
        let node: Int32
        let ranges: [Range<UInt64>]
    }

    let rootPath: String
    private(set) var nodes: [DiskTree.Node] = []
    private var names: [UInt8] = []
    private var contributions: [DiskSizes] = []
    private var links: [LinkOccurrence] = []
    private var clones: [CloneOccurrence] = []
    private var extents: [ExtentOccurrence] = []
    private var directories: Set<FileKey> = []
    private(set) var unreadablePaths: [String] = []

    /// Starts a tree whose root is the scanned folder, classified from its own attributes like any entry.
    init(rootPath: String, rootName: String, root: EntryFacts) {
        self.rootPath = rootPath
        _ = append(name: rootName, facts: root, parent: -1)
    }

    var count: Int { nodes.count }

    /// Whether `count` more items fit the tree's 32-bit indices and offsets.
    func hasRoom(for count: Int, nameBytes: Int) -> Bool {
        nodes.count + count < Int(Int32.max) && names.count + nameBytes < Int(UInt32.max)
    }

    /// Adds a folder's children, contiguously, and returns the index of the first.
    mutating func appendChildren(_ children: [(name: String, facts: EntryFacts)], to parent: Int32,
                                 parentPath: String) -> Int32 {
        let first = Int32(nodes.count)
        nodes[Int(parent)].firstChild = first
        nodes[Int(parent)].childCount = Int32(children.count)
        for child in children {
            let index = append(name: child.name, facts: child.facts, parent: parent)
            record(child.facts, node: index, isItem: true, path: DiskScan.join(parentPath, child.name))
        }
        return first
    }

    /// Adds an entry read inside the package `owner` to the package's total. A placeholder inside flags the package
    /// `containsDataless`, since its contents are not listed.
    mutating func addToPackage(_ facts: EntryFacts, owner: Int32, path: @autoclosure () -> String) {
        contributions[Int(owner)].add(facts.contribution)
        insert(facts.flags.intersection(.allocatedUpperBound), into: owner)
        if facts.flags.contains(.dataless) { insert(.containsDataless, into: owner) }
        if facts.flags.contains(.unreadable) { markUnreadable(owner, path: path(), isItem: false) }
        record(facts, node: owner, isItem: false, path: path())
    }

    /// Records a folder about to be read. One reached before (a directory hard link) comes back counting nothing,
    /// flagged `countedElsewhere`, and not to be read.
    mutating func admit(_ facts: EntryFacts) -> EntryFacts {
        guard facts.descent != nil, let key = facts.directory, !directories.insert(key).inserted else { return facts }
        var duplicate = facts
        duplicate.flags.insert(.countedElsewhere)
        duplicate.contribution = .zero
        duplicate.descent = nil
        return duplicate
    }

    /// A folder that turned out, when opened, to be another volume's root: mounted after its parent was read, it counts
    /// zero and is not read, like a mount point listed as one.
    mutating func becameMountPoint(_ node: Int32) {
        nodes[Int(node)].kind = .mountPoint
        contributions[Int(node)] = .zero
    }

    mutating func insert(_ flags: DiskItemFlags, into node: Int32) {
        nodes[Int(node)].flags.formUnion(flags)
    }

    /// A folder that could not be opened or read: an item's size (a package's too) becomes unknown; a folder inside a
    /// package makes the package's sizes a lower bound.
    mutating func markUnreadable(_ node: Int32, path: String, isItem: Bool) {
        insert(isItem ? .unreadable : .incomplete, into: node)
        unreadablePaths.append(path)
    }

    private mutating func append(name: String, facts: EntryFacts, parent: Int32) -> Int32 {
        let index = Int32(nodes.count)
        let bytes = Array(name.utf8.prefix(Int(UInt16.max)))
        nodes.append(DiskTree.Node(
            nameStart: UInt32(names.count), nameLength: UInt16(bytes.count), kind: facts.kind, flags: facts.flags,
            parent: parent, firstChild: index + 1, childCount: 0, sizes: facts.sizes))
        names.append(contentsOf: bytes)
        contributions.append(facts.contribution)
        return index
    }

    private mutating func record(_ facts: EntryFacts, node: Int32, isItem: Bool, path: @autoclosure () -> String) {
        if facts.flags.contains(.unreadable), isItem { unreadablePaths.append(path()) }
        if let key = facts.link {
            links.append(LinkOccurrence(node: node, isItem: isItem, key: key, linkCount: facts.linkCount,
                                        facts: facts, path: path()))
        } else if let ranges = facts.extents {
            extents.append(ExtentOccurrence(node: node, ranges: ranges))
        } else if let key = facts.clone {
            clones.append(CloneOccurrence(node: node, key: key, shared: facts.shared))
        }
    }

    /// Resolves hard links and clones, sums each folder's contents, and packs the tree.
    mutating func finish() -> DiskTree {
        var totals = contributions
        var cloneOccurrences = clones
        var extentOccurrences = extents
        for group in Dictionary(grouping: links, by: \.key).values {
            let counted = group.min { $0.path < $1.path }!
            var add = counted.facts.contribution
            add.logical = counted.facts.sizes.logical
            if let ranges = counted.facts.extents {
                add.allocated = 0
                extentOccurrences.append(ExtentOccurrence(node: counted.node, ranges: ranges))
            } else if let clone = counted.facts.clone {
                add.allocated = counted.facts.privateBytes
                cloneOccurrences.append(CloneOccurrence(node: counted.node, key: clone, shared: counted.facts.shared))
            } else {
                add.allocated = counted.facts.sizes.allocated
            }
            totals[Int(counted.node)].add(add)
            for other in group where other.isItem && other.node != counted.node {
                nodes[Int(other.node)].flags.insert(.countedElsewhere)
            }
            if group.count >= Int(counted.linkCount) {
                totals[Int(commonAncestor(of: group.map(\.node)))].private += counted.facts.privateBytes
            }
        }
        var sharedOnce = [UInt64](repeating: 0, count: nodes.count)
        // The one source of shared bytes each total includes so far, a clone group or the read ranges; a second makes
        // it an upper bound.
        var onlyGroup = [Int32](repeating: -1, count: nodes.count)
        func claim(_ node: Int32, for id: Int32) {
            // A walk stops where this source was seen or the flag is already set; the flag spreads up below.
            var current = node
            while current >= 0, onlyGroup[Int(current)] != id,
                  !nodes[Int(current)].flags.contains(.allocatedUpperBound) {
                guard onlyGroup[Int(current)] < 0 else {
                    nodes[Int(current)].flags.insert(.allocatedUpperBound)
                    break
                }
                onlyGroup[Int(current)] = id
                current = nodes[Int(current)].parent
            }
        }
        var ranges: [Int32: [Range<UInt64>]] = [:]
        for occurrence in extentOccurrences {
            claim(occurrence.node, for: Int32.max)
            ranges[occurrence.node, default: []].append(contentsOf: occurrence.ranges)
        }
        for (index, group) in Dictionary(grouping: cloneOccurrences, by: \.key).values.enumerated() {
            let id = Int32(index)
            for occurrence in group where occurrence.shared > 0 {
                claim(occurrence.node, for: id)
            }
            guard group.count > 1 else {
                totals[Int(group[0].node)].allocated += group[0].shared
                continue
            }
            // Each folder holding a member counts the group's largest shared size once. A walk stops at a folder
            // that already counts as much, since every folder above it does too.
            var largest: [Int32: UInt64] = [:]
            for occurrence in group {
                var current = occurrence.node
                while current >= 0, largest[current, default: 0] < occurrence.shared {
                    largest[current] = occurrence.shared
                    current = nodes[Int(current)].parent
                }
            }
            for (node, shared) in largest { sharedOnce[Int(node)] += shared }
        }
        let lowerBound: DiskItemFlags = [.unreadable, .partial, .incomplete]
        for index in stride(from: nodes.count - 1, through: 0, by: -1) {
            let parent = Int(nodes[index].parent)
            if !nodes[index].flags.isDisjoint(with: lowerBound) {
                nodes[index].flags.insert(.incomplete)
                if parent >= 0 { nodes[parent].flags.insert(.incomplete) }
            }
            if parent >= 0, nodes[index].flags.contains(.allocatedUpperBound) {
                nodes[parent].flags.insert(.allocatedUpperBound)
            }
            if parent >= 0 { totals[parent].add(totals[index]) }
            // The ranges of every read clone beneath, merged once here and passed up merged.
            var union: UInt64 = 0
            if let beneath = ranges.removeValue(forKey: Int32(index)) {
                let merged = PhysicalExtents.union(beneath)
                union = PhysicalExtents.bytes(merged)
                if parent >= 0 { ranges[Int32(parent), default: []].append(contentsOf: merged) }
            }
            switch nodes[index].kind {
            case .directory, .package:
                var sizes = totals[index]
                sizes.allocated += sharedOnce[index] + union
                nodes[index].sizes = sizes
            case .file, .symlink, .other, .mountPoint:
                break
            }
        }
        return DiskTree(rootPath: rootPath, nodes: nodes, names: names)
    }

    /// The deepest node that is an ancestor of, or one of, every node given.
    private func commonAncestor(of members: [Int32]) -> Int32 {
        var chain: [Int32] = []
        var current = members[0]
        while current >= 0 {
            chain.append(current)
            current = nodes[Int(current)].parent
        }
        let position = Dictionary(uniqueKeysWithValues: chain.enumerated().map { ($1, $0) })
        var highest = 0
        for member in members.dropFirst() {
            var node = member
            while position[node] == nil { node = nodes[Int(node)].parent }
            highest = max(highest, position[node]!)
        }
        return chain[highest]
    }
}

extension DiskSizes {
    mutating func add(_ other: DiskSizes) {
        logical += other.logical
        allocated += other.allocated
        `private` += other.private
    }
}
