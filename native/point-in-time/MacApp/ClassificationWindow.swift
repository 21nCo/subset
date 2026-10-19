import AppKit
import PointInTimeCore
import SwiftUI

/// Classification settings: the provider, what is sent, `Memory.md`, the queue's status, and recent blocks to correct.
@MainActor
final class ClassificationWindowController {
    private var window: NSWindow?
    let model: ClassificationModel

    init(controller: ClassificationController, store: ActivityStore?) {
        model = ClassificationModel(controller: controller, store: store)
    }

    func show() {
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: ClassificationView(model: model)))
            window.title = "pointInTime Classification"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 600, height: 720))
            window.isReleasedWhenClosed = false
            self.window = window
        }
        model.modelField = model.settings.openRouterModel
        model.refresh()
        model.checkProvider()
        NSApp.activate(ignoringOtherApps: true)
        window?.center()
        window?.makeKeyAndOrderFront(nil)
    }
}

@MainActor
final class ClassificationModel: ObservableObject {
    @Published var status = ClassificationStatus()
    @Published var recent: [Block] = []
    @Published var codexState = ""
    @Published var keyField = ""
    /// The OpenRouter model being typed; it is used only once committed, so a partial ID is never sent.
    @Published var modelField = ""
    @Published var keyMessage: String?
    @Published var hasKey = false
    @Published var storeError: String?
    let controller: ClassificationController
    private let store: ActivityStore?

    init(controller: ClassificationController, store: ActivityStore?) {
        self.controller = controller
        self.store = store
    }

    var settings: ClassificationSettings { controller.settings }

    func binding<T>(_ keyPath: ReferenceWritableKeyPath<ClassificationSettings, T>) -> Binding<T> {
        Binding(get: { self.settings[keyPath: keyPath] }, set: { value in
            self.objectWillChange.send()
            self.settings[keyPath: keyPath] = value
            self.checkProvider()
        })
    }

    func refresh() {
        status = controller.status
        hasKey = ((try? KeychainSecret.openRouterKey.read()) ?? nil) != nil
        // Today's completed blocks with recorded time, newest first.
        let now = Date()
        recent = ((try? store?.blocks(from: Calendar.current.startOfDay(for: now), to: now)) ?? [])
            .filter { $0.activeSeconds > 0 && $0.end <= now }.reversed().prefix(30).map { $0 }
    }

    func checkProvider(refresh: Bool = false) {
        guard settings.provider == .codex else { return }
        codexState = "Checking codex…"
        Task {
            guard let codex = await controller.codex(refresh: refresh) else {
                codexState = "codex was not found in the login shell’s PATH. Choose the binary below."
                return
            }
            switch await codex.loginStatus() {
            case .signedIn: codexState = "\(codex.executable.path): signed in with ChatGPT"
            case .notChatGPT: codexState = "Codex is not signed in with ChatGPT (an API key is not used). Sign in with `codex login` using ChatGPT in Terminal, then check again."
            case .signedOut: codexState = "Sign in with `codex login` in Terminal, then check again."
            case .unavailable(let message): codexState = "\(codex.executable.path) could not run: \(message)"
            }
        }
    }

