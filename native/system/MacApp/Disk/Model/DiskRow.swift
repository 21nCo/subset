import Foundation
import SystemCore
import SystemProcesses

/// The Disk section's tabs.
public enum DiskTab: String, CaseIterable, Sendable {
    case folders
    case origins
    case suggestions

    public var title: String {
        switch self {
        case .folders: "Folders"
        case .origins: "By origin"
        case .suggestions: "Suggestions"
        }
    }
}

/// How the Folders tab orders a folder's items.
public enum DiskSortKey: String, CaseIterable, Sendable {
    /// Allocated size, largest first.
    case allocated
    /// Private size, largest first.
    case `private`
    /// Name, A to Z as Finder orders names.
    case name

    public var title: String {
        switch self {
        case .allocated: "Size"
        case .private: "Private size"
        case .name: "Name"
        }
    }
}

/// The By origin tab's sections.
public enum DiskOriginSection: String, CaseIterable, Sendable {
    case apps
    case vendors
    case developerTools
    case leftovers

    public var title: String {
        switch self {
        case .apps: "Apps"
        case .vendors: "Vendors"
        case .developerTools: "Developer tools"
        case .leftovers: "Leftovers and not attributed"
        }
    }
}

/// A row's identity, stable while the scan it shows stays.
public enum DiskRowID: Hashable, Sendable {
    /// A tree item in the Folders tab.
    case item(Int)
    case originGroup(DiskOriginSection, DiskOriginGroupKey)
    case originItem(DiskOriginSection, DiskOriginGroupKey, item: Int)
    /// A reclaim match, by its position in the analysis.
    case match(Int)
    case matchItem(match: Int, item: Int)
    /// The row standing for the items a list leaves out.
    case more(parent: String)
}

/// A flag on a row that changes what its sizes mean.
public enum DiskBadge: String, CaseIterable, Sendable {
    /// The size is unknown: the item could not be read, or a match could not be measured.
    case unknown
    /// An iCloud placeholder whose data is not on this Mac; it is never downloaded.
    case dataless
    /// A package holding placeholders, whose data its size leaves out.
    case containsDataless
    /// The scan was cancelled before this folder was read in full.
    case partial
    /// Something inside could not be read, so the sizes are at least these.
    case lowerBound
    /// Clones may be counted more than once, so the allocated size is at most this.
    case upperBound
    /// Another hard link, or the same folder reached another way, is where the space is counted.
    case countedElsewhere

    public var title: String {
        switch self {
        case .unknown: "Unknown size"
        case .dataless: "Not downloaded"
        case .containsDataless: "Has items not downloaded"
        case .partial: "Not fully scanned"
        case .lowerBound: "At least"
        case .upperBound: "At most"
        case .countedElsewhere: "Counted elsewhere"
        }
    }

    public var explanation: String {
        switch self {
        case .unknown: "This could not be read, so its size is unknown."
        case .dataless: "Stored in iCloud and not downloaded to this Mac, so it uses no space here. System never downloads it."
        case .containsDataless: "Some items inside are stored in iCloud and not downloaded, so the size leaves them out."
        case .partial: "The scan was cancelled before this folder was read in full."
        case .lowerBound: "Something inside could not be read, so the sizes are at least these."
        case .upperBound: "Blocks shared between clones may be counted more than once, so the size is at most this."
        case .countedElsewhere: "Another hard link to it, or the same folder reached another way, is where its space is counted."
        }
    }
}

/// One row of a Disk tab, ready to draw and to speak.
public struct DiskRow: Identifiable, Equatable, Sendable {
    public let id: DiskRowID
    /// 0 for a folder's items, a group, or a match; 1 for the items inside an open group or match.
    public let depth: Int
    public let name: String
    /// The kind of item, a match's location, or what a group stands for.
    public let detail: String
    /// The allocated size, "≥" when a lower bound, "≤" when an upper bound, "–" when unknown.
    public let size: String
    /// The private size, shown only when it differs from the allocated size.
    public let privateSize: String?
    /// The share of the parent folder's or the section's largest allocation, for the bar; `nil` without a size.
    public let fraction: Double?
    public let badges: [DiskBadge]
    /// The file to reveal or copy; `nil` for a row with no single file.
    public let path: String?
    /// A match's explanation, rebuild note, and what its cleanup would free.
    public let explanation: String?
    public let rebuild: String?
    public let yield: String?
    public let isExpandable: Bool
    public let isExpanded: Bool
    /// A folder the Folders tab can open.
    public let isNavigable: Bool
    public let accessibilityLabel: String
    public let accessibilityValue: String
}

/// A titled list of rows: the Folders tab has one untitled section, By origin one per `DiskOriginSection`, and
/// Suggestions one per risk.
public struct DiskRowSection: Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String?
    /// Why the section is empty, incomplete, or what its sizes mean.
    public let note: String?
    public let rows: [DiskRow]
}

