import PDFKit
import SwiftUI
import UniformTypeIdentifiers

enum InkColorOption: String, CaseIterable, Identifiable {
    case red
    case blue
    case green
    case yellow
    case black

    var id: String { rawValue }

    var name: String {
        rawValue.capitalized
    }

    var color: Color {
        switch self {
        case .red:
            return .red
        case .blue:
            return .blue
        case .green:
            return .green
        case .yellow:
            return .yellow
        case .black:
            return .black
        }
    }

    var uiColor: UIColor {
        switch self {
        case .red:
            return UIColor(red: 0.93, green: 0.24, blue: 0.21, alpha: 1)
        case .blue:
            return UIColor(red: 0.06, green: 0.52, blue: 0.98, alpha: 1)
        case .green:
            return UIColor(red: 0.20, green: 0.78, blue: 0.35, alpha: 1)
        case .yellow:
            return UIColor(red: 1.0, green: 0.84, blue: 0.04, alpha: 1)
        case .black:
            return .black
        }
    }
}

enum AnnotationTool: String, CaseIterable, Identifiable {
    case ink
    case highlight
    case underline
    case strikeOut
    case note
    case freeText
    case circle
    case square
    case arrow
    case stamp
    case link
    case redaction

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ink:
            return "Ink"
        case .highlight:
            return "Highlight"
        case .underline:
            return "Underline"
        case .strikeOut:
            return "Strike"
        case .note:
            return "Note"
        case .freeText:
            return "Text"
        case .circle:
            return "Circle"
        case .square:
            return "Square"
        case .arrow:
            return "Arrow"
        case .stamp:
            return "Stamp"
        case .link:
            return "Link"
        case .redaction:
            // An opaque box annotation. The page content underneath is not removed,
            // so this must not be presented as redaction.
            return "Cover"
        }
    }

    var systemImage: String {
        switch self {
        case .ink:
            return "applepencil.tip"
        case .highlight:
            return "highlighter"
        case .underline:
            return "underline"
        case .strikeOut:
            return "strikethrough"
        case .note:
            return "note.text"
        case .freeText:
            return "text.cursor"
        case .circle:
            return "circle"
        case .square:
            return "square"
        case .arrow:
            return "arrow.right"
        case .stamp:
            return "checkmark.seal"
        case .link:
            return "link"
        case .redaction:
            return "eye.slash"
        }
    }

    var instruction: String {
        switch self {
        case .ink:
            return "Drag to draw freehand ink. Use two fingers to scroll and pinch to zoom."
        case .highlight:
            return "Select text to apply highlight immediately."
        case .underline:
            return "Select text to apply underline immediately."
        case .strikeOut:
            return "Select text to apply strike immediately."
        case .note:
            return "Tap anywhere on the page to place a text note."
        case .freeText:
            return "Tap anywhere on the page to place a free text box."
        case .circle:
            return "Tap to drop a circle annotation."
        case .square:
            return "Tap to drop a square annotation."
        case .arrow:
            return "Tap to place an arrow annotation."
        case .stamp:
            return "Tap to place an Approved stamp."
        case .link:
            return "Tap to place a link annotation."
        case .redaction:
            return "Select text to cover it. The text stays in the file; this is not secure redaction."
        }
    }

    var requiresPointInput: Bool {
        switch self {
        case .note, .freeText, .circle, .square, .arrow, .stamp:
            return true
        default:
            return false
        }
    }

    var usesTextSelection: Bool {
        switch self {
        case .highlight, .underline, .strikeOut, .redaction:
            return true
        default:
            return false
        }
    }

    var usesOverlayInteraction: Bool {
        switch self {
        case .highlight, .underline, .strikeOut, .redaction:
            return false
        default:
            return true
        }
    }

    var markupType: PDFMarkupType? {
        switch self {
        case .highlight:
            return .highlight
        case .underline:
            return .underline
        case .strikeOut:
            return .strikeOut
        case .redaction:
            return .redact
        default:
            return nil
        }
    }
}

struct AnnotatedPDFFile: FileDocument {
    static var readableContentTypes: [UTType] = [.pdf]

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct PDFNavigationRequest: Identifiable {
    let id = UUID()
    let destination: PDFDestination?
    let pageIndex: Int?
}

enum PDFZoomCommand {
    case zoomIn
    case zoomOut
    case fit
}

struct PDFZoomRequest: Identifiable {
    let id = UUID()
    let command: PDFZoomCommand
}

struct PDFZoomState {
    let scaleFactor: CGFloat
    let fitScaleFactor: CGFloat

    var displayPercentage: Int {
        let normalizedFitScale = max(fitScaleFactor, 0.0001)
        let zoomRatio = scaleFactor / normalizedFitScale
        return max(Int((zoomRatio * 100).rounded()), 10)
    }
}

struct PDFOutlineItem: Identifiable {
    let id = UUID()
    let title: String
    let depth: Int
    let pageIndex: Int
    let destination: PDFDestination?
}

struct PendingAnnotationInput: Identifiable {
    let id = UUID()
    let tool: AnnotationTool
    let page: PDFPage
    let point: CGPoint?
    let selection: PDFSelection?
}

struct NotePreview: Identifiable {
    let id = UUID()
    let author: String
    let timestamp: String
    let pageLabel: String
    let message: String
}

struct PendingShapeDraft {
    let tool: AnnotationTool
    let page: PDFPage
    let point: CGPoint
}

struct SelectedPDFElement {
    let page: PDFPage
    let annotation: PDFAnnotation
}

enum AnnotationColorRole {
    case drawing
    case highlight
    case text
    case note

    var title: String {
        switch self {
        case .drawing:
            return "Drawing color"
        case .highlight:
            return "Markup color"
        case .text:
            return "Text color"
        case .note:
            return "Note color"
        }
    }
}

struct AnnotationColorPalette {
    var preset: InkColorOption
    var customColor: Color
    var usesCustomColor: Bool

    init(preset: InkColorOption) {
        self.preset = preset
        customColor = preset.color
        usesCustomColor = false
    }

    var color: Color {
        usesCustomColor ? customColor : preset.color
    }

    var uiColor: UIColor {
        usesCustomColor ? UIColor(customColor) : preset.uiColor
    }
}

private struct AnnotationMutation {
    enum Kind {
        case added
        case removed
    }

    let kind: Kind
    let entries: [(page: PDFPage, annotation: PDFAnnotation)]
}

private enum SelectionActionTrigger {
    case inlineBar
    case toolbarArm
}

@MainActor
final class PDFDocumentStore: ObservableObject {
    private static let commentUserNamePrefix = "comment:"
    private static let markupUserNamePrefix = "markup:"

    @Published var document: PDFDocument?
    @Published var sourceURL: URL?
    @Published var isImporterPresented = false
    @Published var isExporterPresented = false
    @Published var exportFile: AnnotatedPDFFile?
    @Published var errorMessage: String?
    @Published var selectedTool: AnnotationTool?
    @Published var drawingPalette = AnnotationColorPalette(preset: .red)
    @Published var highlightPalette = AnnotationColorPalette(preset: .yellow)
    @Published var textPalette = AnnotationColorPalette(preset: .black)
    @Published var notePalette = AnnotationColorPalette(preset: .yellow)
    @Published var highlightOpacity = 0.38
    @Published var strokeWidth: CGFloat = 4
    @Published var shapeSize: CGFloat = 120
    @Published var outlineItems: [PDFOutlineItem] = []
    @Published var isOutlinePresented = false
    @Published var currentPageIndex = 0
    @Published var navigationRequest: PDFNavigationRequest?
    @Published var pendingAnnotationInput: PendingAnnotationInput?
    @Published var inputText = ""
    @Published var linkURLString = "https://"
    @Published var annotationRefreshID = UUID()
    @Published var presentedNotePreview: NotePreview?
    @Published var hasTextSelection = false
    @Published var selectionClearRequestID = UUID()
    @Published var zoomRequest: PDFZoomRequest?
    @Published var zoomScaleLabel = "100%"
    @Published var canUndo = false
    @Published var pendingExternalURL: URL?
    @Published var isLinkPlacementMode = false
    @Published var pendingShapeDraft: PendingShapeDraft?
    @Published var selectionUpdateID = UUID()
    @Published var selectedElement: SelectedPDFElement?
    @Published var inlineSelectionViewRect: CGRect?
    /// True after any annotation change that has not been exported. The source file is never
    /// modified; export always writes a separate copy chosen by the user.
    @Published private(set) var hasUnexportedChanges = false
    /// Set when closing or replacing the document would discard unexported annotations.
    @Published var pendingDiscard: DiscardIntent?
    @Published var isClearAllConfirmationPresented = false

