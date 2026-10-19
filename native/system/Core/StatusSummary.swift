/// What the menu bar item shows: the whole machine's CPU use, and memory pressure.
public struct StatusSummary: Equatable, Sendable {
    /// The machine's CPU share (0–100), or `nil` when it is not measured yet, unavailable, or sampling is failing.
    public let cpuPercent: Double?
    public let pressure: MemoryPressure?
    /// The latest sample failed, so the previous CPU figure is not current.
    public let samplingFailed: Bool
    /// Fewer than two samples have succeeded, so a missing CPU figure is still to come rather than unavailable.
    public let cpuNotMeasuredYet: Bool

    /// Pass `samplingFailed` while the latest sample failed: the menu bar then shows CPU as unavailable instead of
    /// the last successful sample's figure.
    public init(snapshot: ProcessSnapshot?, memory: SystemMemory?, samplingFailed: Bool = false) {
        cpuPercent = samplingFailed ? nil : snapshot?.machineCPUPercent
        pressure = memory?.pressure
        self.samplingFailed = samplingFailed
        cpuNotMeasuredYet = snapshot?.isFirstSample ?? true
    }

    public var cpuText: String { cpuPercent.map { "\(Int($0.rounded()))%" } ?? "–" }

    public var pressureText: String { pressure?.title ?? "Unknown" }

    /// The status item's title.
    public var title: String { cpuText }

    public var accessibilityLabel: String {
        "\(SystemIdentity.appName): CPU \(cpuDescription), memory pressure \(pressureText.lowercased())"
    }

    /// The status menu's CPU row, for example "CPU: 23% of 8 cores".
    public func cpuRow(logicalCoreCount: Int?) -> String {
        guard cpuPercent != nil else { return "CPU: \(cpuDescription)" }
        return "CPU: \(cpuText)" + (logicalCoreCount.map { " of \($0) cores" } ?? "")
    }

    /// The status item's SF Symbol for memory pressure. The gauge needle rises with the level, so warning and
    /// critical differ by shape and not only by the color the menu bar adds.
    public var pressureSymbolName: String {
        switch pressure {
        case .normal: "gauge.with.dots.needle.33percent"
        case .warning: "gauge.with.dots.needle.67percent"
        case .critical: "gauge.with.dots.needle.100percent"
        case nil: "questionmark.circle"
        }
    }

    /// The status menu's memory pressure row.
    public var pressureRow: String { "Memory pressure: \(pressureText)" }

    private var cpuDescription: String {
        if cpuPercent != nil { return cpuText }
        if samplingFailed { return "unavailable, sampling failed" }
        return cpuNotMeasuredYet ? "not measured yet" : "unavailable"
    }
}
