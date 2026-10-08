import PDFKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var store: PDFDocumentStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [
                        Color(red: 0.94, green: 0.97, blue: 1.0),
                        Color(red: 0.86, green: 0.91, blue: 0.98)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Group {
                    if let document = store.document {
                        loadedDocumentView(document: document)
                    } else {
                        emptyStateView
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.hidden, for: .navigationBar)
        }
        .fileImporter(
            isPresented: $store.isImporterPresented,
            allowedContentTypes: [.pdf]
        ) { result in
            store.importDocument(from: result)
        }
        .fileExporter(
            isPresented: $store.isExporterPresented,
            document: store.exportFile,
            contentType: .pdf,
            defaultFilename: store.suggestedExportName
        ) { result in
            store.finishExport(result: result)
        }
        .sheet(isPresented: $store.isOutlinePresented) {
            OutlineSheet(store: store)
        }
        .sheet(item: $store.pendingAnnotationInput) { pendingInput in
            AnnotationInputSheet(store: store, pendingInput: pendingInput)
                .presentationDetents([.medium])
        }
        .sheet(item: $store.presentedNotePreview) { notePreview in
            NotePreviewSheet(notePreview: notePreview)
                .presentationDetents([.fraction(0.3), .medium])
        }
        .confirmationDialog(
            "Discard annotations that have not been exported?",
            isPresented: Binding(
                get: { store.pendingDiscard != nil },
                set: { if !$0 { store.pendingDiscard = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Discard Changes", role: .destructive) { store.confirmDiscard() }
            Button("Export First…") {
                store.pendingDiscard = nil
                store.prepareExport()
            }
            Button("Cancel", role: .cancel) { store.pendingDiscard = nil }
        } message: {
            Text("Your original PDF is unchanged. Annotations exist only in this session until you export a copy.")
        }
        .confirmationDialog(
            "Remove all \(store.totalAnnotationCount) annotations?",
            isPresented: $store.isClearAllConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Remove All", role: .destructive) { store.removeAllAnnotations() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This includes annotations the PDF already had when you opened it. You can undo this.")
        }
        .alert(
            "Annotate",
            isPresented: Binding(
                get: { store.errorMessage != nil },
                set: { _ in store.errorMessage = nil }
            ),
            actions: {
                Button("OK", role: .cancel) {
                    store.errorMessage = nil
                }
            },
            message: {
                Text(store.errorMessage ?? "")
            }
        )
        .onChange(of: store.pendingExternalURL) { _, newValue in
            guard let newValue else {
                return
            }

            openURL(newValue)
            DispatchQueue.main.async {
                store.pendingExternalURL = nil
            }
        }
    }

    @ViewBuilder
    private func loadedDocumentView(document: PDFDocument) -> some View {
        ZStack {
            PDFAnnotatorView(
                document: document,
                selectedTool: store.selectedTool,
                linkPlacementMode: store.isLinkPlacementMode,
                shapeDraft: store.pendingShapeDraft,
                inkColor: store.drawingUIColor,
                lineWidth: store.strokeWidth,
                shapeSize: store.shapeSize,
                navigationRequest: store.navigationRequest,
                annotationRefreshID: store.annotationRefreshID,
                selectionClearRequestID: store.selectionClearRequestID,
                zoomRequest: store.zoomRequest,
                onPageTap: store.handleTap(on:at:),
                onAnnotationTap: { _ = store.handleAnnotationActivation($0) },
                onAnnotationTapAtPoint: store.handleAnnotationActivation(on:at:),
                onShapeDraftMoved: store.updatePendingShapeLocation(on:at:),
                onTextSelectionChanged: store.updateTextSelection(_:),
                onTextSelectionAnchorChanged: store.updateInlineSelectionViewRect(_:),
                onZoomScaleChanged: store.updateZoomScale(_:),
                onInkStrokeCommitted: store.commitInkStroke(on:pagePoints:),
                onCurrentPageChanged: store.updateCurrentPage(index:)
            )
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.65), lineWidth: 1)
            }
            .overlay {
                if store.shouldShowFloatingTextSelectionBar {
                    FloatingInlineSelectionBar(store: store)
                }
            }
            .shadow(color: Color.black.opacity(0.12), radius: 24, y: 14)
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .overlay(alignment: .topLeading) {
                LoadedTopBar(store: store)
                    .padding(.top, 16)
                    .padding(.leading, 18)
            }
            .overlay(alignment: .topTrailing) {
                ZoomControlPanel(store: store)
                    .padding(.top, 16)
                    .padding(.trailing, 18)
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: 10) {
                    if store.shouldShowElementInlineSelectionBar {
                        InlineSelectionBar(store: store)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }

                    AnnotationControlsView(store: store)
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.84), value: store.shouldShowInlineSelectionBar)
        }
    }

    private var emptyStateView: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 52)

            VStack(spacing: 22) {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.16, green: 0.48, blue: 0.95),
                                Color(red: 0.31, green: 0.76, blue: 0.96)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 82, height: 82)
                    .overlay {
                        Image(systemName: "doc.text.viewfinder")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                    }

                VStack(spacing: 10) {
                    Text("Annotate")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(Color(red: 0.14, green: 0.18, blue: 0.27))

                    Text("Open a PDF and start annotating.")
                        .font(.title3.weight(.medium))
                        .foregroundStyle(Color(red: 0.38, green: 0.45, blue: 0.58))
                }
                .multilineTextAlignment(.center)

                HStack(spacing: 10) {
                    MinimalBadge(title: "Highlight")
                    MinimalBadge(title: "Notes")
                    MinimalBadge(title: "Export")
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 24)

            Button {
                store.isImporterPresented = true
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "folder.badge.plus")
                        .font(.headline.weight(.semibold))

                    Text("Open PDF")
                        .font(.headline.weight(.semibold))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .foregroundStyle(.white)
                .background(
                    LinearGradient(
                        colors: [
                            Color(red: 0.09, green: 0.50, blue: 0.96),
                            Color(red: 0.28, green: 0.76, blue: 0.97)
                        ],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 24, style: .continuous)
                )
                .shadow(color: Color.blue.opacity(0.24), radius: 16, y: 10)
            }
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityHint("Choose a PDF from Files")
            .padding(.horizontal, 24)

            Text("PDF files only. Your original file is never changed; Export saves an annotated copy where you choose.")
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Color(red: 0.46, green: 0.52, blue: 0.62))

            Spacer()
        }
    }
}

