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
                for name in try FileManager.default.contentsOfDirectory(atPath: path) {
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
