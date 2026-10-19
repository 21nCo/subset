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
