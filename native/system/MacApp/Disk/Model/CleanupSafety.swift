import Darwin
import Foundation
import SystemCore

/// The places a cleanup never moves anything from, checked for every item even when a rule matched it. Only the home
/// folder's contents may be moved to the Trash; a tool command acts on its tool's own folders, which it chooses.
public struct CleanupProtection: Sendable {
    /// Folders of macOS that are refused with everything inside them. `/usr/local` is not one of them, but it is outside
    /// the home folder, so it is refused too.
    public static let systemFolders = ["/System", "/usr", "/bin", "/sbin", "/private/var"]
    static let systemExceptions = ["/usr/local"]
    /// Folders in the home folder refused with everything inside them. The Trash is among them: System never moves,
    /// empties, or deletes what is already there.
    public static let homeFolders = ["Library/Mobile Documents", "Library/Keychains", "Library/Mail", ".Trash"]

    /// The home folder's real path.
    public let home: String
    let systemFolders: [String]

    public init(home: String) {
        self.init(home: home, systemFolders: Self.systemFolders)
    }

    /// Tests keep their fixture home folder in the temporary folder, which is inside `/private/var`, and so leave that
    /// folder out here.
    init(home: String, systemFolders: [String]) {
        self.home = home
        self.systemFolders = systemFolders
    }

    /// Why `path` must not be moved, or `nil` when it may be. Every refusal of a protected folder compares names folded
    /// for case and Unicode normalization, as APFS compares them by default, so another spelling of one is refused too.
    /// Being inside the home folder is the one thing that allows, so it is decided on the exact spelling: on a
    /// case-sensitive volume another spelling of the home folder is another folder.
    public func refusal(_ path: String) -> String? {
        guard Self.isPlain(path) else { return "\(path) is not a plain absolute path." }
        let key = Self.key(path)
        let exempt = Self.systemExceptions.contains { Self.isInside(key, Self.key($0)) }
        if !exempt, let folder = systemFolders.first(where: { Self.isInside(key, Self.key($0)) }) {
            return "\(path) is in \(folder), which System never changes."
        }
        let homeKey = Self.key(home)
        if key == homeKey { return "Your home folder itself is never removed." }
        guard Self.isPlain(home), home != "/", Self.isExactlyInside(path, home) else {
            return "\(path) is outside your home folder."
        }
        let relative = Self.key(String(decoding: path.utf8.dropFirst(home.utf8.count + 1), as: UTF8.self))
        if relative == "library" { return "Your Library folder itself is never removed." }
        if let folder = Self.homeFolders.first(where: { Self.isInside(relative, Self.key($0)) }) {
            return "\(path) is in ~/\(folder), which System never changes."
        }
        let components = relative.split(separator: "/")
        if components.count >= 2, components[0] == "pictures", components[1].hasSuffix(".photoslibrary") {
            return "\(path) is a Photos library in ~/Pictures or inside one, which System never changes."
        }
        return nil
    }

    /// An absolute path without empty, `.`, or `..` components, so that comparing it as text compares the place.
    static func isPlain(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return false }
        if path == "/" { return true }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    static func key(_ path: String) -> String {
        path.decomposedStringWithCanonicalMapping.lowercased()
    }

    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder == "/" ? "/" : folder + "/")
    }

    /// `path` is strictly inside `folder`, comparing their bytes: Swift's own comparison treats canonically equivalent
    /// spellings as equal, which a file system need not.
    static func isExactlyInside(_ path: String, _ folder: String) -> Bool {
        path.utf8.starts(with: (folder == "/" ? "/" : folder + "/").utf8) && path.utf8.count > folder.utf8.count + 1
    }
}

/// One item a Trash cleanup would move, as the scan found it.
public struct CleanupItem: Hashable, Sendable {
    public let path: String
    /// The rule's folder that holds it, which a cleanup never removes.
    public let root: String
    /// The volume and inode the scan read; an item without both is never moved.
    public let identity: DiskItemIdentity?
    /// Its private size when scanned: what emptying the Trash frees at least once it is there. `nil` when unknown.
    public let privateBytes: UInt64?
    /// The size is a lower bound (something inside could not be read, or another hard link counts its blocks).
    public let isLowerBound: Bool

    public init(path: String, root: String, identity: DiskItemIdentity?, privateBytes: UInt64?, isLowerBound: Bool) {
        self.path = path
        self.root = root
        self.identity = identity
        self.privateBytes = privateBytes
        self.isLowerBound = isLowerBound
    }

    init(_ item: ReclaimItem) {
        let lowerBound: DiskItemFlags = [.unreadable, .partial, .incomplete, .countedElsewhere]
        self.init(path: item.path, root: item.root, identity: item.identity, privateBytes: item.sizes?.private,
                  isLowerBound: item.sizes == nil || !item.flags.isDisjoint(with: lowerBound))
    }

    /// Checks, just before the move, that the item may still be moved: it is not protected, it is inside its rule's
    /// folder and not that folder, no folder above it has become a link elsewhere, it is not a link itself, and it is
    /// still the file the scan read: the same volume and inode, both read then and now. Returns why it is skipped, or
    /// `nil`. `identify` reads what is at a path now (`DiskItemIdentity.current`).
    func revalidate(_ protection: CleanupProtection,
                    identify: (String) -> DiskItemCurrent = DiskItemIdentity.current) -> CleanupSkipReason? {
        if case let .failure(reason) = check(protection, identify: identify) { return reason }
        return nil
    }

