import Foundation
import SystemCore

/// The disk reads behind `disk`, injected so tests run them on fixtures. Nothing here deletes, moves, or downloads
/// anything.
public struct DiskProbe: Sendable {
    /// Scans a folder; cancelling the calling task returns what was read.
    public var scan: @Sendable (_ root: String) async -> Result<DiskScanResult, DiskScanError>
    /// The summary of the volume holding a folder.
    public var volume: @Sendable (_ root: String) async -> VolumeSummary
    /// What the reclaim rules read besides the tree. `includeDocker` asks the Docker-compatible CLI for its image space.
    public var context: @Sendable (_ includeDocker: Bool) async -> ReclaimContext

    public init(scan: @escaping @Sendable (String) async -> Result<DiskScanResult, DiskScanError>,
                volume: @escaping @Sendable (String) async -> VolumeSummary,
                context: @escaping @Sendable (Bool) async -> ReclaimContext) {
        self.scan = scan
        self.volume = volume
        self.context = context
    }

    /// This Mac's: `DiskScanner`, `tmutil`, the installed apps and simulator runtimes, and `docker system df`.
    public static let live = DiskProbe(
        scan: { root in
            do throws(DiskScanError) {
                return .success(try await DiskScanner().scan(URL(fileURLWithPath: root)))
            } catch {
                return .failure(error)
            }
        },
        volume: { root in await VolumeSummary.read(volumeOf: URL(fileURLWithPath: root)) },
        context: { includeDocker in
            let docker = includeDocker ? await DockerCLI().imageUsage() : nil
            return ReclaimContext.live(dockerImages: docker)
        })
}

/// The `disk` and `disk --suggestions` results.
enum DiskReports {
    /// Children listed per folder, largest first; the rest are counted.
    static let childLimit = 20
    static let unreadableLimit = 100

    struct Scan {
        let result: Result<DiskScanResult, DiskScanError>
        let timedOut: Bool
    }

    /// Scans `root`, cancelling the scan after `timeout`; a cancelled scan returns what it read.
    static func scan(_ root: String, probe: DiskProbe, timeout: Duration) async -> Scan {
        enum Event: Sendable {
            case finished(Result<DiskScanResult, DiskScanError>)
            case timedOut
            case timerStopped
        }
        return await withTaskGroup(of: Event.self) { group in
            group.addTask { .finished(await probe.scan(root)) }
            group.addTask {
                do {
                    try await Task.sleep(for: timeout)
                    return .timedOut
                } catch {
                    return .timerStopped
                }
            }
            var timedOut = false
            while let event = await group.next() {
                switch event {
                case let .finished(result):
                    group.cancelAll()
                    return Scan(result: result, timedOut: timedOut)
                case .timedOut:
                    timedOut = true
                    group.cancelAll()
                case .timerStopped:
                    continue
                }
            }
            preconditionFailure("The scan task always finishes.")
        }
    }

    static func disk(path: String, depth: Int, timeout: Duration, probe: DiskProbe, paths: PathDisplay,
                     now: @Sendable () -> Date) async -> HelperReport {
        let scan = await scan(path, probe: probe, timeout: timeout)
        guard case let .success(result) = scan.result else {
            return failed(scan, command: "disk", path: path, timeout: timeout, paths: paths, now: now,
                          fields: [("depth", .count(depth)), ("totals", .null), ("entriesRead", .null), ("tree", .null),
                                   ("largestFiles", .array([])), ("unreadablePaths", .array([])), ("volume", .null)])
        }
        let volume = await probe.volume(result.tree.rootPath)
        let tree = result.tree
        let largest = result.largestFiles.map { index in
            let item = tree[index]
            return JSONValue.object([("path", .string(paths(tree.path(of: index)))),
                                     ("allocatedBytes", .optional(item.sizes?.allocated)),
                                     ("privateBytes", .optional(item.sizes?.private))])
        }
        var lines = ["\(paths(tree.rootPath)): \(bytes(result.totals?.allocated)) allocated, "
                        + "\(bytes(result.totals?.private)) private, \(result.entriesRead) items read"]
        lines.append(volumeLine(volume))
        lines += topChildren(of: 0, in: tree).shown.map { "  \(bytes($0.sizes?.allocated).padded(9))  \($0.name)" }
        return finished(scan, result: result, command: "disk", path: path, timeout: timeout, paths: paths, now: now,
                        sources: [("volume", "URL resource values: volumeTotalCapacity, volumeAvailableCapacity, volumeAvailableCapacityForImportantUsage"),
                                  ("volume.localSnapshots", "/usr/bin/tmutil listlocalsnapshots on the volume's mount point")],
                        fields: [("depth", .count(depth)), ("tree", node(0, in: tree, depth: depth, paths: paths)),
                                 ("largestFiles", .array(largest)), ("volume", volumeJSON(volume, paths: paths))],
                        lines: lines)
    }

