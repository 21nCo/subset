import Darwin
import Foundation
import Security

/// The code signature of a running process's executable.
public protocol CodeSignatureReading: Sendable {
    func codeSignature(of identity: ProcessIdentity, executablePath: String?) -> Signal<CodeSignature>
}

/// An executable file as `stat` sees it. A signature read for one stamp holds until the file changes size,
/// modification time, or status-change time. The status-change time is kept as well because installers and
/// archives often preserve an older modification time, while the kernel always sets the status-change time.
struct FileStamp: Hashable, Sendable {
    let path: String
    let size: Int64
    let modified: timespec
    let changed: timespec

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.path = path
        size = info.st_size
        modified = info.st_mtimespec
        changed = info.st_ctimespec
    }

    /// The file has not changed since the process started, so the process runs this version of it. A process
    /// started earlier may run a version the file has since replaced. Start times are microseconds since 1970.
    func predates(_ identity: ProcessIdentity) -> Bool {
        guard changed.tv_sec >= 0 else { return false }
        let changedMicroseconds = UInt64(changed.tv_sec) &* 1_000_000 &+ UInt64(changed.tv_nsec / 1000)
        return changedMicroseconds <= identity.startTime
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(size)
        hasher.combine(modified.tv_sec)
        hasher.combine(modified.tv_nsec)
        hasher.combine(changed.tv_sec)
        hasher.combine(changed.tv_nsec)
    }
}

/// Reads signatures through another reader and keeps each one by executable path, file size, and modification
/// time (plus status-change time), so the many processes running one executable cost one read, and a replaced or
/// rebuilt file is read again.
///
/// The reads are by PID, so an entry is published only when the read must describe the file as stamped: the
/// process started after the file last changed, the file did not change during the read, and the PID still
/// belongs to the same process afterwards. A process that started before the file changed may still run the
/// replaced version, so it is read directly and neither uses nor fills the entry. Only values are kept: a failure
/// such as an exited process says nothing about the file. Without an executable path, or when `stat` fails (the
/// file was deleted), the read is not cached.
public final class CachedCodeSignatureReader: CodeSignatureReading, @unchecked Sendable {
    private let reader: any CodeSignatureReading
    private let isCurrent: @Sendable (ProcessIdentity) -> Bool
    private let lock = NSLock()
    /// One entry per path, so a modified file replaces its earlier entry instead of adding one.
    private var cache: [String: (stamp: FileStamp, signature: Signal<CodeSignature>)] = [:]
    /// Tools such as `go run` build each run to a new temporary path; past this many paths the cache starts over
    /// rather than grow for as long as the app runs.
    static let capacity = 4096

    /// `isCurrent` tells whether a PID still belongs to an identity; by default the kernel is asked.
    public init(
        reader: any CodeSignatureReading = SecCodeSignatureReader(),
        isCurrent: (@Sendable (ProcessIdentity) -> Bool)? = nil
    ) {
        self.reader = reader
        self.isCurrent = isCurrent ?? { LibprocProcessSource.currentIdentity(of: $0.pid) == $0 }
    }

    public func codeSignature(of identity: ProcessIdentity, executablePath: String?) -> Signal<CodeSignature> {
        guard let executablePath, let stamp = FileStamp(path: executablePath), stamp.predates(identity) else {
            return reader.codeSignature(of: identity, executablePath: executablePath)
        }
        if let cached = lock.withLock({ cache[executablePath] }), cached.stamp == stamp { return cached.signature }
        let signature = reader.codeSignature(of: identity, executablePath: executablePath)
        if signature.value != nil, FileStamp(path: executablePath) == stamp, isCurrent(identity) {
            lock.withLock {
                if cache.count >= Self.capacity, cache[executablePath] == nil { cache.removeAll(keepingCapacity: true) }
                cache[executablePath] = (stamp, signature)
            }
        }
        return signature
    }
}

/// Reads a running process's signature with `SecCodeCopyGuestWithAttributes` (by PID) and
/// `SecCodeCopySigningInformation`. Any user may read any process's signature this way.
public struct SecCodeSignatureReader: CodeSignatureReading {
    public init() {}

    public func codeSignature(of identity: ProcessIdentity, executablePath: String?) -> Signal<CodeSignature> {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: identity.pid)] as CFDictionary
        let guestStatus = SecCodeCopyGuestWithAttributes(nil, attributes, [], &code)
        guard guestStatus == errSecSuccess else { return .unavailable(Self.failure(guestStatus), source: .codeSigning) }
        guard let code else { return .unavailable(.unexpectedResult("returned no code object"), source: .codeSigning) }
        var information: CFDictionary?
        // A SecCode is a SecStaticCode for this call, as Security's own headers document.
        let infoStatus = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self),
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &information
        )
        guard infoStatus == errSecSuccess, let information = information as? [String: Any] else {
            return .unavailable(Self.failure(infoStatus), source: .codeSigning)
        }
        return .value(Self.signature(from: information), source: .codeSigning)
    }

    /// Unsigned code yields a dictionary without an identifier, which is a valid answer.
    static func signature(from information: [String: Any]) -> CodeSignature {
        let platform = (information[kSecCodeInfoPlatformIdentifier as String] as? NSNumber)?.intValue ?? 0
        return CodeSignature(
            signingID: information[kSecCodeInfoIdentifier as String] as? String,
            teamID: information[kSecCodeInfoTeamIdentifier as String] as? String,
            isPlatformBinary: platform != 0
        )
    }

    /// Security reports a failed system call as 100000 plus its `errno`.
    static func failure(_ status: OSStatus) -> SignalFailure {
        switch status {
        case 100_000 + ESRCH, errSecCSNoSuchCode: .processExited
        case 100_000 + EPERM: .denied
        default: .securityError(status)
        }
    }
}