private struct NotePreviewSheet: View {
    let notePreview: NotePreview
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.black.opacity(0.08))
                            .frame(width: 40, height: 40)
                            .overlay {
                                Text(String(notePreview.author.prefix(1)).uppercased())
                                    .font(.headline.weight(.bold))
                                    .foregroundStyle(.primary)
                            }

                        VStack(alignment: .leading, spacing: 2) {
                            Text(notePreview.author)
                                .font(.headline.weight(.semibold))

                            Text([notePreview.timestamp, notePreview.pageLabel].filter { !$0.isEmpty }.joined(separator: " • "))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Text(notePreview.message)
                        .font(.body)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(Color.white.opacity(0.82), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 18, style: .continuous)
                                .stroke(Color.black.opacity(0.08), lineWidth: 1)
                        }
                }
                .padding(20)
            }
            .navigationTitle("Comment")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }
}

private struct ZoomControlPanel: View {
    @ObservedObject var store: PDFDocumentStore

    var body: some View {
        HStack(spacing: 8) {
            ZoomButton(systemImage: "minus") {
                store.requestZoomOut()
            }

            Text(store.zoomScaleLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .frame(minWidth: 52)

            ZoomButton(systemImage: "plus") {
                store.requestZoomIn()
            }

            Button("Fit") {
                store.requestZoomToFit()
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Color.blue.opacity(0.92))
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.82), in: Capsule())
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)
    }
}

private struct ZoomButton: View {
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.blue.opacity(0.92))
                .frame(width: 28, height: 28)
                .background(Color.white.opacity(0.82), in: Circle())
        }
        .buttonStyle(.plain)
    }
}

private struct AnnotationControlsView: View {
    @ObservedObject var store: PDFDocumentStore

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                UtilityIconButton(systemImage: "list.bullet.rectangle", label: "Contents") {
                    store.isOutlinePresented = true
                }

                UtilityIconButton(systemImage: "folder.badge.plus", label: "Open Another PDF (⌘O)") {
                    store.requestOpenAnother()
                }
                .keyboardShortcut("o", modifiers: .command)