    static func suggestions(path: String, timeout: Duration, home: String, probe: DiskProbe, paths: PathDisplay,
                            now: @Sendable () -> Date) async -> HelperReport {
        let scan = await scan(path, probe: probe, timeout: timeout)
        guard case let .success(result) = scan.result else {
            return failed(scan, command: "disk-suggestions", path: path, timeout: timeout, paths: paths, now: now,
                          fields: [("catalogVersion", .count(ReclaimRules.catalogVersion)), ("totals", .null),
                                   ("entriesRead", .null), ("unreadablePaths", .array([])), ("suggestions", .array([]))])
        }
        // Docker's images are in no folder, so, as in the app, they are asked for only when the home folder is scanned.
        let includeDocker = result.tree.rootPath == home
        let context = await probe.context(includeDocker)
        let origins = DiskOrigins.entries(in: result.tree, home: context.home, apps: context.installedApps)
        let matches = ReclaimMatcher.matches(in: result.tree, origins: origins, context: context)
        var lines = ["\(matches.count) reclaim suggestions for \(paths(result.tree.rootPath)) (catalog version \(ReclaimRules.catalogVersion)):"]
        lines += matches.map { match in
            let size = match.bytes.bytes.map { bytes($0) } ?? match.bytes.upperBound.map { "up to \(bytes($0))" } ?? "size unknown"
            let subject = match.app?.name ?? match.identifier
            return "  \(match.rule.name)\(subject.map { " (\($0))" } ?? ""): \(size), \(match.risk.rawValue)"
        }
        return finished(scan, result: result, command: "disk-suggestions", path: path, timeout: timeout, paths: paths,
                        now: now, sources: [
                            ("suggestions", "Subset System's reclaim rule catalog, version \(ReclaimRules.catalogVersion), over the scan"),
                            ("installedApps", "Info.plist and code signature of each app in /Applications, /System/Applications, and ~/Applications"),
                            ("dockerImages", includeDocker ? "docker system df --format json on this Mac's Docker-compatible VM"
                                : "not asked: Docker's image space is reported only for a scan of the home folder")
                        ], fields: [("catalogVersion", .count(ReclaimRules.catalogVersion)),
                                    ("suggestions", .array(matches.map { suggestion($0, paths: paths) }))],
                        lines: lines)
    }

    private static func failed(_ scan: Scan, command: String, path: String, timeout: Duration, paths: PathDisplay,
                               now: () -> Date, fields: [(String, JSONValue)]) -> HelperReport {
        let error: HelperError
        let exit: HelperExit
        switch scan.result {
        case let .failure(.cannotResolve(failedPath, code)):
            error = HelperError(code: "cannotResolve", message: "Cannot open \(paths(failedPath)): \(String(cString: strerror(code))).")
            exit = .usage
        case let .failure(.notADirectory(failedPath)):
            error = HelperError(code: "notADirectory", message: "\(paths(failedPath)) is not a folder.")
            exit = .usage
        case let .failure(.notLocal(failedPath, fileSystem)):
            error = HelperError(code: "notLocal", message: "\(paths(failedPath)) is on a \(fileSystem) volume, which is not a local disk.")
            exit = .usage
        case .success:
            preconditionFailure("Only a failed scan has no result.")
        }
        let outcome = scan.timedOut ? "timedOut" : "failed"
        return HelperReport(command: command, observedAt: now(), sources: [("sizes", sizeSource)],
                            restricted: [("unreadablePaths", 0)], errors: [error],
                            fields: [("path", .string(paths(path))), ("outcome", .string(outcome)),
                                     ("timeoutSeconds", .double(seconds(timeout)))] + fields,
                            text: "Error: \(error.message)", exit: scan.timedOut ? .timeout : exit)
    }

