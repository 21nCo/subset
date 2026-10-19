import Darwin

/// Looks up a C symbol by name at run time, so a private interface missing from some macOS version is reported as
/// unavailable instead of failing to link. The live resolver searches every loaded image with `dlsym`.
public struct SymbolResolver: Sendable {
    let resolve: @Sendable (String) -> UnsafeMutableRawPointer?

    public init(_ resolve: @escaping @Sendable (String) -> UnsafeMutableRawPointer?) {
        self.resolve = resolve
    }

    public static let live = SymbolResolver { name in
        // RTLD_DEFAULT is ((void *)-2), a macro Swift does not import.
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    func function<Function>(_ name: String, as type: Function.Type) -> Function? {
        resolve(name).map { unsafeBitCast($0, to: type) }
    }
}

/// The process macOS holds responsible for another: the app behind its helpers and XPC services, or the terminal
/// behind a command run in it.
public protocol ResponsibleProcessReading: Sendable {
    func responsibleProcess(of pid: pid_t) -> Signal<Int32>
}

/// Calls the private `responsibility_get_pid_responsible_for_pid`. macOS answers for the caller's own processes and
/// denies (`EPERM`) the rest without root.
public struct LiveResponsibleProcessReader: ResponsibleProcessReading {
    public typealias Function = @convention(c) (pid_t) -> pid_t
    static let symbol = "responsibility_get_pid_responsible_for_pid"
    private let function: Function?

    public init(resolver: SymbolResolver = .live) {
        function = resolver.function(Self.symbol, as: Function.self)
    }

    public func responsibleProcess(of pid: pid_t) -> Signal<Int32> {
        guard let function else { return .unavailable(.symbolMissing(Self.symbol), source: .responsibility) }
        errno = 0
        let responsible = function(pid)
        let failure = errno
        guard responsible > 0 else {
            let reason: SignalFailure = responsible < 0 && failure != 0
                ? SignalFailure(errno: failure)
                : .unexpectedResult("returned pid \(responsible)")
            return .unavailable(reason, source: .responsibility)
        }
        return .value(responsible, source: .responsibility)
    }
}

/// The resource coalition a process belongs to. macOS puts an app and the XPC services and helpers it launches in
/// one coalition, as Activity Monitor's app grouping shows.
public protocol CoalitionReading: Sendable {
    func coalition(of pid: pid_t) -> Signal<UInt64>
}

/// Calls `proc_pidinfo` with the private `PROC_PIDCOALITIONINFO` flavor. The flavor and its result layout come from
/// XNU's `proc_info_private.h`: `struct proc_pidcoalitioninfo { uint64_t coalition_id[COALITION_NUM_TYPES];
/// uint64_t reserved1, reserved2, reserved3; }`, with the resource coalition at index 0. A macOS that does not know
/// the flavor fails the call, which is recorded rather than trusted.
public struct LiveCoalitionReader: CoalitionReading {
    public typealias Function = @convention(c) (
        _ pid: Int32, _ flavor: Int32, _ arg: UInt64, _ buffer: UnsafeMutableRawPointer?, _ size: Int32
    ) -> Int32
    static let symbol = "proc_pidinfo"
    static let flavor: Int32 = 20
    /// `COALITION_NUM_TYPES` (2) identifiers plus three reserved words.
    static let resultWords = 5
    private let function: Function?

    public init(resolver: SymbolResolver = .live) {
        function = resolver.function(Self.symbol, as: Function.self)
    }

    public func coalition(of pid: pid_t) -> Signal<UInt64> {
        guard let function else { return .unavailable(.symbolMissing(Self.symbol), source: .coalitionInfo) }
        var words = [UInt64](repeating: 0, count: Self.resultWords)
        let expected = Int32(Self.resultWords * MemoryLayout<UInt64>.stride)
        errno = 0
        let size = words.withUnsafeMutableBytes { function(pid, Self.flavor, 0, $0.baseAddress, expected) }
        let failure = errno
        guard size > 0 else {
            // libproc reports a failure as 0 and leaves the reason in errno.
            let reason: SignalFailure = failure != 0 ? SignalFailure(errno: failure) : .unexpectedResult("returned no data")
            return .unavailable(reason, source: .coalitionInfo)
        }
        guard size == expected else {
            return .unavailable(.unexpectedResult("returned \(size) bytes, expected \(expected)"), source: .coalitionInfo)
        }
        guard words[0] != 0 else {
            return .unavailable(.unexpectedResult("reported no resource coalition"), source: .coalitionInfo)
        }
        return .value(words[0], source: .coalitionInfo)
    }
}
