import AppKit
import Combine
import SwiftUI
import SystemCore
import SystemDisk

/// The Disk section: the scope picker, Scan and Cancel, progress, the volume header, the unreadable-folder banner, and
/// the Folders, By origin, and Suggestions tabs. Its row actions reveal or copy a path or explain an item; a suggestion's
/// Clean Up opens the confirmation sheet, the only way it changes anything. Its state lives in `DiskWindowModel`.
struct DiskView: View {
    @Bindable var model: DiskWindowModel
    let explain: ExplainCenter
    let openSettings: () -> Void
    /// The row the Explain sheet is open for.
    @State private var explaining: ExplainTarget?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let header = model.volumeHeader {
                VolumeHeaderView(header: header)
            }
            controls
            Text(model.statusText)
                .font(.callout)
                .foregroundStyle(statusIsError ? .red : .secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("Scan status")
                .accessibilityValue(model.statusText)
            if let banner = model.unreadableBanner {
                UnreadableBannerView(banner: banner)
            }
            Picker("Tab", selection: $model.tab) {
                ForEach(DiskTab.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel("Disk view")
            .accessibilityValue(model.tab.title)
            if model.tab == .folders, !model.breadcrumbs.isEmpty {
                folderBar
            }
            if model.tab == .suggestions, !model.cleanupResults.isEmpty {
                CleanupHistoryView(results: model.cleanupResults, format: model.format)
            }
            list
                .sheet(item: $explaining) { target in
                    ExplainSheet(target: target, model: model, explain: explain, openSettings: openSettings) {
                        explaining = nil
                    }
                }
                // A new scan replaces the rows, as it closes the cleanup sheet.
                .onChange(of: model.isScanning) { _, scanning in
                    if scanning { explaining = nil }
                }
            actionBar
        }
        .sheet(item: Binding(get: { model.cleanupSheet }, set: { if $0 == nil { model.dismissCleanup() } })) { sheet in
            CleanupSheetView(sheet: sheet, model: model)
        }
        .padding(12)
        .frame(minWidth: 760, maxWidth: .infinity, minHeight: 520, maxHeight: .infinity)
        // Volumes are read off the main actor, so a stalled network mount cannot hold up the window. A volume renamed
        // while this section was not shown is found again by its UUID.
        .task { await model.refreshVolumes() }
        .onReceive(Self.volumesChanged) { note in
            let renamed = Self.rename(in: note)
            Task { await model.refreshVolumes(renamed: renamed) }
        }
    }

    /// A renamed volume's old and new mount paths, which macOS changes with the name.
    private static func rename(in note: Notification) -> (from: String, to: String)? {
        guard note.name == NSWorkspace.didRenameVolumeNotification,
              let old = note.userInfo?[NSWorkspace.oldVolumeURLUserInfoKey] as? URL,
              let new = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL else { return nil }
        return (old.path, new.path)
    }

    /// Posted when a volume is mounted, unmounted, or renamed, so the scope picker lists the volumes there are now.
    private static let volumesChanged = {
        let center = NSWorkspace.shared.notificationCenter
        return center.publisher(for: NSWorkspace.didMountNotification)
            .merge(with: center.publisher(for: NSWorkspace.didUnmountNotification),
                   center.publisher(for: NSWorkspace.didRenameVolumeNotification))
    }()

    private var statusIsError: Bool {
        if case .failed = model.phase { return true }
        return false
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Scan", selection: $model.scope) {
                ForEach(model.scopes, id: \.self) { scope in
                    Text(scope.title).tag(scope)
                }
            }
            .fixedSize()
            .disabled(model.isScanning)
            .accessibilityLabel("What to scan")
            .accessibilityValue(model.scope.title)
            Button("Choose Folder…", action: chooseFolder)
                .disabled(model.isScanning)
                .help("Scan a folder you choose")
            Spacer()
            if model.isScanning {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Scanning")
                Button("Cancel", action: model.cancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isCancelling)
                    .help("Stop the scan and keep what it read (Esc)")
            } else {
                Button("Scan", action: model.scan)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.isCleaning)
                    .help("Scan \(model.scope.title) (⌘R)")
            }
        }
    }

    private var folderBar: some View {
        HStack(spacing: 4) {
            Button {
                model.goUp()
            } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(.borderless)
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(model.breadcrumbs.count < 2)
            .help("Enclosing folder (⌘↑)")
            .accessibilityLabel("Enclosing folder")
            ForEach(Array(model.breadcrumbs.enumerated()), id: \.element.id) { position, crumb in
                if position > 0 {
                    Image(systemName: "chevron.compact.right")
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                Button(crumb.name) { model.navigate(to: crumb.id) }
                    .buttonStyle(.borderless)
                    .lineLimit(1)
                    .fontWeight(position == model.breadcrumbs.count - 1 ? .semibold : .regular)
                    .accessibilityLabel(crumb.accessibilityLabel)
            }
            Spacer()
            Picker("Sort by", selection: $model.sortKey) {
                ForEach(DiskSortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .fixedSize()
            .accessibilityLabel("Sort by")
            .accessibilityValue(model.sortKey.title)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Folder path")
    }

    private var list: some View {
        ScrollViewReader { proxy in
            rowList
                // Selections the model sets (going up, a breadcrumb, Show more, switching tabs) may be off screen.
                .onChange(of: model.selection, initial: true) { _, selection in
                    if let selection { proxy.scrollTo(selection) }
                }
        }
    }

    private var rowList: some View {
        List(selection: $model.selection) {
            ForEach(model.sections) { section in
                Section {
                    ForEach(section.rows) { row in
                        DiskRowView(row: row, toggle: { model.toggle(row.id) }, open: { model.open(row.id) },
                                    cleanUp: model.canCleanUp(row.id) ? { model.beginCleanup(row.id) } : nil,
                                    explain: model.canExplain(row.id) ? { explaining = target(row.id) } : nil)
                            .tag(Optional(row.id))
                            .id(row.id)
                    }
                } header: {
                    if let title = section.title { Text(title) }
                } footer: {
                    if let note = section.note {
                        Text(note).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .contextMenu(forSelectionType: DiskRowID.self) { ids in
            RowActions(path: ids.first.flatMap(model.path(for:)))
            if let id = ids.first, model.canExplain(id) {
                Button("Explain…") { explaining = target(id) }
            }
        } primaryAction: { ids in
            if let id = ids.first { model.activate(id) }
        }
        .onKeyPress(.rightArrow) {
            model.openSelection()
            return .handled
        }
        .onKeyPress(.return) {
            model.openSelection()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            model.closeSelection()
            return .handled
        }
        .accessibilityLabel("\(model.tab.title) list")
    }

    /// Reveal in Finder and Copy path for the selected row, and Clean Up for a suggestion, also reachable from the
    /// keyboard.
    private var actionBar: some View {
        let path = model.selection.flatMap(model.path(for:))
        let cleanable = model.selection.map(model.canCleanUp) ?? false
        let explainable = model.selection.map(model.canExplain) ?? false
        return HStack {
            Text(path.map(model.format.path) ?? "Select an item to reveal it in Finder or copy its path.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
            Spacer()
            Button("Reveal in Finder") { if let path { RowActions.reveal(path) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(path == nil)
                .help("Reveal the selected item in Finder (⇧⌘R)")
            Button("Copy Path") { if let path { RowActions.copy(path) } }
                .keyboardShortcut("c", modifiers: [.command, .option])
                .disabled(path == nil)
                .help("Copy the selected item's path (⌥⌘C)")
            Button("Explain…") { explaining = model.selection.flatMap(target) }
                .disabled(!explainable)
                .help("Explain what the selected item is and how to remove it")
            if model.tab == .suggestions {
                Button("Clean Up…") { if let selection = model.selection { model.beginCleanup(selection) } }
                    .disabled(!cleanable)
                    .help("Preview and confirm a cleanup of the selected suggestion")
            }
        }
    }

    /// What the Explain sheet needs for a row; `nil` for a row Explain does not offer. Made only when Explain is chosen,
    /// since it builds the row's path.
    private func target(_ id: DiskRowID) -> ExplainTarget? {
        guard let key = model.explainKey(for: id),
              let row = model.sections.lazy.flatMap(\.rows).first(where: { $0.id == id }) else { return nil }
        return ExplainTarget(id: id, key: key, name: row.name)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.message = "Choose a folder to scan. Nothing in it is changed."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.chooseFolder(url.path)
    }
}

/// One row: a disclosure button for a group or match, the name and detail, the badges, the bar, and the sizes; a
/// match adds its explanation, rebuild note, and what a cleanup would free. The row ending a long list is a Show more
/// button.
private struct DiskRowView: View {
    let row: DiskRow
    let toggle: () -> Void
    let open: () -> Void
    /// Opens the cleanup sheet; `nil` when the row offers no cleanup now.
    let cleanUp: (() -> Void)?
    /// Opens the Explain sheet; `nil` when Explain is not offered for the row.
    let explain: (() -> Void)?

    var body: some View {
        if row.isMore {
            moreButton
        } else {
            item
        }
    }

    private var moreButton: some View {
        HStack(spacing: 6) {
            Color.clear.frame(width: 14, height: 1)
            Button(row.name, action: open)
                .buttonStyle(.link)
            Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction(.default, open)
        .accessibilityAction(named: "Show more", open)
    }

    private var item: some View {
        HStack(alignment: .top, spacing: 6) {
            if row.isExpandable {
                Button(action: toggle) {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right").frame(width: 14)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14, height: 1)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if row.isNavigable {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                    }
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                    ForEach(row.badges, id: \.self) { badge in
                        Text(badge.title)
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .background(.quaternary, in: Capsule())
                            .help(badge.explanation)
                    }
                }
                Text(row.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let explanation = row.explanation {
                    Text(explanation).font(.caption).fixedSize(horizontal: false, vertical: true)
                }
                if let rebuild = row.rebuild {
                    Text(rebuild).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                if let yield = row.yield {
                    Text(yield).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let fraction = row.fraction {
                SizeBar(fraction: fraction)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(row.size).monospacedDigit()
                if let privateSize = row.privateSize {
                    Text(privateSize).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            .frame(width: 120, alignment: .trailing)
        }
        .padding(.leading, CGFloat(row.depth) * 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityValue(row.accessibilityValue)
        .accessibilityHint([row.explanation, row.rebuild, row.yield].compactMap { $0 }.joined(separator: " "))
        .accessibilityActions {
            if row.isExpandable {
                Button(row.isExpanded ? "Collapse" : "Expand", action: toggle)
            }
            if row.isNavigable {
                Button("Open folder", action: open)
            }
            if let cleanUp {
                Button("Clean up…", action: cleanUp)
            }
            if let explain {
                Button("Explain…", action: explain)
            }
            if let path = row.path {
                Button("Reveal in Finder") { RowActions.reveal(path) }
                Button("Copy path") { RowActions.copy(path) }
            }
        }
    }
}

/// A row Explain was chosen for.
private struct ExplainTarget: Identifiable {
    let id: DiskRowID
    let key: ExplainKey
    let name: String
}

/// Explain for a scanned item, leftover, or suggestion, started when the sheet opens.
private struct ExplainSheet: View {
    let target: ExplainTarget
    let model: DiskWindowModel
    let explain: ExplainCenter
    let openSettings: () -> Void
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(target.name).font(.title3.bold()).lineLimit(2)
            ScrollView {
                ExplainPanel(center: explain, key: target.key,
                             request: { [model, id = target.id, key = target.key] in
                                 model.explainRequest(for: id, key: key, redactor: $0)
                             },
                             openSettings: openSettings, startsAtOnce: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done", action: done).keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520, height: 460)
    }
}

/// A row's share of its folder or section, as a bar; the size beside it is what is spoken.
private struct SizeBar: View {
    static let width: CGFloat = 90
    let fraction: Double

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(.quaternary)
            Capsule().fill(.tint).frame(width: max(2, Self.width * fraction))
        }
        .frame(width: Self.width, height: 6)
        .padding(.top, 6)
        .accessibilityHidden(true)
    }
}

private struct VolumeHeaderView: View {
    let header: DiskVolumeHeader

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(header.title).font(.headline)
            Text("Capacity \(header.capacity) · \(header.availableForImportantUse) available for important use · "
                + "\(header.purgeable) purgeable")
            Text(header.snapshots).foregroundStyle(.secondary)
        }
        .font(.callout)
        .textSelection(.enabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(header.accessibilityLabel)
    }
}

private struct UnreadableBannerView: View {
    let banner: DiskUnreadableBanner

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lock.trianglebadge.exclamationmark")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(banner.message).fixedSize(horizontal: false, vertical: true)
                Text(banner.examples.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(banner.accessibilityLabel)
            Spacer()
            Button("Open Full Disk Access settings") {
                NSWorkspace.shared.open(DiskUnreadableBanner.fullDiskAccessSettings)
            }
        }
        .font(.callout)
        .padding(10)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