    private static func finished(_ scan: Scan, result: DiskScanResult, command: String, path _: String, timeout: Duration,
                                 paths: PathDisplay, now: () -> Date, sources: [(String, String)],
                                 fields: [(String, JSONValue)], lines: [String]) -> HelperReport {
        var errors: [HelperError] = []
        if scan.timedOut {
            errors.append(HelperError(code: "timedOut",
                                      message: "The scan did not finish within \(seconds(timeout).formatted()) seconds; sizes count only what was read."))
        }
        let unreadable = result.unreadablePaths.count
        var text = lines
        if unreadable > 0 { text.append("\(unreadable) items could not be read; their sizes are not in the totals.") }
        text += errors.map { "Note: \($0.message)" }
        let totals = result.totals.map { sizes in
            JSONValue.object([("allocatedBytes", .unsigned(sizes.allocated)), ("logicalBytes", .unsigned(sizes.logical)),
                              ("privateBytes", .unsigned(sizes.private))])
        } ?? .null
        let common: [(String, JSONValue)] = [
            ("path", .string(paths(result.tree.rootPath))),
            ("outcome", .string(scan.timedOut ? "timedOut" : "completed")),
            ("timeoutSeconds", .double(seconds(timeout))),
            ("totals", totals),
            ("entriesRead", .count(result.entriesRead)),
            ("unreadablePaths", .array(result.unreadablePaths.prefix(unreadableLimit).map { .string(paths($0)) }))
        ]
        return HelperReport(command: command, observedAt: now(), sources: [("sizes", sizeSource)] + sources,
                            restricted: [("unreadablePaths", unreadable)], errors: errors,
                            fields: common + fields, text: text.joined(separator: "\n"),
                            exit: scan.timedOut ? .timeout : nil)
    }

    private static let sizeSource = "getattrlistbulk over the folder, without crossing volumes or following links; allocated, logical, and private bytes per item"

    private static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// A folder's largest children, largest first, then by name; children of unknown size come last.
    private static func topChildren(of index: Int, in tree: DiskTree) -> (shown: [DiskItem], omitted: [DiskItem]) {
        let sorted = tree.children(of: index).sorted {
            let (left, right) = ($0.sizes?.allocated, $1.sizes?.allocated)
            return left != right ? (left ?? 0, left != nil ? 1 : 0) > (right ?? 0, right != nil ? 1 : 0) : $0.name < $1.name
        }
        return (Array(sorted.prefix(childLimit)), Array(sorted.dropFirst(childLimit)))
    }

    private static func node(_ index: Int, in tree: DiskTree, depth: Int, paths: PathDisplay) -> JSONValue {
        let item = tree[index]
        let (shown, omitted) = depth > 0 ? topChildren(of: index, in: tree) : ([], tree.children(of: index))
        let flags: [(DiskItemFlags, String)] = [
            (.dataless, "dataless"), (.unreadable, "unreadable"), (.partial, "partial"), (.hardLinked, "hardLinked"),
            (.countedElsewhere, "countedElsewhere"), (.sharesBlocks, "sharesBlocks"), (.incomplete, "incomplete"),
            (.firmlink, "firmlink"), (.allocatedUpperBound, "allocatedUpperBound"), (.containsDataless, "containsDataless")
        ]
        let omittedAllocated = omitted.reduce(UInt64(0)) { $0 &+ ($1.sizes?.allocated ?? 0) }
        return .object([
            ("name", .string(index == 0 ? paths(tree.rootPath) : item.name)),
            ("path", .string(paths(tree.path(of: index)))),
            ("kind", .string("\(item.kind)")),
            ("allocatedBytes", .optional(item.sizes?.allocated)),
            ("logicalBytes", .optional(item.sizes?.logical)),
            ("privateBytes", .optional(item.sizes?.private)),
            ("flags", .array(flags.filter { item.flags.contains($0.0) }.map { .string($0.1) })),
            ("children", .array(shown.map { node($0.index, in: tree, depth: depth - 1, paths: paths) })),
            ("omittedChildren", .count(omitted.count)),
            ("omittedAllocatedBytes", .unsigned(omittedAllocated))
        ])
    }

