import Darwin
@testable import SystemCore
import XCTest

/// How the scanner classifies recorded `getattrlistbulk` entries, including ones a test cannot create on disk.
final class DiskEntryTests: XCTestCase {
    private func file(_ name: String = "file", allocated: UInt64 = 8192, logical: UInt64 = 5000) -> DirectoryEntry {
        var entry = DirectoryEntry(name: name)
        entry.objectType = VREG.rawValue
        entry.flags = 0
        entry.fileID = 42
        entry.linkCount = 1
        entry.logicalSize = logical
        entry.allocatedSize = allocated
        entry.privateSize = allocated
        entry.realDevice = 7
        entry.cloneID = 42
        entry.extendedFlags = 0
        return entry
    }

    private func folder(_ name: String) -> DirectoryEntry {
        var entry = DirectoryEntry(name: name)
        entry.objectType = VDIR.rawValue
        entry.flags = 0
        entry.fileID = 9
        entry.mountStatus = 0
        entry.allocatedSize = 0
        entry.finderFlags = 0
        return entry
    }

    private func facts(_ entry: DirectoryEntry, package: Bool = false) -> (EntryFacts, asked: Bool) {
        var asked = false
        let facts = EntryFacts(entry) {
            asked = true
            return package
        }
        return (facts, asked)
    }

    func testICloudPlaceholderCountsAsZeroAllocatedAndIsFlagged() {
        var placeholder = file(allocated: 0, logical: 2_000_000)
        placeholder.flags = UInt32(bitPattern: SF_DATALESS)
        placeholder.allocatedSize = 4096
        let (facts, _) = facts(placeholder)
        XCTAssertEqual(facts.sizes, DiskSizes(logical: 2_000_000, allocated: 0, private: 0))
        XCTAssertEqual(facts.contribution, facts.sizes)
        XCTAssertTrue(facts.flags.contains(.dataless))

        var placeholderFolder = folder("Projects")
        placeholderFolder.flags = UInt32(bitPattern: SF_DATALESS)
        let folderFacts = self.facts(placeholderFolder).0
        XCTAssertNil(folderFacts.descent, "reading a dataless folder would download it")
        XCTAssertTrue(folderFacts.flags.contains(.dataless))
    }

    func testMountPointsAndAutomountTriggersAreNotCrossed() {
        for status in [DIR_MNTSTATUS_MNTPOINT, DIR_MNTSTATUS_TRIGGER] {
            var entry = folder("Volume")
            entry.mountStatus = UInt32(status)
            let (facts, asked) = facts(entry)
            XCTAssertEqual(facts.kind, .mountPoint)
            XCTAssertNil(facts.descent)
            XCTAssertEqual(facts.contribution, .zero)
            XCTAssertFalse(asked)
        }
    }

    func testPackagesComeFromTheBundleBitOrLaunchServices() {
        var bundleBit = folder("Library")
        bundleBit.finderFlags = EntryFacts.hasBundleBit
        let bit = facts(bundleBit)
        XCTAssertEqual(bit.0.kind, .package)
        XCTAssertFalse(bit.asked, "the bundle bit alone makes a package")

        let app = facts(folder("Tool.app"), package: true)
        XCTAssertEqual(app.0.kind, .package)
        XCTAssertEqual(app.0.descent, .package)
        XCTAssertTrue(app.asked)

        let framework = facts(folder("Kit.framework"), package: false)
        XCTAssertEqual(framework.0.kind, .directory)
        XCTAssertEqual(framework.0.descent, .folder)

        for name in ["src", ".git", "notes."] {
            let plain = facts(folder(name), package: true)
            XCTAssertEqual(plain.0.kind, .directory, name)
            XCTAssertFalse(plain.asked, "\(name) has no extension, so Launch Services is not asked")
        }
    }

    func testFirmlinkIsReadAsAFolder() {
        var users = folder("Users")
        users.flags = UInt32(SF_FIRMLINK)
        let (facts, _) = facts(users)
        XCTAssertEqual(facts.descent, .folder)
        XCTAssertTrue(facts.flags.contains(.firmlink))
    }

