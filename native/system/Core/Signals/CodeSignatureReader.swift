import Darwin
import Foundation
import Security

/// The code signature of a running process's executable.
public protocol CodeSignatureReading: Sendable {
    func codeSignature(of pid: pid_t, executablePath: String?) -> Signal<CodeSignature>
}

/// An executable file as `stat` sees it. A signature read for one stamp holds until the file changes size or
/// modification time.
struct FileStamp: Hashable, Sendable {
    let path: String
    let size: Int64
    let modified: timespec

    init?(path: String) {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        self.path = path
        size = info.st_size
        modified = info.st_mtimespec
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(size)
        hasher.combine(modified.tv_sec)
        hasher.combine(modified.tv_nsec)
    }
}

/// Reads signatures through another reader and keeps each one by executable path, file size, and modification
/// time, so the many processes running one executable cost one read, and a replaced or rebuilt file is read again.
/// Only values are kept: a failure such as an exited process says nothing about the file. Without an executable
/// path, or when `stat` fails (the file was deleted), the read is not cached.
public final class CachedCodeSignatureReader: CodeSignatureReading, @unchecked Sendable {
    private let reader: any CodeSignatureReading
    private let lock = NSLock()
    /// One entry per path, so a modified file replaces its earlier entry instead of adding one.
    private var cache: [String: (stamp: FileStamp, signature: Signal<CodeSignature>)] = [:]
    /// Tools such as `go run` build each run to a new temporary path; past this many paths the cache starts over
    /// rather than grow for as long as the app runs.
    static let capacity = 4096

    public init(reader: any CodeSignatureReading = SecCodeSignatureReader()) {
        self.reader = reader
    }

    public func codeSignature(of pid: pid_t, executablePath: String?) -> Signal<CodeSignature> {
        guard let executablePath, let stamp = FileStamp(path: executablePath) else {
            return reader.codeSignature(of: pid, executablePath: executablePath)
        }
        if let cached = lock.withLock({ cache[executablePath] }), cached.stamp == stamp { return cached.signature }
        let signature = reader.codeSignature(of: pid, executablePath: executablePath)
        if signature.value != nil {
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

    public func codeSignature(of pid: pid_t, executablePath: String?) -> Signal<CodeSignature> {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary
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
