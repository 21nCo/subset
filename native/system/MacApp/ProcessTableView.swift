import SwiftUI
import SystemCore

/// A plain, temporary process table for the main window. SET-44 replaces it with the origin-grouped view.
struct ProcessTableView: View {
    let monitor: SystemMonitor
    @State private var sortOrder = [KeyPathComparator(\ProcessFacts.cpuSortKey, order: .reverse)]
    @State private var selection: ProcessIdentity?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            MemorySummaryView(snapshot: monitor.snapshot, memory: monitor.memory, error: monitor.sampleError)
                .padding(12)
            if !monitor.containerVMs.isEmpty {
                ContainerVMsView(groups: monitor.containerVMs, report: monitor.containerReport)
                    .padding([.horizontal, .bottom], 12)
            }
            VSplitView {
                Table(rows, selection: $selection, sortOrder: $sortOrder) {
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
                        Text(process.energy.map { String(format: "%.1f J", Double($0) / 1e9) } ?? unavailable(process))
                    }
                    TableColumn("UID", value: \.uid) { Text(String($0.uid)) }
                }
                .frame(minHeight: 200)
                OriginSignalsView(process: monitor.snapshot?.processes.first { $0.identity == selection })
                    .frame(minHeight: 120, idealHeight: 180)
            }
        }
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 480, maxHeight: .infinity)
    }

    /// Rows without a value in the sorted column come last in either direction.
    private var rows: [ProcessFacts] {
        let sorted = (monitor.snapshot?.processes ?? []).sorted(using: sortOrder)
        guard let key = sortOrder.first?.keyPath else { return sorted }
        return sorted.filter { $0.hasValue(for: key) } + sorted.filter { !$0.hasValue(for: key) }
    }

    private func unavailable(_ process: ProcessFacts) -> String {
        process.restricted ? "Restricted" : "–"
    }
}

/// The selected process's raw origin signals, each with the interface that supplied it or the reason it is missing.
/// SET-42 turns them into origins; this view only shows them.
private struct OriginSignalsView: View {
    let process: ProcessFacts?

    var body: some View {
        ScrollView {
            if let process {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("\(process.name) (\(String(process.pid)))").font(.headline).gridCellColumns(3)
                    }
                    GridRow {
                        Text("Executable").foregroundStyle(.secondary)
                        Text(process.executablePath ?? "–").gridCellColumns(2)
                    }
                    ForEach(rows(process), id: \.label) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary)
                            Text(row.value)
                            Text(row.source).foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Select a process to see its origin signals.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.callout)
        .textSelection(.enabled)
        .padding(12)
    }

    private func rows(_ process: ProcessFacts) -> [(label: String, value: String, source: String)] {
        guard let origin = process.origin else { return [("Origin signals", "Not read yet", "")] }
        return [
            row("Responsible process", origin.responsibleProcess) { String($0) },
            row("Coalition", origin.coalition) { String($0) },
            row("Code signature", origin.codeSignature) { signature in
                guard let signingID = signature.signingID else { return "Unsigned" }
                let team = signature.teamID.map { "team \($0)" } ?? "no team"
                return "\(signingID), \(team)\(signature.isPlatformBinary ? ", Apple platform binary" : "")"
            },
            row("launchd jobs", origin.launchdJobs) { found in
                let jobs = found.jobs.isEmpty ? "None" : found.jobs.map { "\($0.label) (\($0.plistPath))" }.joined(separator: "\n")
                guard !found.isComplete else { return jobs }
                let failures = found.scanFailures.map { "\($0.path) (\($0.reason))" }.joined(separator: ", ")
                return jobs + "\nNot every plist or program could be read: " + failures
            },
            (label: "launchd match", value: process.launchdMatch.map(describe) ?? "–", source: ""),
            row("Working directory", origin.workingDirectory) { $0 },
            row("Terminal", origin.terminal) { terminal in
                switch terminal {
                case .none: "None"
                case let .device(name): name
                }
            }
        ]
    }

    private func describe(_ match: LaunchdMatch) -> String {
        switch match {
        case .none: "None"
        case let .job(label): label
        case .executableOnly(.sharedExecutable): "Executable only: a shared or unverified executable"
        case .executableOnly(.notStartedByLaunchd): "Executable only: not started by launchd"
        case .executableOnly(.conflictingLabels): "Executable only: plists disagree on the label"
        case .executableOnly(.incompleteScan): "Executable only: an unread plist or program may name it too"
        }
    }

    private func row<Value>(_ label: String, _ signal: Signal<Value>, _ format: (Value) -> String)
        -> (label: String, value: String, source: String) {
        switch signal {
        case let .value(value, source): (label, format(value), source.rawValue)
        case let .unavailable(failure, source): (label, "Unavailable: \(failure.reason)", source.rawValue)
        }
    }
}

private struct MemorySummaryView: View {
    let snapshot: ProcessSnapshot?
    let memory: SystemMemory?
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(summary.pressureRow).font(.headline)
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

    private var summary: StatusSummary {
        StatusSummary(snapshot: snapshot, memory: memory, samplingFailed: error != nil)
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
        let cpu = summary.cpuRow(logicalCoreCount: snapshot.logicalCoreCount)
        let restricted = snapshot.processes.filter(\.restricted).count
        return "\(cpu) · \(snapshot.processes.count) processes, \(restricted) restricted by macOS"
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

/// Non-optional sort keys: unavailable values sort below every measured one, and `rows` moves them last.
private extension ProcessFacts {
    var cpuSortKey: Double { cpuPercent ?? -1 }
    var memorySortKey: Int64 { physFootprint.map { Int64(clamping: $0) } ?? -1 }
    var cpuTimeSortKey: Int64 { totalCPUTime.map { Int64(clamping: $0) } ?? -1 }
    var energySortKey: Int64 { energy.map { Int64(clamping: $0) } ?? -1 }

    func hasValue(for sortKey: PartialKeyPath<ProcessFacts>) -> Bool {
        switch sortKey {
        case \ProcessFacts.cpuSortKey: cpuPercent != nil
        case \ProcessFacts.memorySortKey: physFootprint != nil
        case \ProcessFacts.cpuTimeSortKey: totalCPUTime != nil
        case \ProcessFacts.energySortKey: energy != nil
        default: true
        }
    }
}
