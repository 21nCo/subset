import Foundation

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
    /// A FIFO, socket, or device node, or an unreadable entry whose type was not returned.
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
    /// Something inside could not be read or was not scanned, so the item's sizes are a lower bound. A folder replaced
    /// by another between being listed and being opened is not read and carries it.
    public static let incomplete = DiskItemFlags(rawValue: 1 << 6)
    /// A firmlink, the startup disk's link from the system volume into the data volume (`/Users`, `/Applications`).
    public static let firmlink = DiskItemFlags(rawValue: 1 << 7)
    /// The allocated size may count blocks shared between clones more than once, so it is an upper bound. Totals count
    /// a clone's blocks from its physical ranges, exactly, so this is set only where those could not be read (the file
    /// cannot be opened, is too fragmented, or its ranges do not add up to its allocated size, as with a compressed
    /// file). Such a file is counted from its clone ID and shared byte count instead, which is exact only while a total
    /// includes shared bytes from one source: one clone ID every member of which shares all its blocks, or the read
    /// ranges. Set on an unread file that shares some but not all of its blocks (`EF_MAY_SHARE_BLOCKS` without
    /// `EF_SHARES_ALL_BLOCKS`: a clone changed after cloning), and on every folder or package whose total includes such
    /// a file or shared bytes from two or more sources. Unrelated sources in one folder set it too, conservatively.
    public static let allocatedUpperBound = DiskItemFlags(rawValue: 1 << 8)
    /// A package whose contents, which are not listed, include a `dataless` file or folder: those count as zero
    /// allocated and a placeholder folder is not read, so the package's sizes leave out data that is not on this Mac.
    public static let containsDataless = DiskItemFlags(rawValue: 1 << 9)
}

/// One item of a scan.
public struct DiskItem: Equatable, Sendable {
    public let index: Int
    public let name: String
    public let kind: DiskItemKind
    public let flags: DiskItemFlags
    /// For a folder or package, its own allocation plus its contents' totals, with each hard-linked file counted once
    /// and each block clones share once. `nil` when the item itself could not be read.
    public let sizes: DiskSizes?
    /// The parent's index, `nil` for the root.
    public let parent: Int?
    /// The indices of the listed children; a package's contents are not listed.
    public let children: Range<Int>
    /// The later of when the item was last modified and when it was put in its folder (its date added); `nil` when
    /// the file system returned neither. A folder's own time, which changes when an entry in it is added, removed,
    /// or renamed, not when a file deeper down is written.
    public let touched: Date?
    /// The volume and inode the item had when it was scanned; `nil` when they were not read.
    public let identity: DiskItemIdentity?
}

/// Which file an item was when it was scanned: its volume and inode. A cleanup acts on an item only while its path still
/// leads to the same one.
public struct DiskItemIdentity: Hashable, Sendable {
    /// The volume's ID (`ATTR_CMNEXT_REALDEVID`, the file system ID `statfs` reports), which keeps the startup disk's
    /// system and data volumes apart; 0 when the volume did not report it.
    public let device: UInt32
    public let inode: UInt64

    public init(device: UInt32, inode: UInt64) {
        self.device = device
        self.inode = inode
    }

    /// Whether both the volume and the inode were read: only such an identity says which file it is.
    public var isComplete: Bool { device != 0 && inode != 0 }

    /// Whether `other` is the same file: both identities complete, with the same volume and the same inode. An
    /// identity whose volume was not read matches nothing, not even itself.
    public func isSameFile(as other: DiskItemIdentity) -> Bool {
        isComplete && other.isComplete && device == other.device && inode == other.inode
    }

    /// What is at `path` now, without following a symbolic link at its end (`lstat`, then `getattrlist` for the
    /// volume).
    public static func current(atPath path: String) -> DiskItemCurrent {
        var info = stat()
        guard lstat(path, &info) == 0 else {
            let error = errno
            return error == ENOENT || error == ENOTDIR ? .missing : .unreadable(error)
        }
        if info.st_mode & S_IFMT == S_IFLNK { return .symlink }
        let entry = BulkAttributes.read(path: path)
        // Both reads must describe the same file: one replaced between them is not judged.
        if let id = entry?.fileID, id != UInt64(info.st_ino) { return .unreadable(EAGAIN) }
        // Without the volume the file cannot be told from one with the same inode on another volume.
        guard let entry, let device = entry.realDevice, device != 0 else { return .unreadable(ENOTSUP) }
        return .item(DiskItemIdentity(device: device, inode: UInt64(info.st_ino)),
                     isDirectory: info.st_mode & S_IFMT == S_IFDIR)
    }
}

/// What a path leads to now, for `DiskItemIdentity.current(atPath:)`.
public enum DiskItemCurrent: Equatable, Sendable {
    case missing
    /// A symbolic link, which a cleanup never follows or moves.
    case symlink
    /// A file or folder, with its volume and inode both read.
    case item(DiskItemIdentity, isDirectory: Bool)
    /// It could not be read with this `errno`: `lstat` failed, the volume was not returned (`ENOTSUP`), or the file
    /// changed between the two reads (`EAGAIN`).
    case unreadable(Int32)
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
        /// Seconds since 1970, `Node.unknownTime` when unknown.
        var touched: Int64
        /// The volume (`ATTR_CMNEXT_REALDEVID`, 0 when not reported) and inode the entry had; `fileID` 0 when unknown.
        var device: UInt32
        var fileID: UInt64

        static let unknownTime = Int64.min
    }

    /// The scanned root's path.
    public let rootPath: String
    var nodes: [Node]
    var names: [UInt8]
    /// The latest `touched` of the entries read inside each package with any, by the package's index, which the tree
    /// does not list; `Node.unknownTime` when one had no time.
    var newestInPackages: [Int32: Int64] = [:]

    public var count: Int { nodes.count }
    public var root: DiskItem { self[0] }

    public subscript(index: Int) -> DiskItem {
        let node = nodes[index]
        let first = Int(node.firstChild)
        return DiskItem(
            index: index, name: name(of: index), kind: node.kind, flags: node.flags,
            sizes: node.flags.contains(.unreadable) ? nil : node.sizes,
            parent: node.parent < 0 ? nil : Int(node.parent), children: first..<(first + Int(node.childCount)),
            touched: node.touched == Node.unknownTime ? nil : Date(timeIntervalSince1970: TimeInterval(node.touched)),
            identity: node.fileID == 0 || node.device == 0 ? nil : DiskItemIdentity(device: node.device, inode: node.fileID))
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

    /// The latest time the item, or for a package an entry read inside it, was touched; `nil` when one has no time.
    /// A package's own time does not change when a file inside it is written.
    func newestTouch(_ index: Int) -> Date? {
        let own = nodes[index].touched
        let newest = newestInPackages[Int32(index)].map { $0 == Node.unknownTime ? $0 : max($0, own) } ?? own
        return own == Node.unknownTime || newest == Node.unknownTime ? nil : Date(timeIntervalSince1970: TimeInterval(newest))
    }

    func name(of index: Int) -> String {
        let node = nodes[index]
        let start = Int(node.nameStart)
        return String(decoding: names[start..<(start + Int(node.nameLength))], as: UTF8.self)
    }
}
