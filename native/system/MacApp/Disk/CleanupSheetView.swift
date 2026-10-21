import SwiftUI
import SystemCore
import SystemDisk
import SystemProcesses

/// The cleanup confirmation sheet: every path or the command, the expected bytes, the risk, and the rebuild note; then
/// the run and what it did. Its state lives in `CleanupSheet`, and only its confirm button starts a cleanup.
struct CleanupSheetView: View {
    let sheet: CleanupSheet
    let model: DiskWindowModel

    private var format: UsageFormat { model.format }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            Divider()
            switch sheet.phase {
            case .reviewing, .running:
                plan
            case let .finished(result):
                ResultView(result: result, format: format)
            }
            Divider()
            buttons
        }
        .padding(16)
        .frame(minWidth: 620, idealWidth: 680, minHeight: 420, idealHeight: 520)
        .interactiveDismissDisabled(sheet.isRunning)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text("\(sheet.match.risk.title): \(sheet.match.risk.note)")
                .foregroundStyle(sheet.match.risk == .review ? .orange : .secondary)
            Text(sheet.match.rule.explanation)
            Text(sheet.match.rule.rebuild).foregroundStyle(.secondary)
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let name = [sheet.match.rule.name, sheet.match.app?.name ?? sheet.match.identifier].compactMap { $0 }
            .joined(separator: ": ")
        return "Clean up \(name)"
    }

    @ViewBuilder private var plan: some View {
        if sheet.isCommand {
            command
        } else {
            items
        }
        switch sheet.preview {
        case let .success(preview):
            VStack(alignment: .leading, spacing: 2) {
                Text("Expected to free: \(preview.estimate.text(format))").monospacedDigit()
                Text(preview.estimate.note).foregroundStyle(.secondary)
            }
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        case let .failure(error):
            Text(error.text).font(.callout).foregroundStyle(.orange)
        }
    }

    private var command: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("System runs this command, exactly, and nothing else:").font(.callout)
            switch sheet.preview {
            case let .success(preview):
                if case let .command(_, resolution) = preview.action {
                    switch resolution {
                    case let .success(command):
                        Text(command.commandLine)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                        if let real = command.realExecutable {
                            Text("\(command.executable) is a link to \(real).").font(.caption).foregroundStyle(.secondary)
                        }
                        if let endpoint = command.dockerEndpoint {
                            Text("Against the Docker daemon at \(endpoint).").font(.caption).foregroundStyle(.secondary)
                        }
                        Text("It stops after 10 minutes. Its last \(CleanupCommands.outputLineLimit) lines of output "
                            + "are shown when it ends, and are not saved.")
                            .font(.caption).foregroundStyle(.secondary)
                    case let .failure(reason):
                        Text(reason.text).foregroundStyle(.orange)
                    }
                }
            case .failure:
                EmptyView()
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var items: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(sheet.allowsChoosingAll
                     ? "These items are moved to the Trash. Uncheck any you want to keep."
                     : "Check each item to move to the Trash; none is chosen for you.")
                    .font(.callout)
                Spacer()
                if sheet.allowsChoosingAll {
                    Button("Check All") { sheet.chooseAll(true) }.disabled(sheet.isRunning)
                    Button("Uncheck All") { sheet.chooseAll(false) }.disabled(sheet.isRunning)
                }
            }
            List(sheet.match.items, id: \.path) { item in
                ItemToggle(sheet: sheet, item: item, format: format, refusal: refusal(item.path))
            }
            .frame(minHeight: 160)
            .accessibilityLabel("Items to move to the Trash")
            Text("Nothing is deleted: items go to the Trash, which System never empties.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func refusal(_ path: String) -> String? {
        guard case let .success(preview) = sheet.preview else { return nil }
        return preview.refusals[path]
    }

    private var buttons: some View {
        HStack {
            if sheet.isRunning {
                ProgressView().controlSize(.small).accessibilityLabel("Cleaning up")
                Text("Cleaning up…").foregroundStyle(.secondary)
            }
            Spacer()
            switch sheet.phase {
            case .reviewing:
                Button("Cancel") { model.dismissCleanup() }
                    .keyboardShortcut(.cancelAction)
                Button(sheet.confirmTitle, role: .destructive) {
                    if let confirmation = sheet.confirm() { model.perform(confirmation) }
                }
                .disabled(!canConfirm)
            case .running:
                Button("Stop") { model.stopCleanup() }
                    .keyboardShortcut(.cancelAction)
            case .finished:
                Button("Done") { model.dismissCleanup() }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private var canConfirm: Bool {
        if case let .success(preview) = sheet.preview { return preview.canConfirm }
        return false
    }
}

private struct ItemToggle: View {
    let sheet: CleanupSheet
    let item: ReclaimItem
    let format: UsageFormat
    let refusal: String?

    var body: some View {
        Toggle(isOn: Binding(get: { sheet.isChosen(item.path) }, set: { sheet.setChosen(item.path, $0) })) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(format.path(item.path)).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                    if let refusal {
                        Text("Refused: \(refusal)").font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Text(format.diskBytes(item.sizes?.private)).monospacedDigit().foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.checkbox)
        .disabled(sheet.isRunning)
        .accessibilityValue(sheet.isChosen(item.path) ? "Chosen" : "Not chosen")
    }
}

/// What a finished cleanup did: the summary, each item's outcome, and a command's last lines of output.
private struct ResultView: View {
    let result: CleanupResult
    let format: UsageFormat

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(result.summary(format)).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            switch result.outcome {
            case let .trash(items):
                List(items, id: \.path) { item in
                    VStack(alignment: .leading, spacing: 1) {
                        Text(format.path(item.path)).lineLimit(1).truncationMode(.middle)
                        Text(item.status.text).font(.caption).foregroundStyle(item.status.isMoved ? Color.secondary : .orange)
                    }
                    .accessibilityElement(children: .combine)
                }
            case .command:
                if !result.outputLines.isEmpty {
                    ScrollView {
                        Text(result.outputLines.joined(separator: "\n"))
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .accessibilityLabel("Command output")
                }
            case .notConfirmed:
                EmptyView()
            }
        }
    }
}

/// The session's cleanups on the Suggestions tab, newest first.
struct CleanupHistoryView: View {
    let results: [CleanupResult]
    let format: UsageFormat

    var body: some View {
        DisclosureGroup("Cleanups this session (\(results.count))") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(results.reversed()) { result in
                    Text("\(format.time(result.finishedAt)) · \(result.title): \(result.summary(format))")
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

private extension CleanupResult.ItemStatus {
    var isMoved: Bool {
        if case .moved = self { return true }
        return false
    }
}
