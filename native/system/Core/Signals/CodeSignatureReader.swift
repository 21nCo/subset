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
        self.init(path: path, info: info)
    }

    init(path: String, info: stat) {
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
/// process started after the file last changed, the file did not change during the read, and afterwards the PID
/// still belongs to the same process and that process still runs the file. `exec` keeps the PID and start time, so
/// without the last check a process that ran `exec` during the read would file its new executable's signature
/// under the old path. A process that started before the file changed may still run the replaced version, so it is
/// read directly and neither uses nor fills the entry; so is one that no longer runs the file when it is checked
/// before an entry is used. Only values are kept: a failure such as an exited process says nothing about the file.
/// Without an executable path, or when `stat` fails (the file was deleted), the read is not cached.
public final class CachedCodeSignatureReader: CodeSignatureReading, @unchecked Sendable {
    private let reader: any CodeSignatureReading
    private let check: @Sendable (ProcessIdentity, String?) -> ProcessImageCheck
    private let lock = NSLock()
    /// One entry per path, so a modified file replaces its earlier entry instead of adding one.
    private var cache: [String: (stamp: FileStamp, signature: Signal<CodeSignature>)] = [:]
    /// Tools such as `go run` build each run to a new temporary path; past this many paths the cache starts over
    /// rather than grow for as long as the app runs.
    static let capacity = 4096

    /// `check` tells whether a PID still belongs to an identity and runs an executable; by default the kernel is
    /// asked.
    public init(
        reader: any CodeSignatureReading = SecCodeSignatureReader(),
        check: (@Sendable (ProcessIdentity, String?) -> ProcessImageCheck)? = nil
    ) {
        self.reader = reader
        self.check = check ?? LibprocProcessSource.check
    }

    public func codeSignature(of identity: ProcessIdentity, executablePath: String?) -> Signal<CodeSignature> {
        guard let executablePath, let stamp = FileStamp(path: executablePath), stamp.predates(identity) else {
            return reader.codeSignature(of: identity, executablePath: executablePath)
        }
        if let cached = lock.withLock({ cache[executablePath] }), cached.stamp == stamp {
            if check(identity, executablePath) == .unchanged { return cached.signature }
            return reader.codeSignature(of: identity, executablePath: executablePath)
        }
        let signature = reader.codeSignature(of: identity, executablePath: executablePath)
        if signature.value != nil, FileStamp(path: executablePath) == stamp, check(identity, executablePath) == .unchanged {
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
///
/// The signing information comes from the file on disk, which may have been replaced since the process started (an
/// app updated while it runs), so it is published only when two views of the code agree: `SecCodeCheckValidity`,
/// without network access, over the file, and the kernel's status of the running code (`kSecCodeInfoStatus`). A signed
/// file must pass the check, which compares it with the running code, and the running code must be signed. An unsigned
/// file has nothing to compare, so it is published as unsigned only when the running code is unsigned too.
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
        // The dynamic information adds the kernel's status of the running code to the file's signing information.
        let infoStatus = SecCodeCopySigningInformation(
            unsafeBitCast(code, to: SecStaticCode.self),
            SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSDynamicInformation),
            &information
        )
        guard infoStatus == errSecSuccess, let information = information as? [String: Any] else {
            return .unavailable(Self.failure(infoStatus), source: .codeSigning)
        }
        let validity = SecCodeCheckValidity(code, .noNetworkAccess, nil)
        let kernelStatus = (information[kSecCodeInfoStatus as String] as? NSNumber)?.uint32Value
        if let failure = Self.runningImageFailure(validity: validity, kernelStatus: kernelStatus) {
            return .unavailable(failure, source: .codeSigning)
        }
        return .value(Self.signature(from: information), source: .codeSigning)
    }

    /// `CS_SIGNED` in the kernel's code-signing status (`<kern/cs_blobs.h>`): the running code has a signature.
    static let kernelSigned: UInt32 = 0x2000_0000

    /// Why the file's signing information cannot be published for the running code, or `nil` when it can: the file
    /// passed `SecCodeCheckValidity` and the running code is signed, or both are unsigned. `errSecCSUnsigned` comes from
    /// checking the file before it is compared with the running code, so on its own it says nothing about the process.
    static func runningImageFailure(validity: OSStatus, kernelStatus: UInt32?) -> SignalFailure? {
        guard validity == errSecSuccess || validity == errSecCSUnsigned else { return failure(validity) }
        guard let kernelStatus else { return .unexpectedResult("the kernel did not report the running code's status") }
        let runningSigned = kernelStatus & kernelSigned != 0
        switch (validity == errSecSuccess, runningSigned) {
        case (true, true), (false, false): return nil
        case (false, true): return .unexpectedResult("the process runs signed code but the executable on disk is unsigned")
        case (true, false): return .unexpectedResult("the process runs unsigned code but the executable on disk is signed")
        }
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
        case errSecCSStaticCodeChanged: .unexpectedResult("the executable on disk is not the one the process runs")
        default: .securityError(status)
        }
    }
}
