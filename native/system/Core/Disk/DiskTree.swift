/// The sizes of a scanned item, in bytes.
public struct DiskSizes: Equatable, Sendable {
    /// The size its contents claim (`st_size`, summed over all forks).
    public var logical: UInt64
    /// The space allocated on the volume, the figure totals use. A sparse file allocates less than its logical size,
    /// a compressed one too. Exact unless the item is flagged `allocatedUpperBound`, when it may count blocks clones
    /// share more than once.
    public var allocated: UInt64
    /// The space freed if only this item were deleted: allocated blocks not shared with a clone, not kept by a local
    /// snapshot, and not reachable through a hard link outside the item. A lower bound: APFS reports a compressed
    /// file's data, held in an extended attribute, as not private, and blocks clones share are never counted as freed,
    /// even when every clone is inside a folder.
    public var `private`: UInt64

    public init(logical: UInt64, allocated: UInt64, private: UInt64) {
        self.logical = logical
        self.allocated = allocated
        self.private = `private`
    }

    public static let zero = DiskSizes(logical: 0, allocated: 0, private: 0)
}

/// What a scanned item is.
public enum DiskItemKind: UInt8, Sendable {
    case file
    case directory
    /// A package bundle (`.app`, `.photoslibrary`, a folder with the bundle bit): one item with its contents' total,
    /// which are not listed.
    case package
    /// A symbolic link, counted as itself and never followed.
    case symlink
    /// A FIFO, socket, or device node.
    case other
    /// A directory another volume (or an automount trigger) is mounted on. It is not crossed and counts as zero.
    case mountPoint
}

public struct DiskItemFlags: OptionSet, Hashable, Sendable {
    public let rawValue: UInt16
    public init(rawValue: UInt16) { self.rawValue = rawValue }

    /// An iCloud (or other file provider) placeholder whose data is not on this Mac: zero allocated, never downloaded.
    public static let dataless = DiskItemFlags(rawValue: 1 << 0)
    /// The item could not be read (permission, privacy protection, an I/O error): its size is unknown.
    public static let unreadable = DiskItemFlags(rawValue: 1 << 1)
    /// The scan was cancelled before this folder was read in full, or before it was read at all.
    public static let partial = DiskItemFlags(rawValue: 1 << 2)
    /// The file has more than one hard link.
    public static let hardLinked = DiskItemFlags(rawValue: 1 << 3)
    /// Another link to the same file, or the same folder reached another way, is the one totals count.
    public static let countedElsewhere = DiskItemFlags(rawValue: 1 << 4)
    /// The file may share blocks with a clone (`EF_MAY_SHARE_BLOCKS`).
    public static let sharesBlocks = DiskItemFlags(rawValue: 1 << 5)
    /// Something inside could not be read or was not scanned, so the item's sizes are a lower bound.
    public static let incomplete = DiskItemFlags(rawValue: 1 << 6)
    /// A firmlink, the startup disk's link from the system volume into the data volume (`/Users`, `/Applications`).
    public static let firmlink = DiskItemFlags(rawValue: 1 << 7)
    /// The allocated size may count blocks shared between clones more than once, so it is an upper bound. APFS gives
    /// only a clone ID and a shared byte count, so a total is exact only while it includes shared bytes from at most
    /// one clone ID, every member of which shares all its blocks. Set on a file that shares some but not all of its
    /// blocks (`EF_MAY_SHARE_BLOCKS` without `EF_SHARES_ALL_BLOCKS`: a clone changed after cloning), and on every
    /// folder or package whose total includes such a file or shared bytes from two or more clone IDs (a clone of a
    /// changed clone gets another ID while sharing most blocks with the first). Unrelated clone groups in one folder
    /// set it too, conservatively.
    public static let allocatedUpperBound = DiskItemFlags(rawValue: 1 << 8)
}

/// One item of a scan.
public struct DiskItem: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let kind: DiskItemKind
    public let flags: DiskItemFlags
    /// For a folder or package, its own allocation plus its contents' totals, with each hard-linked file counted once
    /// and each clone ID's shared bytes once. `nil` when the item itself could not be read.
    public let sizes: DiskSizes?
    /// The parent's index, `nil` for the root.
    public let parent: Int?
    /// The indices of the listed children; a package's contents are not listed.
    public let children: Range<Int>
}

/// A scan's items, packed for memory: one fixed-size record per item and one buffer for all names. Children of a
/// folder are contiguous, and every item comes after its parent, so index 0 is the root.
public struct DiskTree: Sendable {
    struct Node {
        var nameStart: UInt32
        var nameLength: UInt16
        var kind: DiskItemKind
        var flags: DiskItemFlags
        var parent: Int32
        var firstChild: Int32
        var childCount: Int32
        var sizes: DiskSizes
    }

    /// The scanned root's path.
    public let rootPath: String
    var nodes: [Node]
    var names: [UInt8]

    public var count: Int { nodes.count }
    public var root: DiskItem { self[0] }

    public subscript(index: Int) -> DiskItem {
        let node = nodes[index]
        let first = Int(node.firstChild)
        return DiskItem(
            index: index, name: name(of: index), kind: node.kind, flags: node.flags,
            sizes: node.flags.contains(.unreadable) ? nil : node.sizes,
            parent: node.parent < 0 ? nil : Int(node.parent), children: first..<(first + Int(node.childCount)))
    }

    public func children(of index: Int) -> [DiskItem] {
        self[index].children.map { self[$0] }
    }

    /// The item's path: the root's path, then each name below it.
    public func path(of index: Int) -> String {
        var components: [String] = []
        var current = index
        while current > 0 {
            components.append(name(of: current))
            current = Int(nodes[current].parent)
        }
        let base = rootPath == "/" ? "" : rootPath
        return components.isEmpty ? rootPath : base + "/" + components.reversed().joined(separator: "/")
    }

    /// The first item whose path relative to the root is `relativePath` (`"a/b"`), or `nil`.
    public func item(at relativePath: String) -> DiskItem? {
        var current = 0
        for component in relativePath.split(separator: "/") {
            guard let next = self[current].children.first(where: { name(of: $0) == component }) else { return nil }
            current = next
        }
        return self[current]
    }

    func name(of index: Int) -> String {
        let node = nodes[index]
        let start = Int(node.nameStart)
        return String(decoding: names[start..<(start + Int(node.nameLength))], as: UTF8.self)
    }
}