    func testEntryErrorsAndMissingSizesAreUnreadable() {
        var denied = folder("Mail")
        denied.error = EPERM
        let deniedFacts = facts(denied).0
        XCTAssertEqual(deniedFacts.kind, .directory)
        XCTAssertTrue(deniedFacts.flags.contains(.unreadable))
        XCTAssertNil(deniedFacts.descent)
        XCTAssertEqual(deniedFacts.error, EPERM, "a type that was returned is kept")

        // getattrlistbulk returns only the name and the error for an entry whose attributes failed.
        var failed = DirectoryEntry(name: "Mail")
        failed.error = EACCES
        let failedFacts = facts(failed).0
        XCTAssertEqual(failedFacts.kind, .other)
        XCTAssertEqual(failedFacts.flags, .unreadable)
        XCTAssertNil(failedFacts.descent)
        XCTAssertEqual(failedFacts.error, EACCES)
        var builder = TreeBuilder(rootPath: "/r", rootName: "r", root: EntryFacts(kind: .directory, descent: .folder))
        _ = builder.appendChildren([(name: "Mail", facts: failedFacts)], to: 0, parentPath: "/r")
        XCTAssertEqual(builder.unreadablePaths, ["/r/Mail"])
        let tree = builder.finish()
        XCTAssertNil(tree.item(at: "Mail")?.sizes)
        XCTAssertTrue(tree.root.flags.contains(.incomplete))

        var noSize = file()
        noSize.allocatedSize = nil
        XCTAssertTrue(facts(noSize).0.flags.contains(.unreadable))
        XCTAssertEqual(facts(noSize).0.contribution, .zero)

        var fifo = DirectoryEntry(name: "pipe")
        fifo.objectType = VFIFO.rawValue
        XCTAssertEqual(facts(fifo).0.kind, .other)
        XCTAssertEqual(facts(fifo).0.sizes, .zero)
        XCTAssertTrue(facts(fifo).0.flags.isEmpty)
    }

    func testVolumeWithoutPrivateSizesTreatsAllocatedAsPrivate() {
        var hfs = file()
        hfs.privateSize = nil
        hfs.cloneID = nil
        hfs.extendedFlags = nil
        XCTAssertEqual(facts(hfs).0.sizes, DiskSizes(logical: 5000, allocated: 8192, private: 8192))
    }

    func testCloneContributesItsPrivateBytesAndSharesTheRest() {
        var clone = file(allocated: 4 << 20, logical: 4 << 20)
        clone.privateSize = 16384
        clone.cloneID = 1000
        clone.extendedFlags = UInt64(EF_MAY_SHARE_BLOCKS | EF_SHARES_ALL_BLOCKS)
        let (facts, _) = facts(clone)
        XCTAssertEqual(facts.sizes, DiskSizes(logical: 4 << 20, allocated: 4 << 20, private: 16384))
        XCTAssertEqual(facts.contribution.allocated, 16384)
        XCTAssertEqual(facts.shared, (4 << 20) - 16384)
        XCTAssertEqual(facts.clone, FileKey(device: 7, id: 1000))
        XCTAssertTrue(facts.flags.contains(.sharesBlocks))

        // A clone ID alone, without the flag, does not mean shared blocks: every file has one.
        XCTAssertNil(self.facts(file()).0.clone)
    }

    func testHardLinkShowsNoPrivateSizeAndWaitsToBeCountedOnce() {
        var linked = file()
        linked.linkCount = 3
        let (facts, _) = facts(linked)
        XCTAssertEqual(facts.link, FileKey(device: 7, id: 42))
        XCTAssertEqual(facts.linkCount, 3)
        XCTAssertEqual(facts.sizes.private, 0)
        XCTAssertEqual(facts.privateBytes, 8192)
        XCTAssertEqual(facts.contribution, .zero)
    }

