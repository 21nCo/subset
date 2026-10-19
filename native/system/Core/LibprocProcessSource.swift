import Darwin

/// Reads every process on this Mac with libproc. Without root, macOS denies another user's usage counters
/// (`EPERM`); those processes are kept as `restricted`. Processes that exit mid-read are left out.
public struct LibprocProcessSource: ProcessSource {
    public let timebase: MachTimebase

    public init() {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        timebase = MachTimebase(numer: info.numer, denom: info.denom)
    }

    public func sample() throws -> RawProcessSample {
        let pids = try Self.listPIDs()
        let timestamp = mach_absolute_time()
        return RawProcessSample(timestamp: timestamp, timebase: timebase, processes: pids.compactMap(Self.read))
    }

    static func listPIDs() throws -> [pid_t] {
        // With no buffer, proc_listallpids returns the current count; the list can grow before the second call,
        // so leave headroom and retry while the buffer comes back full.
        var capacity = Int(proc_listallpids(nil, 0))
        guard capacity > 0 else { throw ProcessSourceError.listFailed(errno) }
        while true {
            capacity += 64
            var pids = [pid_t](repeating: 0, count: capacity)
            var failure: Int32 = 0
            let count = pids.withUnsafeMutableBufferPointer { buffer in
                let count = proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<pid_t>.stride))
                failure = errno
                return Int(count)
            }
            guard count >= 0 else { throw ProcessSourceError.listFailed(failure) }
            if count < capacity { return Array(pids.prefix(count)) }
            capacity = count * 2
        }
    }

    static func read(_ pid: pid_t) -> RawProcessRecord? {
        guard let basics = basics(pid), let usage = usage(pid) else { return nil }
        let path = executablePath(pid)
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

    private struct Basics {
        let identity: ProcessIdentity
        let ppid: Int32
        let uid: UInt32
        let name: String
    }

    /// Identity, parent, owner, and name, or `nil` when the process is gone.
    private static func basics(_ pid: pid_t) -> Basics? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let name = cString(info.pbi_name)
            return Basics(
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
        return Basics(
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