                UtilityIconButton(systemImage: "square.and.arrow.up", label: "Export Annotated Copy (⇧⌘S)") {
                    store.prepareExport()
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])

                Spacer()

                if let selectedTool = store.selectedTool {
                    UtilityIconButton(systemImage: "xmark", label: "Stop \(selectedTool.title) (Esc)") {
                        if store.pendingShapeDraft != nil {
                            store.cancelPendingShape()
                        } else {
                            store.toggleTool(selectedTool)
                        }
                    }
                    .keyboardShortcut(.cancelAction)
                }

                UtilityIconButton(systemImage: "arrow.uturn.backward", label: "Undo (⌘Z)") {
                    store.undoLastChange()
                }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!store.canUndo)
                .opacity(store.canUndo ? 1 : 0.45)

                UtilityIconButton(systemImage: "trash", label: "Remove All Annotations…") {
                    store.isClearAllConfirmationPresented = true
                }
                .disabled(store.totalAnnotationCount == 0)
                .opacity(store.totalAnnotationCount == 0 ? 0.45 : 1)
            }

            if let instruction = store.activeToolInstruction {
                Text(instruction)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(Color(red: 0.18, green: 0.28, blue: 0.42))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white.opacity(0.86), in: Capsule())
            }

            if store.shouldShowShapeSaveButton {
                Button {
                    store.savePendingShape()
                } label: {
                    Label("Save Shape", systemImage: "checkmark.circle.fill")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .foregroundStyle(.white)
                        .background(
                            LinearGradient(
                                colors: [Color.blue, Color.cyan],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(visibleTools) { tool in
                        ToolIconButton(
                            tool: tool,
                            isSelected: store.isToolSelected(tool),
                            isEnabled: store.isToolEnabled(tool)
                        ) {
                            store.toggleTool(tool)
                        }
                    }
                }
                .padding(.vertical, 2)
            }

            if supportsStroke(for: store.selectedTool) || supportsShapeSize(for: store.selectedTool) || supportsColor {
                VStack(alignment: .leading, spacing: 8) {
                    if supportsStroke(for: store.selectedTool) {
                        HStack(spacing: 10) {
                            Image(systemName: "scribble.variable")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Slider(value: $store.strokeWidth, in: 2...12, step: 1)

                            Text("\(Int(store.strokeWidth))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 24)
                        }
                    }

                    if supportsShapeSize(for: store.selectedTool) {
                        HStack(spacing: 10) {
                            Image(systemName: "aspectratio")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Slider(value: $store.shapeSize, in: 60...220, step: 10)

                            Text("\(Int(store.shapeSize))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 32)
                        }
                    }

                    if supportsColor {
                        if let activeColorSectionTitle = store.activeColorSectionTitle {
                            Text(activeColorSectionTitle)
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }

                        HStack(spacing: 10) {
                            ForEach(InkColorOption.allCases) { option in
                                Button {
                                    store.selectPresetColor(option)
                                } label: {
                                    Circle()
                                        .fill(option.color)
                                        .frame(width: 28, height: 28)
                                        .overlay {
                                            Circle()
                                                .stroke(Color.white, lineWidth: store.isPresetColorSelected(option) ? 3 : 0)
                                        }
                                        .overlay {
                                            Circle()
                                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                                        }
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(option.name)
                            }

                            ColorPicker(
                                "",
                                selection: Binding(
                                    get: { store.activeColor },
                                    set: { newValue in
                                        store.updateActiveCustomColor(newValue)
                                    }
                                ),
                                supportsOpacity: false
                            )
                            .labelsHidden()
                            .frame(width: 28, height: 28)
                            .background(
                                Circle()
                                    .fill(store.activeColor)
                            )
                            .clipShape(Circle())
                            .overlay {
                                Circle()
                                    .stroke(Color.white, lineWidth: store.isUsingCustomActiveColor ? 3 : 0)
                            }
                            .overlay {
                                Circle()
                                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
                            }
                        }
                    }

                    if store.shouldShowHighlightOpacityControl {
                        HStack(spacing: 10) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)

                            Slider(value: $store.highlightOpacity, in: 0.2...0.75, step: 0.05)

                            Text(store.highlightOpacityLabel)
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 40)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.white.opacity(0.9), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.white.opacity(0.92), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)
        .frame(maxWidth: .infinity)
    }

    private func supportsStroke(for tool: AnnotationTool?) -> Bool {
        switch tool {
        case .ink, .circle, .square, .arrow:
            return true
        default:
            return false
        }
    }

    private func supportsShapeSize(for tool: AnnotationTool?) -> Bool {
        switch tool {
        case .circle, .square, .arrow:
            return true
        default:
            return false
        }
    }

    private var supportsColor: Bool {
        store.activeColorRole != nil
    }

    private var visibleTools: [AnnotationTool] {
        AnnotationTool.allCases.filter { $0 != .stamp }
    }
}

private struct InlineSelectionBar: View {
    @ObservedObject var store: PDFDocumentStore

    private let tools: [AnnotationTool] = [
        .highlight,
        .underline,
        .strikeOut,
        .link,
        .redaction
    ]

    var body: some View {
        HStack(spacing: 8) {
            if store.hasSelectedElement {
                if store.selectedElementCanOpen {
                    inlineButton(
                        systemImage: store.selectedElementPrimaryActionSymbol,
                        isSelected: true,
                        accessibilityLabel: store.selectedElementPrimaryActionTitle
                    ) {
                        store.activateSelectedElement()
                    }
                }

                inlineButton(
                    systemImage: "trash",
                    isSelected: false,
                    accessibilityLabel: "Delete selected element"
                ) {
                    store.deleteSelectedElement()
                }
            } else {
                ForEach(tools) { tool in
                    inlineButton(
                        systemImage: tool.systemImage,
                        isSelected: store.isToolSelected(tool),
                        accessibilityLabel: tool.title
                    ) {
                        store.performInlineSelectionAction(tool)
                    }
                }
            }

            if store.shouldShowInlineMarkupColorControls {
                Divider()
                    .frame(height: 20)

                inlineColorControls
            }

            Divider()
                .frame(height: 20)

            Button {
                store.clearInlineSelection()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 13, weight: .bold))
                    .frame(width: 30, height: 30)
                    .foregroundStyle(Color(red: 0.18, green: 0.26, blue: 0.38))
                    .background(Color.white.opacity(0.9), in: Circle())
                    .overlay {
                        Circle()
                            .stroke(Color.black.opacity(0.06), lineWidth: 1)
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss selection")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.9), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)
    }

    private var inlineColorControls: some View {
        HStack(spacing: 6) {
            ForEach(InkColorOption.allCases) { option in
                Button {
                    store.selectPresetColor(option)
                } label: {
                    Circle()
                        .fill(option.color)
                        .frame(width: 22, height: 22)
                        .overlay {
                            Circle()
                                .stroke(Color.white, lineWidth: store.isPresetColorSelected(option) ? 2.5 : 0)
                        }
                        .overlay {
                            Circle()
                                .stroke(Color.black.opacity(0.12), lineWidth: 1)
                        }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(option.name) markup color")
            }

            ColorPicker(
                "",
                selection: Binding(
                    get: { store.activeColor },
                    set: { newValue in
                        store.updateActiveCustomColor(newValue)
                    }
                ),
                supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 22, height: 22)
            .background(
                Circle()
                    .fill(store.activeColor)
            )
            .clipShape(Circle())
            .overlay {
                Circle()
                    .stroke(Color.white, lineWidth: store.isUsingCustomActiveColor ? 2.5 : 0)
            }
            .overlay {
                Circle()
                    .stroke(Color.black.opacity(0.12), lineWidth: 1)
            }
            .accessibilityLabel("Custom markup color")
        }
    }

    private func inlineButton(
        systemImage: String,
        isSelected: Bool,
        accessibilityLabel: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .foregroundStyle(
                    isSelected
                    ? .white
                    : Color(red: 0.19, green: 0.28, blue: 0.4)
                )
                .background(
                    Circle()
                        .fill(
                            isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.blue, Color.cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(Color.white.opacity(0.92))
                        )
                )
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }
}

private struct FloatingInlineSelectionBar: View {
    @ObservedObject var store: PDFDocumentStore

    private let estimatedBarSize = CGSize(width: 452, height: 56)
    private let edgePadding: CGFloat = 18
    private let verticalGap: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            if let targetRect = store.inlineSelectionViewRect {
                InlineSelectionBar(store: store)
                    .fixedSize()
                    .position(position(for: targetRect, in: proxy.size))
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
            }
        }
    }

    private func position(for targetRect: CGRect, in containerSize: CGSize) -> CGPoint {
        let halfWidth = estimatedBarSize.width / 2
        let halfHeight = estimatedBarSize.height / 2
        let minX = edgePadding + halfWidth
        let maxX = containerSize.width - edgePadding - halfWidth
        let minY = edgePadding + halfHeight
        let maxY = containerSize.height - edgePadding - halfHeight

        let preferredX = targetRect.midX
        let x = min(max(preferredX, minX), maxX)

        let preferredTopY = targetRect.minY - verticalGap - halfHeight
        if preferredTopY >= minY {
            return CGPoint(x: x, y: preferredTopY)
        }

        let fallbackBottomY = targetRect.maxY + verticalGap + halfHeight
        return CGPoint(x: x, y: min(max(fallbackBottomY, minY), maxY))
    }
}

private struct LoadedTopBar: View {
    @ObservedObject var store: PDFDocumentStore

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Button {
                store.requestClose()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.footnote.weight(.bold))
                    .foregroundStyle(Color.blue.opacity(0.92))
                    .frame(width: 34, height: 34)
                    .background(Color.white.opacity(0.82), in: Circle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("w", modifiers: .command)
            .help("Close Document (⌘W)")
            .accessibilityLabel("Close document")

            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.red.opacity(0.92), Color.orange.opacity(0.92)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: 30, height: 34)
                .overlay {
                    Image(systemName: "doc.richtext")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.white)
                }

            VStack(alignment: .leading, spacing: 3) {
                Text(store.documentTitle)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)

                Text("\(store.pageCountDescription) • \(store.currentPageDescription)\(store.hasUnexportedChanges ? " • Not exported" : "")")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.78), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.08), radius: 12, y: 6)
    }
}