    func chooseCodex() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.message = "Choose your codex binary"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        objectWillChange.send()
        settings.codexPath = url.path
        checkProvider()
    }

    func useLoginShellCodex() {
        objectWillChange.send()
        settings.codexPath = nil
        checkProvider(refresh: true)
    }

    func saveKey() {
        let key = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try KeychainSecret.openRouterKey.save(key)
            keyField = ""
            keyMessage = "Saved in the Keychain."
            controller.settingsChanged(providerChanged: true)
        } catch {
            keyMessage = "Could not save the key: \(error)"
        }
        refresh()
    }

    func removeKey() {
        do {
            try KeychainSecret.openRouterKey.delete()
            keyMessage = "Removed from the Keychain."
            controller.settingsChanged(providerChanged: true)
        } catch {
            keyMessage = "Could not remove the key: \(error)"
        }
        refresh()
    }

    /// Tests the typed key, or the saved one when the field is empty. Sends no activity.
    func testKey() {
        let typed = keyField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let key = typed.isEmpty ? (try? KeychainSecret.openRouterKey.read()) ?? nil : typed else {
            keyMessage = "Enter a key first."
            return
        }
        keyMessage = "Testing…"
        let client = OpenRouterClient(key: key, model: settings.openRouterModel)
        Task {
            do {
                try await client.testKey()
                keyMessage = "OpenRouter accepted the key."
            } catch {
                keyMessage = String(describing: error)
            }
        }
    }

    func commitModel() {
        let typed = modelField.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != settings.openRouterModel else { return }
        objectWillChange.send()
        settings.openRouterModel = typed
    }

    func openMemory() {
        guard let memory = controller.memory, let url = try? memory.ensureExists() else {
            storeError = "Memory.md could not be created in the support folder."
            return
        }
        if !NSWorkspace.shared.open(url), let textEdit = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            NSWorkspace.shared.open([url], withApplicationAt: textEdit, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    /// Asks for an optional note, then stores the correction; the block shows the new label at once.
    func correct(_ block: Block, to label: BlockLabel) {
        guard let store else { return }
        let alert = NSAlert()
        alert.messageText = "Label this block \(label.title)?"
        alert.informativeText = "An optional note helps later blocks like this one."
        let note = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        note.placeholderString = "Note (optional)"
        alert.accessoryView = note
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do {
            try store.correct(blockStart: block.start, to: label, note: note.stringValue, at: Date())
            storeError = nil
        } catch {
            storeError = String(describing: error)
        }
        refresh()
    }
}

extension BlockLabel {
    var title: String { rawValue.capitalized }
}

struct ClassificationView: View {
    @ObservedObject var model: ClassificationModel
    @FocusState private var editingModel: Bool

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Classify blocks with", selection: model.binding(\.provider)) {
                    Text("Off (nothing is sent)").tag(ProviderChoice.off)
                    Text("ChatGPT subscription (Codex CLI)").tag(ProviderChoice.codex)
                    Text("OpenRouter key").tag(ProviderChoice.openRouter)
                }
                switch model.settings.provider {
                case .off:
                    Text("Blocks stay on this Mac, pending, until you choose a provider.").foregroundStyle(.secondary)
                case .codex:
                    Text(verbatim: model.codexState)
                    HStack {
                        Button("Choose codex Binary…") { model.chooseCodex() }
                        if model.settings.codexPath != nil { Button("Use Login Shell PATH") { model.useLoginShellCodex() } }
                        Button("Check Again") { model.checkProvider(refresh: true) }
                    }
                    Text("pointInTime runs your codex binary in an empty private folder and never reads Codex’s credential files.")
                        .font(.caption).foregroundStyle(.secondary)
                case .openRouter:
                    Text(model.hasKey ? "A key is saved in the Keychain." : "No key is saved.")
                    SecureField("OpenRouter API key", text: $model.keyField)
                    HStack {
                        Button("Save Key") { model.saveKey() }.disabled(model.keyField.isEmpty)
                        Button("Test Key") { model.testKey() }
                        if model.hasKey { Button("Remove Key") { model.removeKey() } }
                    }
                    if let message = model.keyMessage { Text(verbatim: message).font(.caption) }
                    Text("The key is kept in your login keychain, never synchronized to iCloud, and never written to a file, a log, or the database. Like other login-keychain items, it moves with Migration Assistant and keychain backups.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Model (default \(OpenRouterClient.defaultModel))", text: $model.modelField)
                        .focused($editingModel)
                        .onSubmit { model.commitModel() }
                        .onChange(of: editingModel) { _, editing in if !editing { model.commitModel() } }
                    Text("Press Return to use the model.").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("What is sent") {
                Toggle("Send window titles", isOn: model.binding(\.sendWindowTitles))
                Text(sentFields).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
            Section("Memory.md") {
                Text("Describe your work in Memory.md to steer the labels. Its first 8 KB is sent with each request.")
                Button("Open Memory.md") { model.openMemory() }
            }
            Section("Status") {
                Text(verbatim: "Pending: \(model.status.pending)\(model.status.failed > 0 ? ", failed: \(model.status.failed)" : "")\(model.status.inFlight ? " (request in progress)" : "")")
                if model.status.failed > 0 { Button("Retry Failed Blocks") { model.controller.retryFailed() } }
                Text(verbatim: "Last success: \(model.status.lastSuccess?.formatted(date: .abbreviated, time: .shortened) ?? "never")")
                if let error = model.status.lastError {
                    Text(verbatim: "Last error (\(model.status.lastErrorAt?.formatted(date: .omitted, time: .shortened) ?? "")): \(error)")
                        .foregroundStyle(.red)
                }
                if let error = model.storeError { Text(verbatim: error).foregroundStyle(.red) }
            }
            Section("Today’s blocks") {
                if model.recent.isEmpty { Text("No completed blocks today.").foregroundStyle(.secondary) }
                ForEach(model.recent, id: \.start) { block in
                    BlockRow(block: block) { model.correct(block, to: $0) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 480)
    }

    private var sentFields: String {
        let title = model.settings.sendWindowTitles ? ", and its window title" : " (window titles are not sent)"
        return """
            Once a provider is chosen, each completed block sends: its start time; the name, bundle ID, and seconds of each \
            app used; and for the app used most, its website host and path\(title). Each request also sends the first 8 KB \
            of Memory.md and your 20 most recent corrections (the same fields for those blocks, the labels, and your note).
            Never sent: excluded apps, blocks whose main app is excluded, anonymous excluded time, URL query strings, and \
            anything from blocks still in progress.
            """
    }
}

/// One block and its label. The reason is shown as plain text, never as markup.
private struct BlockRow: View {
    let block: Block
    let correct: (BlockLabel) -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "\(block.start.formatted(date: .omitted, time: .shortened))  \(block.dominantAppName ?? "")\(block.dominantURL.map { " · \($0.host)" } ?? "")")
                Text(verbatim: summary).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Menu(block.labeling.label?.title ?? "Label") {
                ForEach(BlockLabel.allCases, id: \.self) { label in Button(label.title) { correct(label) } }
            }
            .fixedSize()
        }
    }

    private var summary: String {
        let labeling = block.labeling
        switch labeling.state {
        case .pending: return "Pending"
        case .failed: return "Could not be classified"
        case .corrected: return "Corrected by you" + (labeling.reason.map { ": \($0)" } ?? "")
        case .classified:
            return "\(labeling.reason ?? "") (\(labeling.provider ?? ""), \(Int((labeling.confidence ?? 0) * 100))%)"
        }
    }
}
