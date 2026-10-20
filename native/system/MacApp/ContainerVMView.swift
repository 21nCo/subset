import SwiftUI
import SystemCore

/// Each running container runtime's VM: what macOS measures for its processes, and beneath it the containers and
/// compose projects the runtime reports from inside the VM. The two figures are shown side by side and never
/// reconciled. SET-44 places this under the VM's origin group.
struct ContainerVMsView: View {
    let groups: [ContainerVMGroup]
    let report: ContainerReport?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(groups, id: \.runtime) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.runtime.displayName).font(.headline)
                    Text("On this Mac: \(Self.usage(memory: group.totals.memory, cpu: group.totals.cpuPercent)) · "
                        + "\(group.totals.processCount) processes")
                    breakdown(report?.status(of: group.runtime, running: groups.map(\.runtime)) ?? .notMeasured)
                }
            }
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func breakdown(_ status: ContainerBreakdownStatus) -> some View {
        switch status {
        case .notMeasured:
            Text("Containers: not measured yet.").foregroundStyle(.secondary)
        case let .unavailable(reason):
            Text("Containers: no breakdown. \(reason.reason)").foregroundStyle(.secondary)
        case let .otherContext(name, runtime):
            Text("Containers: not listed; the current Docker context “\(name)” reaches \(runtime.displayName).")
                .foregroundStyle(.secondary)
        case let .measured(breakdown):
            DisclosureGroup {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(breakdown.projects, id: \.name) { project in
                        Text("\(project.name) (compose): \(Self.usage(memory: project.totals.memoryUsed, cpu: project.totals.cpuPercent))")
                        ForEach(project.containers, id: \.id) { Text("    " + Self.line($0)) }
                    }
                    ForEach(breakdown.standalone, id: \.id) { Text(Self.line($0)) }
                    if breakdown.skippedLines + breakdown.unreadableValues > 0 {
                        Text("Skipped \(breakdown.skippedLines) unreadable lines and \(breakdown.unreadableValues) unreadable values.")
                            .foregroundStyle(.secondary)
                    }
                }
            } label: {
                Text("Measured inside the VM by docker: \(Self.usage(memory: breakdown.totals.memoryUsed, cpu: breakdown.totals.cpuPercent)) · "
                    + "\(breakdown.totals.containerCount) containers"
                    + (report.map { " at \($0.observedAt.formatted(date: .omitted, time: .standard))" } ?? ""))
            }
        }
    }

    private static func line(_ container: Container) -> String {
        let memory = container.memoryUsed.map(bytes) ?? "–"
        let cpu = container.cpuPercent.map { String(format: "%.1f%%", $0) } ?? "–"
        return "\(container.name): \(memory), \(cpu) CPU"
    }

    private static func usage(memory: MetricTotal<UInt64>, cpu: MetricTotal<Double>) -> String {
        let memoryText = memory.sum.map(bytes) ?? "–"
        let cpuText = cpu.sum.map { String(format: "%.1f%%", $0) } ?? "–"
        let partial = memory.isComplete && cpu.isComplete ? "" : " (some not measured)"
        return "\(memory.isApproximate ? "≈" : "")\(memoryText) memory, \(cpuText) CPU\(partial)"
    }

    private static func bytes(_ value: UInt64) -> String {
        Int64(clamping: value).formatted(.byteCount(style: .memory))
    }
}
