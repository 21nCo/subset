/// Collects a scan's items and resolves its totals once reading stops. Not thread-safe; the scan holds its lock.
///
/// Totals use allocated sizes. A hard-linked file counts once, at its link with the smallest path, and its private
/// size counts at the closest folder holding every link. A file that may share blocks with a clone adds its private
/// bytes, and its shared bytes count once per clone ID in each folder: pure clones share an ID, so a folder holding a
/// file and its clone counts their blocks once. A clone changed after cloning gets its own ID, so the blocks it still
/// shares count with each copy, as `du` counts them.
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

    let rootPath: String
    private(set) var nodes: [DiskTree.Node] = []
    private var names: [UInt8] = []
    private var contributions: [DiskSizes] = []
    private var links: [LinkOccurrence] = []
    private var clones: [CloneOccurrence] = []
    private var directories: Set<FileKey> = []
    private(set) var unreadablePaths: [String] = []

    init(rootPath: String, rootName: String) {
        self.rootPath = rootPath
        _ = append(name: rootName, facts: EntryFacts(kind: .directory, descent: .folder), parent: -1)
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

    /// Adds an entry read inside the package `owner` to the package's total.
    mutating func addToPackage(_ facts: EntryFacts, owner: Int32, path: @autoclosure () -> String) {
        contributions[Int(owner)].add(facts.contribution)
        if facts.flags.contains(.unreadable) { markUnreadable(owner, path: path(), isItem: false) }
        record(facts, node: owner, isItem: false, path: path())
    }

    /// Records a folder about to be read, or returns `false` when it was reached before (a directory hard link).
    mutating func visit(_ key: FileKey?) -> Bool {
        guard let key else { return true }
        return directories.insert(key).inserted
    }

    mutating func insert(_ flags: DiskItemFlags, into node: Int32) {
        nodes[Int(node)].flags.formUnion(flags)
    }

    /// A folder that could not be opened or read: an item's size becomes unknown; a package's is incomplete.
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
        } else if let key = facts.clone {
            clones.append(CloneOccurrence(node: node, key: key, shared: facts.shared))
        }
    }

    /// Resolves hard links and clones, sums each folder's contents, and packs the tree.
    mutating func finish() -> DiskTree {
        var totals = contributions
        var cloneOccurrences = clones
        for group in Dictionary(grouping: links, by: \.key).values {
            let counted = group.min { $0.path < $1.path }!
            var add = counted.facts.contribution
            add.logical = counted.facts.sizes.logical
            add.allocated = counted.facts.clone == nil ? counted.facts.sizes.allocated : counted.facts.privateBytes
            totals[Int(counted.node)].add(add)
            if let clone = counted.facts.clone {
                cloneOccurrences.append(CloneOccurrence(node: counted.node, key: clone, shared: counted.facts.shared))
            }
            for other in group where other.isItem && other.node != counted.node {
                nodes[Int(other.node)].flags.insert(.countedElsewhere)
            }
            if group.count >= Int(counted.linkCount) {
                totals[Int(commonAncestor(of: group.map(\.node)))].private += counted.facts.privateBytes
            }
        }
        var sharedOnce = [UInt64](repeating: 0, count: nodes.count)
        for group in Dictionary(grouping: cloneOccurrences, by: \.key).values {
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
            if parent >= 0 { totals[parent].add(totals[index]) }
            switch nodes[index].kind {
            case .directory, .package:
                var sizes = totals[index]
                sizes.allocated += sharedOnce[index]
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
