import AppKit
import SwiftUI
import SystemCore
import SystemProcesses

/// The System window: the header, the layer, sort, and filter controls, the outline of origin groups and their
/// processes, the selected row's detail, and the footnote. Its state lives in `ProcessesWindowModel`.
struct ProcessesView: View {
    @Bindable var model: ProcessesWindowModel
    let monitor: SystemMonitor
    let explain: ExplainCenter
    let openSettings: () -> Void
    @FocusState private var filterFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Re-evaluated every second, so the header says when the figures stop being current.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                HeaderView(header: model.header(now: context.date))
            }
            .padding(12)
            controls
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            HSplitView {
                outline
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
                ProcessDetailView(detail: model.detail, monitor: monitor, model: model, explain: explain,
                                  openSettings: openSettings)
                    .frame(minWidth: 280, idealWidth: 340, maxWidth: .infinity, maxHeight: .infinity)
            }
            if let footnote = model.footnote {
                Text(footnote)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
            }
        }
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Layer", selection: $model.layer) {
                ForEach(AttributionLayer.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("Group by app, vendor, launch source, or project (⌘1–⌘4)")
            .accessibilityLabel("Group by")
            .accessibilityValue(model.layer.title)
            Picker("Sort by", selection: $model.sortKey) {
                ForEach(UsageSortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .accessibilityLabel("Sort by")
            .accessibilityValue(model.sortKey.title)
            Spacer()
            TextField("Filter by name", text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 220)
                .focused($filterFocused)
                .help("Filter groups and processes by name (⌘F)")
                .accessibilityLabel("Filter by name")
                .accessibilityValue(model.filter.isEmpty ? "No filter" : model.filter)
        }
        // `initial`: ⌘F from the Disk section asks before this view exists. Focus is set on the next turn, once the
        // field is in the window.
        .onChange(of: model.isFilterFocusPending, initial: true) { _, pending in
            guard pending else { return }
            Task { @MainActor in
                filterFocused = true
                model.didFocusFilter()
            }
        }
    }

    private var outline: some View {
        VStack(spacing: 0) {
            ColumnHeader(sortKey: $model.sortKey)
            ScrollViewReader { proxy in
                List(selection: $model.selection) {
                    ForEach(model.rows) { row in
                        ProcessRowView(row: row) { if case let .group(id) = row.id { model.toggle(id) } }
                            .tag(Optional(row.id))
                            .id(row.id)
                            .contextMenu { RowActions(path: model.path(for: row.id)) }
                    }
                }
                .onKeyPress(.rightArrow) {
                    model.expandSelection()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    model.collapseSelection()
                    return .handled
                }
                // Initially too, so a window opened on a menu-bar group shows it.
                .onChange(of: model.selection, initial: true) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
                .overlay {
                    if model.rows.isEmpty {
                        Text(model.sample == nil ? "Waiting for the first sample…" : "No group or process matches the filter.")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Groups in the \(model.layer.title) layer")
            }
        }
    }
}

/// The column titles above the outline. Clicking CPU, Memory, or Energy sorts by it.
private struct ColumnHeader: View {
    @Binding var sortKey: UsageSortKey

    var body: some View {
        HStack(spacing: 0) {
            Text("Name").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            ForEach(UsageSortKey.allCases, id: \.self) { key in
                Button {
                    sortKey = key
                } label: {
                    Text(key.title + (key == sortKey ? " ▾" : ""))
                        .fontWeight(key == sortKey ? .semibold : .regular)
                        .frame(width: ProcessRowView.columnWidth, alignment: .trailing)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Sort by \(key.title)")
                .accessibilityValue(key == sortKey ? "Sorted, largest first" : "Not sorted")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
    }
}

/// One outline row: a disclosure button for a group, the name and count, and the three figures.
private struct ProcessRowView: View {
    static let columnWidth: CGFloat = 84
    let row: ProcessRow
    let toggle: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if row.isExpandable {
                Button(action: toggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Text(row.detail).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Group {
                Text(row.cpu)
                Text(row.memory)
                Text(row.energy)
            }
            .monospacedDigit()
            .frame(width: Self.columnWidth, alignment: .trailing)
        }
        .padding(.leading, CGFloat(row.depth) * 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityActions {
            if row.isExpandable {
                Button(row.isExpanded ? "Collapse" : "Expand", action: toggle)
            }
        }
    }
}

/// Reveal in Finder and Copy path: the only row actions, in Processes and Disk alike. Nothing here quits or signals a
/// process, or changes a file.
struct RowActions: View {
    let path: String?

    var body: some View {
        if let path {
            Button("Reveal in Finder") { Self.reveal(path) }
                .accessibilityLabel("Reveal \(path) in Finder")
            Button("Copy path") { Self.copy(path) }
                .accessibilityLabel("Copy path \(path)")
        } else {
            Text("No file to reveal")
        }
    }

    static func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    static func copy(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }
}

private struct HeaderView: View {
    let header: WindowHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: header.pressureSymbol)
                    .foregroundStyle(pressureColor)
                    .accessibilityHidden(true)
                Text(header.pressureText).font(.headline)
                Spacer()
                Text(header.stateText)
                    .foregroundStyle(stateColor)
                    .accessibilityLabel("Sampling")
                    .accessibilityValue(header.stateText)
            }
            Text("\(header.memoryText) · \(header.swapText)")
            Text("\(header.cpuText) · \(header.processText) · \(header.observedText)")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .textSelection(.enabled)
    }

    private var pressureColor: Color {
        switch header.pressure {
        case .critical: .red
        case .warning: .yellow
        case .normal, nil: .secondary
        }
    }

    private var stateColor: Color {
        switch header.state {
        case .failed: .red
        case .stale: .orange
        case .waiting, .live: .secondary
        }
    }
}