    func testClonesSplitAcrossFoldersCountSharedBytesOncePerFolder() {
        // root ─ a ─ (x: clone 1, 100 shared) (y: clone 1, 60 shared)
        //      └ b ─ (z: clone 1, 100 shared) (w: clone 2, 50 shared)
        let folderFacts = EntryFacts(kind: .directory, descent: .folder)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: folderFacts)
        let first = builder.appendChildren([("a", folderFacts), ("b", folderFacts)], to: 0, parentPath: "/fixture")
        func clone(_ id: UInt64, shared: UInt64, private: UInt64) -> EntryFacts {
            var facts = EntryFacts(kind: .file, sizes: DiskSizes(logical: shared + `private`, allocated: shared + `private`,
                                                                    private: `private`))
            facts.contribution = DiskSizes(logical: shared + `private`, allocated: `private`, private: `private`)
            facts.clone = FileKey(device: 1, id: id)
            facts.shared = shared
            return facts
        }
        _ = builder.appendChildren([("x", clone(1, shared: 100, private: 1)), ("y", clone(1, shared: 60, private: 2))],
                                   to: first, parentPath: "/fixture/a")
        _ = builder.appendChildren([("z", clone(1, shared: 100, private: 4)), ("w", clone(2, shared: 50, private: 8))],
                                   to: first + 1, parentPath: "/fixture/b")
        let tree = builder.finish()
        XCTAssertEqual(tree.item(at: "a")?.sizes?.allocated, 1 + 2 + 100)
        XCTAssertEqual(tree.item(at: "b")?.sizes?.allocated, 4 + 8 + 100 + 50)
        XCTAssertEqual(tree.root.sizes?.allocated, 1 + 2 + 4 + 8 + 100 + 50)
        XCTAssertEqual(tree.root.sizes?.private, 15)
        XCTAssertEqual(tree.item(at: "a/x")?.sizes?.allocated, 101, "a file shows its own allocation")
        XCTAssertFalse(try XCTUnwrap(tree.item(at: "a")).flags.contains(.allocatedUpperBound), "one clone group is exact")
        XCTAssertTrue(try XCTUnwrap(tree.item(at: "b")).flags.contains(.allocatedUpperBound), "two clone IDs may overlap")
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
    }

    private func pureClone(_ id: UInt64, shared: UInt64) -> EntryFacts {
        var facts = EntryFacts(kind: .file, flags: .sharesBlocks,
                               sizes: DiskSizes(logical: shared, allocated: shared, private: 0))
        facts.contribution = DiskSizes(logical: shared, allocated: 0, private: 0)
        facts.clone = FileKey(device: 1, id: id)
        facts.shared = shared
        return facts
    }

    func testTwoPureCloneIDsMarkEveryTotalHoldingBothAsAnUpperBound() {
        // Recorded on APFS: a and c (clone 1) and d, a clone of a changed clone (clone 2), all carry 0x41 and share
        // nearly every block. root ─ n ─ x ─ (a, c, d)   root ─ n ─ y ─ (e, f: clone 3)
        //                                                root ─ Tool.app ⊃ (clone 4, clone 5)   root ─ z ─ (g: clone 6, h: 0 shared)
        let folderFacts = EntryFacts(kind: .directory, descent: .folder)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: folderFacts)
        let top = builder.appendChildren([("n", folderFacts), ("Tool.app", EntryFacts(kind: .package, descent: .package)),
                                          ("z", folderFacts)], to: 0, parentPath: "/fixture")
        let n = builder.appendChildren([("x", folderFacts), ("y", folderFacts)], to: top, parentPath: "/fixture/n")
        _ = builder.appendChildren([("a", pureClone(1, shared: 100)), ("c", pureClone(1, shared: 100)),
                                    ("d", pureClone(2, shared: 100))], to: n, parentPath: "/fixture/n/x")
        _ = builder.appendChildren([("e", pureClone(3, shared: 40)), ("f", pureClone(3, shared: 40))],
                                   to: n + 1, parentPath: "/fixture/n/y")
        builder.addToPackage(pureClone(4, shared: 30), owner: top + 1, path: "/fixture/Tool.app/one")
        builder.addToPackage(pureClone(5, shared: 30), owner: top + 1, path: "/fixture/Tool.app/two")
        _ = builder.appendChildren([("g", pureClone(6, shared: 20)), ("h", pureClone(7, shared: 0))],
                                   to: top + 2, parentPath: "/fixture/z")
        let tree = builder.finish()

        for path in ["n/x", "n", "Tool.app"] {
            XCTAssertTrue(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
        for path in ["n/y", "z", "n/x/a", "n/x/d"] {
            XCTAssertFalse(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        XCTAssertEqual(tree.item(at: "n/y")?.sizes?.allocated, 40, "one pure group counts its blocks once, exactly")
        XCTAssertEqual(tree.item(at: "z")?.sizes?.allocated, 20, "a clone that shares nothing adds no second group")
        XCTAssertEqual(tree.item(at: "n/x")?.sizes?.allocated, 200, "each clone ID counts once, an upper bound")
    }

    func testFolderReachedTwiceCountsItsOwnAllocationOnce() {
        // A directory hard link (HFS+): two entries for one folder, each with its own allocation.
        var linked = EntryFacts(kind: .directory, contribution: DiskSizes(logical: 0, allocated: 4096, private: 4096),
                                descent: .folder)
        linked.directory = FileKey(device: 1, id: 77)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: EntryFacts(kind: .directory, descent: .folder))
        let first = builder.admit(linked)
        let second = builder.admit(linked)
        XCTAssertEqual(first, linked)
        XCTAssertNil(second.descent, "the folder is read once")
        XCTAssertTrue(second.flags.contains(.countedElsewhere))
        let package = EntryFacts(kind: .package, descent: .package)
        let top = builder.appendChildren([("a", first), ("b", second), ("Tool.app", package)], to: 0, parentPath: "/fixture")

        var inner = linked
        inner.directory = FileKey(device: 1, id: 78)
        builder.addToPackage(builder.admit(inner), owner: top + 2, path: "/fixture/Tool.app/one")
        builder.addToPackage(builder.admit(inner), owner: top + 2, path: "/fixture/Tool.app/two")
        let tree = builder.finish()
        XCTAssertEqual(tree.item(at: "a")?.sizes?.allocated, 4096)
        XCTAssertEqual(tree.item(at: "b")?.sizes?.allocated, 0)
        XCTAssertTrue(try XCTUnwrap(tree.item(at: "b")).flags.contains(.countedElsewhere))
        XCTAssertEqual(tree.item(at: "Tool.app")?.sizes?.allocated, 4096, "inside a package too")
        XCTAssertEqual(tree.root.sizes?.allocated, 8192)
    }

    func testPlaceholderInsideAPackageFlagsThePackage() throws {
        var placeholder = file("Model.bin", allocated: 0, logical: 2_000_000)
        placeholder.flags = UInt32(bitPattern: SF_DATALESS)
        var placeholderFolder = folder("Assets")
        placeholderFolder.flags = UInt32(bitPattern: SF_DATALESS)
        let present = facts(file("Info.plist", allocated: 4096, logical: 900)).0
        let package = EntryFacts(kind: .package, descent: .package)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: EntryFacts(kind: .directory, descent: .folder))
        let top = builder.appendChildren([("A.app", package), ("B.app", package), ("C.app", package)],
                                         to: 0, parentPath: "/fixture")
        for (owner, name) in [(top, "A.app"), (top + 1, "B.app"), (top + 2, "C.app")] {
            builder.addToPackage(present, owner: owner, path: "/fixture/\(name)/Info.plist")
        }
        builder.addToPackage(facts(placeholder).0, owner: top, path: "/fixture/A.app/Model.bin")
        builder.addToPackage(facts(placeholderFolder).0, owner: top + 1, path: "/fixture/B.app/Assets")
        let tree = builder.finish()

        for path in ["A.app", "B.app"] {
            let item = try XCTUnwrap(tree.item(at: path))
            XCTAssertTrue(item.flags.contains(.containsDataless), path)
            XCTAssertFalse(item.flags.contains(.dataless), "the package itself is on this Mac")
            XCTAssertEqual(item.sizes?.allocated, 4096, "a placeholder adds no allocation")
        }
        XCTAssertEqual(tree.item(at: "A.app")?.sizes?.logical, 2_000_900, "a placeholder file keeps its logical size")
        XCTAssertFalse(try XCTUnwrap(tree.item(at: "C.app")).flags.contains(.containsDataless))
        XCTAssertEqual(tree.item(at: "C.app")?.sizes?.allocated, 4096)
    }

    func testCloneThatSharesOnlySomeBlocksMarksItsAllocatedAsAnUpperBound() {
        // Recorded on APFS: three pure clones carry 0x41; a 4-byte write into one gives it a new clone ID and 0x1.
        var pure = file(allocated: 4 << 20, logical: 4 << 20)
        pure.privateSize = 0
        pure.cloneID = 429_948_957
        pure.extendedFlags = 0x41
        let pureFacts = facts(pure).0
        XCTAssertTrue(pureFacts.flags.contains(.sharesBlocks))
        XCTAssertFalse(pureFacts.flags.contains(.allocatedUpperBound))

        var changed = pure
        changed.privateSize = 16384
        changed.cloneID = 429_948_961
        changed.extendedFlags = 0x1
        let changedFacts = facts(changed).0
        XCTAssertTrue(changedFacts.flags.contains(.sharesBlocks))
        XCTAssertTrue(changedFacts.flags.contains(.allocatedUpperBound))
        XCTAssertEqual(changedFacts.shared, (4 << 20) - 16384)

        // Once nothing is shared, nothing can be counted twice.
        changed.privateSize = 4 << 20
        XCTAssertFalse(facts(changed).0.flags.contains(.allocatedUpperBound))
    }

    func testUpperBoundReachesEveryFolderAndPackageAboveAndNoOther() {
        // root ─ a ─ b ─ (changed)   root ─ c ─ (pure)   root ─ Tool.app ⊃ (changed)
        var changed = EntryFacts(kind: .file, flags: [.sharesBlocks, .allocatedUpperBound],
                                 sizes: DiskSizes(logical: 10, allocated: 10, private: 2))
        changed.contribution = DiskSizes(logical: 10, allocated: 2, private: 2)
        changed.clone = FileKey(device: 1, id: 5)
        changed.shared = 8
        var pure = EntryFacts(kind: .file, flags: .sharesBlocks, sizes: DiskSizes(logical: 10, allocated: 10, private: 0))
        pure.contribution = DiskSizes(logical: 10, allocated: 0, private: 0)
        pure.clone = FileKey(device: 1, id: 6)
        pure.shared = 10
        let folderFacts = EntryFacts(kind: .directory, descent: .folder)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: folderFacts)
        let first = builder.appendChildren([("a", folderFacts), ("c", folderFacts),
                                            ("Tool.app", EntryFacts(kind: .package, descent: .package))],
                                           to: 0, parentPath: "/fixture")
        let b = builder.appendChildren([("b", folderFacts)], to: first, parentPath: "/fixture/a")
        _ = builder.appendChildren([("changed", changed)], to: b, parentPath: "/fixture/a/b")
        _ = builder.appendChildren([("pure", pure)], to: first + 1, parentPath: "/fixture/c")
        builder.addToPackage(changed, owner: first + 2, path: "/fixture/Tool.app/Contents/changed")
        let tree = builder.finish()

        for path in ["a/b/changed", "a/b", "a", "Tool.app"] {
            XCTAssertTrue(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
        XCTAssertFalse(try XCTUnwrap(tree.item(at: "c")).flags.contains(.allocatedUpperBound))
        XCTAssertFalse(try XCTUnwrap(tree.item(at: "c/pure")).flags.contains(.allocatedUpperBound))
    }

    func testReadRangesCountTheirUnionInEveryTotalAndAnUnreadCloneStaysAnUpperBound() {
        // Recorded on APFS: a 4-byte write into a clone gives it a new clone ID and 0x1.
        var entry = file(allocated: 300, logical: 300)
        entry.privateSize = 100
        entry.cloneID = 429_948_961
        entry.extendedFlags = 0x1
        var unread = facts(entry).0
        XCTAssertTrue(unread.needsExtents)
        unread.use(extents: nil)
        XCTAssertTrue(unread.flags.contains(.allocatedUpperBound), "without ranges it is counted by clone ID")
        func clone(_ ranges: [Range<UInt64>]) -> EntryFacts {
            var facts = facts(entry).0
            facts.use(extents: ranges)
            return facts
        }
        let read = clone([0..<100, 200..<300])
        XCTAssertFalse(read.flags.contains(.allocatedUpperBound))
        XCTAssertEqual(read.contribution.allocated, 0)
        XCTAssertEqual(read.sizes.allocated, 300, "a file shows its own allocation")
        var linked = clone([1000..<1100])
        linked.flags.insert(.hardLinked)
        linked.link = FileKey(device: 7, id: 77)
        linked.linkCount = 2
        linked.contribution = .zero

        // root ─ a ─ (p, q sharing 0..<100, h: a link)   root ─ Tool.app ⊃ (r sharing p's 200..<300)
        // root ─ m ─ (s: 0..<100, u: unread clone)        root ─ h: the link's other name
        let folderFacts = EntryFacts(kind: .directory, descent: .folder)
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture", root: folderFacts)
        let top = builder.appendChildren([("a", folderFacts), ("Tool.app", EntryFacts(kind: .package, descent: .package)),
                                          ("m", folderFacts), ("h", linked)], to: 0, parentPath: "/fixture")
        _ = builder.appendChildren([("p", read), ("q", clone([0..<100, 300..<350])), ("h", linked)],
                                   to: top, parentPath: "/fixture/a")
        builder.addToPackage(clone([200..<300]), owner: top + 1, path: "/fixture/Tool.app/r")
        _ = builder.appendChildren([("s", clone([0..<100])), ("u", unread)], to: top + 2, parentPath: "/fixture/m")
        let tree = builder.finish()

        XCTAssertEqual(tree.item(at: "a")?.sizes?.allocated, 100 + 150 + 100, "shared ranges count once, the link too")
        XCTAssertEqual(tree.item(at: "Tool.app")?.sizes?.allocated, 100)
        XCTAssertEqual(tree.item(at: "m")?.sizes?.allocated, 100 + 100 + 200)
        XCTAssertEqual(tree.root.sizes?.allocated, 350 + 100 + 200, "the ranges' union plus the unread clone")
        XCTAssertTrue(try XCTUnwrap(tree.item(at: "h")).flags.contains(.countedElsewhere))
        for path in ["a", "a/p", "Tool.app", "m/s"] {
            XCTAssertFalse(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        for path in ["m", "m/u"] {
            XCTAssertTrue(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
    }

    func testRootCountsItsOwnAllocation() {
        // exFAT gives every folder an allocation, the scanned one included.
        var root = folder("sub")
        root.allocatedSize = 4096
        let rootFacts = facts(root).0
        XCTAssertEqual(rootFacts.contribution, DiskSizes(logical: 0, allocated: 4096, private: 4096))
        var builder = TreeBuilder(rootPath: "/Volumes/Stick/sub", rootName: "sub", root: rootFacts)
        let child = EntryFacts(kind: .directory, contribution: DiskSizes(logical: 0, allocated: 4096, private: 4096),
                               descent: .folder)
        let first = builder.appendChildren([("a", child)], to: 0, parentPath: "/Volumes/Stick/sub")
        let file = EntryFacts(kind: .file, sizes: DiskSizes(logical: 3, allocated: 4096, private: 4096),
                              contribution: DiskSizes(logical: 3, allocated: 4096, private: 4096))
        _ = builder.appendChildren([("f", file)], to: first, parentPath: "/Volumes/Stick/sub/a")
        let tree = builder.finish()
        XCTAssertEqual(tree.item(at: "a")?.sizes, DiskSizes(logical: 3, allocated: 8192, private: 8192))
        XCTAssertEqual(tree.root.sizes, DiskSizes(logical: 3, allocated: 12288, private: 12288))
    }
}
