import SwiftUI
import SystemCore

/// A process's raw origin signals, each with the interface that supplied it or the reason it is missing, under the
/// detail pane's explanation of its placement.
struct OriginSignalsView: View {
    let process: ProcessFacts

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
            ForEach(rows(process), id: \.label) { row in
                GridRow {
                    Text(row.label).foregroundStyle(.secondary)
                    Text(row.value)
                    Text(row.source).foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(row.label)
                .accessibilityValue(row.source.isEmpty ? row.value : "\(row.value), from \(row.source)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
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
