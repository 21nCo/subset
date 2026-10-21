import Foundation
import SystemCore

/// What the Disk section scans: the home folder, a folder the user chose, or a mounted local volume.
public enum DiskScope: Hashable, Sendable {
    case home
    case folder(path: String)
    /// `id` is the volume's UUID, which stays the same when it is renamed and its mount path moves with the name.
    case volume(name: String, path: String, id: String? = nil)

    /// The scope's title in the picker.
    public var title: String {
        switch self {
        case .home: "Home"
        case let .folder(path): path == "/" ? "/" : (path as NSString).lastPathComponent
        case let .volume(name, _, _): name
        }
    }

    /// The folder scanned, with `home` the home folder's path.
    public func path(home: String) -> String {
        switch self {
        case .home: home
        case let .folder(path), let .volume(_, path, _): path
        }
    }

    /// Whether this and `other` are the same mounted volume: the same UUID, or the same mount path when either has none.
    public func isSameVolume(as other: DiskScope) -> Bool {
        guard case let .volume(_, path, id) = self, case let .volume(_, otherPath, otherID) = other else { return false }
        if let id, let otherID { return id == otherID }
        return path == otherPath
    }

    /// The local volumes mounted now, the startup disk first, as scopes. Hidden and network volumes are left out:
    /// the scanner does not read them. Reading a mount can wait on a stalled network server, so call this off the main
    /// actor, as `currentVolumes()` does.
    public static func mountedVolumes() -> [DiskScope] {
        let keys: [URLResourceKey] = [.volumeLocalizedNameKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
                                      .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { url -> (DiskScope, Bool)? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal == true else { return nil }
            let name = values.volumeLocalizedName ?? url.lastPathComponent
            return (.volume(name: name, path: url.path, id: values.volumeUUIDString), values.volumeIsRootFileSystem == true)
        }
        .sorted { $0.1 && !$1.1 }
        .map(\.0)
    }

    /// `mountedVolumes()`, read off the caller's actor.
    public static func currentVolumes() async -> [DiskScope] {
        await DiskScanService.detached { mountedVolumes() }
    }
}

/// What a finished scan adds to its tree: its Library entries by origin and the reclaim rules' matches.
public struct DiskAnalysis: Sendable {
    public let origins: DiskOriginReport
    public let matches: [ReclaimMatch]

    public init(origins: DiskOriginReport, matches: [ReclaimMatch]) {
        self.origins = origins
        self.matches = matches
    }

    /// Attributes the tree's Library entries and matches the reclaim rules with `context`.
    public init(tree: DiskTree, context: ReclaimContext) {
        let entries = DiskOrigins.entries(in: tree, home: context.home, apps: context.installedApps)
        let matches = ReclaimMatcher.matches(in: tree, origins: entries, context: context)
        self.init(origins: DiskOrigins.report(entries: entries, matches: matches, tree: tree, home: context.home,
                                              apps: context.installedApps),
                  matches: matches)
    }
}

/// The work behind the Disk section, injected so tests run it on fixtures. Nothing here deletes, moves, or downloads
/// anything, and results stay in memory.
public struct DiskScanService: Sendable {
    /// Scans a folder, reporting progress from any thread; cancelling the calling task returns what was read. A
    /// `Result` rather than a typed throw, whose function types need macOS 15.
    public var scan: @Sendable (_ root: String, _ onProgress: @escaping @Sendable (DiskScanProgress) -> Void) async
        -> Result<DiskScanResult, DiskScanError>
    /// Works out origins and suggestions for a scan; `nil` when the calling task was cancelled first. `includeDocker`
    /// asks the Docker-compatible CLI for its image space, which no folder holds.
    public var analyze: @Sendable (_ result: DiskScanResult, _ includeDocker: Bool) async -> DiskAnalysis?
    /// The summary of the volume holding a folder.
    public var volume: @Sendable (_ root: String) async -> VolumeSummary

    public init(scan: @escaping @Sendable (String, @escaping @Sendable (DiskScanProgress) -> Void) async
                    -> Result<DiskScanResult, DiskScanError>,
                analyze: @escaping @Sendable (DiskScanResult, Bool) async -> DiskAnalysis?,
                volume: @escaping @Sendable (String) async -> VolumeSummary) {
        self.scan = scan
        self.analyze = analyze
        self.volume = volume
    }

    /// This Mac's: `DiskScanner`, the installed apps and simulator runtimes, `docker system df`, and `tmutil`.
    public static let live = DiskScanService(
        scan: { root, onProgress in
            await DiskScanService.scan(DiskScanner(), root: root, onProgress: onProgress)
        },
        analyze: { result, includeDocker in
            let docker = includeDocker && !Task.isCancelled ? await DockerCLI().imageUsage() : nil
            // Reading apps checks each one's signature, so it runs off the caller's actor. Cancel stops it between
            // steps: a read of the apps under way finishes, and the matching after it is skipped.
            return await DiskScanService.detached {
                guard !Task.isCancelled else { return nil }
                let context = ReclaimContext.live(dockerImages: docker)
                guard !Task.isCancelled else { return nil }
                return DiskAnalysis(tree: result.tree, context: context)
            }
        },
        volume: { root in await VolumeSummary.read(volumeOf: URL(fileURLWithPath: root)) })

    /// Runs `work` off the caller's actor, cancelling it when the calling task is cancelled, which a detached task alone
    /// does not.
    public static func detached<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        let task = Task.detached(priority: .utility, operation: work)
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Runs `scanner` on `root`, its error as a `Result`.
    public static func scan(_ scanner: DiskScanner, root: String,
                            onProgress: @escaping @Sendable (DiskScanProgress) -> Void) async -> Result<DiskScanResult, DiskScanError> {
        do throws(DiskScanError) {
            return .success(try await scanner.scan(URL(fileURLWithPath: root), onProgress: onProgress))
        } catch {
            return .failure(error)
        }
    }
}
