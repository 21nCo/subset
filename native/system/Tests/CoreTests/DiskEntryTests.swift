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
        XCTAssertEqual(deniedFacts.error, EPERM)

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
        XCTAssertFalse(tree.root.flags.contains(.allocatedUpperBound), "pure clones are counted exactly")
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
