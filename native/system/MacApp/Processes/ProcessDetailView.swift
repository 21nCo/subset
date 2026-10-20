import SwiftUI
import SystemCore
import SystemProcesses

/// The selected group's totals or the selected process's placement: why it is in its group (the rule, a confidence
/// badge, and the evidence), its executable, Team ID, launchd label, and restricted state, and its raw origin signals.
struct ProcessDetailView: View {
    let detail: RowDetail?
    let monitor: SystemMonitor

    var body: some View {
        ScrollView {
            if let detail {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(detail.title).font(.title3.bold()).textSelection(.enabled)
                        Text(detail.subtitle).foregroundStyle(.secondary)
                    }
                    if let placement = detail.placement {
                        PlacementView(placement: placement)
                    }
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                        ForEach(detail.fields, id: \.label) { field in
                            GridRow {
                                Text(field.label).foregroundStyle(.secondary)
                                Text(field.value).textSelection(.enabled)
                            }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(field.label)
                            .accessibilityValue(field.value)
                        }
                    }
                    if detail.path != nil {
                        HStack { RowActions(path: detail.path) }
                    }
                    if let runtime = detail.containerRuntime,
                       let group = monitor.containerVMs.first(where: { $0.runtime.displayName == runtime }) {
                        ContainerVMsView(groups: [group], report: monitor.containerReport)
                    }
                    if let process = detail.process {
                        DisclosureGroup("Origin signals") {
                            OriginSignalsView(process: process)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            } else {
                Text("Select a group or process to see why it is grouped there.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
        .font(.callout)
    }
}

private struct PlacementView: View {
    let placement: PlacementDetail

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(placement.group).font(.headline)
                ConfidenceBadge(confidence: placement.confidence)
            }
            Text(placement.rule)
            ForEach(Array(placement.evidence.enumerated()), id: \.offset) { _, line in
                Label { Text(Self.styled(line)) } icon: { Image(systemName: "checkmark.circle") }
            }
            ForEach(Array(placement.conflicts.enumerated()), id: \.offset) { _, line in
                Label { Text(Self.styled(line)) } icon: { Image(systemName: "exclamationmark.triangle") }
                    .foregroundStyle(.secondary)
            }
        }
        .textSelection(.enabled)
    }

    /// Text between backticks (a bundle, label, or marker name) is shown in a monospaced font. Paths are not read as
    /// Markdown, so an underscore or asterisk in one stays as it is.
    static func styled(_ text: String) -> AttributedString {
        var result = AttributedString()
        for (index, part) in text.split(separator: "`", omittingEmptySubsequences: false).enumerated() {
            var piece = AttributedString(String(part))
            if index.isMultiple(of: 2) == false { piece.font = .callout.monospaced() }
            result += piece
        }
        return result
    }
}

private struct ConfidenceBadge: View {
    let confidence: AttributionConfidence

    var body: some View {
        Text(OriginExplanation.confidence(confidence))
            .font(.caption.bold())
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.2)))
            .foregroundStyle(color)
            .help(OriginExplanation.confidenceMeaning(confidence))
            .accessibilityLabel("Confidence")
            .accessibilityValue("\(OriginExplanation.confidence(confidence)). \(OriginExplanation.confidenceMeaning(confidence))")
    }

    private var color: Color {
        switch confidence {
        case .rule: .green
        case .signal: .blue
        case .fallback: .orange
        }
    }
}
