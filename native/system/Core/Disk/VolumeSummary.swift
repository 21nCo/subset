import Foundation

/// The capacity figures a volume reports through its resource values, in bytes. A value it did not report is `nil`.
public struct VolumeCapacityValues: Equatable, Sendable {
    /// `volumeURL`: the volume's mount point.
    public var mountPoint: String?
    public var name: String?
    /// `volumeTotalCapacity`.
    public var capacity: Int64?
    /// `volumeAvailableCapacityForImportantUsage`: free space plus what macOS would purge to make room.
    public var availableForImportantUsage: Int64?
    /// `volumeAvailableCapacity`: free space alone.
    public var available: Int64?

    public init(mountPoint: String? = nil, name: String? = nil, capacity: Int64? = nil,
                availableForImportantUsage: Int64? = nil, available: Int64? = nil) {
        self.mountPoint = mountPoint
        self.name = name
        self.capacity = capacity
        self.availableForImportantUsage = availableForImportantUsage
        self.available = available
    }

    /// Reads the values for the volume holding `url`.
    public init(volumeOf url: URL) {
        let keys: Set<URLResourceKey> = [.volumeURLKey, .volumeLocalizedNameKey, .volumeTotalCapacityKey,
                                         .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        let values = try? url.resourceValues(forKeys: keys)
        self.init(mountPoint: values?.volume?.path, name: values?.volumeLocalizedName,
                  capacity: values?.volumeTotalCapacity.map(Int64.init),
                  availableForImportantUsage: values?.volumeAvailableCapacityForImportantUsage,
                  available: values?.volumeAvailableCapacity.map(Int64.init))
    }
}

/// Local Time Machine snapshots, as `tmutil listlocalsnapshots` lists them.
public enum LocalSnapshots: Equatable, Sendable {
    case count(Int)
    /// The list could not be read; the reason says why.
    case unavailable(String)

    /// Parses `tmutil listlocalsnapshots <mount point>` output: an optional heading (`Snapshots for disk …:`, or
    /// `Snapshots for volume group containing disk …:`), then one `com.apple.TimeMachine.<date>.local` name per line.
    /// Any other line means the format is not understood, so the count is unavailable rather than wrong.
    public init(tmutilOutput output: String) {
        var count = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.isEmpty || (text.hasPrefix("Snapshots for ") && text.hasSuffix(":")) { continue }
            guard text.hasPrefix("com.apple.TimeMachine."), !text.contains(" ") else {
                self = .unavailable("tmutil printed a line System does not recognize: \(text.prefix(80))")
                return
            }
            count += 1
        }
        self = .count(count)
    }
}

/// A volume's space: capacity, what is free, what macOS could purge, and its local snapshots.
public struct VolumeSummary: Equatable, Sendable {
    public let values: VolumeCapacityValues
    public let snapshots: LocalSnapshots

    public init(values: VolumeCapacityValues, snapshots: LocalSnapshots) {
        self.values = values
        self.snapshots = snapshots
    }

    public var capacity: Int64? { values.capacity }
    public var availableForImportantUsage: Int64? { values.availableForImportantUsage }
    public var available: Int64? { values.available }

    /// Purgeable space, the difference between the two available figures. `nil` when either is missing or when the
    /// figure for important use is the smaller one, which the difference cannot explain.
    public var purgeable: Int64? {
        guard let important = values.availableForImportantUsage, let available = values.available,
              important >= available else { return nil }
        return important - available
    }

    /// The space local snapshots hold. `tmutil` does not report it, so it is always unavailable.
    public var snapshotBytes: Int64? { nil }

    /// Reads the summary for the volume holding `url`, running `/usr/bin/tmutil listlocalsnapshots` on its mount point
    /// (`/` for the startup disk) with a 5-second timeout.
    public static func read(volumeOf url: URL, runner: CommandRunning = ProcessCommandRunner()) async -> VolumeSummary {
        let values = VolumeCapacityValues(volumeOf: url)
        let snapshots: LocalSnapshots
        if let mountPoint = values.mountPoint {
            let result = await runner.run("/usr/bin/tmutil", arguments: ["listlocalsnapshots", mountPoint],
                                          environment: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], timeout: .seconds(5))
            snapshots = LocalSnapshots(tmutilResult: result)
        } else {
            snapshots = .unavailable("The volume's mount point could not be read.")
        }
        return VolumeSummary(values: values, snapshots: snapshots)
    }
}

extension LocalSnapshots {
    init(tmutilResult result: Result<CommandOutput, CommandFailure>) {
        switch result {
        case .success(let output) where output.status == 0:
            self.init(tmutilOutput: String(decoding: output.stdout, as: UTF8.self))
        case .success(let output):
            let message = String(decoding: output.stderr.isEmpty ? output.stdout : output.stderr, as: UTF8.self)
                .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            self = .unavailable("tmutil exited with status \(output.status)\(message.isEmpty ? "" : ": \(message)")")
        case .failure(.timedOut):
            self = .unavailable("tmutil did not answer within 5 seconds.")
        case .failure(.launchFailed(let reason)):
            self = .unavailable("tmutil could not be started: \(reason)")
        case .failure(.outputTooLarge):
            self = .unavailable("tmutil printed more than System reads.")
        case .failure(.cancelled):
            self = .unavailable("Reading snapshots was cancelled.")
        }
    }
}
