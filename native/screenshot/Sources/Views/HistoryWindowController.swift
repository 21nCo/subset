import AppKit
import SwiftUI

@MainActor
final class HistoryWindowController {
    private let appState: AppState
    private var controller: NSWindowController?

    init(appState: AppState) {
        self.appState = appState
    }

    func show() {
        if let controller {
            controller.showWindow(nil)
            controller.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable, .unifiedTitleAndToolbar], backing: .buffered, defer: false)
        window.title = "Capture History"
        window.center()
        window.minSize = CGSize(width: 720, height: 460)
        window.contentView = NSHostingView(rootView: HistoryView(appState: appState))
        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.controller = controller
    }
}

private struct HistoryView: View {
    @ObservedObject var appState: AppState
    @ObservedObject private var history: HistoryStore
    @State private var search = ""
    @State private var selectedKind: CaptureKind?

    init(appState: AppState) {
        self.appState = appState
        history = appState.history
    }

    private let columns = [GridItem(.adaptive(minimum: 180, maximum: 240), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "clock.arrow.circlepath").font(.title2)
                Text("Capture History").font(.title2.bold())
                Spacer()
                Picker("Type", selection: $selectedKind) {
                    Text("All").tag(CaptureKind?.none)
                    ForEach(CaptureKind.allCases) { Text($0.title).tag(Optional($0)) }
                }.frame(width: 170)
                TextField("Search names and tags", text: $search).textFieldStyle(.roundedBorder).frame(width: 220)
                    .accessibilityLabel("Search captures")
            }
            .padding(18)
            Divider()
            if history.records.isEmpty {
                ContentUnavailableView {
                    Label("No Captures Yet", systemImage: "camera.viewfinder")
                } description: {
                    Text("Screenshots and recordings appear here. Press ⌥S to capture an area or ⌥⇧S to capture a window.")
                } actions: {
                    Button("Capture Area") { appState.captureArea() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                ContentUnavailableView {
                    Label("No Matching Captures", systemImage: "magnifyingglass")
                } description: {
                    Text("Nothing matches the current search or type filter.")
                } actions: {
                    Button("Clear Filters") {
                        search = ""
                        selectedKind = nil
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(filtered) { record in HistoryCard(record: record, appState: appState) }
                    }
                    .padding(18)
                }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var filtered: [CaptureRecord] {
        history.records.filter { record in
            (selectedKind == nil || selectedKind == record.kind) &&
            (search.isEmpty || record.displayName.localizedCaseInsensitiveContains(search) || record.tags.contains(where: { $0.localizedCaseInsensitiveContains(search) }))
        }
    }
}

private struct HistoryCard: View {
    let record: CaptureRecord
    @ObservedObject var appState: AppState
    @State private var hovering = false
    @State private var managingShare = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 11).fill(.black.opacity(0.12))
                if let image = image {
                    Image(nsImage: image).resizable().scaledToFit().padding(4)
                } else {
                    Image(systemName: record.kind == .recording || record.kind == .gif ? "film" : "photo").font(.largeTitle).foregroundStyle(.secondary)
                }
                if hovering {
                    HStack(spacing: 8) {
                        cardButton("pencil", "Annotate") { appState.openEditor(record: record) }
                        if appState.preferences.isCloudConfigured {
                            cardButton("icloud.and.arrow.up", "Upload and copy link") { appState.upload(record: record) }
                        }
                        if record.cloudShareURL != nil { cardButton("slider.horizontal.3", "Manage share") { managingShare = true } }
                        cardButton("pin", "Pin to the screen") { appState.pin(record: record) }
                    }
                    .padding(8)
                    .background(.ultraThickMaterial, in: Capsule())
                }
            }
            .frame(height: 130)
            .onHover { hovering = $0 }
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.displayName).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(record.createdAt, style: .relative).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if record.cloudShareURL != nil { Image(systemName: "cloud.fill").foregroundStyle(.purple) }
                if record.isFavorite { Image(systemName: "star.fill").foregroundStyle(.yellow) }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            Button("Open Annotate") { appState.openEditor(record: record) }
            Button("Copy") { appState.copy(record: record) }
            if appState.preferences.isCloudConfigured {
                Button("Upload and Copy Link") { appState.upload(record: record) }
            }
            if record.cloudShareURL != nil { Button("Manage Share…") { managingShare = true } }
            Button("Pin to the Screen") { appState.pin(record: record) }
            Button(record.isFavorite ? "Remove Favorite" : "Favorite") { appState.history.toggleFavorite(id: record.id) }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([record.fileURL]) }
            Button("Delete", role: .destructive) { appState.history.delete(record) }
        }
        .onTapGesture(count: 2) { appState.openEditor(record: record) }
        .sheet(isPresented: $managingShare) {
            CloudShareManagerView(record: record, appState: appState)
        }
    }

    private var image: NSImage? {
        NSImage(contentsOf: record.fileURL) ?? record.thumbnailURL.flatMap(NSImage.init(contentsOf:))
    }

    private func cardButton(_ symbol: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).frame(width: 24, height: 24) }
            .buttonStyle(.plain)
            .help(label)
            .accessibilityLabel(label)
    }
}

private struct CloudShareManagerView: View {
    let record: CaptureRecord
    @ObservedObject var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var password = ""
    @State private var expires = false
    @State private var expiration = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var tags = ""
    @State private var isWorking = false
    @State private var status: String?
    @State private var confirmDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Label("Manage Share", systemImage: "cloud.fill").font(.title2.bold())
                Spacer()
                Button("Done") { dismiss() }
            }
            if let url = record.cloudShareURL {
                HStack {
                    Text(url.absoluteString).lineLimit(1).foregroundStyle(.secondary)
                    Spacer()
                    Button("Copy Link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Open") { NSWorkspace.shared.open(url) }
                }
            }
            GroupBox("Access") {
                VStack(alignment: .leading, spacing: 12) {
                    SecureField("New password (leave blank for none)", text: $password)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Expire this link", isOn: $expires)
                    if expires { DatePicker("Expiration", selection: $expiration, in: Date()...) }
                }.padding(4)
            }
            GroupBox("Organization") {
                TextField("Tags separated by commas", text: $tags)
                    .textFieldStyle(.roundedBorder).padding(4)
            }
            if let status { Text(status).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Button("Delete Hosted Copy", role: .destructive) { confirmDelete = true }.disabled(isWorking)
                Spacer()
                Button("Save Changes", action: save).buttonStyle(.borderedProminent).disabled(isWorking)
            }
        }
        .padding(24)
        .frame(width: 560)
        .onAppear { tags = record.tags.joined(separator: ", ") }
        .confirmationDialog(
            "Delete this hosted copy? The public link will stop working immediately.",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Hosted Copy", role: .destructive, action: deleteShare)
            Button("Cancel", role: .cancel) {}
        }
    }

    private var parsedTags: [String] {
        tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func save() {
        isWorking = true
        status = nil
        Task {
            do {
                try await appState.updateShare(
                    record: record,
                    password: password.isEmpty ? nil : password,
                    expiresAt: expires ? expiration : nil,
                    tags: parsedTags
                )
                status = "Share settings updated."
            } catch { status = error.localizedDescription }
            isWorking = false
        }
    }

    private func deleteShare() {
        isWorking = true
        status = nil
        Task {
            do {
                try await appState.deleteShare(record: record)
                dismiss()
            } catch {
                status = error.localizedDescription
                isWorking = false
            }
        }
    }
}
