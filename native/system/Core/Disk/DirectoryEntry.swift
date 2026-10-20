import Darwin

/// One directory entry as `getattrlistbulk` returned it. An attribute the file system did not return is `nil`.
struct DirectoryEntry: Equatable, Sendable {
    var name: String
    /// `ATTR_CMN_ERROR`: a nonzero errno when the entry's attributes could not be read.
    var error: Int32 = 0
    /// `ATTR_CMN_OBJTYPE` (`VREG`, `VDIR`, `VLNK`, ...).
    var objectType: UInt32?
    /// The Finder flags from `ATTR_CMN_FNDRINFO`, which hold the bundle bit.
    var finderFlags: UInt16?
    /// `ATTR_CMN_FLAGS`, the `st_flags` bits such as `SF_DATALESS` and `SF_FIRMLINK`.
    var flags: UInt32?
    /// `ATTR_CMN_FILEID`, the inode number.
    var fileID: UInt64?
    /// `ATTR_FILE_LINKCOUNT`.
    var linkCount: UInt32?
    /// `ATTR_FILE_TOTALSIZE`, the logical size of all forks.
    var logicalSize: UInt64?
    /// `ATTR_FILE_ALLOCSIZE` or `ATTR_DIR_ALLOCSIZE`, the bytes allocated to all forks.
    var allocatedSize: UInt64?
    /// `ATTR_DIR_MOUNTSTATUS`.
    var mountStatus: UInt32?
    /// `ATTR_CMNEXT_PRIVATESIZE`: the bytes not shared with a clone or kept by a snapshot, freed if it is deleted.
    var privateSize: UInt64?
    /// `ATTR_CMNEXT_REALDEVID`, the volume the entry is on, even across a firmlink.
    var realDevice: UInt32?
    /// `ATTR_CMNEXT_CLONEID`: pure clones of each other share it.
    var cloneID: UInt64?
    /// `ATTR_CMNEXT_EXT_FLAGS` (`EF_MAY_SHARE_BLOCKS`, ...).
    var extendedFlags: UInt64?

    init(name: String) {
        self.name = name
    }
}

