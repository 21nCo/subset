import Foundation
import SystemCore
import SystemProcesses

/// The volume summary above the tabs: capacity, what is available for important use, what macOS could purge, and the
/// local snapshots, whose sizes macOS does not report. A figure the volume did not give is "–".
public struct DiskVolumeHeader: Equatable, Sendable {
    public let title: String
    /// The volume's own name and its mount point, kept apart because a mount point is a path (SET-51 redacts it as one).
    public let name: String?
    public let mountPoint: String?
    public let capacity: String
    public let availableForImportantUse: String
    public let purgeable: String
    public let snapshots: String
    /// How many local snapshots there are; `nil` when they could not be listed.
    public let snapshotCount: Int?
    public let accessibilityLabel: String

    public init(_ summary: VolumeSummary, format: UsageFormat) {
        name = summary.values.name
        mountPoint = summary.values.mountPoint
        title = name ?? mountPoint ?? "Volume"
        capacity = format.diskBytes(summary.capacity)
        availableForImportantUse = format.diskBytes(summary.availableForImportantUsage)
        purgeable = format.diskBytes(summary.purgeable)
        switch summary.snapshots {
        case let .count(count):
            snapshotCount = count
            snapshots = count == 0 ? "No local snapshots"
                : "\(format.count(count)) local snapshot\(count == 1 ? "" : "s"), sizes unavailable"
        case let .unavailable(reason):
            snapshotCount = nil
            snapshots = "Local snapshots unavailable: \(reason)"
        }
        accessibilityLabel = "\(title): capacity \(capacity), \(availableForImportantUse) available for important use, "
            + "\(purgeable) purgeable, \(snapshots)"
    }
}

/// Why folders were not read, with the way to let System read them. Shown only when a scan met unreadable folders.
public struct DiskUnreadableBanner: Equatable, Sendable {
    /// The Privacy & Security pane's Full Disk Access list.
    public static let fullDiskAccessSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
    /// How many paths `examples` lists.
    static let exampleCount = 5

    public let message: String
    /// The first unreadable paths, with the home folder as `~`.
    public let examples: [String]
    public let accessibilityLabel: String

    public init(unreadablePaths: [String], format: UsageFormat) {
        let count = unreadablePaths.count
        let subject = count == 1 ? "1 folder or item could not be read" : "\(format.count(count)) folders or items could not be read"
        message = "\(subject), so their sizes are unknown and the totals above them are at least what is shown. "
            + "macOS protects some folders until System has Full Disk Access; System works without it."
        examples = unreadablePaths.prefix(Self.exampleCount).map(format.path)
        accessibilityLabel = message
    }
}
