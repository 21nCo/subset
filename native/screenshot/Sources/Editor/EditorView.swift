import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditorView: View {
    @ObservedObject var session: EditorSession
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            EditorCanvas(session: session)
                .padding(18)
                .background(Color(nsColor: .underPageBackgroundColor))
            Divider()
            toolBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button(action: session.undo) { Image(systemName: "arrow.uturn.backward") }
                .disabled(!session.canUndo)
                .keyboardShortcut("z", modifiers: .command)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
            Button(action: session.redo) { Image(systemName: "arrow.uturn.forward") }
                .disabled(!session.canRedo)
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
            Divider().frame(height: 20)
            ColorPicker("", selection: $session.selectedColor, supportsOpacity: true).labelsHidden().frame(width: 30)
                .help("Annotation color")
                .accessibilityLabel("Annotation color")
            Slider(value: $session.lineWidth, in: 1...14, step: 1).frame(width: 110)
                .help("Stroke width")
                .accessibilityLabel("Stroke width")
                .accessibilityValue("\(Int(session.lineWidth)) pixels")
            Text("\(Int(session.lineWidth)) px").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            if session.selectedTool == .text {
                TextField("Text", text: $session.textDraft).frame(width: 180)
                    .onSubmit { session.updateSelectedText(session.textDraft) }
                    .accessibilityLabel("Annotation text")
            }
            Spacer()
            Menu("Background") {
                ForEach(BackgroundConfiguration.Style.allCases) { style in
                    Button(style.rawValue.capitalized) { session.background.style = style }
                }
            }
            Button("Save Project", action: saveProject)
                .keyboardShortcut("s", modifiers: .command)
                .help("Save an editable project (⌘S)")
            Button("Copy") { copyRendered() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .help("Copy the annotated image (⇧⌘C)")
            Button("Export", action: exportRendered).buttonStyle(.borderedProminent)
                .keyboardShortcut("e", modifiers: .command)
                .help("Export as PNG or JPEG (⌘E)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private var toolBar: some View {
        HStack(spacing: 6) {
            ForEach(AnnotationTool.allCases) { tool in
                Button {
                    session.selectedTool = tool
                    if tool == .background, session.background.style == .transparent { session.background.style = .gradient }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tool.symbol).font(.system(size: 15, weight: .semibold))
                        Text(tool.rawValue.capitalized).font(.system(size: 8, weight: .medium))
                    }
                    .frame(width: 54, height: 42)
                    .background(session.selectedTool == tool ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .help(tool.rawValue.capitalized)
                .accessibilityLabel(tool.rawValue.capitalized)
                .accessibilityAddTraits(session.selectedTool == tool ? .isSelected : [])
            }
            Spacer()
            Button(role: .destructive, action: session.removeSelected) { Image(systemName: "trash") }
                .buttonStyle(.plain)
                .keyboardShortcut(.delete, modifiers: .command)
                .help("Delete selected annotation (⌘⌫)")
                .accessibilityLabel("Delete selected annotation")
        }
        .padding(.horizontal, 12)
        .frame(height: 60)
        .background(.regularMaterial)
    }

    @MainActor
    private func renderedImage() -> NSImage? {
        // Render at the capture's own size (plus the canvas padding EditorCanvas applies) and at
        // the image's pixel density, so Copy and Export keep every source pixel.
        let base = session.image.size
        let padding = session.background.style == .transparent ? 24 : max(24, session.background.padding)
        let target = CGSize(width: base.width + padding * 2, height: base.height + padding * 2)
        let renderer = ImageRenderer(content: EditorCanvas(session: session, showsSelection: false).frame(width: target.width, height: target.height))
        renderer.scale = max(1, session.image.pixelSize.width / max(1, base.width))
        return renderer.nsImage
    }

    private func exportRendered() {
        guard let image = renderedImage() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png, .jpeg]
        panel.nameFieldStringValue = appState.preferences.formattedFileName() + ".png"
        panel.directoryURL = appState.preferences.exportDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = url.pathExtension.lowercased().hasPrefix("jp") ? "jpg" : "png"
        if let data = try? image.encodedData(format: format, quality: appState.preferences.jpegQuality) { try? data.write(to: url, options: .atomic) }
    }

    private func copyRendered() {
        guard let image = renderedImage() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func saveProject() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(exportedAs: "dev.subset.screenshot.project")]
        panel.nameFieldStringValue = (session.record?.displayName ?? "Screenshot") + ".ssproject"
        guard panel.runModal() == .OK, let url = panel.url,
              let project = try? session.makeProject() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(project) { try? data.write(to: url, options: .atomic) }
    }
}