    /// `revalidate`, returning, when the item may be moved, the folder holding it, held open: it must still be the
    /// folder at that path once the item has been moved, and it is the only place the item is ever put back into.
    func check(_ protection: CleanupProtection,
               identify: (String) -> DiskItemCurrent) -> Result<HeldFolder, CleanupSkipReason> {
        if let reason = recheck(protection, identify: identify) { return .failure(reason) }
        return HeldFolder.open((path as NSString).deletingLastPathComponent)
    }

    private func recheck(_ protection: CleanupProtection, identify: (String) -> DiskItemCurrent) -> CleanupSkipReason? {
        if let reason = protection.refusal(path) { return .protected(reason) }
        guard CleanupProtection.isPlain(root) else { return .outsideRoot }
        if CleanupProtection.key(path) == CleanupProtection.key(root) { return .isRoot }
        guard CleanupProtection.isExactlyInside(path, root) else { return .outsideRoot }
        guard let identity, identity.isComplete else { return .notIdentified }
        // Every folder above it, its rule's folder included, must still be the folder of that name: one replaced by a
        // link would lead the move somewhere else.
        let parent = (path as NSString).deletingLastPathComponent
        guard let real = Self.realPath(parent) else { return .missing }
        guard real.utf8.elementsEqual(parent.utf8) else { return .outsideRoot }
        switch identify(path) {
        case .missing: return .missing
        case .symlink: return .symlink
        case let .unreadable(code): return .unreadable(code)
        case let .item(now, _): return now.isSameFile(as: identity) ? nil : .replaced
        }
    }

    static func realPath(_ path: String) -> String? {
        guard let real = realpath(path, nil) else { return nil }
        defer { free(real) }
        return String(cString: real)
    }
}

/// Which folder is at a path, reached without following any link: its volume and inode (`fstat`). A folder has one
/// place, so the same folder found at the same path again, with no link on the way, is the folder that was there.
struct FolderIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t

    /// The folder at `path` now; a link anywhere on the way, or a file, is `outsideRoot`.
    static func read(_ path: String) -> Result<FolderIdentity, CleanupSkipReason> {
        HeldFolder.open(path).map(\.identity)
    }
}

/// A folder opened without following any link and kept open, so it can be reached however it is renamed or moved
/// afterwards. The descriptor is closed when this is released.
final class HeldFolder {
    let descriptor: Int32
    let identity: FolderIdentity

    private init(descriptor: Int32, identity: FolderIdentity) {
        self.descriptor = descriptor
        self.identity = identity
    }

    deinit { close(descriptor) }

    /// The folder at `path` now; a link anywhere on the way, or a file, is `outsideRoot`.
    static func open(_ path: String) -> Result<HeldFolder, CleanupSkipReason> {
        let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else {
            let error = errno
            switch error {
            case ENOENT: return .failure(.missing)
            case ELOOP, ENOTDIR: return .failure(.outsideRoot)
            default: return .failure(.unreadable(error))
            }
        }
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            let error = errno
            close(fd)
            return .failure(.unreadable(error))
        }
        return .success(HeldFolder(descriptor: fd, identity: FolderIdentity(device: info.st_dev, inode: info.st_ino)))
    }
}

/// Why an item was not moved.
public enum CleanupSkipReason: Error, Equatable, Sendable {
    /// A protected place (`CleanupProtection`).
    case protected(String)
    case missing
    case symlink
    /// Its path no longer leads inside its rule's folder.
    case outsideRoot
    /// It is the rule's folder itself.
    case isRoot
    /// Another file is at its path now.
    case replaced
    /// Another file took its place between the check and the move; it was moved back from the Trash.
    case replacedWhileMoving
    /// The folder holding it moved or became a link during the move, so it may have been taken from elsewhere; it was
    /// moved back from the Trash.
    case folderChangedWhileMoving
    /// The scan did not read both its volume and its inode, so it cannot be checked.
    case notIdentified
    case unreadable(Int32)
    /// The cleanup was stopped before this item.
    case stopped

    public var text: String {
        switch self {
        case let .protected(reason): reason
        case .missing: "It is no longer there."
        case .symlink: "It is now a symbolic link, which System never follows or moves."
        case .outsideRoot: "Its path no longer leads inside the rule's folder."
        case .isRoot: "It is the rule's folder itself, which is never removed."
        case .replaced: "Another item has taken its place since the scan."
        case .replacedWhileMoving:
            "Another item took its place just before the move; it was put back from the Trash, and this item was not moved."
        case .folderChangedWhileMoving:
            "The folder holding it moved or became a link during the move, so it was put back from the Trash."
        case .notIdentified: "The scan could not read which file it was, so it cannot be checked."
        case let .unreadable(code): "It could not be checked: \(String(cString: strerror(code)))."
        case .stopped: "The cleanup was stopped before this item."
        }
    }
}
