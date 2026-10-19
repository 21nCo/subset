import SwiftUI
import SystemCore

/// A plain, temporary process table for the main window. SET-44 replaces it with the origin-grouped view.
struct ProcessTableView: View {
    let monitor: SystemMonitor
    @State private var sortOrder = [KeyPathComparator(\ProcessFacts.cpuSortKey, order: .reverse)]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemorySummaryView(snapshot: monitor.snapshot, memory: monitor.memory, error: monitor.sampleError)
                .padding(12)
            Table(rows, sortOrder: $sortOrder) {
                TableColumn("Process", value: \.name)
                TableColumn("PID", value: \.pid) { Text(String($0.pid)) }
                TableColumn("% CPU", value: \.cpuSortKey) { process in
                    Text(process.cpuPercent.map { String(format: "%.1f", $0) } ?? unavailable(process))
                }
                TableColumn("Memory", value: \.memorySortKey) { process in
                    Text(process.physFootprint.map(Format.bytes) ?? unavailable(process))
                }
                TableColumn("CPU Time", value: \.cpuTimeSortKey) { process in
                    Text(process.totalCPUTime.map { String(format: "%.2f s", Double($0) / 1e9) } ?? unavailable(process))
                }
                TableColumn("Energy Used", value: \.energySortKey) { process in
                    Text(process.billedEnergy.map { String(format: "%.1f J", Double($0) / 1e9) } ?? unavailable(process))
                }
                TableColumn("UID", value: \.uid) { Text(String($0.uid)) }
            }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 360, maxHeight: .infinity)
    }

    private var rows: [ProcessFacts] {
        (monitor.snapshot?.processes ?? []).sorted(using: sortOrder)
    }

    private func unavailable(_ process: ProcessFacts) -> String {
        process.restricted ? "Restricted" : "–"
    }
}

private struct MemorySummaryView: View {
    let snapshot: ProcessSnapshot?
    let memory: SystemMemory?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(StatusSummary(snapshot: snapshot, memory: memory).pressureRow).font(.headline)
            Text(memoryLine)
            Text(swapLine)
            Text(processLine).foregroundStyle(.secondary)
            if let error {
                Text(error).foregroundStyle(.red)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var memoryLine: String {
        "Used \(Format.bytes(memory?.used)) of \(Format.bytes(memory?.physicalMemory)): "
            + "app \(Format.bytes(memory?.app)), wired \(Format.bytes(memory?.wired)), "
            + "compressed \(Format.bytes(memory?.compressed))"
    }

    private var swapLine: String {
        "Swap used \(Format.bytes(memory?.swapUsed)) of \(Format.bytes(memory?.swapTotal))"
    }

    private var processLine: String {
        guard let snapshot else { return "Sampling…" }
        let cpu = StatusSummary(snapshot: snapshot, memory: memory).cpuRow(logicalCoreCount: snapshot.logicalCoreCount)
        let restricted = snapshot.processes.filter(\.restricted).count
        return "\(cpu) · "
            + "\(snapshot.processes.count) processes, \(restricted) restricted by macOS (not counted in CPU)"
    }
}

private enum Format {
    static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }

    static func bytes(_ value: UInt64?) -> String {
        value.map(bytes) ?? "–"
    }
}

/// Non-optional sort keys: unavailable values sort below every measured one.
private extension ProcessFacts {
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memorySortKey: Int64 { physFootprint.map { Int64(clamping: $0) } ?? -1 }
    var cpuTimeSortKey: Int64 { totalCPUTime.map { Int64(clamping: $0) } ?? -1 }
    var energySortKey: Int64 { billedEnergy.map { Int64(clamping: $0) } ?? -1 }
}
