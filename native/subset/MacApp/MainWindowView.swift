import AppKit
import SubsetCore
import SwiftUI

/// The main window: every app in the catalog feed with what is installed, its newest live release, its newest beta when
/// Show betas is on, an Update available badge, and Install, Update and Move to Trash buttons with their progress; below
/// it, the Command Line section.
struct MainWindowView: View {
    @ObservedObject var model: AppListModel
    @ObservedObject var actions: AppActions
    let commandLine: CommandLineModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(status: model.status)
            if !actions.notices.isEmpty {
                HStack {
                    Label(actions.notices.joined(separator: "\n"), systemImage: "exclamationmark.triangle").font(.callout).textSelection(.enabled)
                    Spacer()
                    Button("Dismiss") { actions.dismissNotices() }.controlSize(.small)
                }
                .padding(10)
                .background(.yellow.opacity(0.15))
            }
            content
            Divider()
            CommandLineSection(
                model: commandLine, examples: HelperExamples.examples(apps: model.catalog?.apps ?? [], installed: model.installed)
            )
        }
        .frame(minWidth: 560, minHeight: 360)
        .toolbar {
            ToolbarItemGroup {
                Toggle("Show betas", isOn: $model.showBetas)
                Button {
                    Task { await model.refresh(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)
            }
        }
        // Opening the window refreshes too; within 5 minutes of a fetch that uses the cache, and while another refresh
        // runs it is skipped. Unstructured, as Refresh is, so closing the window does not abandon the refresh.
        .onAppear { Task { await model.refresh() } }
        // A running app is quit only after the user agrees. The alert's binding and its buttons each answer the request
        // presented when it was drawn, so reporting one answer twice never dismisses the next question.
        .alert(
            actions.quitRequest?.title ?? "", isPresented: quitBinding(actions.quitRequest),
            presenting: actions.quitRequest
        ) { request in
            Button("Quit \(request.appName)") { actions.confirmQuit(request) }
            Button("Cancel", role: .cancel) { actions.dismissQuit(request) }
        } message: { request in
            Text(request.message)
        }
    }

    /// Whether the alert shows `presented`; dismissing it answers that request only.
    private func quitBinding(_ presented: QuitRequest?) -> Binding<Bool> {
        Binding(get: { actions.quitRequest != nil }, set: { if !$0, let presented { actions.dismissQuit(presented) } })
    }

    @ViewBuilder
    private var content: some View {
        if model.catalog == nil {
            if case .failed = model.status {
                placeholder("The catalog cannot be shown.")
            } else {
                ProgressView("Loading the catalog…").frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if model.rows.isEmpty {
            placeholder("The catalog lists no apps.")
        } else {
            List(model.rows) { row in
                AppRowView(row: row, actions: actions)
            }
        }
    }

    private func placeholder(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The offline warning or the reason the catalog cannot be loaded, above the list.
private struct StatusBanner: View {
    let status: CatalogStatus

    var body: some View {
        switch status {
        case .offline(let warning):
            banner(warning, symbol: "wifi.slash")
        case .failed(let reason):
            banner(reason, symbol: "exclamationmark.triangle")
        case .loading, .current:
            EmptyView()
        }
    }

    private func banner(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(.yellow.opacity(0.15))
    }
}

/// One app: its icon, name and summary, where and which version it is installed, the newest releases, and its buttons.
private struct AppRowView: View {
    let row: AppRow
    @ObservedObject var actions: AppActions

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            icon
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(row.name).font(.headline)
                    if let update = row.update {
                        Text("Update available")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
                            .help("\(update) is available")
                    }
                }
                Text(row.summary).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text(installedText).font(.caption)
                HStack(spacing: 12) {
                    Text("Live: \(row.live ?? "none")")
                    if let beta = row.beta { Text("Beta: \(beta)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                activity
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var buttons: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if actions.canCancel(row.id) {
                Button("Cancel") { actions.cancel(row.id) }
            } else {
                if row.installed.isEmpty {
                    Button("Install") { actions.install(row.id) }
                        .disabled(row.install == nil)
                        .help(row.install.map { "Install \($0)" } ?? "No release to install; a beta is listed when Show betas is on")
                }
                if let update = row.update {
                    Button("Update") { actions.update(row.id) }.help("Update to \(update)")
                }
                if !row.installed.isEmpty {
                    Button("Move to Trash") { actions.moveToTrash(row.id) }
                        .help("Move every installed copy to the Trash; its data stays")
                }
            }
        }
        // After an operation, until its app has been looked for again.
        .disabled(actions.isBusy(row.id) && !actions.canCancel(row.id))
        .controlSize(.small)
    }

    // The running operation's step and progress, or how the last one ended.
    @ViewBuilder
    private var activity: some View {
        switch actions.activities[row.id] {
        case let .working(text, fraction)?:
            HStack(spacing: 6) {
                if let fraction { ProgressView(value: fraction).frame(width: 120) } else { ProgressView().controlSize(.small) }
                Text(text).font(.caption)
            }
        case let .succeeded(text)?:
            message(text, symbol: "checkmark.circle", color: .green)
        case let .failed(text)?:
            message(text, symbol: "exclamationmark.triangle", color: .red)
        case nil:
            EmptyView()
        }
    }

    private func message(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 4) {
            Label(text, systemImage: symbol).font(.caption).foregroundStyle(color).textSelection(.enabled)
            Button { actions.dismiss(row.id) } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless).font(.caption).help("Dismiss")
                .accessibilityLabel("Dismiss message")
        }
    }

    // The installed app's own icon, or a generic one when it is not installed.
    @ViewBuilder
    private var icon: some View {
        if let copy = row.installed.first {
            Image(nsImage: NSWorkspace.shared.icon(forFile: copy.path)).resizable().frame(width: 40, height: 40)
        } else {
            Image(systemName: "app.dashed").font(.system(size: 30)).frame(width: 40, height: 40).foregroundStyle(.secondary)
        }
    }

    private var installedText: String {
        guard !row.installed.isEmpty else { return "Not installed" }
        let copies = row.installed.map { copy in
            let channel = copy.channel.map { " \($0.rawValue)" } ?? ""
            return "\(copy.versionLabel)\(channel) in \(copy.folder)"
        }
        return "Installed: \(copies.joined(separator: ", "))"
    }
}
