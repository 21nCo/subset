import Darwin
import Foundation

/// One sample's processes indexed by PID, with each process's parent resolved once, so ancestor questions cost
/// linear time over the whole sample instead of a walk per process.
final class ProcessTree {
    let processes: [ProcessFacts]
    private let indexByPID: [Int32: Int]
    /// The parent's index; `nil` when the parent is not in the sample, is the process itself, or started after it
    /// (its PID was reused).
    let parent: [Int?]
    /// Parent links followed and processes tested by the ancestor queries, for the linear-time check.
    private(set) var steps = 0

    init(_ processes: [ProcessFacts]) {
        self.processes = processes
        var indexByPID: [Int32: Int] = [:]
        indexByPID.reserveCapacity(processes.count)
        for (index, process) in processes.enumerated() where indexByPID[process.pid] == nil {
            indexByPID[process.pid] = index
        }
        self.indexByPID = indexByPID
        parent = processes.map { process in
            guard process.ppid != process.pid, let index = indexByPID[process.ppid],
                  processes[index].identity.startTime <= process.identity.startTime else { return nil }
            return index
        }
    }

    var count: Int { processes.count }

    /// The index of the sampled process with this PID that started no later than `startedBy`, so a PID reused
    /// after that moment does not stand in for the process it names.
    func index(of pid: Int32, startedBy startTime: UInt64) -> Int? {
        guard let index = indexByPID[pid], processes[index].identity.startTime <= startTime else { return nil }
        return index
    }

    /// For every process, the nearest of itself and its ancestors that `matches`, or `nil`. Each process is tested
    /// and each parent link followed at most once. A parent cycle, which a consistent sample cannot have, ends the
    /// walk with no match.
    func nearest(where matches: (Int) -> Bool) -> [Int?] {
        var result = [Int?](repeating: nil, count: count)
        var state = [UInt8](repeating: 0, count: count) // 0 not visited, 1 on the current walk, 2 done
        var walk: [Int] = []
        for start in 0..<count where state[start] == 0 {
            var answer: Int?
            var next: Int? = start
            while let current = next {
                if state[current] == 2 { answer = result[current]; break }
                if state[current] == 1 { break }
                steps += 1
                state[current] = 1
                walk.append(current)
                if matches(current) { answer = current; break }
                next = parent[current]
            }
            while let node = walk.popLast() {
                result[node] = answer
                state[node] = 2
            }
        }
        return result
    }

    /// For every process, the nearest strict ancestor that `matches`.
    func nearestAncestor(where matches: (Int) -> Bool) -> [Int?] {
        let inclusive = nearest(where: matches)
        return parent.map { $0.flatMap { inclusive[$0] } }
    }
}

/// Answers whether a folder holds a project marker. `Attribution` asks once per folder per call.
public protocol ProjectMarkerLookup: Sendable {
    /// The first of `AttributionNames.projectMarkers`, in that order, present in `directory`, or `nil`.
    func marker(in directory: String) -> String?
}

/// Looks for markers on disk with `lstat`, which reads no file contents. A folder macOS protects (Documents,
/// Desktop, Downloads) may need the user's permission first; on-screen behavior is checked in SET-53.
public struct FileSystemProjectMarkers: ProjectMarkerLookup {
    public init() {}

    public func marker(in directory: String) -> String? {
        let folder = directory.hasSuffix("/") ? directory : directory + "/"
        var info = stat()
        return AttributionNames.projectMarkers.first { lstat(folder + $0, &info) == 0 }
    }
}

/// A mounted volume: where it is mounted, and whether it is on a local disk (`MNT_LOCAL`).
public struct MountPoint: Equatable, Sendable {
    public let path: String
    public let isLocal: Bool

    public init(path: String, isLocal: Bool) {
        self.path = path
        self.isLocal = isLocal
    }
}

/// Lists the mounted volumes. `Attribution` reads the table once per call and looks for project markers only on
/// local volumes, since a hung network or FUSE volume can block `lstat` indefinitely.
public protocol MountTableReading: Sendable {
    func mounts() -> [MountPoint]
}

/// Reads the mount table with `getmntinfo(MNT_NOWAIT)`, which returns the kernel's cached figures without asking
/// any file system, so a hung volume cannot block it.
public struct SystemMountTable: MountTableReading {
    public init() {}

    public func mounts() -> [MountPoint] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&buffer, MNT_NOWAIT)
        guard count > 0, let buffer else { return [] }
        return UnsafeBufferPointer(start: buffer, count: Int(count)).map { volume in
            var name = volume.f_mntonname
            let path = withUnsafeBytes(of: &name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
            return MountPoint(path: path, isLocal: volume.f_flags & UInt32(MNT_LOCAL) != 0)
        }
    }
}

/// A fixed mount table for tests.
public struct FixtureMountTable: MountTableReading {
    public let points: [MountPoint]

    public init(_ points: [MountPoint] = [MountPoint(path: "/", isLocal: true)]) {
        self.points = points
    }

    public func mounts() -> [MountPoint] { points }
}

/// Fixture markers: folders mapped to the marker names they hold, counting lookups.
public final class FixtureProjectMarkers: ProjectMarkerLookup, @unchecked Sendable {
    @Locked public var folders: [String: Set<String>]
    private let lock = NSLock()
    private var counts: [String: Int] = [:]

    public init(_ folders: [String: Set<String>] = [:]) {
        self.folders = folders
    }

    /// How many times each folder was looked in.
    public var lookups: [String: Int] { lock.withLock { counts } }

    public func marker(in directory: String) -> String? {
        lock.withLock { counts[directory, default: 0] += 1 }
        let present = folders[directory] ?? []
        return AttributionNames.projectMarkers.first { present.contains($0) }
    }
}
