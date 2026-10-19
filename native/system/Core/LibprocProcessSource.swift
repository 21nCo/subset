import Darwin

/// Reads every process on this Mac with libproc. Without root, macOS denies another user's usage counters
/// (`EPERM`); those processes are kept as `restricted`. Processes that exit mid-read are left out.
public struct LibprocProcessSource: ProcessSource {
    public let timebase: MachTimebase
    private let listAllPIDs: ListAllPIDs
    private let reads: Reads

    public init() {
        self.init(listAllPIDs: Self.liveListAllPIDs, reads: .live)
    }

    init(listAllPIDs: @escaping ListAllPIDs, reads: Reads) {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = MachTimebase(numer: info.numer, denom: info.denom)
        self.listAllPIDs = listAllPIDs
        self.reads = reads
    }

    public func sample() throws -> RawProcessSample {
        let pids = try Self.listPIDs(with: listAllPIDs)
        let timestamp = mach_absolute_time()
        return RawProcessSample(timestamp: timestamp, timebase: timebase, processes: pids.compactMap { Self.read($0, with: reads) })
    }

    /// `proc_listallpids` with the `errno` it left, replaceable in tests.
    typealias ListAllPIDs = @Sendable (_ buffer: UnsafeMutablePointer<pid_t>?, _ size: Int32) -> (count: Int32, errno: Int32)

    static let liveListAllPIDs: ListAllPIDs = { buffer, size in
        errno = 0
        let count = proc_listallpids(buffer, size)
        return (count, errno)
    }

    static func listPIDs(with listAllPIDs: ListAllPIDs = liveListAllPIDs) throws -> [pid_t] {
        // With no buffer, proc_listallpids returns the current count; the list can grow before the second call,
        // so leave headroom and retry while the buffer comes back full. libproc reports a failed call as 0 rather
        // than -1, and pids 0 and 1 always exist, so 0 is a failure, never an empty process list.
        let (initial, initialFailure) = listAllPIDs(nil, 0)
        guard initial > 0 else { throw ProcessSourceError.listFailed(initialFailure) }
        var capacity = Int(initial)
        while true {
            capacity += 64
            var pids = [pid_t](repeating: 0, count: capacity)
            let (count, failure) = pids.withUnsafeMutableBufferPointer { buffer in
                listAllPIDs(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
            }
            guard count > 0 else { throw ProcessSourceError.listFailed(failure) }
            if Int(count) < capacity { return Array(pids.prefix(Int(count))) }
            capacity = Int(count) * 2
        }
    }

    /// The PID-keyed reads one record is built from, replaceable in tests.
    struct Reads: Sendable {
        var basics: @Sendable (pid_t) -> ProcessBasics?
        var usage: @Sendable (pid_t) -> UsageReading?
        var executablePath: @Sendable (pid_t) -> String?

        static let live = Reads(
            basics: LibprocProcessSource.basics,
            usage: LibprocProcessSource.usage,
            executablePath: LibprocProcessSource.executablePath
        )
    }

    /// Reads one process, or `nil` when it exited. Each read is keyed by PID alone, so the identity is read again
    /// afterwards: if the PID now belongs to a later process, the counters or path may be the new process's, and the
    /// whole record is read once more. A PID that changes hands twice during one read is left for the next sample.
    static func read(_ pid: pid_t, with reads: Reads = .live) -> RawProcessRecord? {
        for _ in 0..<2 {
            guard let basics = reads.basics(pid), let usage = reads.usage(pid) else { return nil }
            let path = reads.executablePath(pid)
            guard let current = reads.basics(pid) else { return nil }
            guard current.identity == basics.identity else { continue }
            let name = basics.name.isEmpty ? path.map { String($0.split(separator: "/").last ?? "") } ?? "" : basics.name
            return RawProcessRecord(
                identity: basics.identity,
                ppid: basics.ppid,
                uid: basics.uid,
                executablePath: path,
                name: name,
                usage: usage
            )
        }
        return nil
    }

    struct ProcessBasics: Sendable {
        let identity: ProcessIdentity
        let ppid: Int32
        let uid: UInt32
        let name: String
    }

    /// Identity, parent, owner, and name, or `nil` when the process is gone.
    private static func basics(_ pid: pid_t) -> ProcessBasics? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let name = cString(info.pbi_name)
            return ProcessBasics(
                identity: ProcessIdentity(pid: pid, startTime: info.pbi_start_tvsec &* 1_000_000 &+ info.pbi_start_tvusec),
                ppid: Int32(bitPattern: info.pbi_ppid),
                uid: info.pbi_uid,
                name: name.isEmpty ? cString(info.pbi_comm) : name
            )
        }
        if errno == ESRCH { return nil }
        // proc_pidinfo refuses another user's process with EPERM, but the process table still has its start time,
        // parent, and owner, so the process keeps a stable identity.
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &process, &length, nil, 0) == 0, length == MemoryLayout<kinfo_proc>.stride
        else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        return ProcessBasics(
            identity: ProcessIdentity(
                pid: pid,
                startTime: UInt64(clamping: start.tv_sec) &* 1_000_000 &+ UInt64(clamping: start.tv_usec)
            ),
            ppid: process.kp_eproc.e_ppid,
            uid: process.kp_eproc.e_ucred.cr_uid,
            name: cString(process.kp_proc.p_comm)
        )
    }

    /// The usage counters, or `nil` when the process is gone.
    private static func usage(_ pid: pid_t) -> UsageReading? {
        var info = rusage_info_v6()
        var failure: Int32 = 0
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { buffer in
                let result = proc_pid_rusage(pid, RUSAGE_INFO_V6, buffer)
                failure = errno
                return result
            }
        }
        guard result != 0 else {
            return .available(RawProcessUsage(
                physFootprint: info.ri_phys_footprint,
                userTime: info.ri_user_time,
                systemTime: info.ri_system_time,
                billedEnergy: info.ri_billed_energy
            ))
        }
        switch failure {
        case EPERM: return .restricted
        case ESRCH: return nil
        default: return .unavailable
        }
    }

    private static func executablePath(_ pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE (4 × MAXPATHLEN) is not imported into Swift.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Decodes a fixed-size, NUL-terminated C char array imported as a tuple.
    private static func cString<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
