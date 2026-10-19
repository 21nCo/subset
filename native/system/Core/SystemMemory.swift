import Darwin

/// `kern.memorystatus_vm_pressure_level`, the level Activity Monitor's Memory Pressure graph colors.
public enum MemoryPressure: Equatable, Sendable {
    case normal
    case warning
    case critical

    /// The kernel reports 1, 2, or 4; anything else is not a level.
    public init?(level: Int32) {
        switch level {
        case 1: self = .normal
        case 2: self = .warning
        case 4: self = .critical
        default: return nil
        }
    }

    public var title: String {
        switch self {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }
}

/// The Mac's memory state, in bytes. A value that could not be read or parsed is `nil`, never zero.
public struct SystemMemory: Equatable, Sendable {
    public let pressure: MemoryPressure?
    public let physicalMemory: UInt64?
    public let swapUsed: UInt64?
    public let swapTotal: UInt64?
    /// Memory the compressor occupies (Activity Monitor's Compressed).
    public let compressed: UInt64?
    public let wired: UInt64?
    /// Anonymous memory that is not purgeable (Activity Monitor's App Memory).
    public let app: UInt64?

    /// App, wired, and compressed memory: Activity Monitor's Memory Used, or `nil` if the sum does not fit.
    public var used: UInt64? {
        guard let app, let wired, let compressed else { return nil }
        let (appAndWired, overflow) = app.addingReportingOverflow(wired)
        let (total, totalOverflow) = appAndWired.addingReportingOverflow(compressed)
        return overflow || totalOverflow ? nil : total
    }

    public init(raw: RawSystemMemory) {
        pressure = raw.pressureLevel.flatMap { Self.load(Int32.self, from: $0) }.flatMap(MemoryPressure.init(level:))
        physicalMemory = raw.memorySize.flatMap { Self.load(UInt64.self, from: $0) }
        let swap = raw.swapUsage.flatMap { Self.load(xsw_usage.self, from: $0) }
        swapUsed = swap?.xsu_used
        swapTotal = swap?.xsu_total
        if let stats = raw.vmStatistics, let pageSize = raw.pageSize, pageSize > 0 {
            func bytes(_ pages: UInt64) -> UInt64? {
                let (product, overflow) = pages.multipliedReportingOverflow(by: pageSize)
                return overflow ? nil : product
            }
            compressed = bytes(UInt64(stats.compressor_page_count))
            wired = bytes(UInt64(stats.wire_count))
            let (appPages, underflow) = UInt64(stats.internal_page_count)
                .subtractingReportingOverflow(UInt64(stats.purgeable_count))
            app = underflow ? nil : bytes(appPages)
        } else {
            compressed = nil
            wired = nil
            app = nil
        }
    }

    /// Reads a sysctl value of exactly this type's size; a value of another size is malformed.
    private static func load<T>(_: T.Type, from bytes: [UInt8]) -> T? {
        guard bytes.count == MemoryLayout<T>.size else { return nil }
        return bytes.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}

/// System memory values as the kernel returns them: sysctl byte buffers and `host_statistics64` counters.
public struct RawSystemMemory: Sendable {
    /// `kern.memorystatus_vm_pressure_level` (an `Int32`).
    public var pressureLevel: [UInt8]?
    /// `vm.swapusage` (an `xsw_usage`).
    public var swapUsage: [UInt8]?
    /// `hw.memsize` (a `UInt64`).
    public var memorySize: [UInt8]?
    /// `host_statistics64(HOST_VM_INFO64)`, counted in pages.
    public var vmStatistics: vm_statistics64?
    public var pageSize: UInt64?

    public init(
        pressureLevel: [UInt8]?,
        swapUsage: [UInt8]?,
        memorySize: [UInt8]?,
        vmStatistics: vm_statistics64?,
        pageSize: UInt64?
    ) {
        self.pressureLevel = pressureLevel
        self.swapUsage = swapUsage
        self.memorySize = memorySize
        self.vmStatistics = vmStatistics
        self.pageSize = pageSize
    }
}

public protocol SystemMemorySource: Sendable {
    func read() -> RawSystemMemory
}

/// Reads this Mac's memory state.
public struct LiveSystemMemorySource: SystemMemorySource {
    public init() {}

    public func read() -> RawSystemMemory {
        RawSystemMemory(
            pressureLevel: Self.sysctl("kern.memorystatus_vm_pressure_level"),
            swapUsage: Self.sysctl("vm.swapusage"),
            memorySize: Self.sysctl("hw.memsize"),
            vmStatistics: Self.vmStatistics(),
            pageSize: Self.pageSize()
        )
    }

    private static func sysctl(_ name: String) -> [UInt8]? {
        var length = 0
        guard sysctlbyname(name, nil, &length, nil, 0) == 0, length > 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: length)
        guard sysctlbyname(name, &bytes, &length, nil, 0) == 0 else { return nil }
        return Array(bytes.prefix(length))
    }

    private static func vmStatistics() -> vm_statistics64? {
        var stats = vm_statistics64()
        // HOST_VM_INFO64_COUNT is a macro Swift does not import.
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(MachHost.port, HOST_VM_INFO64, $0, &count)
            }
        }
        return result == KERN_SUCCESS ? stats : nil
    }

    private static func pageSize() -> UInt64? {
        var size: vm_size_t = 0
        return host_page_size(MachHost.port, &size) == KERN_SUCCESS ? UInt64(size) : nil
    }
}