private struct OutlineSheet: View {
    @ObservedObject var store: PDFDocumentStore

    var body: some View {
        NavigationStack {
            List(store.outlineItems) { item in
                Button {
                    store.jump(to: item)
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(.primary)
                                .multilineTextAlignment(.leading)

                            Text("Page \(item.pageIndex + 1)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()
                    }
                    .padding(.leading, CGFloat(item.depth) * 14)
                    .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(store.contentsButtonTitle)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        store.isOutlinePresented = false
                    }
                }
            }
        }
    }
}

private struct AnnotationInputSheet: View {
    @ObservedObject var store: PDFDocumentStore
    let pendingInput: PendingAnnotationInput

    var body: some View {
        NavigationStack {
            Form {
                switch pendingInput.tool {
                case .note:
                    Section {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Leave a comment", systemImage: "text.bubble")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(.primary)

                            TextField("Add context, feedback, or a quick comment", text: $store.inputText, axis: .vertical)
                                .lineLimit(5, reservesSpace: true)

                            HStack {
                                Label("You", systemImage: "person.crop.circle.fill")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(.secondary)

                                Spacer()

                                Text("Saved on this PDF note")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                case .freeText:
                    Section("Text") {
                        TextField("Type text to place on the PDF", text: $store.inputText, axis: .vertical)
                            .lineLimit(4, reservesSpace: true)
                    }
                case .link:
                    if pendingInput.selection == nil {
                        Section("Link Label") {
                            TextField("Link", text: $store.inputText)
                        }
                    }

                    Section("URL") {
                        TextField("https://example.com", text: $store.linkURLString)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                    }
                default:
                    EmptyView()
                }
            }
            .navigationTitle(sheetTitle)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        store.cancelPendingAnnotationInput()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add") {
                        store.submitPendingAnnotationInput()
                    }
                }
            }
        }
    }

    private var sheetTitle: String {
        switch pendingInput.tool {
        case .note:
            return "New Comment"
        case .freeText:
            return "Add Text"
        case .link:
            return pendingInput.selection != nil ? "Add Link" : "Add Link"
        default:
            return "Annotation"
        }
    }
}

