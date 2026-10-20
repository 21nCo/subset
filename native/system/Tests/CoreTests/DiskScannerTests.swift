import Darwin
import Foundation
import os
@testable import SystemCore
import XCTest

/// Scans real fixtures in a temporary folder on the runner's APFS volume.
final class DiskScannerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("DiskScannerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        // The scanner reports real paths; the temporary folder is reached through /var.
        let real = try XCTUnwrap(realpath(base.path, nil))
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real))
    }

    override func tearDownWithError() throws {
        if let root {
            // A locked fixture folder is opened again so it can be removed.
            let enumerator = FileManager.default.enumerator(atPath: root.path)
            while let path = enumerator?.nextObject() as? String { chmod(root.appendingPathComponent(path).path, 0o755) }
            chmod(root.appendingPathComponent("locked").path, 0o755)
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testSparseFileAllocatesLessThanItsLogicalSize() async throws {
        let path = root.appendingPathComponent("sparse").path
        let fd = open(path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertGreaterThanOrEqual(fd, 0)
        XCTAssertEqual(ftruncate(fd, 64 << 20), 0)
        XCTAssertEqual(pwrite(fd, "x", 1, 32 << 20), 1)
        close(fd)

        let result = try await DiskScanner().scan(root)
        let sparse = try XCTUnwrap(result.tree.item(at: "sparse"))
        let sizes = try XCTUnwrap(sparse.sizes)
        XCTAssertEqual(sparse.kind, .file)
        XCTAssertEqual(sizes.logical, 64 << 20)
        XCTAssertEqual(sizes.allocated, try Self.allocated(path))
        XCTAssertLessThan(sizes.allocated, 1 << 20)
        XCTAssertEqual(result.totals?.allocated, sizes.allocated)
        XCTAssertEqual(result.outcome, .completed)
    }

    func testHardLinkPairCountsOnceAndItsPrivateSizeOnlyWhereBothLinksAre() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("pair"), withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("split"), withIntermediateDirectories: false)
        try Self.write(root.appendingPathComponent("pair/a"), bytes: 300_000)
        XCTAssertEqual(link(root.appendingPathComponent("pair/a").path, root.appendingPathComponent("pair/b").path), 0)
        try Self.write(root.appendingPathComponent("split/c"), bytes: 200_000)
        XCTAssertEqual(link(root.appendingPathComponent("split/c").path, root.appendingPathComponent("other").path), 0)
        let pairBytes = try Self.allocated(root.appendingPathComponent("pair/a").path)
        let splitBytes = try Self.allocated(root.appendingPathComponent("split/c").path)

        let tree = try await DiskScanner().scan(root).tree
        let pair = try XCTUnwrap(tree.item(at: "pair")?.sizes)
        XCTAssertEqual(pair.allocated, pairBytes)
        XCTAssertEqual(pair.logical, 300_000)
        XCTAssertEqual(pair.private, pairBytes, "both links are in the folder, so deleting it frees the file")
        let a = try XCTUnwrap(tree.item(at: "pair/a"))
        let b = try XCTUnwrap(tree.item(at: "pair/b"))
        XCTAssertEqual(a.sizes?.allocated, pairBytes)
        XCTAssertEqual(a.sizes?.private, 0, "deleting one link frees nothing")
        XCTAssertTrue(a.flags.contains(.hardLinked))
        XCTAssertFalse(a.flags.contains(.countedElsewhere))
        XCTAssertTrue(b.flags.contains(.countedElsewhere))

        // The link outside "split" keeps its file alive: the folder counts it but would free nothing.
        let split = try XCTUnwrap(tree.item(at: "split")?.sizes)
        XCTAssertEqual(split.private, 0)
        let total = try XCTUnwrap(tree.root.sizes)
        XCTAssertEqual(total.allocated, pairBytes + splitBytes)
        XCTAssertEqual(total.private, pairBytes + splitBytes)
        XCTAssertEqual(total.logical, 500_000)
    }

    func testCloneHasLessPrivateThanAllocatedAndFoldersCountSharedBlocksOnce() async throws {
        for folder in ["x", "y"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        let original = root.appendingPathComponent("x/original")
        try Self.write(original, bytes: 4 << 20)
        XCTAssertEqual(clonefile(original.path, root.appendingPathComponent("x/clone").path, 0), 0)
        XCTAssertEqual(clonefile(original.path, root.appendingPathComponent("y/clone").path, 0), 0)
        let fileBytes = try Self.allocated(original.path)

        let tree = try await DiskScanner().scan(root).tree
        let clone = try XCTUnwrap(tree.item(at: "x/clone"))
        let sizes = try XCTUnwrap(clone.sizes)
        XCTAssertEqual(sizes.allocated, fileBytes)
        XCTAssertLessThan(sizes.private, sizes.allocated)
        XCTAssertTrue(clone.flags.contains(.sharesBlocks))
        XCTAssertEqual(tree.item(at: "x")?.sizes?.allocated, fileBytes, "two clones in one folder count their blocks once")
        XCTAssertEqual(tree.item(at: "y")?.sizes?.allocated, fileBytes)
        XCTAssertEqual(tree.root.sizes?.allocated, fileBytes, "three pure clones count their blocks once")
        XCTAssertEqual(tree.root.sizes?.logical, 3 * (4 << 20))
        XCTAssertLessThan(try XCTUnwrap(tree.root.sizes?.private), fileBytes)
        XCTAssertFalse(tree.root.flags.contains(.allocatedUpperBound), "pure clones are counted exactly")
    }

    func testCloneChangedAfterCloningFlagsEveryTotalThatMayCountItsSharedBlocksTwice() async throws {
        for folder in ["changed", "pure"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        let original = root.appendingPathComponent("changed/a")
        try Self.write(original, bytes: 4 << 20)
        for copy in ["changed/b", "changed/c"] {
            XCTAssertEqual(clonefile(original.path, root.appendingPathComponent(copy).path, 0), 0)
        }
        try Self.overwriteFirstBytes(root.appendingPathComponent("changed/b"))
        try Self.write(root.appendingPathComponent("pure/d"), bytes: 1 << 20)
        XCTAssertEqual(clonefile(root.appendingPathComponent("pure/d").path, root.appendingPathComponent("pure/e").path, 0), 0)
        // The copies share every block but the one rewritten in b.
        let fileBytes = try Self.allocated(original.path)
        let changedBytes = try Self.privateSize(root.appendingPathComponent("changed/b").path)
        XCTAssertGreaterThan(changedBytes, 0)
        let pureBytes = try Self.allocated(root.appendingPathComponent("pure/d").path)

        let tree = try await DiskScanner().scan(root).tree
        try Self.assertAllocated(tree, "changed", physical: fileBytes + changedBytes)
        try Self.assertAllocated(tree, "pure", physical: pureBytes)
        try Self.assertAllocated(tree, "", physical: fileBytes + changedBytes + pureBytes)
        let changed = try XCTUnwrap(tree.item(at: "changed/b"))
        XCTAssertTrue(changed.flags.contains(.sharesBlocks))
        XCTAssertTrue(changed.flags.contains(.allocatedUpperBound), "the changed copy shares only some blocks")
        XCTAssertTrue(try XCTUnwrap(tree.item(at: "changed")).flags.contains(.allocatedUpperBound))
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
        for path in ["pure", "pure/d", "pure/e"] {
            XCTAssertFalse(try XCTUnwrap(tree.item(at: path)).flags.contains(.allocatedUpperBound), path)
        }
        XCTAssertEqual(tree.item(at: "pure")?.sizes?.allocated, pureBytes)
    }

    func testTwoCloneIDsSharingBlocksFlagTheTotalThatHoldsBoth() async throws {
        // y/a is cloned to y/b and y/c; b is changed, so it gets a new clone ID, then cloned to x/d, which shares
        // b's ID. a, c (one ID) and d (another) end up in x, sharing all but one rewritten block.
        for folder in ["x", "y", "z"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: false)
        }
        let path = { (name: String) in self.root.appendingPathComponent(name).path }
        try Self.write(root.appendingPathComponent("y/a"), bytes: 4 << 20)
        XCTAssertEqual(clonefile(path("y/a"), path("y/c"), 0), 0)
        XCTAssertEqual(clonefile(path("y/a"), path("y/b"), 0), 0)
        try Self.overwriteFirstBytes(root.appendingPathComponent("y/b"))
        let changedBytes = try Self.privateSize(path("y/b"))
        XCTAssertGreaterThan(changedBytes, 0)
        XCTAssertEqual(clonefile(path("y/b"), path("x/d"), 0), 0)
        XCTAssertEqual(rename(path("y/a"), path("x/a")), 0)
        XCTAssertEqual(rename(path("y/c"), path("x/c")), 0)
        try Self.write(root.appendingPathComponent("z/p"), bytes: 1 << 20)
        XCTAssertEqual(clonefile(path("z/p"), path("z/q"), 0), 0)
        let fileBytes = try Self.allocated(path("x/a"))
        let pureBytes = try Self.allocated(path("z/p"))

        let tree = try await DiskScanner().scan(root).tree
        let x = try XCTUnwrap(tree.item(at: "x"))
        XCTAssertTrue(x.flags.contains(.allocatedUpperBound), "x holds two clone IDs that share blocks")
        try Self.assertAllocated(tree, "x", physical: fileBytes + changedBytes)
        try Self.assertAllocated(tree, "y", physical: try Self.allocated(path("y/b")))
        try Self.assertAllocated(tree, "z", physical: pureBytes)
        XCTAssertFalse(try XCTUnwrap(tree.item(at: "z")).flags.contains(.allocatedUpperBound), "one pure clone group")
        XCTAssertTrue(tree.root.flags.contains(.allocatedUpperBound))
        try Self.assertAllocated(tree, "", physical: fileBytes + changedBytes + pureBytes)
    }

    func testSymlinkIsCountedAsItselfAndNotFollowed() async throws {
        let outside = root.deletingLastPathComponent().appendingPathComponent("DiskScannerTarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: outside) }
        try Self.write(outside.appendingPathComponent("big"), bytes: 1 << 20)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("folder-link"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("file-link"),
                                                   withDestinationURL: outside.appendingPathComponent("big"))

        let result = try await DiskScanner().scan(root)
        for name in ["folder-link", "file-link"] {
            let link = try XCTUnwrap(result.tree.item(at: name))
            XCTAssertEqual(link.kind, .symlink)
            XCTAssertTrue(link.children.isEmpty)
            XCTAssertLessThan(try XCTUnwrap(link.sizes?.allocated), 1 << 20)
        }
        XCTAssertLessThan(try XCTUnwrap(result.totals?.allocated), 1 << 20)
        XCTAssertEqual(result.tree.count, 3)
    }

    func testPackageBundleIsOneItemWithItsTotal() async throws {
        let bundle = root.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Self.write(bundle.appendingPathComponent("Contents/MacOS/Tool"), bytes: 100_000)
        try Self.write(bundle.appendingPathComponent("Contents/Info.plist"), bytes: 1_000)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain.d"), withIntermediateDirectories: false)
        let expected = try Self.allocated(bundle.appendingPathComponent("Contents/MacOS/Tool").path)
            + Self.allocated(bundle.appendingPathComponent("Contents/Info.plist").path)

        let result = try await DiskScanner().scan(root)
        let package = try XCTUnwrap(result.tree.item(at: "Tool.app"))
        XCTAssertEqual(package.kind, .package)
        XCTAssertTrue(package.children.isEmpty)
        XCTAssertEqual(package.sizes?.allocated, expected)
        XCTAssertEqual(package.sizes?.logical, 101_000)
        XCTAssertEqual(result.tree.item(at: "plain.d")?.kind, .directory, "an extension alone does not make a package")
        XCTAssertEqual(result.entriesRead, 6, "the package's contents are read for its total")
        XCTAssertEqual(result.tree.count, 3)
    }

    func testLaunchServicesIsNotAskedInsideAPackage() async throws {
        let bundle = root.appendingPathComponent("Tool.app")
        for folder in ["Contents/Resources/en.lproj", "Contents/Frameworks/Kit.framework/Versions",
                       "Contents/PlugIns/Share.appex", "Contents/Library/Helper.app/Contents"] {
            try FileManager.default.createDirectory(at: bundle.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
            try Self.write(bundle.appendingPathComponent(folder + "/data"), bytes: 20_000)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain.d"), withIntermediateDirectories: false)
        let expected = try Self.statTotals(bundle.path)
        let asked = OSAllocatedUnfairLock(initialState: [String]())
        let scanner = DiskScanner(workers: 4, progressInterval: .milliseconds(100), bufferSize: 128 << 10) { path in
            asked.withLock { $0.append(path) }
            return path.hasSuffix(".app")
        }

        let result = try await scanner.scan(root)
        XCTAssertEqual(asked.withLock { $0 }.sorted(), [bundle.path, root.appendingPathComponent("plain.d").path])
        let package = try XCTUnwrap(result.tree.item(at: "Tool.app"))
        XCTAssertEqual(package.kind, .package)
        XCTAssertEqual(package.sizes?.allocated, expected.allocated)
        XCTAssertEqual(package.sizes?.logical, 80_000)
        XCTAssertEqual(result.entriesRead, expected.entries + 2)
    }

    func testRootIsClassifiedOnAThreadThatNeverDownloads() async throws {
        // Launch Services is asked only about folders with an extension.
        let chosen = root.appendingPathComponent("Chosen.d")
        try FileManager.default.createDirectory(at: chosen.appendingPathComponent("a.d"), withIntermediateDirectories: true)
        let policies = OSAllocatedUnfairLock(initialState: [String: Int32]())
        let scanner = DiskScanner(workers: 2, progressInterval: .milliseconds(100), bufferSize: 128 << 10) { path in
            let policy = getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD)
            policies.withLock { $0[path] = policy }
            return false
        }

        let result = try await scanner.scan(chosen)
        let path = result.tree.rootPath
        let off = IOPOL_MATERIALIZE_DATALESS_FILES_OFF
        XCTAssertEqual(policies.withLock { $0 }, [path: off, path + "/a.d": off])
    }

    func testChosenPackageIsOneItemWithItsTotal() async throws {
        let bundle = root.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        try Self.write(bundle.appendingPathComponent("Contents/MacOS/Tool"), bytes: 100_000)
        try Self.write(bundle.appendingPathComponent("Contents/Info.plist"), bytes: 1_000)
        let expected = try Self.statTotals(bundle.path)

        let result = try await DiskScanner().scan(bundle)
        XCTAssertEqual(result.tree.root.kind, .package)
        XCTAssertEqual(result.tree.root.name, "Tool.app")
        XCTAssertTrue(result.tree.root.children.isEmpty, "a package's contents are not listed")
        XCTAssertEqual(result.tree.count, 1)
        XCTAssertEqual(result.totals?.allocated, expected.allocated)
        XCTAssertEqual(result.totals?.logical, 101_000)
        XCTAssertEqual(result.entriesRead, expected.entries)
        XCTAssertEqual(result.outcome, .completed)
    }

    func testRootsOwnAllocationCountsOnAVolumeThatAllocatesFolders() async throws {
        // exFAT allocates a cluster to every folder, the scanned one included; APFS folders allocate nothing.
        let image = root.appendingPathComponent("stick.dmg").path
        let mountPoint = root.appendingPathComponent("mnt").path
        try XCTSkipUnless(Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "ExFAT", "-volname",
                                                         "SCANTEST", "-layout", "NONE", image]),
                          "hdiutil could not create an exFAT image")
        try XCTSkipUnless(Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noverify", "-mountpoint",
                                                         mountPoint, image]),
                          "hdiutil could not attach the image")
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", mountPoint]) }
        let sub = URL(fileURLWithPath: mountPoint).appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Self.write(sub.appendingPathComponent("a/one"), bytes: 3)
        try Self.write(sub.appendingPathComponent("a/b/two"), bytes: 70_000)
        let rootBlocks = try Self.allocated(sub.path)
        XCTAssertGreaterThan(rootBlocks, 0)

        let last = OSAllocatedUnfairLock<DiskScanProgress?>(initialState: nil)
        let result = try await DiskScanner(progressInterval: .zero).scan(sub) { progress in
            last.withLock { $0 = progress }
        }
        let totals = try XCTUnwrap(result.totals)
        let expected = try Self.statTotals(sub.path)
        XCTAssertEqual(last.withLock { $0 }?.allocatedBytes, totals.allocated, "progress counts folders' allocation")
        XCTAssertEqual(totals.allocated, expected.allocated)
        XCTAssertEqual(totals.logical, expected.logical)
        XCTAssertEqual(totals.allocated / 1024, try Self.duKilobytes(sub.path))
        let children = result.tree.children(of: 0).reduce(UInt64(0)) { $0 + ($1.sizes?.allocated ?? 0) }
        XCTAssertEqual(totals.allocated, children + rootBlocks, "the scanned folder adds its own allocation")

        // A chosen volume is scanned, although its root is a mount point.
        let volume = try await DiskScanner().scan(URL(fileURLWithPath: mountPoint))
        XCTAssertEqual(volume.tree.root.kind, .directory)
        XCTAssertNotNil(volume.tree.item(at: "sub/a/b/two"))
        XCTAssertGreaterThan(try XCTUnwrap(volume.totals?.allocated), totals.allocated)
    }

    func testProgressRisesAndCountsAHardLinkPairOnce() async throws {
        let fileManager = FileManager.default
        for index in 0..<8 {
            let folder = root.appendingPathComponent("f\(index)")
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: false)
            for file in 0..<20 { try Self.write(folder.appendingPathComponent("\(file)"), bytes: 5_000) }
        }
        try Self.write(root.appendingPathComponent("f0/big"), bytes: 1 << 20)
        XCTAssertEqual(link(root.appendingPathComponent("f0/big").path, root.appendingPathComponent("f7/big-link").path), 0)
        let expected = try Self.statTotals(root.path)
        let snapshots = OSAllocatedUnfairLock(initialState: [DiskScanProgress]())

        let result = try await DiskScanner(progressInterval: .zero).scan(root) { progress in
            snapshots.withLock { $0.append(progress) }
        }
        let seen = snapshots.withLock { $0 }
        let last = try XCTUnwrap(seen.last)
        XCTAssertEqual(zip(seen, seen.dropFirst()).filter { $0.items >= $1.items }.count, 0, "items always rise")
        XCTAssertEqual(last.items, result.entriesRead)
        XCTAssertEqual(last.allocatedBytes, expected.allocated, "the hard link pair counts once")
        XCTAssertTrue(seen.contains { $0.currentPath.hasPrefix(root.path + "/f") }, "the current path follows the workers")
        XCTAssertTrue(seen.allSatisfy { $0.currentPath == root.path || $0.currentPath.hasPrefix(root.path + "/") })
    }

    func testUnreadableFolderIsCountedAsUnknownAndListed() async throws {
        try XCTSkipIf(geteuid() == 0, "root reads a folder whatever its mode")
        let locked = root.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
        try Self.write(locked.appendingPathComponent("secret"), bytes: 50_000)
        try Self.write(root.appendingPathComponent("visible"), bytes: 10_000)
        XCTAssertEqual(chmod(locked.path, 0), 0)

        let result = try await DiskScanner().scan(root)
        let item = try XCTUnwrap(result.tree.item(at: "locked"))
        XCTAssertEqual(item.kind, .directory)
        XCTAssertNil(item.sizes)
        XCTAssertTrue(item.flags.contains(.unreadable))
        XCTAssertEqual(result.unreadablePaths, [locked.path])
        XCTAssertTrue(result.tree.root.flags.contains(.incomplete), "the root's total is a lower bound")
        XCTAssertEqual(result.totals?.allocated, try Self.allocated(root.appendingPathComponent("visible").path))
        XCTAssertEqual(result.outcome, .completed)
    }

    func testUnreadablePackageIsCountedAsUnknownAsAChildAndAsTheRoot() async throws {
        try XCTSkipIf(geteuid() == 0, "root reads a folder whatever its mode")
        let bundle = root.appendingPathComponent("Tool.app")
        try FileManager.default.createDirectory(at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Self.write(bundle.appendingPathComponent("Contents/Tool"), bytes: 100_000)
        try Self.write(root.appendingPathComponent("visible"), bytes: 10_000)
        XCTAssertEqual(chmod(bundle.path, 0), 0)
        defer { chmod(bundle.path, 0o755) }

        let result = try await DiskScanner().scan(root)
        let package = try XCTUnwrap(result.tree.item(at: "Tool.app"))
        XCTAssertEqual(package.kind, .package)
        XCTAssertNil(package.sizes, "a package that cannot be opened has an unknown size, not zero")
        XCTAssertTrue(package.flags.contains(.unreadable))
        XCTAssertEqual(result.unreadablePaths, [bundle.path])
        XCTAssertTrue(result.tree.root.flags.contains(.incomplete))
        XCTAssertEqual(result.totals?.allocated, try Self.allocated(root.appendingPathComponent("visible").path))

        let chosen = try await DiskScanner().scan(bundle)
        XCTAssertEqual(chosen.tree.root.kind, .package)
        XCTAssertNil(chosen.totals)
        XCTAssertTrue(chosen.tree.root.flags.contains(.unreadable))
        XCTAssertEqual(chosen.unreadablePaths, [bundle.path])
    }

    func testUnreadableFolderInsideAPackageLeavesThePackageSizedAndIncomplete() async throws {
        try XCTSkipIf(geteuid() == 0, "root reads a folder whatever its mode")
        let bundle = root.appendingPathComponent("Tool.app")
        let locked = bundle.appendingPathComponent("Contents/Locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Self.write(bundle.appendingPathComponent("Contents/Tool"), bytes: 100_000)
        try Self.write(locked.appendingPathComponent("secret"), bytes: 50_000)
        XCTAssertEqual(chmod(locked.path, 0), 0)
        defer { chmod(locked.path, 0o755) }

        let result = try await DiskScanner().scan(root)
        let package = try XCTUnwrap(result.tree.item(at: "Tool.app"))
        XCTAssertEqual(package.kind, .package)
        XCTAssertFalse(package.flags.contains(.unreadable))
        XCTAssertTrue(package.flags.contains(.incomplete), "the package's size is a lower bound")
        XCTAssertEqual(package.sizes?.allocated, try Self.allocated(bundle.appendingPathComponent("Contents/Tool").path))
        XCTAssertEqual(package.sizes?.logical, 100_000)
        XCTAssertEqual(result.unreadablePaths, [locked.path])
        XCTAssertTrue(result.tree.root.flags.contains(.incomplete))
    }

    func testTotalsMatchStatAndHardLinksMatchDu() async throws {
        let fileManager = FileManager.default
        for folder in ["a", "a/b", "a/b/c", "d", "e.app/Contents"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        let files: [(String, Int)] = [("one", 1), ("a/two", 5_000), ("a/b/three", 70_000), ("a/b/c/four", 1_234_567),
                                      ("d/five", 4096), ("d/six", 0), ("e.app/Contents/seven", 9_999)]
        for (path, bytes) in files { try Self.write(root.appendingPathComponent(path), bytes: bytes) }
        XCTAssertEqual(link(root.appendingPathComponent("a/b/three").path, root.appendingPathComponent("d/three-link").path), 0)
        XCTAssertEqual(link(root.appendingPathComponent("a/b/c/four").path, root.appendingPathComponent("a/four-link").path), 0)
        try fileManager.createSymbolicLink(atPath: root.appendingPathComponent("d/link").path, withDestinationPath: "../a")
        let fd = open(root.appendingPathComponent("a/sparse").path, O_CREAT | O_WRONLY, 0o644)
        XCTAssertEqual(ftruncate(fd, 10 << 20), 0)
        XCTAssertEqual(pwrite(fd, "x", 1, 5 << 20), 1)
        close(fd)

        let result = try await DiskScanner().scan(root)
        let totals = try XCTUnwrap(result.totals)
        let expected = try Self.statTotals(root.path)
        XCTAssertEqual(totals.allocated, expected.allocated)
        XCTAssertEqual(totals.logical, expected.logical)
        XCTAssertEqual(totals.allocated / 1024, try Self.duKilobytes(root.path))
        XCTAssertEqual(result.entriesRead, expected.entries)
        XCTAssertTrue(result.unreadablePaths.isEmpty)
    }

    func testCancellationReturnsWithinHalfASecondAndKeepsPartialTotals() async throws {
        let folders = 100
        let filesPerFolder = 500
        let base = root.path
        let created = OSAllocatedUnfairLock(initialState: 0)
        DispatchQueue.concurrentPerform(iterations: folders) { folder in
            let path = "\(base)/f\(folder)"
            guard mkdir(path, 0o755) == 0 else { return }
            for file in 0..<filesPerFolder {
                let fd = open("\(path)/\(file)", O_CREAT | O_WRONLY, 0o644)
                if fd >= 0, Darwin.write(fd, "x", 1) == 1 { created.withLock { $0 += 1 } }
                close(fd)
            }
        }
        XCTAssertEqual(created.withLock { $0 }, folders * filesPerFolder)
        let canceller = Canceller()
        let scanRoot: URL = root
        let task = Task {
            try await DiskScanner(progressInterval: .zero).scan(scanRoot) { progress in
                if progress.allocatedBytes > 0 { canceller.cancel() }
            }
        }
        canceller.set(task)
        let result = try await task.value
        let returned = ContinuousClock.now
        let cancelledAt = try XCTUnwrap(canceller.cancelledAt)

        XCTAssertLessThan(returned - cancelledAt, .milliseconds(500))
        XCTAssertEqual(result.outcome, .cancelled)
        XCTAssertGreaterThan(result.entriesRead, 0)
        XCTAssertLessThan(result.entriesRead, folders * (filesPerFolder + 1))
        let totals = try XCTUnwrap(result.totals)
        XCTAssertGreaterThan(totals.allocated, 0, "what was read before the cancellation is kept")
        XCTAssertTrue(result.tree.root.flags.contains(.incomplete))
        XCTAssertTrue((0..<result.tree.count).contains { result.tree[$0].flags.contains(.partial) })
    }

    func testFolderReplacedAfterItWasListedIsNotRead() async throws {
        let fileManager = FileManager.default
        for name in ["a", "b", "z"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            try Self.write(root.appendingPathComponent("\(name)/old"), bytes: 10_000)
        }
        let rootPath = root.path
        let moved = root.deletingLastPathComponent().appendingPathComponent("DiskScannerMoved-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: moved) }
        let swapped = OSAllocatedUnfairLock(initialState: false)

        // One worker reports the root's only batch before it queues the folders listed in it.
        let result = try await DiskScanner(workers: 1, progressInterval: .zero).scan(root) { progress in
            guard progress.currentPath == rootPath, !swapped.withLock({ $0 }) else { return }
            swapped.withLock { $0 = true }
            let b = URL(fileURLWithPath: rootPath).appendingPathComponent("b")
            do {
                try FileManager.default.moveItem(at: b, to: moved)
                try FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
                try Self.write(b.appendingPathComponent("new"), bytes: 200_000)
            } catch {
                XCTFail("could not replace b: \(error)")
            }
        }
        XCTAssertTrue(swapped.withLock { $0 })
        let b = try XCTUnwrap(result.tree.item(at: "b"))
        XCTAssertEqual(b.kind, .directory)
        XCTAssertTrue(b.flags.contains(.incomplete))
        XCTAssertTrue(b.children.isEmpty, "the folder put in its place is not read")
        XCTAssertEqual(b.sizes?.allocated, 0)
        let fileBytes = try Self.allocated(root.appendingPathComponent("a/old").path)
        XCTAssertEqual(result.tree.item(at: "a")?.sizes?.allocated, fileBytes)
        XCTAssertEqual(result.tree.item(at: "z")?.sizes?.allocated, fileBytes)
        XCTAssertEqual(result.totals?.allocated, 2 * fileBytes)
        XCTAssertTrue(result.tree.root.flags.contains(.incomplete))
        XCTAssertEqual(result.outcome, .completed)
    }

    func testVolumeMountedOnAListedFolderIsNotCrossed() async throws {
        let fileManager = FileManager.default
        for name in ["a", "b", "z"] {
            try fileManager.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: false)
            try Self.write(root.appendingPathComponent("\(name)/old"), bytes: 10_000)
        }
        let image = root.deletingLastPathComponent().appendingPathComponent("DiskScannerMount-\(UUID().uuidString).dmg")
        defer { try? fileManager.removeItem(at: image) }
        try XCTSkipUnless(Self.run("/usr/bin/hdiutil", ["create", "-quiet", "-size", "16m", "-fs", "ExFAT", "-volname",
                                                         "MOUNTTEST", "-layout", "NONE", image.path]),
                          "hdiutil could not create an exFAT image")
        let rootPath = root.path
        let mountPoint = root.appendingPathComponent("b").path
        let attached = OSAllocatedUnfairLock(initialState: false)
        defer { _ = Self.run("/usr/bin/hdiutil", ["detach", "-force", mountPoint]) }

        let result = try await DiskScanner(workers: 1, progressInterval: .zero).scan(root) { progress in
            guard progress.currentPath == rootPath, !attached.withLock({ $0 }) else { return }
            let mounted = Self.run("/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-noverify", "-mountpoint",
                                                        mountPoint, image.path])
            attached.withLock { $0 = mounted }
        }
        try XCTSkipUnless(attached.withLock { $0 }, "hdiutil could not attach the image")
        let b = try XCTUnwrap(result.tree.item(at: "b"))
        XCTAssertEqual(b.kind, .mountPoint)
        XCTAssertEqual(b.sizes, .zero)
        XCTAssertTrue(b.children.isEmpty, "the volume mounted after b was listed is not read")
        let fileBytes = try Self.allocated(root.appendingPathComponent("a/old").path)
        XCTAssertEqual(result.totals?.allocated, 2 * fileBytes)
        XCTAssertFalse(result.tree.root.flags.contains(.incomplete))
    }

    func testIdentityCheckPassesTheStartupDisksFoldersAndSkipsFirmlinks() throws {
        // The startup disk's root is on the system volume, whose folders report another st_dev than their volume.
        var checked: [String] = []
        for entry in try Self.entries(in: "/") where entry.objectType == VDIR.rawValue {
            let facts = EntryFacts(entry) { false }
            guard facts.descent != nil else { continue }
            let path = "/" + entry.name
            guard let identity = facts.opensAs else {
                // /Users, /Applications, /Library: the entry is the link on the system volume, not the folder it opens.
                XCTAssertTrue(facts.flags.contains(.firmlink), path)
                XCTAssertNotEqual(facts.directory, Self.opened(path), "\(path) would never pass a check")
                continue
            }
            XCTAssertEqual(identity, Self.opened(path), path)
            checked.append(path)
        }
        XCTAssertTrue(checked.contains("/System"))
        // A firmlink chosen as the root is read with getattrlist, which describes the folder it opens.
        for path in ["/Users", "/System", "/"] {
            let root = DiskScan.rootFacts(path, name: path, isPackage: { _ in false })
            XCTAssertEqual(root.opensAs, Self.opened(path), path)
        }
        let fd = DiskScan.openDirectory("/System")
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        let system = try XCTUnwrap(Self.opened("/System"))
        XCTAssertEqual(DiskScan.check(fd, against: system), .expected)
        XCTAssertEqual(DiskScan.check(fd, against: FileKey(device: system.device, id: system.id + 1)), .replaced)
        XCTAssertEqual(DiskScan.check(fd, against: FileKey(device: system.device &+ 1, id: system.id)), .mounted)
    }

    /// The file system ID and inode `DiskScan.check` compares for the folder `path` opens.
    static func opened(_ path: String) -> FileKey? {
        let fd = DiskScan.openDirectory(path)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        var volume = statfs()
        guard fstat(fd, &info) == 0, fstatfs(fd, &volume) == 0 else { return nil }
        return FileKey(device: UInt32(bitPattern: volume.f_fsid.val.0), id: UInt64(info.st_ino))
    }

    func testMountPointsAreNotCrossed() async throws {
        // On macOS 10.15 and later every entry of /System/Volumes is a volume mounted there.
        let result = try await DiskScanner().scan(URL(fileURLWithPath: "/System/Volumes"))
        let data = try XCTUnwrap(result.tree.item(at: "Data"))
        XCTAssertEqual(data.kind, .mountPoint)
        XCTAssertTrue(data.children.isEmpty)
        XCTAssertEqual(data.sizes, .zero)
        // The data volume holds the whole Mac's files; the folders that hold the mount points hold almost nothing.
        XCTAssertLessThan(try XCTUnwrap(result.totals?.allocated), 1 << 30, "nothing below a mount point is read")
    }

    func testRootMustBeAnExistingFolder() async throws {
        try Self.write(root.appendingPathComponent("file"), bytes: 1)
        do {
            _ = try await DiskScanner().scan(root.appendingPathComponent("missing"))
            XCTFail("a missing root was scanned")
        } catch {
            XCTAssertEqual(error, .cannotResolve(path: root.appendingPathComponent("missing").path, errno: ENOENT))
        }
        do {
            _ = try await DiskScanner().scan(root.appendingPathComponent("file"))
            XCTFail("a file was scanned as a folder")
        } catch {
            XCTAssertEqual(error, .notADirectory(root.appendingPathComponent("file").path))
        }
        XCTAssertEqual(DiskScanner.defaultRoot, FileManager.default.homeDirectoryForCurrentUser)
    }

    func testTreePathsAndTheRootReachedThroughALink() async throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("a/b"), withIntermediateDirectories: true)
        try Self.write(root.appendingPathComponent("a/b/file"), bytes: 10)
        let alias = root.deletingLastPathComponent().appendingPathComponent("DiskScannerAlias-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: root)
        defer { try? FileManager.default.removeItem(at: alias) }

        let tree = try await DiskScanner().scan(alias).tree
        XCTAssertEqual(tree.rootPath, root.path)
        let file = try XCTUnwrap(tree.item(at: "a/b/file"))
        XCTAssertEqual(tree.path(of: file.index), root.appendingPathComponent("a/b/file").path)
        XCTAssertEqual(tree[try XCTUnwrap(file.parent)].name, "b")
        XCTAssertEqual(tree.path(of: 0), root.path)
    }

    // MARK: - Fixture helpers

    static func write(_ url: URL, bytes: Int) throws {
        try Data(repeating: 0x5A, count: bytes).write(to: url)
    }

    static func allocated(_ path: String) throws -> UInt64 {
        var info = stat()
        guard lstat(path, &info) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
        return UInt64(info.st_blocks) * 512
    }

    /// The APFS private size of a file, from `getattrlist`.
    static func privateSize(_ path: String) throws -> UInt64 {
        try XCTUnwrap(BulkAttributes.read(path: path)?.privateSize)
    }

    /// Rewrites a file's first bytes, so a clone stops sharing that block.
    static func overwriteFirstBytes(_ url: URL) throws {
        let fd = open(url.path, O_WRONLY)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno)!) }
        defer { close(fd) }
        XCTAssertEqual(pwrite(fd, "abcd", 4, 0), 4)
        XCTAssertEqual(fsync(fd), 0)
    }

    /// An unflagged total must equal the space its contents use; a flagged one may only exceed it.
    static func assertAllocated(_ tree: DiskTree, _ relativePath: String, physical: UInt64,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        let item = try XCTUnwrap(tree.item(at: relativePath), file: file, line: line)
        let allocated = try XCTUnwrap(item.sizes?.allocated, file: file, line: line)
        if item.flags.contains(.allocatedUpperBound) {
            XCTAssertGreaterThanOrEqual(allocated, physical, "/\(relativePath)", file: file, line: line)
        } else {
            XCTAssertEqual(allocated, physical, "/\(relativePath) is unflagged, so it must be exact", file: file, line: line)
        }
    }

    /// A folder's entries from `getattrlistbulk`, as the scanner reads them.
    static func entries(in path: String) throws -> [DirectoryEntry] {
        let fd = DiskScan.openDirectory(path)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: -fd)!) }
        defer { close(fd) }
        let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: 128 << 10, alignment: 8)
        defer { buffer.deallocate() }
        var list = BulkAttributes.list
        var entries: [DirectoryEntry] = []
        while true {
            let count = getattrlistbulk(fd, &list, buffer.baseAddress!, buffer.count, BulkAttributes.options)
            guard count > 0 else { break }
            entries += BulkAttributes.parse(UnsafeRawBufferPointer(buffer), count: Int(count))
        }
        return entries
    }

    /// A folder's entries from `readdir`, which, unlike `FileManager`, lists the AppleDouble (`._`) files that hold
    /// extended attributes on exFAT and FAT.
    static func names(in path: String) throws -> [String] {
        guard let directory = opendir(path) else { throw POSIXError(.init(rawValue: errno)!) }
        defer { closedir(directory) }
        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafeBytes(of: entry.pointee.d_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            if name != ".", name != ".." { names.append(name) }
        }
        return names
    }

    /// Allocated (`st_blocks`) and logical (`st_size`) bytes under `path` from `lstat`, each inode once. Folders
    /// count their blocks, not their size, as `du` does.
    static func statTotals(_ path: String) throws -> (allocated: UInt64, logical: UInt64, entries: Int) {
        var seen: Set<UInt64> = []
        var allocated: UInt64 = 0
        var logical: UInt64 = 0
        var entries = 0
        func visit(_ path: String) throws {
            var info = stat()
            guard lstat(path, &info) == 0 else { throw POSIXError(.init(rawValue: errno)!) }
            guard seen.insert(info.st_ino).inserted else { return }
            allocated += UInt64(info.st_blocks) * 512
            if info.st_mode & S_IFMT == S_IFDIR {
                for name in try names(in: path) {
                    entries += 1
                    try visit(path + "/" + name)
                }
            } else {
                logical += UInt64(info.st_size)
            }
        }
        try visit(path)
        // Every link is an entry, even when its inode was counted.
        return (allocated, logical, entries)
    }

    /// Runs a tool, discarding its output, and returns whether it succeeded.
    static func run(_ executable: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    static func duKilobytes(_ path: String) throws -> UInt64 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return try XCTUnwrap(output.split(separator: "\t").first.flatMap { UInt64($0) })
    }
}

/// Cancels a scan's task from its progress handler, once, and records when.
private final class Canceller: Sendable {
    private struct State {
        var task: Task<DiskScanResult, any Error>?
        var requested = false
        var cancelledAt: ContinuousClock.Instant?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    var cancelledAt: ContinuousClock.Instant? { state.withLock { $0.cancelledAt } }

    func set(_ task: Task<DiskScanResult, any Error>) {
        let cancelNow = state.withLock { state in
            state.task = task
            if state.requested, state.cancelledAt == nil { state.cancelledAt = .now; return true }
            return false
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let task: Task<DiskScanResult, any Error>? = state.withLock { state in
            guard !state.requested else { return nil }
            state.requested = true
            guard let task = state.task else { return nil }
            state.cancelledAt = .now
            return task
        }
        task?.cancel()
    }
}
