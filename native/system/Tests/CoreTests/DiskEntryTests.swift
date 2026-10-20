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
        var builder = TreeBuilder(rootPath: "/fixture", rootName: "fixture")
        let folderFacts = EntryFacts(kind: .directory, descent: .folder)
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
    }
}