    enum DiscardIntent: Identifiable {
        case close
        case openAnother

        var id: Self { self }
    }

    func requestClose() {
        if hasUnexportedChanges { pendingDiscard = .close } else { closeDocument() }
    }

    func requestOpenAnother() {
        if hasUnexportedChanges { pendingDiscard = .openAnother } else { isImporterPresented = true }
    }

    func confirmDiscard() {
        let intent = pendingDiscard
        pendingDiscard = nil
        switch intent {
        case .close: closeDocument()
        case .openAnother:
            // Keep the dirty flag: loadDocument(from:) clears it only after a new PDF loads,
            // so cancelling the picker or a failed load still guards the current edits.
            isImporterPresented = true
        case nil: break
        }
    }

    private var currentTextSelection: PDFSelection?
    private var undoStack: [AnnotationMutation] = []
    private var pendingSelectionAutoApplyWorkItem: DispatchWorkItem?
    private var selectionAutoApplyToken = 0

    var documentTitle: String {
        let baseName = sourceURL?
            .deletingPathExtension()
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if let baseName, !baseName.isEmpty {
            return baseName
        }

        return "Untitled PDF"
    }

    var pageCountDescription: String {
        let count = document?.pageCount ?? 0
        return count == 1 ? "1 page" : "\(count) pages"
    }

    var currentPageDescription: String {
        let pageCount = document?.pageCount ?? 0
        guard pageCount > 0 else {
            return "Page 0 / 0"
        }

        let current = min(max(currentPageIndex + 1, 1), pageCount)
        return "Page \(current) / \(pageCount)"
    }

    var contentsButtonTitle: String {
        outlineItems.first?.title.hasPrefix("Page ") == true ? "Pages" : "Contents"
    }

    /// Annotations currently on all pages, including ones the PDF already had when opened.
    var totalAnnotationCount: Int {
        guard let document else { return 0 }
        return (0 ..< document.pageCount).reduce(0) { count, index in
            count + (document.page(at: index)?.annotations.count ?? 0)
        }
    }

    var suggestedExportName: String {
        "\(documentTitle)-annotated"
    }

    var drawingColor: Color {
        drawingPalette.color
    }

    var drawingUIColor: UIColor {
        drawingPalette.uiColor
    }

    var activeColorRole: AnnotationColorRole? {
        switch selectedTool {
        case .ink, .circle, .square, .arrow:
            return .drawing
        case .highlight, .underline, .strikeOut:
            return .highlight
        case .freeText:
            return .text
        case .note:
            return .note
        default:
            break
        }

        if selectedTool == nil && hasTextSelection && !hasSelectedElement && pendingAnnotationInput == nil {
            return .highlight
        }

        return nil
    }

    var activeColorSectionTitle: String? {
        activeColorRole?.title
    }

    var activeColor: Color {
        guard let activeColorRole else {
            return drawingPalette.color
        }

        return palette(for: activeColorRole).color
    }

    var isUsingCustomActiveColor: Bool {
        guard let activeColorRole else {
            return false
        }

        return palette(for: activeColorRole).usesCustomColor
    }

    var shouldShowHighlightOpacityControl: Bool {
        selectedTool == .highlight
    }

    var highlightOpacityLabel: String {
        "\(Int((highlightOpacity * 100).rounded()))%"
    }

    var activeToolInstruction: String? {
        if shouldShowInlineSelectionBar {
            if hasSelectedElement {
                return "Element selected. Use the quick bar to inspect or remove it."
            }

            return "Text selected. Use the quick bar or tap a toolbar tool to apply immediately."
        }

        guard let selectedTool else {
            return nil
        }

        if selectedTool == .link && isLinkPlacementMode {
            return "Tap on the PDF to place a named link."
        }

        if isSelectionActionTool(selectedTool) {
            if selectedTool == .link {
                return "Select text to add a link immediately."
            }

            if selectedTool == .redaction {
                return selectedTool.instruction
            }

            return "Select text and \(selectedTool.title.lowercased()) will be applied automatically."
        }

        if selectedTool == .ink {
            return "Drag to draw. Use two fingers to scroll and pinch to zoom."
        }

        return selectedTool.instruction
    }

    var shouldShowApplyButton: Bool {
        false
    }

    var shouldShowShapeSaveButton: Bool {
        false
    }

    var applyButtonTitle: String {
        if hasTextSelection {
            return "Apply"
        }

        return "Select Text First"
    }

    var overlayTool: AnnotationTool? {
        selectedTool
    }

    var shouldShowInlineSelectionBar: Bool {
        shouldShowFloatingTextSelectionBar || shouldShowElementInlineSelectionBar
    }

    var shouldShowFloatingTextSelectionBar: Bool {
        selectedTool == nil &&
        pendingAnnotationInput == nil &&
        hasTextSelection &&
        inlineSelectionViewRect != nil
    }

    var shouldShowElementInlineSelectionBar: Bool {
        selectedTool == nil &&
        pendingAnnotationInput == nil &&
        hasSelectedElement
    }

    var shouldShowInlineMarkupColorControls: Bool {
        !hasSelectedElement &&
        hasTextSelection &&
        activeColorRole == .highlight
    }

    var hasSelectedElement: Bool {
        selectedElement != nil
    }

    var selectedElementCanOpen: Bool {
        guard let annotation = selectedElement?.annotation else {
            return false
        }

        return resolvedURL(for: annotation) != nil || notePreview(for: annotation) != nil
    }

    var selectedElementPrimaryActionTitle: String {
        guard let annotation = selectedElement?.annotation else {
            return "Open"
        }

        if resolvedURL(for: annotation) != nil {
            return "Open Link"
        }

        if notePreview(for: annotation) != nil {
            return "View Note"
        }

        return "Open"
    }

    var selectedElementPrimaryActionSymbol: String {
        guard let annotation = selectedElement?.annotation else {
            return "arrow.up.right.square"
        }

        if resolvedURL(for: annotation) != nil {
            return "arrow.up.right.square"
        }

        if notePreview(for: annotation) != nil {
            return "text.bubble"
        }

        return "info.circle"
    }

    func importDocument(from result: Result<URL, Error>) {
        do {
            let url = try result.get()
            loadDocument(from: url)
        } catch {
            errorMessage = "The PDF could not be opened. \(error.localizedDescription)"
        }
    }

    func closeDocument() {
        hasUnexportedChanges = false
        document = nil
        sourceURL = nil
        exportFile = nil
        errorMessage = nil
        selectedTool = nil
        outlineItems = []
        isOutlinePresented = false
        currentPageIndex = 0
        navigationRequest = nil
        pendingAnnotationInput = nil
        inputText = ""
        linkURLString = "https://"
        presentedNotePreview = nil
        zoomRequest = nil
        zoomScaleLabel = "100%"
        pendingExternalURL = nil
        isLinkPlacementMode = false
        pendingShapeDraft = nil
        selectedElement = nil
        inlineSelectionViewRect = nil
        selectionUpdateID = UUID()
        pendingSelectionAutoApplyWorkItem?.cancel()
        pendingSelectionAutoApplyWorkItem = nil
        selectionAutoApplyToken = 0
        undoStack.removeAll()
        canUndo = false
        clearTextSelection()
        annotationRefreshID = UUID()
    }

    func toggleTool(_ tool: AnnotationTool) {
        guard !isSelectionActionTool(tool) else {
            toggleSelectionActionTool(tool)
            return
        }

        if selectedTool == tool {
            selectedTool = nil
            isLinkPlacementMode = false
            pendingShapeDraft = nil
        } else {
            selectedTool = tool
            isLinkPlacementMode = false
            pendingShapeDraft = nil
        }

        selectedElement = nil

        if selectedTool?.usesTextSelection != true {
            clearTextSelection()
        }
    }

