import AppKit
import SubsetCore
import SwiftUI

/// The main window: every app in the catalog feed with what is installed, its newest live release, its newest beta when
/// Show betas is on, and an Update available badge. Installing and updating are SET-247.
struct MainWindowView: View {
    @ObservedObject var model: AppListModel

    var body: some View {
        VStack(spacing: 0) {
            StatusBanner(status: model.status)
            content
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
        // Opening the window refreshes too; within 5 minutes of a fetch that uses the cache. Unstructured, as Refresh is,
        // so closing the window does not cancel a fetch that another refresh may be waiting on.
        .onAppear { Task { await model.refresh() } }
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
                AppRowView(row: row)
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

/// One app: its icon, name and summary, where and which version it is installed, and the newest releases.
private struct AppRowView: View {
    let row: AppRow

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
            }
        }
        .padding(.vertical, 4)
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