private struct ToolIconButton: View {
    let tool: AnnotationTool
    let isSelected: Bool
    let isEnabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.systemImage)
                .font(.system(size: 16, weight: .semibold))
                .frame(width: 38, height: 38)
                .foregroundStyle(
                    isSelected
                    ? .white
                    : (isEnabled ? Color(red: 0.19, green: 0.28, blue: 0.4) : Color.black.opacity(0.24))
                )
                .background(
                    Circle()
                        .fill(
                            isSelected
                            ? AnyShapeStyle(
                                LinearGradient(
                                    colors: [Color.blue, Color.cyan],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            : AnyShapeStyle(isEnabled ? Color.white.opacity(0.76) : Color.black.opacity(0.06))
                        )
                )
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(isSelected ? 0 : 0.06), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.7)
        .accessibilityLabel(tool.title)
    }
}

private struct UtilityIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color(red: 0.18, green: 0.26, blue: 0.38))
                .frame(width: 34, height: 34)
                .background(Color.white.opacity(0.96), in: Circle())
                .overlay {
                    Circle()
                        .stroke(Color.black.opacity(0.08), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }
}

private struct MinimalBadge: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(Color(red: 0.20, green: 0.28, blue: 0.40))
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Color.white.opacity(0.72), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.85), lineWidth: 1)
            }
    }
}