    func performInlineSelectionAction(_ tool: AnnotationTool) {
        performSelectionAction(tool, trigger: .inlineBar)
    }

    func clearInlineSelection() {
        selectedElement = nil
        inlineSelectionViewRect = nil
        clearTextSelection()
    }

    func updateCurrentPage(index: Int) {
        let normalizedIndex = max(index, 0)
        guard currentPageIndex != normalizedIndex else {
            return
        }

        currentPageIndex = normalizedIndex
    }

    func jump(to item: PDFOutlineItem) {
        navigationRequest = PDFNavigationRequest(
            destination: item.destination,
            pageIndex: item.pageIndex
        )
        isOutlinePresented = false
    }

    func requestZoomIn() {
        zoomRequest = PDFZoomRequest(command: .zoomIn)
    }

    func requestZoomOut() {
        zoomRequest = PDFZoomRequest(command: .zoomOut)
    }

    func requestZoomToFit() {
        zoomRequest = PDFZoomRequest(command: .fit)
    }

    func beginLinkPlacementMode() {
        selectedTool = .link
        isLinkPlacementMode = true
        pendingShapeDraft = nil
        selectedElement = nil
        inlineSelectionViewRect = nil
        clearTextSelection()
    }

    func updateInlineSelectionViewRect(_ rect: CGRect?) {
        inlineSelectionViewRect = rect
    }

    func selectPresetColor(_ option: InkColorOption) {
        guard let activeColorRole else {
            return
        }

        updatePalette(for: activeColorRole) { palette in
            var updatedPalette = palette
            updatedPalette.preset = option
            updatedPalette.customColor = option.color
            updatedPalette.usesCustomColor = false
            return updatedPalette
        }
    }

    func updateActiveCustomColor(_ color: Color) {
        guard let activeColorRole else {
            return
        }

        updatePalette(for: activeColorRole) { palette in
            var updatedPalette = palette
            updatedPalette.customColor = color
            updatedPalette.usesCustomColor = true
            return updatedPalette
        }
    }

    func isPresetColorSelected(_ option: InkColorOption) -> Bool {
        guard let activeColorRole else {
            return false
        }

        let palette = palette(for: activeColorRole)
        return !palette.usesCustomColor && palette.preset == option
    }

    func undoLastChange() {
        guard let mutation = undoStack.popLast() else {
            return
        }

        switch mutation.kind {
        case .added:
            for entry in mutation.entries {
                if entry.page.annotations.contains(where: { $0 === entry.annotation }) {
                    entry.page.removeAnnotation(entry.annotation)
                }
            }
        case .removed:
            for entry in mutation.entries {
                if !entry.page.annotations.contains(where: { $0 === entry.annotation }) {
                    entry.page.addAnnotation(entry.annotation)
                }
            }
        }

        canUndo = !undoStack.isEmpty
        hasUnexportedChanges = true
        finishDocumentMutation()
    }

    func updateZoomScale(_ zoomState: PDFZoomState) {
        let nextLabel = "\(zoomState.displayPercentage)%"
        guard zoomScaleLabel != nextLabel else {
            return
        }

        zoomScaleLabel = nextLabel
    }

    func handleTap(on page: PDFPage, at pagePoint: CGPoint) {
        guard let selectedTool else {
            return
        }

        switch selectedTool {
        case .ink:
            return
        case .highlight, .underline, .strikeOut, .redaction:
            return
        case .note, .freeText, .link:
            guard selectedTool != .link || isLinkPlacementMode else {
                return
            }
            preparePendingInput(for: selectedTool, page: page, point: pagePoint)
        case .circle:
            addCircleAnnotation(on: page, at: pagePoint)
        case .square:
            addSquareAnnotation(on: page, at: pagePoint)
        case .arrow:
            addArrowAnnotation(on: page, at: pagePoint)
        case .stamp:
            addStampAnnotation(on: page, at: pagePoint)
        }
    }

    func savePendingShape() {
        guard let pendingShapeDraft else {
            return
        }

        switch pendingShapeDraft.tool {
        case .circle:
            addCircleAnnotation(on: pendingShapeDraft.page, at: pendingShapeDraft.point)
        case .square:
            addSquareAnnotation(on: pendingShapeDraft.page, at: pendingShapeDraft.point)
        case .arrow:
            addArrowAnnotation(on: pendingShapeDraft.page, at: pendingShapeDraft.point)
        default:
            return
        }

        self.pendingShapeDraft = nil
        selectedTool = nil
    }

    func cancelPendingShape() {
        pendingShapeDraft = nil
    }

    func updatePendingShapeLocation(on page: PDFPage, at point: CGPoint) {
        guard let pendingShapeDraft, pendingShapeDraft.page == page else {
            return
        }

        self.pendingShapeDraft = PendingShapeDraft(
            tool: pendingShapeDraft.tool,
            page: page,
            point: point
        )
    }

    func activateSelectedElement() {
        guard let selectedElement else {
            return
        }

        _ = performDefaultAnnotationActivation(selectedElement.annotation)
    }

    func deleteSelectedElement() {
        guard let selectedElement else {
            return
        }

        let entries = annotationEntries(for: selectedElement.annotation)
        guard !entries.isEmpty else {
            self.selectedElement = nil
            return
        }

        for entry in entries {
            if entry.page.annotations.contains(where: { $0 === entry.annotation }) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }

        registerMutation(.removed, entries: entries)
        self.selectedElement = nil
        finishDocumentMutation()
    }

    @discardableResult
    func handleAnnotationActivation(_ annotation: PDFAnnotation) -> Bool {
        if selectedElementMatches(annotation) {
            _ = performDefaultAnnotationActivation(annotation)
            return true
        }

        selectElement(annotation)
        return true
    }

    func updateTextSelection(_ selection: PDFSelection?) {
        currentTextSelection = selection?.copy() as? PDFSelection ?? selection

        let selectedString = selection?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        hasTextSelection = !selectedString.isEmpty
        if hasTextSelection {
            selectedElement = nil
        } else {
            inlineSelectionViewRect = nil
        }
        selectionUpdateID = UUID()
        scheduleSelectionAutoApplyIfNeeded()
    }

    func applySelectedMarkup() {
        guard
            let tool = selectedTool,
            let currentTextSelection,
            hasTextSelection
        else {
            errorMessage = "Select text in the PDF first."
            return
        }

        if tool == .link {
            preparePendingLinkInput(for: currentTextSelection)
            return
        }

        guard let markupType = tool.markupType else {
            errorMessage = "Select text in the PDF first."
            return
        }

        addMarkupAnnotations(for: currentTextSelection, markupType: markupType)
        selectedTool = nil
        clearTextSelection()
    }

    func isSelectionActionTool(_ tool: AnnotationTool) -> Bool {
        tool.usesTextSelection || tool == .link
    }

    func isToolEnabled(_ tool: AnnotationTool) -> Bool {
        document != nil
    }

    func isToolSelected(_ tool: AnnotationTool) -> Bool {
        if selectedTool == tool {
            return true
        }

        if isSelectionActionTool(tool) {
            guard let selection = currentTextSelection, hasTextSelection else {
                return false
            }

            return selectionHasAppliedAction(selection, tool: tool)
        }

        return false
    }

    func performSelectionAction(_ tool: AnnotationTool) {
        performSelectionAction(tool, trigger: .inlineBar)
    }

    func handleAnnotationActivation(on page: PDFPage, at point: CGPoint) -> Bool {
        guard let annotation = noteAnnotation(near: point, on: page) ?? page.annotation(at: point) else {
            return false
        }

        return handleAnnotationActivation(annotation)
    }

