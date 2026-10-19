import Darwin

/// Where a process runs: its working directory and controlling terminal.
public protocol ProcessContextReading: Sendable {
    func workingDirectory(of pid: pid_t) -> Signal<String>
    func terminal(of pid: pid_t) -> Signal<ControllingTerminal>
}

/// Reads the working directory with `PROC_PIDVNODEPATHINFO` and the controlling terminal with `PROC_PIDTBSDINFO`.
/// macOS denies both for another user's process; the terminal then comes from the process table, which any user
/// may read. The working directory has no such fallback.
public struct LiveProcessContextReader: ProcessContextReading {
    public init() {}

    public func workingDirectory(of pid: pid_t) -> Signal<String> {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size)
        let failure = errno
        guard result == size else {
            let reason: SignalFailure = result <= 0 && failure != 0
                ? SignalFailure(errno: failure)
                : .unexpectedResult("returned \(result) bytes, expected \(size)")
            return .unavailable(reason, source: .vnodePathInfo)
        }
        let path = withUnsafeBytes(of: info.pvi_cdir.vip_path) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        guard !path.isEmpty else {
            return .unavailable(.unexpectedResult("reported no working directory"), source: .vnodePathInfo)
        }
        return .value(path, source: .vnodePathInfo)
    }

    public func terminal(of pid: pid_t) -> Signal<ControllingTerminal> {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        errno = 0
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        let failure = errno
        if result == size {
            return .value(Self.terminal(device: dev_t(bitPattern: info.e_tdev)), source: .bsdInfo)
        }
        guard result <= 0, failure == EPERM else {
            let reason: SignalFailure = result <= 0 && failure != 0
                ? SignalFailure(errno: failure)
                : .unexpectedResult("returned \(result) bytes, expected \(size)")
            return .unavailable(reason, source: .bsdInfo)
        }
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &process, &length, nil, 0) == 0 else {
            return .unavailable(SignalFailure(errno: errno), source: .processTable)
        }
        // A PID that no longer exists yields success with no data.
        guard length == MemoryLayout<kinfo_proc>.stride else { return .unavailable(.processExited, source: .processTable) }
        return .value(Self.terminal(device: process.kp_eproc.e_tdev), source: .processTable)
    }

    /// `NODEV` (all bits set) means no controlling terminal. A device `devname` cannot name is shown by its major and
    /// minor numbers, as `ps` does.
    static func terminal(device: dev_t, name: (dev_t) -> String? = deviceName) -> ControllingTerminal {
        guard device != dev_t(bitPattern: UInt32.max) else { return .none }
        if let name = name(device), !name.isEmpty, name != "??" { return .device(name) }
        let raw = UInt32(bitPattern: device)
        return .device("\(raw >> 24),\(raw & 0xFF_FFFF)")
    }

    private static func deviceName(_ device: dev_t) -> String? {
        devname(device, S_IFCHR).map { String(cString: $0) }
    }
}