    private static func volumeJSON(_ volume: VolumeSummary, paths: PathDisplay) -> JSONValue {
        var count: Int?
        var reason: String?
        switch volume.snapshots {
        case let .count(value): count = value
        case let .unavailable(text): reason = paths.message(text)
        }
        return .object([
            ("mountPoint", .optional(volume.values.mountPoint.map(paths.callAsFunction))),
            ("name", .optional(volume.values.name)),
            ("capacityBytes", .optional(volume.capacity)),
            ("availableBytes", .optional(volume.available)),
            ("availableForImportantUsageBytes", .optional(volume.availableForImportantUsage)),
            ("purgeableBytes", .optional(volume.purgeable)),
            ("localSnapshotCount", .optional(count)),
            ("localSnapshotsUnavailableReason", .optional(reason))
        ])
    }

    private static func volumeLine(_ volume: VolumeSummary) -> String {
        let free = volume.available.map { bytes(UInt64(clamping: $0)) } ?? "unknown"
        let capacity = volume.capacity.map { bytes(UInt64(clamping: $0)) } ?? "unknown"
        let snapshots = switch volume.snapshots {
        case let .count(count): "\(count) local snapshots"
        case .unavailable: "local snapshots unknown"
        }
        return "Volume \(volume.values.name ?? "unknown"): \(free) free of \(capacity), \(snapshots)"
    }

    private static func suggestion(_ match: ReclaimMatch, paths: PathDisplay) -> JSONValue {
        let rule = match.rule
        let (kind, command): (String, [String]?) = switch rule.cleanup {
        case .trash: ("trash", nil)
        case .trashEachItem: ("trashEachItem", nil)
        case .trashPerApp: ("trashPerApp", nil)
        case let .command(arguments): ("command", arguments)
        case .none: ("none", nil)
        }
        var amount: [(String, JSONValue)] = [("privateBytes", .null), ("allocatedBytes", .null), ("complete", .null),
                                             ("allocatedUpperBound", .null), ("upToBytes", .null), ("totalBytes", .null),
                                             ("unavailableReason", .null)]
        func set(_ key: String, _ value: JSONValue) {
            if let position = amount.firstIndex(where: { $0.0 == key }) { amount[position].1 = value }
        }
        let bytesKind: String
        switch match.bytes {
        case let .scanned(privateBytes, allocated, complete, upperBound):
            bytesKind = "scanned"
            set("privateBytes", .unsigned(privateBytes))
            set("allocatedBytes", .unsigned(allocated))
            set("complete", .bool(complete))
            set("allocatedUpperBound", .bool(upperBound))
        case let .dockerReclaimable(upTo, total):
            bytesKind = "dockerReclaimable"
            set("upToBytes", .unsigned(upTo))
            set("totalBytes", .optional(total))
        case let .unavailable(reason):
            bytesKind = "unavailable"
            set("unavailableReason", .string(paths.message(reason)))
        }
        return .object([
            ("ruleId", .string(rule.id.rawValue)),
            ("name", .string(rule.name)),
            ("location", .string(rule.location)),
            ("risk", .string(rule.risk.rawValue)),
            ("yield", .string(rule.yield.rawValue)),
            ("cleanup", .object([("kind", .string(kind)), ("command", command.map { .array($0.map(JSONValue.string)) } ?? .null)])),
            ("explanation", .string(rule.explanation)),
            ("rebuild", .string(rule.rebuild)),
            ("developerTool", .optional(rule.developerTool)),
            ("app", match.app.map { app in
                .object([("name", .string(app.name)), ("bundleID", .string(app.bundleID)), ("path", .string(paths(app.path)))])
            } ?? .null),
            ("identifier", .optional(match.identifier)),
            ("bytes", .object([("kind", .string(bytesKind))] + amount)),
            ("movedToTrashBytes", .optional(match.movedToTrash)),
            ("items", .array(match.items.map { item in
                .object([("path", .string(paths(item.path))), ("allocatedBytes", .optional(item.sizes?.allocated)),
                         ("privateBytes", .optional(item.sizes?.private)),
                         ("touched", item.touched.map(JSONValue.time) ?? .null)])
            }))
        ])
    }
}
