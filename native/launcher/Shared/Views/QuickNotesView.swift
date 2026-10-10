import AppKit
import SwiftUI

struct QuickNotesView: View {
    @ObservedObject var appState: LauncherAppState
    @State private var selection: UUID?
    @State private var search = ""

    private var notes: [QuickNote] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return appState.quickNotes }
        return appState.quickNotes.filter {
            ($0.title ?? "").localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query)
        }
    }

    private var selectedNote: QuickNote? {
        notes.first { $0.id == selection }
    }

    var body: some View {
        NavigationSplitView {
            List(notes, id: \.id, selection: $selection) { note in
                VStack(alignment: .leading, spacing: 3) {
                    Text(note.title ?? "Untitled note").font(.headline).lineLimit(1)
                    Text(note.createdAt, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
                .tag(note.id)
                .contextMenu {
                    Button("Copy Text") { copy(note) }
                    Button("Delete", role: .destructive) { delete(note) }
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: "Search notes")
            .navigationSplitViewColumnWidth(min: 220, ideal: 260)
            .overlay {
                if appState.quickNotes.isEmpty {
                    ContentUnavailableView {
                        Label("No Quick Notes", systemImage: "square.and.pencil")
                    } description: {
                        Text("Press ⌃⌥N anywhere, or type $ and Return in Launcher, to capture a note.")
                    } actions: {
                        Button("New Quick Note") { appState.openLauncher(mode: .quickNote) }
                    }
                } else if notes.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
        } detail: {
            if let note = selectedNote {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(note.title ?? "Untitled note").font(.title2.bold()).textSelection(.enabled)
                        Text(note.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.secondary)
                        Divider()
                        Text(note.body.isEmpty ? "No details." : note.body)
                            .foregroundStyle(note.body.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(24)
                }
                .toolbar {
                    ToolbarItemGroup {
                        Button { copy(note) } label: { Label("Copy Text", systemImage: "doc.on.doc") }
                            .keyboardShortcut("c", modifiers: [.command, .shift])
                            .help("Copy title and details (⇧⌘C)")
                        Button(role: .destructive) { delete(note) } label: { Label("Delete", systemImage: "trash") }
                            .keyboardShortcut(.delete, modifiers: .command)
                            .help("Delete note (⌘⌫)")
                    }
                }
            } else {
                Text(appState.quickNotes.isEmpty ? "" : "Select a note")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear {
            if selection == nil { selection = notes.first?.id }
        }
    }

    private func copy(_ note: QuickNote) {
        let text = [note.title, note.body].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func delete(_ note: QuickNote) {
        // Keep the current selection unless the selected note is the one being deleted.
        let next = note.id == selection ? notes.first { $0.id != note.id }?.id : selection
        appState.deleteQuickNote(note)
        selection = next
    }
}