/// One step of the Folders tab's path, the scanned root first.
public struct DiskBreadcrumb: Identifiable, Equatable, Sendable {
    public let id: Int
    public let name: String
    public let accessibilityLabel: String
}

extension UsageFormat {
    /// Disk space in decimal units, as Finder shows it. A missing value is "–", never zero.
    public func diskBytes(_ value: UInt64?) -> String {
        value.map { Int64(clamping: $0).formatted(.byteCount(style: .file).locale(locale)) } ?? "–"
    }

    public func diskBytes(_ value: Int64?) -> String {
        value.map { $0.formatted(.byteCount(style: .file).locale(locale)) } ?? "–"
    }

    public func count(_ value: Int) -> String {
        value.formatted(.number.locale(locale))
    }
}

/// The figures of one item or sum, formatted with what bounds them.
struct DiskFigures {
    let size: String
    let privateSize: String?
    let spoken: String
    let badges: [DiskBadge]

    /// `lowerBound` and `upperBound` qualify the allocated size; the private size is always at least what deleting
    /// frees, so it is shown only when it differs.
    init(allocated: UInt64?, private privateBytes: UInt64?, lowerBound: Bool, upperBound: Bool, flags: DiskItemFlags = [],
         format: UsageFormat) {
        var badges: [DiskBadge] = []
        if allocated == nil { badges.append(.unknown) }
        if flags.contains(.dataless) { badges.append(.dataless) }
        if flags.contains(.containsDataless) { badges.append(.containsDataless) }
        if flags.contains(.partial) { badges.append(.partial) }
        if allocated != nil, lowerBound { badges.append(.lowerBound) }
        if allocated != nil, upperBound { badges.append(.upperBound) }
        if flags.contains(.countedElsewhere) { badges.append(.countedElsewhere) }
        self.badges = badges
        let prefix = lowerBound && upperBound ? "≈" : lowerBound ? "≥" : upperBound ? "≤" : ""
        let spokenPrefix = lowerBound && upperBound ? "about " : lowerBound ? "at least " : upperBound ? "at most " : ""
        guard let allocated else {
            size = "–"
            privateSize = nil
            spoken = "size unknown"
            return
        }
        size = prefix + format.diskBytes(allocated)
        let differs = privateBytes.map { $0 != allocated } ?? false
        privateSize = differs ? format.diskBytes(privateBytes) + " private" : nil
        spoken = spokenPrefix + format.diskBytes(allocated)
            + (differs ? ", \(format.diskBytes(privateBytes)) private" : "")
    }

    /// Docker's reclaimable image space, the most its cleanup frees.
    init(upTo: UInt64, format: UsageFormat) {
        size = "up to " + format.diskBytes(upTo)
        privateSize = nil
        spoken = size
        badges = []
    }

    init(_ sizes: DiskSizes?, flags: DiskItemFlags, format: UsageFormat) {
        self.init(allocated: sizes?.allocated, private: sizes?.private,
                  lowerBound: !flags.isDisjoint(with: [.incomplete, .partial]), upperBound: flags.contains(.allocatedUpperBound),
                  flags: flags, format: format)
    }

    /// The spoken value: the size, then each badge.
    var accessibilityValue: String {
        ([spoken] + badges.filter { $0 != .unknown && $0 != .lowerBound && $0 != .upperBound }.map(\.title.localizedLowercase))
            .joined(separator: ", ")
    }
}

extension DiskItemKind {
    var title: String {
        switch self {
        case .file: "File"
        case .directory: "Folder"
        case .package: "Package"
        case .symlink: "Symbolic link"
        case .other: "Other item"
        case .mountPoint: "Another volume, not scanned"
        }
    }
}

extension ReclaimRisk {
    public var title: String {
        switch self {
        case .safe: "Safe to reclaim"
        case .review: "Review each item"
        case .info: "For information"
        }
    }

    public var note: String {
        switch self {
        case .safe: "Rebuilt or downloaded again by its tool when needed; nothing of yours is lost."
        case .review: "May hold something you want to keep: look at each item before removing it."
        case .info: "Shown for information only; System offers no cleanup."
        }
    }
}

extension ReclaimYield {
    /// What the rule's cleanup would free, for the Suggestions tab. Nothing in this window runs one.
    var note: String {
        switch self {
        case .movesAllMeasuredToTrash: "A cleanup would move these items to the Trash; the space comes back once the Trash is emptied."
        case .partOfMeasured: "The tool's cleanup keeps what is still in use, so it frees part of this."
        case .estimated: "The tool's cleanup decides what it deletes, so this is an estimate of what it frees."
        case .reportedUpperBound: "Reported by Docker; its cleanup removes only dangling images, so it may free less."
        case .noCleanup: "System offers no cleanup for this."
        }
    }
}