/// The attributes the scanner asks `getattrlistbulk` for, and the parser for the buffer it fills.
enum BulkAttributes {
    static let common: attrgroup_t = attrgroup_t(bitPattern: Int32(bitPattern: ATTR_CMN_RETURNED_ATTRS))
        | attrgroup_t(ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE | ATTR_CMN_FNDRINFO | ATTR_CMN_FLAGS
            | ATTR_CMN_FILEID)
    static let directory = attrgroup_t(ATTR_DIR_MOUNTSTATUS | ATTR_DIR_ALLOCSIZE)
    static let file = attrgroup_t(ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE)
    static let extended = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE | ATTR_CMNEXT_REALDEVID | ATTR_CMNEXT_CLONEID
        | ATTR_CMNEXT_EXT_FLAGS)
    /// The extended attributes live in the fork group and need this option.
    static let options = UInt64(FSOPT_ATTR_CMN_EXTENDED)

    static var list: attrlist {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = common
        list.dirattr = directory
        list.fileattr = file
        list.forkattr = extended
        return list
    }

    /// Parses `count` entries from a buffer `getattrlistbulk` filled. Each entry starts with its length, then the
    /// attributes it returned, packed in bit order within each group (common, directory, file, extended), except that
    /// `ATTR_CMN_ERROR` comes right after the returned set. Only returned attributes take space. An entry whose name
    /// is missing or not UTF-8 is returned with an empty name and `EILSEQ`, so it is counted and listed, not dropped.
    static func parse(_ buffer: UnsafeRawBufferPointer, count: Int) -> [DirectoryEntry] {
        var entries: [DirectoryEntry] = []
        entries.reserveCapacity(count)
        var offset = 0
        for _ in 0..<count {
            guard offset + 4 <= buffer.count else { break }
            let length = Int(buffer.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
            guard length >= 4, offset + length <= buffer.count else { break }
            let entry = UnsafeRawBufferPointer(rebasing: buffer[offset..<(offset + length)])
            entries.append(parseEntry(entry))
            offset += length
        }
        return entries
    }

    private static func parseEntry(_ entry: UnsafeRawBufferPointer) -> DirectoryEntry {
        var reader = FieldReader(entry, offset: 4)
        guard let returned = reader.read(attribute_set_t.self) else { return unreadable() }
        func has(_ group: attrgroup_t, _ bit: Int32) -> Bool { group & attrgroup_t(bitPattern: bit) != 0 }
        var error: Int32 = 0
        if has(returned.commonattr, ATTR_CMN_ERROR) { error = Int32(bitPattern: reader.read(UInt32.self) ?? UInt32(EIO)) }
        var result = DirectoryEntry(name: "")
        if has(returned.commonattr, ATTR_CMN_NAME), let reference = reader.peek(attrreference_t.self) {
            let start = reader.offset + Int(reference.attr_dataoffset)
            let length = Int(reference.attr_length)
            if reference.attr_dataoffset >= 0, length > 0, start + length <= entry.count {
                // attr_length counts the terminating NUL.
                let bytes = UnsafeRawBufferPointer(rebasing: entry[start..<(start + length - 1)])
                let name = String(decoding: bytes, as: UTF8.self)
                // Decoding replaces invalid bytes, so a name that does not round-trip was not UTF-8.
                if name.utf8.elementsEqual(bytes) { result.name = name }
            }
            reader.skip(MemoryLayout<attrreference_t>.size)
        }
        result.error = result.name.isEmpty && error == 0 ? EILSEQ : error
        if has(returned.commonattr, ATTR_CMN_OBJTYPE) { result.objectType = reader.read(UInt32.self) }
        if has(returned.commonattr, ATTR_CMN_FNDRINFO) {
            // FileInfo and FolderInfo both keep their big-endian finderFlags at byte 8 of the 32 bytes.
            if let raw = reader.peek(UInt16.self, at: 8) { result.finderFlags = UInt16(bigEndian: raw) }
            reader.skip(32)
        }
        if has(returned.commonattr, ATTR_CMN_FLAGS) { result.flags = reader.read(UInt32.self) }
        if has(returned.commonattr, ATTR_CMN_FILEID) { result.fileID = reader.read(UInt64.self) }
        if has(returned.dirattr, ATTR_DIR_MOUNTSTATUS) { result.mountStatus = reader.read(UInt32.self) }
        if has(returned.dirattr, ATTR_DIR_ALLOCSIZE) { result.allocatedSize = reader.readSize() }
        if has(returned.fileattr, ATTR_FILE_LINKCOUNT) { result.linkCount = reader.read(UInt32.self) }
        if has(returned.fileattr, ATTR_FILE_TOTALSIZE) { result.logicalSize = reader.readSize() }
        if has(returned.fileattr, ATTR_FILE_ALLOCSIZE) { result.allocatedSize = reader.readSize() }
        if has(returned.forkattr, ATTR_CMNEXT_PRIVATESIZE) { result.privateSize = reader.readSize() }
        if has(returned.forkattr, ATTR_CMNEXT_REALDEVID) { result.realDevice = reader.read(UInt32.self) }
        if has(returned.forkattr, ATTR_CMNEXT_CLONEID) { result.cloneID = reader.read(UInt64.self) }
        if has(returned.forkattr, ATTR_CMNEXT_EXT_FLAGS) { result.extendedFlags = reader.read(UInt64.self) }
        return result
    }

    private static func unreadable() -> DirectoryEntry {
        var entry = DirectoryEntry(name: "")
        entry.error = EIO
        return entry
    }
}

/// Reads fixed-size fields from an attribute buffer, which aligns each one to 4 bytes only.
private struct FieldReader {
    let buffer: UnsafeRawBufferPointer
    var offset: Int

    init(_ buffer: UnsafeRawBufferPointer, offset: Int) {
        self.buffer = buffer
        self.offset = offset
    }

    func peek<T>(_ type: T.Type, at extra: Int = 0) -> T? {
        let start = offset + extra
        guard start + MemoryLayout<T>.size <= buffer.count else { return nil }
        return buffer.loadUnaligned(fromByteOffset: start, as: T.self)
    }

    mutating func read<T>(_ type: T.Type) -> T? {
        defer { skip(MemoryLayout<T>.size) }
        return peek(type)
    }

    /// An `off_t`; a negative one is not a size.
    mutating func readSize() -> UInt64? {
        read(Int64.self).flatMap { $0 >= 0 ? UInt64($0) : nil }
    }

    mutating func skip(_ count: Int) {
        // Each attribute is padded to a multiple of 4 bytes.
        offset += (count + 3) & ~3
    }
}