    func commitInkStroke(on page: PDFPage, pagePoints: [CGPoint]) {
        guard pagePoints.count > 1 else {
            return
        }

        // PDFKit ink paths are in annotation space, relative to the annotation's bounds origin.
        // The bounds cover only the stroke (plus its width), not the whole page, so tapping blank
        // space, links, or other annotations elsewhere on the page does not select this stroke.
        let annotationBounds = Self.inkAnnotationBounds(for: pagePoints, lineWidth: strokeWidth)
        let origin = annotationBounds.origin
        let annotationPoints = pagePoints.map { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
        let path = UIBezierPath()
        path.move(to: annotationPoints[0])

        for point in annotationPoints.dropFirst() {
            path.addLine(to: point)
        }

        let annotation = PDFAnnotation(
            bounds: annotationBounds,
            forType: .ink,
            withProperties: nil
        )
        let border = PDFBorder()
        border.lineWidth = strokeWidth

        annotation.border = border
        annotation.color = drawingUIColor
        annotation.add(path)

        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    static func inkAnnotationBounds(for pagePoints: [CGPoint], lineWidth: CGFloat) -> CGRect {
        let xs = pagePoints.map(\.x)
        let ys = pagePoints.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else {
            return .zero
        }

        let outset = max(lineWidth, 1) / 2 + 2
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            .insetBy(dx: -outset, dy: -outset)
    }

    func submitPendingAnnotationInput() {
        guard let pendingAnnotationInput else {
            return
        }

        switch pendingAnnotationInput.tool {
        case .note:
            addNoteAnnotation(
                on: pendingAnnotationInput.page,
                at: pendingAnnotationInput.point ?? .zero,
                text: inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .freeText:
            addFreeTextAnnotation(
                on: pendingAnnotationInput.page,
                at: pendingAnnotationInput.point ?? .zero,
                text: inputText.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .link:
            // Keep the sheet and its values so the user can correct the address.
            guard isPendingLinkURLValid else {
                return
            }

            if let selection = pendingAnnotationInput.selection {
                addLinkAnnotations(
                    for: selection,
                    label: inputText.trimmingCharacters(in: .whitespacesAndNewlines),
                    urlString: linkURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            } else if let point = pendingAnnotationInput.point {
                addLinkAnnotation(
                    on: pendingAnnotationInput.page,
                    at: point,
                    label: inputText.trimmingCharacters(in: .whitespacesAndNewlines),
                    urlString: linkURLString.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        default:
            break
        }

        resetPendingInput()
    }

    func cancelPendingAnnotationInput() {
        resetPendingInput()
    }

    func removeAllAnnotations() {
        guard let document else {
            return
        }

        var removedEntries: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for pageIndex in 0 ..< document.pageCount {
            guard let page = document.page(at: pageIndex) else {
                continue
            }

            for annotation in page.annotations {
                removedEntries.append((page: page, annotation: annotation))
                page.removeAnnotation(annotation)
            }
        }

        registerMutation(.removed, entries: removedEntries)
        selectedElement = nil
        finishDocumentMutation()
    }

    func prepareExport() {
        guard let data = document?.dataRepresentation(), !data.isEmpty else {
            errorMessage = "There is no annotated PDF data available to export yet."
            return
        }

        exportFile = AnnotatedPDFFile(data: data)
        isExporterPresented = true
    }

    func finishExport(result: Result<URL, Error>) {
        do {
            _ = try result.get()
            exportFile = nil
            hasUnexportedChanges = false
        } catch {
            errorMessage = "The annotated PDF could not be exported. \(error.localizedDescription)"
        }
    }

    private func loadDocument(from url: URL) {
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }

        // Read the bytes while security-scoped access is held. PDFDocument(url:) reads page
        // streams lazily, which can fail after access is revoked for provider-backed files.
        guard let data = try? Data(contentsOf: url), let document = PDFDocument(data: data) else {
            errorMessage = "This file could not be parsed as a PDF."
            return
        }

        self.document = document
        sourceURL = url
        hasUnexportedChanges = false
        exportFile = nil
        selectedTool = nil
        pendingShapeDraft = nil
        selectedElement = nil
        currentPageIndex = 0
        zoomScaleLabel = "100%"
        pendingSelectionAutoApplyWorkItem?.cancel()
        pendingSelectionAutoApplyWorkItem = nil
        selectionAutoApplyToken = 0
        undoStack.removeAll()
        canUndo = false
        clearTextSelection()
        buildOutlineItems(for: document)
        annotationRefreshID = UUID()
    }

    private func buildOutlineItems(for document: PDFDocument) {
        if let outlineRoot = document.outlineRoot, outlineRoot.numberOfChildren > 0 {
            outlineItems = flattenOutline(root: outlineRoot, in: document)
        } else {
            outlineItems = (0 ..< document.pageCount).map { index in
                PDFOutlineItem(
                    title: "Page \(index + 1)",
                    depth: 0,
                    pageIndex: index,
                    destination: nil
                )
            }
        }
    }

    private func flattenOutline(root: PDFOutline, in document: PDFDocument) -> [PDFOutlineItem] {
        var items: [PDFOutlineItem] = []

        func walk(_ outline: PDFOutline, depth: Int) {
            for childIndex in 0 ..< outline.numberOfChildren {
                guard let child = outline.child(at: childIndex) else {
                    continue
                }

                let destination = outlineDestination(for: child)
                let pageIndex = destination.flatMap { destination in
                    destination.page.map { document.index(for: $0) }
                } ?? 0

                if let label = child.label, !label.isEmpty {
                    items.append(
                        PDFOutlineItem(
                            title: label,
                            depth: depth,
                            pageIndex: pageIndex,
                            destination: destination
                        )
                    )
                }

                walk(child, depth: depth + 1)
            }
        }

        walk(root, depth: 0)
        return items
    }

    private func outlineDestination(for outline: PDFOutline) -> PDFDestination? {
        if let destination = outline.destination {
            return destination
        }

        if let action = outline.action as? PDFActionGoTo {
            return action.destination
        }

        return nil
    }

    private func preparePendingInput(for tool: AnnotationTool, page: PDFPage, point: CGPoint) {
        pendingAnnotationInput = PendingAnnotationInput(tool: tool, page: page, point: point, selection: nil)

        switch tool {
        case .note:
            inputText = ""
        case .freeText:
            inputText = ""
        case .link:
            inputText = "Open link"
            linkURLString = "https://"
        default:
            break
        }
    }

    private func preparePendingLinkInput(for selection: PDFSelection) {
        guard let page = selection.pages.first else {
            errorMessage = "Select text in the PDF first."
            return
        }

        pendingAnnotationInput = PendingAnnotationInput(
            tool: .link,
            page: page,
            point: nil,
            selection: selection.copy() as? PDFSelection ?? selection
        )
        inputText = ""
        linkURLString = "https://"
    }

    private func resetPendingInput() {
        pendingAnnotationInput = nil
        inputText = ""
        linkURLString = "https://"
        isLinkPlacementMode = false
        selectedElement = nil
    }

    private func stageShapeDraft(tool: AnnotationTool, on page: PDFPage, at point: CGPoint) {
        pendingShapeDraft = PendingShapeDraft(tool: tool, page: page, point: point)
    }

    private func toggleSelectionActionTool(_ tool: AnnotationTool) {
        if selectedTool == tool {
            selectedTool = nil
            pendingSelectionAutoApplyWorkItem?.cancel()
            pendingSelectionAutoApplyWorkItem = nil
            return
        }

        selectedTool = tool
        isLinkPlacementMode = false
        pendingShapeDraft = nil

        guard let currentTextSelection, hasTextSelection else {
            return
        }

        applySelectionAction(tool, selection: currentTextSelection, trigger: .toolbarArm)
    }

    private func performSelectionAction(_ tool: AnnotationTool, trigger: SelectionActionTrigger) {
        guard isSelectionActionTool(tool) else {
            return
        }

        guard let currentTextSelection, hasTextSelection else {
            errorMessage = "Select text in the PDF first."
            return
        }

        applySelectionAction(tool, selection: currentTextSelection, trigger: trigger)
    }

    private func applySelectionAction(_ tool: AnnotationTool, selection: PDFSelection, trigger: SelectionActionTrigger) {
        let copiedSelection = selection.copy() as? PDFSelection ?? selection

        if selectionHasAppliedAction(copiedSelection, tool: tool) {
            guard trigger == .inlineBar else {
                return
            }

            removeSelectionAction(copiedSelection, tool: tool)
            clearTextSelection()
            return
        }

        if tool == .link {
            preparePendingLinkInput(for: copiedSelection)

            if trigger == .inlineBar {
                selectedTool = nil
            }

            clearTextSelection()
            return
        }

        guard let markupType = tool.markupType else {
            return
        }

        addMarkupAnnotations(for: copiedSelection, markupType: markupType)

        if trigger == .inlineBar {
            selectedTool = nil
        }

        clearTextSelection()
    }

    private func scheduleSelectionAutoApplyIfNeeded() {
        pendingSelectionAutoApplyWorkItem?.cancel()
        pendingSelectionAutoApplyWorkItem = nil
        selectionAutoApplyToken += 1

        guard
            hasTextSelection,
            let selectedTool,
            isSelectionActionTool(selectedTool),
            let currentTextSelection
        else {
            return
        }

        let token = selectionAutoApplyToken
        let selectionSnapshot = currentTextSelection.copy() as? PDFSelection ?? currentTextSelection
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else {
                return
            }

            guard self.selectionAutoApplyToken == token, self.selectedTool == selectedTool else {
                return
            }

            self.applySelectionAction(selectedTool, selection: selectionSnapshot, trigger: .toolbarArm)
        }

        pendingSelectionAutoApplyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24, execute: workItem)
    }

    private func addMarkupAnnotation(on page: PDFPage, at point: CGPoint, markupType: PDFMarkupType) {
        guard
            let selection = preciseMarkupSelection(on: page, at: point)
        else {
            errorMessage = "No selectable text was found at that point."
            return
        }

        addMarkupAnnotations(for: selection, markupType: markupType)
    }

    private func addMarkupAnnotations(for selection: PDFSelection, markupType: PDFMarkupType) {
        var addedEntries: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for target in selectionBounds(for: selection, splitWords: true) {
            if let annotation = visualAnnotation(for: markupType, bounds: target.bounds) {
                addedEntries.append((page: target.page, annotation: annotation))
            }
        }

        addAnnotations(addedEntries)
        finishDocumentMutation()
    }

    private func addNoteAnnotation(on page: PDFPage, at point: CGPoint, text: String) {
        let commentText = text.isEmpty ? "Comment" : text
        let annotation = PDFAnnotation(
            bounds: centeredRect(at: point, on: page, size: CGSize(width: 18, height: 18)),
            forType: .text,
            withProperties: nil
        )
        annotation.iconType = .comment
        annotation.color = noteUIColor
        annotation.contents = commentText
        annotation.userName = Self.commentUserNamePrefix + "You"
        annotation.modificationDate = Date()
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        addAnnotations([(page: page, annotation: annotation)])
        selectedTool = nil
        presentedNotePreview = notePreview(for: annotation)
        finishDocumentMutation()
    }

    private func addFreeTextAnnotation(on page: PDFPage, at point: CGPoint, text: String) {
        let annotation = PDFAnnotation(
            bounds: centeredRect(at: point, on: page, size: CGSize(width: 220, height: 96)),
            forType: .freeText,
            withProperties: nil
        )
        let border = PDFBorder()
        border.lineWidth = 0

        annotation.border = border
        annotation.color = .clear
        annotation.font = UIFont.systemFont(ofSize: 18, weight: .medium)
        annotation.fontColor = textUIColor
        annotation.alignment = .left
        annotation.contents = text.isEmpty ? "Type here" : text
        annotation.shouldDisplay = true
        annotation.shouldPrint = true
        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    private func addLinkAnnotation(on page: PDFPage, at point: CGPoint, label: String, urlString: String) {
        guard let url = Self.validatedLinkURL(urlString) else {
            errorMessage = "Enter a valid URL for the link annotation."
            return
        }

        let visibleText = label.isEmpty ? "Link" : label
        let bounds = centeredRect(at: point, on: page, size: linkLabelSize(for: visibleText))
        addAnnotations(
            linkAnnotationEntries(
                on: page,
                bounds: bounds,
                visibleText: visibleText,
                url: url,
                includesVisibleLabel: true
            )
        )
        finishDocumentMutation()
    }

    private func addLinkAnnotations(for selection: PDFSelection, label: String, urlString: String) {
        guard let url = Self.validatedLinkURL(urlString) else {
            errorMessage = "Enter a valid URL for the link annotation."
            return
        }

        let lineSelections = selection.selectionsByLine()
        let selections = lineSelections.isEmpty ? [selection] : lineSelections
        var entries: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for lineSelection in selections {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -1, dy: -1)
                guard !bounds.isNull, !bounds.isEmpty else {
                    continue
                }

                let visibleText = lineSelection.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                entries.append(
                    contentsOf: linkAnnotationEntries(
                        on: page,
                        bounds: bounds,
                        visibleText: visibleText,
                        url: url,
                        includesVisibleLabel: false
                    )
                )
            }
        }

        addAnnotations(entries)
        selectedTool = nil
        clearTextSelection()
        finishDocumentMutation()
    }

    private func linkAnnotationEntries(
        on page: PDFPage,
        bounds: CGRect,
        visibleText: String,
        url: URL,
        includesVisibleLabel: Bool
    ) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var entries: [(page: PDFPage, annotation: PDFAnnotation)] = []
        let underlineHeight: CGFloat = 2
        let underlineBounds = CGRect(
            x: bounds.minX,
            y: bounds.minY - 1,
            width: bounds.width,
            height: max(underlineHeight * 2, 6)
        )
        let underline = PDFAnnotation(bounds: underlineBounds, forType: .line, withProperties: nil)
        let underlineBorder = PDFBorder()
        underlineBorder.lineWidth = underlineHeight

        underline.border = underlineBorder
        underline.color = UIColor(red: 0.06, green: 0.52, blue: 0.98, alpha: 1)
        underline.startPoint = CGPoint(x: 0, y: underlineHeight)
        underline.endPoint = CGPoint(x: underlineBounds.width, y: underlineHeight)
        underline.startLineStyle = .none
        underline.endLineStyle = .none
        underline.userName = linkMetadataUserName(url: url, bounds: bounds)

        let tapTarget = PDFAnnotation(bounds: bounds, forType: .link, withProperties: nil)
        let tapBorder = PDFBorder()
        tapBorder.lineWidth = 0

        tapTarget.border = tapBorder
        tapTarget.color = .clear
        tapTarget.url = url
        tapTarget.contents = visibleText
        tapTarget.userName = linkMetadataUserName(url: url, bounds: bounds)

        if includesVisibleLabel {
            let visibleLabel = PDFAnnotation(bounds: bounds, forType: .freeText, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 0

            visibleLabel.border = border
            visibleLabel.color = UIColor.clear
            visibleLabel.font = UIFont.systemFont(ofSize: 15, weight: .semibold)
            visibleLabel.fontColor = UIColor(red: 0.06, green: 0.52, blue: 0.98, alpha: 1)
            visibleLabel.alignment = .left
            visibleLabel.contents = visibleText
            visibleLabel.userName = linkMetadataUserName(url: url, bounds: bounds)
            entries.append((page: page, annotation: visibleLabel))
        }

        entries.append((page: page, annotation: underline))
        entries.append((page: page, annotation: tapTarget))
        return entries
    }

    private func addCircleAnnotation(on page: PDFPage, at point: CGPoint) {
        let annotation = PDFAnnotation(
            bounds: centeredRect(at: point, on: page, size: CGSize(width: shapeSize, height: shapeSize)),
            forType: .circle,
            withProperties: nil
        )
        let border = PDFBorder()
        border.lineWidth = strokeWidth

        annotation.border = border
        annotation.color = drawingUIColor
        annotation.interiorColor = .clear
        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    private func addSquareAnnotation(on page: PDFPage, at point: CGPoint) {
        let annotation = PDFAnnotation(
            bounds: centeredRect(at: point, on: page, size: CGSize(width: shapeSize, height: shapeSize)),
            forType: .square,
            withProperties: nil
        )
        let border = PDFBorder()
        border.lineWidth = strokeWidth

        annotation.border = border
        annotation.color = drawingUIColor
        annotation.interiorColor = .clear
        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    private func addArrowAnnotation(on page: PDFPage, at point: CGPoint) {
        let arrowWidth = max(shapeSize * 1.4, 96)
        let arrowHeight = max(shapeSize * 0.36, 40)
        let bounds = centeredRect(at: point, on: page, size: CGSize(width: arrowWidth, height: arrowHeight))
        let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
        let border = PDFBorder()
        border.lineWidth = strokeWidth

        annotation.border = border
        annotation.color = drawingUIColor
        annotation.startPoint = CGPoint(x: 12, y: bounds.height * 0.5)
        annotation.endPoint = CGPoint(x: bounds.width - 18, y: bounds.height * 0.5)
        annotation.startLineStyle = .none
        annotation.endLineStyle = .closedArrow
        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    private func addStampAnnotation(on page: PDFPage, at point: CGPoint) {
        let annotation = PDFAnnotation(
            bounds: centeredRect(at: point, on: page, size: CGSize(width: 160, height: 70)),
            forType: .stamp,
            withProperties: nil
        )
        annotation.stampName = "Approved"
        annotation.color = UIColor.systemGreen
        addAnnotations([(page: page, annotation: annotation)])
        finishDocumentMutation()
    }

    private func addAnnotations(_ entries: [(page: PDFPage, annotation: PDFAnnotation)]) {
        guard !entries.isEmpty else {
            return
        }

        for entry in entries {
            entry.page.addAnnotation(entry.annotation)
        }

        registerMutation(.added, entries: entries)
    }

    private func centeredRect(at point: CGPoint, on page: PDFPage, size: CGSize) -> CGRect {
        let pageBounds = page.bounds(for: .mediaBox)
        let minX = pageBounds.minX
        let minY = pageBounds.minY
        let maxX = pageBounds.maxX - size.width
        let maxY = pageBounds.maxY - size.height

        let originX = min(max(point.x - (size.width / 2), minX), maxX)
        let originY = min(max(point.y - (size.height / 2), minY), maxY)

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }

    private func linkLabelSize(for text: String) -> CGSize {
        let font = UIFont.systemFont(ofSize: 15, weight: .semibold)
        let width = max(80, min(240, (text as NSString).size(withAttributes: [.font: font]).width + 24))
        return CGSize(width: width, height: 28)
    }

    private func visualAnnotation(for markupType: PDFMarkupType, bounds: CGRect) -> PDFAnnotation? {
        switch markupType {
        case .highlight:
            let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
            annotation.color = markupUIColor(for: markupType)
            annotation.quadrilateralPoints = highlightQuadPoints(for: bounds)
            annotation.userName = markupMetadataUserName(for: markupType, bounds: bounds)
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            return annotation

        case .underline:
            let lineHeight = max(strokeWidth * 0.45, 2)
            let annotationBounds = CGRect(
                x: bounds.minX,
                y: bounds.minY - (lineHeight * 0.25),
                width: bounds.width,
                height: max(lineHeight * 2, 6)
            )
            let annotation = PDFAnnotation(bounds: annotationBounds, forType: .line, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = max(strokeWidth * 0.5, 2)

            annotation.border = border
            annotation.color = markupUIColor(for: markupType)
            annotation.startPoint = CGPoint(x: 0, y: lineHeight)
            annotation.endPoint = CGPoint(x: annotationBounds.width, y: lineHeight)
            annotation.startLineStyle = .none
            annotation.endLineStyle = .none
            annotation.userName = markupMetadataUserName(for: markupType, bounds: bounds)
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            return annotation

        case .strikeOut:
            let annotation = PDFAnnotation(bounds: bounds, forType: .line, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = max(strokeWidth * 0.5, 2)

            annotation.border = border
            annotation.color = markupUIColor(for: markupType)
            annotation.startPoint = CGPoint(x: 0, y: bounds.height * 0.55)
            annotation.endPoint = CGPoint(x: bounds.width, y: bounds.height * 0.55)
            annotation.startLineStyle = .none
            annotation.endLineStyle = .none
            annotation.userName = markupMetadataUserName(for: markupType, bounds: bounds)
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            return annotation

        case .redact:
            let annotation = PDFAnnotation(bounds: bounds, forType: .square, withProperties: nil)
            let border = PDFBorder()
            border.lineWidth = 0

            annotation.border = border
            annotation.color = UIColor.clear
            annotation.interiorColor = markupUIColor(for: markupType).withAlphaComponent(0.96)
            annotation.userName = markupMetadataUserName(for: markupType, bounds: bounds)
            annotation.shouldDisplay = true
            annotation.shouldPrint = true
            return annotation

        @unknown default:
            return nil
        }
    }

    private func highlightQuadPoints(for bounds: CGRect) -> [NSValue] {
        [
            NSValue(cgPoint: CGPoint(x: 0, y: bounds.height)),
            NSValue(cgPoint: CGPoint(x: bounds.width, y: bounds.height)),
            NSValue(cgPoint: CGPoint(x: 0, y: 0)),
            NSValue(cgPoint: CGPoint(x: bounds.width, y: 0))
        ]
    }

    private func preciseMarkupSelection(on page: PDFPage, at point: CGPoint) -> PDFSelection? {
        let index = page.characterIndex(at: point)

        if index != NSNotFound,
           let pageString = page.string,
           let wordRange = wordRange(in: pageString, around: index),
           let wordSelection = page.selection(for: wordRange) {
            return wordSelection
        }

        if index != NSNotFound, let characterSelection = page.selection(for: NSRange(location: index, length: 1)) {
            return characterSelection
        }

        return page.selectionForWord(at: point)
    }

    private func wordRange(in text: String, around index: Int) -> NSRange? {
        let nsText = text as NSString
        guard nsText.length > 0, index >= 0, index < nsText.length else {
            return nil
        }

        if isWordBoundary(nsText.character(at: index)) {
            return nil
        }

        var start = index
        var end = index

        while start > 0 {
            let previous = nsText.character(at: start - 1)
            if isWordBoundary(previous) {
                break
            }
            start -= 1
        }

        while end < nsText.length {
            let current = nsText.character(at: end)
            if isWordBoundary(current) {
                break
            }
            end += 1
        }

        guard end > start else {
            return nil
        }

        return NSRange(location: start, length: end - start)
    }

    private func isWordBoundary(_ codeUnit: unichar) -> Bool {
        guard let scalar = UnicodeScalar(codeUnit) else {
            return true
        }

        if CharacterSet.alphanumerics.contains(scalar) {
            return false
        }

        return scalar != "_"
    }

    private func noteAnnotation(near point: CGPoint, on page: PDFPage) -> PDFAnnotation? {
        if let directHit = page.annotation(at: point), isCommentAnnotation(directHit) {
            return directHit
        }

        let hitRect = CGRect(x: point.x - 16, y: point.y - 16, width: 32, height: 32)

        return page.annotations
            .filter { annotation in
                isCommentAnnotation(annotation) &&
                annotation.bounds.insetBy(dx: -14, dy: -14).intersects(hitRect)
            }
            .min { left, right in
                distanceSquared(from: point, to: left.bounds.center) < distanceSquared(from: point, to: right.bounds.center)
            }
    }

    private func isCommentAnnotation(_ annotation: PDFAnnotation) -> Bool {
        if let userName = annotation.userName, userName.hasPrefix(Self.commentUserNamePrefix) {
            return true
        }

        return annotation.type == PDFAnnotationSubtype.text.rawValue &&
            !(annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func notePreview(for annotation: PDFAnnotation) -> NotePreview? {
        guard isCommentAnnotation(annotation) else {
            return nil
        }

        guard let contents = annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines),
              !contents.isEmpty else {
            return nil
        }

        return NotePreview(
            author: commentAuthor(for: annotation),
            timestamp: formattedTimestamp(for: annotation.modificationDate),
            pageLabel: annotation.page.map { "Page \($0.label ?? "")" } ?? "",
            message: contents
        )
    }

    private func commentAuthor(for annotation: PDFAnnotation) -> String {
        if let userName = annotation.userName,
           userName.hasPrefix(Self.commentUserNamePrefix) {
            let author = String(userName.dropFirst(Self.commentUserNamePrefix.count))
            return author.isEmpty ? "You" : author
        }

        let legacyAuthor = annotation.userName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return legacyAuthor.isEmpty ? "You" : legacyAuthor
    }

    private func distanceSquared(from point: CGPoint, to other: CGPoint) -> CGFloat {
        let dx = point.x - other.x
        let dy = point.y - other.y
        return (dx * dx) + (dy * dy)
    }

    private func selectElement(_ annotation: PDFAnnotation) {
        if hasTextSelection {
            clearTextSelection()
        }

        inlineSelectionViewRect = nil

        guard let page = annotation.page else {
            selectedElement = nil
            return
        }

        selectedElement = SelectedPDFElement(page: page, annotation: annotation)
    }

    private func selectedElementMatches(_ annotation: PDFAnnotation) -> Bool {
        guard let selectedElement else {
            return false
        }

        if selectedElement.annotation === annotation {
            return true
        }

        return annotationGroupingKey(for: selectedElement.annotation) == annotationGroupingKey(for: annotation)
    }

    private func performDefaultAnnotationActivation(_ annotation: PDFAnnotation) -> Bool {
        if let url = resolvedURL(for: annotation) {
            pendingExternalURL = url
            return true
        }

        if let notePreview = notePreview(for: annotation) {
            presentedNotePreview = notePreview
            return true
        }

        return false
    }

    private func resolvedURL(for annotation: PDFAnnotation) -> URL? {
        // Links come from untrusted PDFs, so only web and mail links are opened.
        if let url = annotation.url {
            return Self.validatedLinkURL(url.absoluteString)
        }

        guard let userName = annotation.userName, userName.hasPrefix("link:") else {
            return nil
        }

        let payload = String(userName.dropFirst(5))
        let urlString = payload.split(separator: "|", maxSplits: 1).first.map(String.init) ?? payload
        return Self.validatedLinkURL(urlString)
    }

    /// Accepts only absolute http(s) URLs with a host, or mailto URLs with an address.
    /// Rejects relative input such as `example.com`, the bare `https://` default, and
    /// schemes such as file:, tel:, or app-specific schemes.
    static func validatedLinkURL(_ string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed), let scheme = url.scheme?.lowercased() else {
            return nil
        }

        switch scheme {
        case "http", "https":
            guard let host = url.host, !host.isEmpty else { return nil }
            return url
        case "mailto":
            return url.absoluteString.count > "mailto:".count ? url : nil
        default:
            return nil
        }
    }

    var isPendingLinkURLValid: Bool {
        Self.validatedLinkURL(linkURLString) != nil
    }

    private func annotationEntries(for annotation: PDFAnnotation) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        guard let page = annotation.page else {
            return []
        }

        let groupingKey = annotationGroupingKey(for: annotation)
        return page.annotations.compactMap { candidate in
            if candidate === annotation || annotationGroupingKey(for: candidate) == groupingKey {
                return (page: page, annotation: candidate)
            }

            return nil
        }
    }

    private func annotationGroupingKey(for annotation: PDFAnnotation) -> String {
        if let userName = annotation.userName, userName.hasPrefix("link:") {
            return "link:\(userName)"
        }

        if let userName = annotation.userName, userName.hasPrefix(Self.markupUserNamePrefix) {
            return "markup:\(userName)"
        }

        return "object:\(ObjectIdentifier(annotation).hashValue)"
    }

    private func selectionHasAppliedAction(_ selection: PDFSelection, tool: AnnotationTool) -> Bool {
        let selectionBounds = selectionBounds(for: selection, splitWords: tool != .link)
        guard !selectionBounds.isEmpty else {
            return false
        }

        let matchingEntries = annotationsForSelectionAction(selectionBounds: selectionBounds, tool: tool)
        guard !matchingEntries.isEmpty else {
            return false
        }

        return selectionBounds.allSatisfy { target in
            matchingEntries.contains { entry in
                entry.page == target.page &&
                entry.annotation.bounds.intersects(target.bounds.insetBy(dx: -4, dy: -4))
            }
        }
    }

    private func removeSelectionAction(_ selection: PDFSelection, tool: AnnotationTool) {
        let selectionBounds = selectionBounds(for: selection, splitWords: tool != .link)
        let entries = annotationsForSelectionAction(selectionBounds: selectionBounds, tool: tool)
        guard !entries.isEmpty else {
            return
        }

        for entry in entries {
            if entry.page.annotations.contains(where: { $0 === entry.annotation }) {
                entry.page.removeAnnotation(entry.annotation)
            }
        }

        registerMutation(.removed, entries: entries)
        finishDocumentMutation()
    }

    private func selectionBounds(for selection: PDFSelection, splitWords: Bool) -> [(page: PDFPage, bounds: CGRect)] {
        let lineSelections = selection.selectionsByLine()
        let selections = lineSelections.isEmpty ? [selection] : lineSelections

        return selections.flatMap { lineSelection in
            lineSelection.pages.flatMap { page in
                if splitWords {
                    let wordBounds = wordBounds(for: lineSelection, on: page)
                    if !wordBounds.isEmpty {
                        return wordBounds.map { (page: page, bounds: $0) }
                    }
                }

                let bounds = lineSelection.bounds(for: page).insetBy(dx: -2, dy: -2)
                guard !bounds.isNull, !bounds.isEmpty else {
                    return []
                }

                return [(page: page, bounds: bounds)]
            }
        }
    }

    private func annotationsForSelectionAction(
        selectionBounds: [(page: PDFPage, bounds: CGRect)],
        tool: AnnotationTool
    ) -> [(page: PDFPage, annotation: PDFAnnotation)] {
        var matches: [(page: PDFPage, annotation: PDFAnnotation)] = []

        for target in selectionBounds {
            for annotation in target.page.annotations where annotationMatchesSelectionAction(annotation, tool: tool) {
                if selectionActionBoundsMatch(annotation: annotation, targetBounds: target.bounds),
                   !matches.contains(where: { $0.page == target.page && $0.annotation === annotation }) {
                    matches.append((page: target.page, annotation: annotation))
                }
            }
        }

        return matches
    }

    private func annotationMatchesSelectionAction(_ annotation: PDFAnnotation, tool: AnnotationTool) -> Bool {
        if tool == .link {
            return resolvedURL(for: annotation) != nil
        }

        guard let markupType = tool.markupType else {
            return false
        }

        return annotation.userName?.hasPrefix(markupUserName(for: markupType)) == true
    }

    private func markupUserName(for markupType: PDFMarkupType) -> String {
        switch markupType {
        case .highlight:
            return Self.markupUserNamePrefix + "highlight"
        case .underline:
            return Self.markupUserNamePrefix + "underline"
        case .strikeOut:
            return Self.markupUserNamePrefix + "strike"
        case .redact:
            return Self.markupUserNamePrefix + "redact"
        @unknown default:
            return Self.markupUserNamePrefix + "unknown"
        }
    }

    private func markupMetadataUserName(for markupType: PDFMarkupType, bounds: CGRect) -> String {
        markupUserName(for: markupType) + "|" + serializedBounds(bounds)
    }

    private func linkMetadataUserName(url: URL, bounds: CGRect) -> String {
        "link:\(url.absoluteString)|\(serializedBounds(bounds))"
    }

    private func serializedBounds(_ bounds: CGRect) -> String {
        let rounded = bounds.standardized.integral.insetBy(dx: 0, dy: 0)
        return [rounded.minX, rounded.minY, rounded.width, rounded.height]
            .map { String(format: "%.2f", $0) }
            .joined(separator: ",")
    }

    private func decodedBounds(from userName: String?) -> CGRect? {
        guard let userName, let serialized = userName.split(separator: "|", maxSplits: 1).last, serialized.contains(",") else {
            return nil
        }

        let values = serialized.split(separator: ",").compactMap { Double($0) }
        guard values.count == 4 else {
            return nil
        }

        return CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
    }

    private func selectionActionBoundsMatch(annotation: PDFAnnotation, targetBounds: CGRect) -> Bool {
        let candidateBounds = decodedBounds(from: annotation.userName) ?? annotation.bounds
        let expandedCandidate = candidateBounds.insetBy(dx: -1.5, dy: -1.5)
        let expandedTarget = targetBounds.insetBy(dx: -1.5, dy: -1.5)

        let centerDelta = distanceSquared(from: expandedCandidate.center, to: expandedTarget.center)
        let intersection = expandedCandidate.intersection(expandedTarget)

        guard !intersection.isNull, !intersection.isEmpty else {
            return centerDelta < 9
        }

        let overlapRatio = (intersection.width * intersection.height) / max(expandedTarget.width * expandedTarget.height, 1)
        return overlapRatio > 0.65 || centerDelta < 9
    }

    private func wordBounds(for selection: PDFSelection, on page: PDFPage) -> [CGRect] {
        guard let range = exactRange(for: selection, on: page) else {
            return []
        }

        let ranges = wordRanges(in: page, limitedTo: range)
        guard !ranges.isEmpty else {
            return []
        }

        let rawBounds: [CGRect] = ranges.compactMap { (wordRange: NSRange) -> CGRect? in
            guard let wordSelection = page.selection(for: wordRange) else {
                return nil
            }

            let bounds = wordSelection.bounds(for: page).standardized
            guard !bounds.isNull, !bounds.isEmpty else {
                return nil
            }

            return bounds
        }

        return mergedMarkupBounds(from: rawBounds)
    }

    private func mergedMarkupBounds(from bounds: [CGRect]) -> [CGRect] {
        let sortedBounds = bounds
            .map(\.standardized)
            .filter { !$0.isNull && !$0.isEmpty }
            .sorted { lhs, rhs in
                if abs(lhs.midY - rhs.midY) > max(lhs.height, rhs.height) * 0.35 {
                    return lhs.midY > rhs.midY
                }

                return lhs.minX < rhs.minX
            }

        guard var current = sortedBounds.first?.insetBy(dx: -0.8, dy: -1.2) else {
            return []
        }

        var merged: [CGRect] = []

        for candidate in sortedBounds.dropFirst() {
            let expandedCandidate = candidate.insetBy(dx: -0.8, dy: -1.2)
            if shouldMergeMarkupBounds(current, expandedCandidate) {
                current = current.union(expandedCandidate)
            } else {
                merged.append(current)
                current = expandedCandidate
            }
        }

        merged.append(current)
        return merged
    }

    private func shouldMergeMarkupBounds(_ current: CGRect, _ candidate: CGRect) -> Bool {
        let verticalIntersection = current.intersection(candidate).height
        let minimumLineHeight = min(current.height, candidate.height)
        let isSameLine =
            verticalIntersection >= minimumLineHeight * 0.55 ||
            abs(current.midY - candidate.midY) <= max(current.height, candidate.height) * 0.4

        guard isSameLine else {
            return false
        }

        let horizontalGap = candidate.minX - current.maxX
        return horizontalGap <= max(max(current.height, candidate.height) * 0.9, 6)
    }

    private func exactRange(for selection: PDFSelection, on page: PDFPage) -> NSRange? {
        guard let selectedText = selection.string, !selectedText.isEmpty, let pageText = page.string else {
            return nil
        }

        let pageNSString = pageText as NSString
        let targetBounds = selection.bounds(for: page)
        guard !targetBounds.isNull, !targetBounds.isEmpty else {
            return nil
        }

        var searchRange = NSRange(location: 0, length: pageNSString.length)
        var bestMatch: (range: NSRange, score: CGFloat)?

        while true {
            let foundRange = pageNSString.range(of: selectedText, options: [], range: searchRange)
            if foundRange.location == NSNotFound {
                break
            }

            if let candidateSelection = page.selection(for: foundRange) {
                let candidateBounds = candidateSelection.bounds(for: page)
                if !candidateBounds.isNull, !candidateBounds.isEmpty {
                    let score = distanceSquared(from: targetBounds.center, to: candidateBounds.center)
                    if bestMatch == nil || score < bestMatch?.score ?? .greatestFiniteMagnitude {
                        bestMatch = (range: foundRange, score: score)
                    }
                }
            }

            let nextLocation = foundRange.location + max(foundRange.length, 1)
            if nextLocation >= pageNSString.length {
                break
            }
            searchRange = NSRange(location: nextLocation, length: pageNSString.length - nextLocation)
        }

        return bestMatch?.range
    }

    private func wordRanges(in page: PDFPage, limitedTo selectionRange: NSRange) -> [NSRange] {
        guard let pageText = page.string else {
            return []
        }

        return Self.wordRanges(in: pageText as NSString, limitedTo: selectionRange)
    }

    /// Splits `selectionRange` of `nsText` into whitespace-separated UTF-16 word ranges.
    static func wordRanges(in nsText: NSString, limitedTo selectionRange: NSRange) -> [NSRange] {
        guard selectionRange.location != NSNotFound, NSMaxRange(selectionRange) <= nsText.length else {
            return []
        }

        let whitespace = CharacterSet.whitespacesAndNewlines
        var ranges: [NSRange] = []
        var index = selectionRange.location
        let endIndex = NSMaxRange(selectionRange)

        // UTF-16 surrogate halves have no UnicodeScalar; treat them as word characters so
        // the loops always advance (emoji and other non-BMP text would otherwise hang here).
        func isWhitespace(at index: Int) -> Bool {
            UnicodeScalar(nsText.character(at: index)).map(whitespace.contains) ?? false
        }

        while index < endIndex {
            while index < endIndex, isWhitespace(at: index) {
                index += 1
            }

            let start = index

            while index < endIndex, !isWhitespace(at: index) {
                index += 1
            }

            if index > start {
                ranges.append(NSRange(location: start, length: index - start))
            }
        }

        return ranges
    }

    private var noteUIColor: UIColor {
        notePalette.uiColor
    }

    private var textUIColor: UIColor {
        textPalette.uiColor
    }

    private func markupUIColor(for markupType: PDFMarkupType) -> UIColor {
        switch markupType {
        case .highlight:
            let opacity = CGFloat(min(max(highlightOpacity, 0.18), 0.8))
            return highlightPalette.uiColor.withAlphaComponent(opacity)
        case .underline, .strikeOut:
            return highlightPalette.uiColor
        case .redact:
            return .black
        @unknown default:
            return highlightPalette.uiColor
        }
    }

    private func palette(for role: AnnotationColorRole) -> AnnotationColorPalette {
        switch role {
        case .drawing:
            return drawingPalette
        case .highlight:
            return highlightPalette
        case .text:
            return textPalette
        case .note:
            return notePalette
        }
    }

    private func updatePalette(
        for role: AnnotationColorRole,
        transform: (AnnotationColorPalette) -> AnnotationColorPalette
    ) {
        switch role {
        case .drawing:
            drawingPalette = transform(drawingPalette)
        case .highlight:
            highlightPalette = transform(highlightPalette)
        case .text:
            textPalette = transform(textPalette)
        case .note:
            notePalette = transform(notePalette)
        }
    }

    private func clearTextSelection() {
        pendingSelectionAutoApplyWorkItem?.cancel()
        pendingSelectionAutoApplyWorkItem = nil
        selectionAutoApplyToken += 1
        currentTextSelection = nil
        hasTextSelection = false
        selectionClearRequestID = UUID()
    }

    private func formattedTimestamp(for date: Date?) -> String {
        guard let date else {
            return "Just now"
        }

        return Self.relativeDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    private func registerMutation(_ kind: AnnotationMutation.Kind, entries: [(page: PDFPage, annotation: PDFAnnotation)]) {
        guard !entries.isEmpty else {
            return
        }

        undoStack.append(AnnotationMutation(kind: kind, entries: entries))
        canUndo = true
        hasUnexportedChanges = true
    }

    private func finishDocumentMutation() {
        if let selectedElement,
           selectedElement.page.annotations.contains(where: { $0 === selectedElement.annotation }) == false {
            self.selectedElement = nil
        }
        annotationRefreshID = UUID()
        objectWillChange.send()
    }

    private static let relativeDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

private extension CGRect {
    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
