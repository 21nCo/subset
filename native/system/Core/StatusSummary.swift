/// What the menu bar item shows: total CPU as a share of the whole machine, and memory pressure.
public struct StatusSummary: Equatable, Sendable {
    public let cpuText: String
    public let pressure: MemoryPressure?

    public init(snapshot: ProcessSnapshot?, memory: SystemMemory?) {
        if let percent = snapshot?.machineCPUPercent {
            // Processes are read one after another, so the sum can slightly exceed the machine's capacity.
            cpuText = "\(Int(min(percent, 100).rounded()))%"
        } else {
            cpuText = "–"
        }
        pressure = memory?.pressure
    }

    public var pressureText: String { pressure?.title ?? "Unknown" }

    /// The status item's title.
    public var title: String { cpuText }

    public var accessibilityLabel: String {
        "\(SystemIdentity.appName): CPU \(cpuText == "–" ? "not measured yet" : cpuText), memory pressure \(pressureText.lowercased())"
    }

    /// The status menu's CPU row, for example "CPU: 23% of 8 cores".
    public func cpuRow(logicalCoreCount: Int?) -> String {
        "CPU: \(cpuText)" + (logicalCoreCount.map { " of \($0) cores" } ?? "")
    }

    /// The status menu's memory pressure row.
    public var pressureRow: String { "Memory pressure: \(pressureText)" }
}
