import Darwin

/// A file on one volume: an inode, or a clone ID. `realDevice` keeps the system and data volumes of the startup disk
/// apart across a firmlink, where inode numbers can repeat.
struct FileKey: Hashable, Sendable {
    let device: UInt32
    let id: UInt64
}

/// What a scan does with one directory entry.
struct EntryFacts: Equatable, Sendable {
    enum Descent: Equatable, Sendable {
        /// A folder: listed, with its children as items.
        case folder
        /// A package: read for its total, but its contents are not items.
        case package
    }

    var kind: DiskItemKind
    var flags: DiskItemFlags = []
    /// The sizes shown for a file. A folder's or package's come from its contents after the scan.
    var sizes: DiskSizes = .zero
    /// What the item adds to its parent's total before hard links and clones are resolved: a folder's own
    /// allocation, or a file's allocated size less the blocks it shares with a clone.
    var contribution: DiskSizes = .zero
    var descent: Descent?
    /// The inode of a file with more than one hard link, counted once.
    var link: FileKey?
    var linkCount: UInt32 = 1
    /// The clone ID of a file that may share blocks. Its shared bytes are counted once per ID only when its physical
    /// ranges could not be read.
    var clone: FileKey?
    var shared: UInt64 = 0
    /// Where a file that shares blocks has them, merged; totals count the union of their contents' ranges.
    var extents: [Range<UInt64>]?
    /// The file's private bytes, kept when a hard link shows zero: they count where every link is.
    var privateBytes: UInt64 = 0
    /// A folder's inode, so one reached twice is read once.
    var directory: FileKey?
    /// The identity the folder must still have when it is opened. A firmlink's entry describes the link on the
    /// read-only system volume, not the folder it opens on the data volume, so it is not checked.
    var opensAs: FileKey? { flags.contains(.firmlink) ? nil : directory }
    /// The errno that made the entry unreadable.
    var error: Int32 = 0

    /// The Finder flag that makes a folder a package.
    static let hasBundleBit: UInt16 = 0x2000

    /// Classifies an entry. `isPackage` asks Launch Services about a folder whose name has an extension and that lacks
    /// the bundle bit; it is not called otherwise.
    init(_ entry: DirectoryEntry, isPackage: () -> Bool) {
        let type = entry.objectType
        let device = entry.realDevice ?? 0
        let flags = entry.flags ?? 0
        guard entry.error == 0, let type else {
            // An entry whose attributes failed returns no type, so its kind is unknown.
            self.init(kind: type.map(Self.kind) ?? .other, flags: .unreadable)
            error = entry.error == 0 ? EIO : entry.error
            return
        }
        if type == VDIR.rawValue {
            if let status = entry.mountStatus,
               status & UInt32(DIR_MNTSTATUS_MNTPOINT | DIR_MNTSTATUS_TRIGGER) != 0 {
                self.init(kind: .mountPoint)
                return
            }
            if flags & UInt32(bitPattern: SF_DATALESS) != 0 {
                // Reading a dataless folder would download it.
                self.init(kind: .directory, flags: .dataless)
                return
            }
            let own = entry.allocatedSize ?? 0
            let bundle = (entry.finderFlags ?? 0) & Self.hasBundleBit != 0
            if bundle || (Self.hasExtension(entry.name) && isPackage()) {
                self.init(kind: .package, contribution: DiskSizes(logical: 0, allocated: own, private: own),
                          descent: .package)
            } else {
                self.init(kind: .directory, flags: flags & UInt32(SF_FIRMLINK) != 0 ? .firmlink : [],
                          contribution: DiskSizes(logical: 0, allocated: own, private: own), descent: .folder)
            }
            directory = entry.fileID.map { FileKey(device: device, id: $0) }
            return
        }
        let kind = Self.kind(type)
        let logical = entry.logicalSize ?? (kind == .other ? 0 : nil)
        let allocated = entry.allocatedSize ?? (kind == .other ? 0 : nil)
        guard let logical, let allocated else {
            self.init(kind: kind, flags: .unreadable)
            error = ENOTSUP
            return
        }
        if flags & UInt32(bitPattern: SF_DATALESS) != 0 {
            let sizes = DiskSizes(logical: logical, allocated: 0, private: 0)
            self.init(kind: kind, flags: .dataless, sizes: sizes, contribution: sizes)
            return
        }
        // A file system without private sizes (HFS+, exFAT) shares no blocks, so all of it is private.
        let privateSize = min(entry.privateSize ?? allocated, allocated)
        self.init(kind: kind, sizes: DiskSizes(logical: logical, allocated: allocated, private: privateSize))
        contribution = sizes
        privateBytes = privateSize
        if let count = entry.linkCount, count > 1, let id = entry.fileID {
            // Deleting one link frees nothing; the folder holding every link frees the file.
            self.flags.insert(.hardLinked)
            link = FileKey(device: device, id: id)
            linkCount = count
            sizes.private = 0
            contribution = .zero
        }
        if let extended = entry.extendedFlags, extended & UInt64(EF_MAY_SHARE_BLOCKS) != 0, let id = entry.cloneID {
            self.flags.insert(.sharesBlocks)
            clone = FileKey(device: device, id: id)
            shared = allocated - privateSize
            if link == nil { contribution.allocated = privateSize }
            // A clone changed after cloning has its own ID, so the blocks it still shares count with each copy.
            if extended & UInt64(EF_SHARES_ALL_BLOCKS) == 0, shared > 0 { self.flags.insert(.allocatedUpperBound) }
        }
    }

    /// A file sharing blocks with a clone, whose physical ranges make totals exact.
    var needsExtents: Bool { kind == .file && clone != nil && shared > 0 }

    /// Counts the file from its physical ranges: it adds nothing to its parent itself, its ranges join the union every
    /// total above counts, and it no longer makes a total an upper bound. Without ranges it stays counted by clone ID.
    mutating func use(extents: [Range<UInt64>]?) {
        guard let extents else { return }
        self.extents = extents
        flags.remove(.allocatedUpperBound)
        contribution.allocated = 0
    }

    init(kind: DiskItemKind, flags: DiskItemFlags = [], sizes: DiskSizes = .zero,
                 contribution: DiskSizes = .zero, descent: Descent? = nil) {
        self.kind = kind
        self.flags = flags
        self.sizes = sizes
        self.contribution = contribution
        self.descent = descent
    }

    static func kind(_ objectType: UInt32) -> DiskItemKind {
        switch objectType {
        case VDIR.rawValue: .directory
        case VREG.rawValue: .file
        case VLNK.rawValue: .symlink
        default: .other
        }
    }

    /// `Foo.app` has one; `.git`, `notes.`, and `README` do not.
    static func hasExtension(_ name: String) -> Bool {
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return false }
        return name.index(after: dot) != name.endIndex
    }
}
