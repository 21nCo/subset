import PDFKit
import SwiftUI
import UIKit

struct PDFAnnotatorView: UIViewRepresentable {
    let document: PDFDocument
    let selectedTool: AnnotationTool?
    let linkPlacementMode: Bool
    let shapeDraft: PendingShapeDraft?
    let inkColor: UIColor
    let lineWidth: CGFloat
    let shapeSize: CGFloat
    let navigationRequest: PDFNavigationRequest?
    let annotationRefreshID: UUID
    let selectionClearRequestID: UUID
    let zoomRequest: PDFZoomRequest?
    let onPageTap: (PDFPage, CGPoint) -> Void
    let onAnnotationTap: (PDFAnnotation) -> Void
    let onAnnotationTapAtPoint: (PDFPage, CGPoint) -> Bool
    let onShapeDraftMoved: (PDFPage, CGPoint) -> Void
    let onTextSelectionChanged: (PDFSelection?) -> Void
    let onTextSelectionAnchorChanged: (CGRect?) -> Void
    let onZoomScaleChanged: (PDFZoomState) -> Void
    let onInkStrokeCommitted: (PDFPage, [CGPoint]) -> Void
    let onCurrentPageChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> AnnotatablePDFContainerView {
        let view = AnnotatablePDFContainerView()
        view.onPageTap = onPageTap
        view.onAnnotationTap = onAnnotationTap
        view.onAnnotationTapAtPoint = onAnnotationTapAtPoint
        view.onShapeDraftMoved = onShapeDraftMoved
        view.onTextSelectionChanged = onTextSelectionChanged
        view.onTextSelectionAnchorChanged = onTextSelectionAnchorChanged
        view.onZoomScaleChanged = onZoomScaleChanged
        view.onInkStrokeCommitted = onInkStrokeCommitted
        view.onCurrentPageChanged = onCurrentPageChanged
        view.setDocument(document)
        view.updateInteraction(
            selectedTool: selectedTool,
            linkPlacementMode: linkPlacementMode,
            shapeDraft: shapeDraft,
            inkColor: inkColor,
            lineWidth: lineWidth,
            shapeSize: shapeSize
        )
        return view
    }

    func updateUIView(_ uiView: AnnotatablePDFContainerView, context: Context) {
        uiView.onPageTap = onPageTap
        uiView.onAnnotationTap = onAnnotationTap
        uiView.onAnnotationTapAtPoint = onAnnotationTapAtPoint
        uiView.onShapeDraftMoved = onShapeDraftMoved
        uiView.onTextSelectionChanged = onTextSelectionChanged
        uiView.onTextSelectionAnchorChanged = onTextSelectionAnchorChanged
        uiView.onZoomScaleChanged = onZoomScaleChanged
        uiView.onInkStrokeCommitted = onInkStrokeCommitted
        uiView.onCurrentPageChanged = onCurrentPageChanged
        uiView.setDocument(document)
        uiView.updateInteraction(
            selectedTool: selectedTool,
            linkPlacementMode: linkPlacementMode,
            shapeDraft: shapeDraft,
            inkColor: inkColor,
            lineWidth: lineWidth,
            shapeSize: shapeSize
        )
        uiView.refreshAnnotations(trigger: annotationRefreshID)

        if context.coordinator.lastNavigationRequestID != navigationRequest?.id {
            uiView.navigate(using: navigationRequest)
            context.coordinator.lastNavigationRequestID = navigationRequest?.id
        }

        if context.coordinator.lastSelectionClearRequestID != selectionClearRequestID {
            uiView.clearTextSelection()
            context.coordinator.lastSelectionClearRequestID = selectionClearRequestID
        }

        if context.coordinator.lastZoomRequestID != zoomRequest?.id {
            uiView.handleZoomRequest(zoomRequest)
            context.coordinator.lastZoomRequestID = zoomRequest?.id
        }
    }

    final class Coordinator {
        var lastNavigationRequestID: UUID?
        var lastSelectionClearRequestID: UUID?
        var lastZoomRequestID: UUID?
    }
}

final class AnnotatablePDFContainerView: UIView {
    let pdfView = PDFView()
    let overlayView = AnnotationGestureOverlayView()

    var onPageTap: ((PDFPage, CGPoint) -> Void)? {
        didSet {
            overlayView.onPageTap = onPageTap
        }
    }

    var onAnnotationTap: ((PDFAnnotation) -> Void)?
    var onAnnotationTapAtPoint: ((PDFPage, CGPoint) -> Bool)? {
        didSet {
            overlayView.onAnnotationTapAtPoint = onAnnotationTapAtPoint
        }
    }
    var onShapeDraftMoved: ((PDFPage, CGPoint) -> Void)?
    var onTextSelectionChanged: ((PDFSelection?) -> Void)?
    var onTextSelectionAnchorChanged: ((CGRect?) -> Void)?
    var onZoomScaleChanged: ((PDFZoomState) -> Void)?

    var onInkStrokeCommitted: ((PDFPage, [CGPoint]) -> Void)? {
        didSet {
            overlayView.onInkStrokeCommitted = onInkStrokeCommitted
        }
    }

    var onCurrentPageChanged: ((Int) -> Void)?

    private var pageChangedObserver: NSObjectProtocol?
    private var selectionChangedObserver: NSObjectProtocol?
    private var scaleChangedObserver: NSObjectProtocol?
    private var lastRefreshTrigger: UUID?
    private var pointTool: AnnotationTool?
    private var pendingShapeDraft: PendingShapeDraft?
    private var referencePageBounds: CGRect = .zero
    private var lastKnownFitScale: CGFloat = 1
    private var zoomRatioToFit: CGFloat = 1
    private var zoomMode: ViewerZoomMode = .fit
    private lazy var annotationTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handleAnnotationTap(_:)))
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var pointToolTapRecognizer: UITapGestureRecognizer = {
        let recognizer = UITapGestureRecognizer(target: self, action: #selector(handlePointToolTap(_:)))
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var inkPanRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleInkGesture(_:)))
        recognizer.minimumNumberOfTouches = 1
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = true
        recognizer.delegate = self
        return recognizer
    }()
    private lazy var shapeDragRecognizer: UIPanGestureRecognizer = {
        let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handleShapeDrag(_:)))
        recognizer.maximumNumberOfTouches = 1
        recognizer.cancelsTouchesInView = false
        recognizer.delegate = self
        return recognizer
    }()
    private weak var pdfScrollView: UIScrollView?

    private enum ViewerZoomMode {
        case fit
        case manual
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    deinit {
        if let pageChangedObserver {
            NotificationCenter.default.removeObserver(pageChangedObserver)
        }
        if let selectionChangedObserver {
            NotificationCenter.default.removeObserver(selectionChangedObserver)
        }
        if let scaleChangedObserver {
            NotificationCenter.default.removeObserver(scaleChangedObserver)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        syncZoomRatioToCurrentScale()
        guard updateScaleBounds() else {
            return
        }

        applyScale(
            lastKnownFitScale * effectiveZoomRatio,
            preservingVisibleAnchor: true
        )
    }

    func setDocument(_ document: PDFDocument) {
        guard pdfView.document !== document else {
            return
        }

        pdfView.document = document
        referencePageBounds = resolvedReferencePageBounds(for: document)
        lastKnownFitScale = 1
        zoomRatioToFit = 1
        zoomMode = .fit
        pdfView.autoScales = false
        pdfView.goToFirstPage(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self else {
                return
            }

            guard self.updateScaleBounds() else {
                return
            }

            self.applyScale(self.lastKnownFitScale, preservingVisibleAnchor: false)
            self.reportCurrentPage()
            self.emitSelectionAnchor()
        }
    }

    func updateInteraction(
        selectedTool: AnnotationTool?,
        linkPlacementMode: Bool,
        shapeDraft: PendingShapeDraft?,
        inkColor: UIColor,
        lineWidth: CGFloat,
        shapeSize: CGFloat
    ) {
        if selectedTool == .link, linkPlacementMode {
            pointTool = .link
        } else {
            pointTool = selectedTool?.requiresPointInput == true ? selectedTool : nil
        }

        pendingShapeDraft = shapeDraft
        pointToolTapRecognizer.isEnabled = pointTool != nil
        inkPanRecognizer.isEnabled = selectedTool == .ink
        shapeDragRecognizer.isEnabled = shapeDraft != nil
        overlayView.selectedTool = selectedTool == .ink ? .ink : nil
        overlayView.isUserInteractionEnabled = false
        overlayView.shapeDraft = shapeDraft
        overlayView.inkColor = inkColor
        overlayView.lineWidth = lineWidth
        overlayView.shapeSize = shapeSize

        if selectedTool != .ink {
            setPDFScrollingEnabled(true)
            overlayView.cancelInkStroke()
        }
    }

    func navigate(using request: PDFNavigationRequest?) {
        guard let request else {
            return
        }

        if let destination = request.destination {
            pdfView.go(to: destination)
        } else if let pageIndex = request.pageIndex, let page = pdfView.document?.page(at: pageIndex) {
            pdfView.go(to: page)
        }

        reportCurrentPage()
    }

    func refreshAnnotations(trigger: UUID) {
        guard trigger != lastRefreshTrigger else {
            return
        }

        lastRefreshTrigger = trigger
        if let document = pdfView.document {
            for pageIndex in 0 ..< document.pageCount {
                if let page = document.page(at: pageIndex) {
                    pdfView.annotationsChanged(on: page)
                }
            }
        }
        pdfView.setNeedsDisplay()
        pdfView.layoutDocumentView()
    }

    func clearTextSelection() {
        pdfView.clearSelection()
        DispatchQueue.main.async { [weak self] in
            self?.onTextSelectionChanged?(nil)
            self?.onTextSelectionAnchorChanged?(nil)
        }
    }

    func handleZoomRequest(_ request: PDFZoomRequest?) {
        guard let request else {
            return
        }

        syncZoomRatioToCurrentScale()
        guard updateScaleBounds() else {
            return
        }

        switch request.command {
        case .zoomIn:
            zoomMode = .manual
            zoomRatioToFit = clampedZoomRatio(max(zoomRatioToFit, 1) * 1.2)
            applyScale(lastKnownFitScale * zoomRatioToFit, preservingVisibleAnchor: true)
        case .zoomOut:
            zoomMode = .manual
            zoomRatioToFit = clampedZoomRatio(zoomRatioToFit / 1.2)
            if abs(zoomRatioToFit - 1) < 0.02 {
                zoomMode = .fit
                zoomRatioToFit = 1
            }
            applyScale(lastKnownFitScale * effectiveZoomRatio, preservingVisibleAnchor: true)
        case .fit:
            zoomMode = .fit
            zoomRatioToFit = 1
            applyScale(lastKnownFitScale, preservingVisibleAnchor: true)
        }
    }

    private func configure() {
        backgroundColor = .secondarySystemBackground

        pdfView.translatesAutoresizingMaskIntoConstraints = false
        overlayView.translatesAutoresizingMaskIntoConstraints = false

        pdfView.displayMode = .singlePageContinuous
        pdfView.displayDirection = .vertical
        pdfView.displaysPageBreaks = true
        pdfView.usePageViewController(false)
        pdfView.autoScales = false
        pdfView.backgroundColor = .secondarySystemBackground
        pdfView.displayBox = .mediaBox
        pdfView.displaysAsBook = false
        pdfView.addGestureRecognizer(annotationTapRecognizer)
        pdfView.addGestureRecognizer(pointToolTapRecognizer)
        pdfView.addGestureRecognizer(inkPanRecognizer)
        pdfView.addGestureRecognizer(shapeDragRecognizer)

        overlayView.pdfView = pdfView

        addSubview(pdfView)
        addSubview(overlayView)

        NSLayoutConstraint.activate([
            pdfView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pdfView.topAnchor.constraint(equalTo: topAnchor),
            pdfView.bottomAnchor.constraint(equalTo: bottomAnchor),
            overlayView.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlayView.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlayView.topAnchor.constraint(equalTo: topAnchor),
            overlayView.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        pageChangedObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            self?.reportCurrentPage()
            self?.emitSelectionAnchor()
        }

        selectionChangedObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            self?.onTextSelectionChanged?(self?.pdfView.currentSelection)
            self?.emitSelectionAnchor()
        }

        scaleChangedObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged,
            object: pdfView,
            queue: .main
        ) { [weak self] _ in
            guard let self else {
                return
            }

            self.syncZoomRatioToCurrentScale()
            self.emitZoomState()
            self.emitSelectionAnchor()
        }
    }

    private var effectiveZoomRatio: CGFloat {
        zoomMode == .fit ? 1 : zoomRatioToFit
    }

    private func updateScaleBounds() -> Bool {
        guard let fitScale = fitScaleForCurrentLayout() else {
            return false
        }

        lastKnownFitScale = fitScale
        // Keep a 0.35 floor, but never above the fit scale, so large-format pages can still fit.
        pdfView.minScaleFactor = min(fitScale, max(fitScale * 0.75, 0.35))
        pdfView.maxScaleFactor = max(fitScale * 6, fitScale + 4)
        return true
    }

    private func fitScaleForCurrentLayout() -> CGFloat? {
        let targetBounds = referencePageBounds.isNull || referencePageBounds.isEmpty
            ? pdfView.document?.page(at: 0)?.bounds(for: pdfView.displayBox)
            : referencePageBounds

        guard let targetBounds, !targetBounds.isNull, !targetBounds.isEmpty else {
            return nil
        }

        let availableWidth = max(pdfView.bounds.width - 28, 1)
        let availableHeight = max(pdfView.bounds.height - 28, 1)
        let widthScale = availableWidth / targetBounds.width
        let heightScale = availableHeight / targetBounds.height
        let fitScale = min(widthScale, heightScale)

        guard fitScale.isFinite, fitScale > 0 else {
            return nil
        }

        return fitScale
    }

    private func applyScale(_ targetScale: CGFloat, preservingVisibleAnchor: Bool) {
        let clampedScale = min(max(targetScale, pdfView.minScaleFactor), pdfView.maxScaleFactor)
        let didAdjustScale = abs(pdfView.scaleFactor - clampedScale) > 0.001

        if didAdjustScale {
            pdfView.scaleFactor = clampedScale
            pdfView.layoutDocumentView()
        }

        syncZoomRatioToCurrentScale()
        emitZoomState()
        emitSelectionAnchor()
    }

    private func syncZoomRatioToCurrentScale() {
        guard lastKnownFitScale > 0, pdfView.scaleFactor > 0 else {
            return
        }

        let ratio = clampedZoomRatio(pdfView.scaleFactor / lastKnownFitScale)
        zoomRatioToFit = ratio
        zoomMode = abs(ratio - 1) < 0.02 ? .fit : .manual
    }

    private func clampedZoomRatio(_ ratio: CGFloat) -> CGFloat {
        min(max(ratio, 0.75), 6)
    }

    private func emitZoomState() {
        onZoomScaleChanged?(
            PDFZoomState(
                scaleFactor: max(pdfView.scaleFactor, 0.0001),
                fitScaleFactor: max(lastKnownFitScale, 0.0001)
            )
        )
    }

    private func emitSelectionAnchor() {
        onTextSelectionAnchorChanged?(currentSelectionViewRect())
    }

    private func currentSelectionViewRect() -> CGRect? {
        guard let selection = pdfView.currentSelection else {
            return nil
        }

        let preferredPages = preferredSelectionPages(for: selection)

        for page in preferredPages {
            let pageBounds = selection.bounds(for: page)
            guard !pageBounds.isNull, !pageBounds.isEmpty else {
                continue
            }

            let viewRect = pdfView.convert(pageBounds, from: page).standardized
            guard !viewRect.isNull, !viewRect.isEmpty else {
                continue
            }

            return viewRect.insetBy(dx: -4, dy: -2)
        }

        return nil
    }

    private func preferredSelectionPages(for selection: PDFSelection) -> [PDFPage] {
        let pages = selection.pages
        guard let currentPage = pdfView.currentPage else {
            return pages
        }

        if pages.contains(currentPage) {
            return [currentPage] + pages.filter { $0 != currentPage }
        }

        return pages
    }

    private func resolvedReferencePageBounds(for document: PDFDocument) -> CGRect {
        var maxWidth: CGFloat = 0
        var maxHeight: CGFloat = 0

        for index in 0 ..< document.pageCount {
            guard let page = document.page(at: index) else {
                continue
            }

            let bounds = page.bounds(for: pdfView.displayBox).standardized
            maxWidth = max(maxWidth, bounds.width)
            maxHeight = max(maxHeight, bounds.height)
        }

        guard maxWidth > 0, maxHeight > 0 else {
            return .zero
        }

        return CGRect(x: 0, y: 0, width: maxWidth, height: maxHeight)
    }

    private func reportCurrentPage() {
        guard let page = pdfView.currentPage, let document = pdfView.document else {
            return
        }

        onCurrentPageChanged?(document.index(for: page))
    }

    @objc
    private func handleAnnotationTap(_ gesture: UITapGestureRecognizer) {
        guard overlayView.selectedTool == nil, pointTool == nil else {
            return
        }

        let locationInPDFView = gesture.location(in: pdfView)

        guard
            let page = pdfView.page(for: locationInPDFView, nearest: true)
        else {
            return
        }

        let pagePoint = pdfView.convert(locationInPDFView, to: page)

        if let annotation = page.annotation(at: pagePoint) {
            onAnnotationTap?(annotation)
            return
        }

        if onAnnotationTapAtPoint?(page, pagePoint) == true {
            return
        }
    }

    @objc
    private func handlePointToolTap(_ gesture: UITapGestureRecognizer) {
        guard pointTool != nil else {
            return
        }

        let locationInPDFView = gesture.location(in: pdfView)

        guard let page = pdfView.page(for: locationInPDFView, nearest: true) else {
            return
        }

        let pagePoint = pdfView.convert(locationInPDFView, to: page)
        onPageTap?(page, pagePoint)
    }

    @objc
    private func handleInkGesture(_ gesture: UIPanGestureRecognizer) {
        guard overlayView.selectedTool == .ink else {
            return
        }

        let locationInPDFView = gesture.location(in: pdfView)
        let locationInOverlay = gesture.location(in: overlayView)

        switch gesture.state {
        case .began:
            guard overlayView.beginInkStroke(in: pdfView, viewPoint: locationInOverlay, pdfViewPoint: locationInPDFView) else {
                setPDFScrollingEnabled(true)
                return
            }

            setPDFScrollingEnabled(false)

        case .changed:
            overlayView.appendInkStroke(in: pdfView, viewPoint: locationInOverlay, pdfViewPoint: locationInPDFView)

        case .ended:
            overlayView.finishInkStroke()
            setPDFScrollingEnabled(true)

        case .cancelled, .failed:
            overlayView.cancelInkStroke()
            setPDFScrollingEnabled(true)

        default:
            break
        }
    }

    @objc
    private func handleShapeDrag(_ gesture: UIPanGestureRecognizer) {
        guard let pendingShapeDraft else {
            return
        }

        let locationInPDFView = gesture.location(in: pdfView)

        guard let page = pdfView.page(for: locationInPDFView, nearest: true), page == pendingShapeDraft.page else {
            return
        }

        let pagePoint = pdfView.convert(locationInPDFView, to: page)

        switch gesture.state {
        case .began, .changed:
            onShapeDraftMoved?(page, pagePoint)
        default:
            break
        }
    }

    private func setPDFScrollingEnabled(_ enabled: Bool) {
        if let scrollView = resolvedPDFScrollView() {
            scrollView.isScrollEnabled = enabled
        }
    }

    private func resolvedPDFScrollView() -> UIScrollView? {
        if let pdfScrollView, pdfScrollView.superview != nil {
            return pdfScrollView
        }

        let discoveredScrollView = findScrollView(in: pdfView)
        pdfScrollView = discoveredScrollView
        return discoveredScrollView
    }

    private func findScrollView(in view: UIView) -> UIScrollView? {
        if let scrollView = view as? UIScrollView {
            return scrollView
        }

        for subview in view.subviews {
            if let scrollView = findScrollView(in: subview) {
                return scrollView
            }
        }

        return nil
    }
}

extension AnnotatablePDFContainerView: UIGestureRecognizerDelegate {
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === pointToolTapRecognizer {
            return pointTool != nil
        }

        guard gestureRecognizer === annotationTapRecognizer else {
            return true
        }

        guard overlayView.selectedTool == nil, pointTool == nil else {
            return false
        }

        let locationInPDFView = touch.location(in: pdfView)
        guard let page = pdfView.page(for: locationInPDFView, nearest: true) else {
            return false
        }

        let pagePoint = pdfView.convert(locationInPDFView, to: page)
        return page.annotation(at: pagePoint) != nil
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === annotationTapRecognizer ||
            gestureRecognizer === pointToolTapRecognizer ||
            otherGestureRecognizer === annotationTapRecognizer ||
            otherGestureRecognizer === pointToolTapRecognizer {
            return false
        }

        return true
    }
}

final class AnnotationGestureOverlayView: UIView {
    weak var pdfView: PDFView?
    var onPageTap: ((PDFPage, CGPoint) -> Void)?
    var onInkStrokeCommitted: ((PDFPage, [CGPoint]) -> Void)?
    var onAnnotationTapAtPoint: ((PDFPage, CGPoint) -> Bool)?

    var selectedTool: AnnotationTool? {
        didSet {
            updateVisibility()

            if selectedTool != .ink {
                resetStroke()
            }

            redrawShapeDraft()
        }
    }

    var shapeDraft: PendingShapeDraft? {
        didSet {
            updateVisibility()
            redrawShapeDraft()
        }
    }

    var inkColor: UIColor = .systemRed {
        didSet {
            previewLayer.strokeColor = inkColor.cgColor
            shapePreviewLayer.strokeColor = inkColor.cgColor
            redrawShapeDraft()
        }
    }

    var lineWidth: CGFloat = 4 {
        didSet {
            previewLayer.lineWidth = lineWidth
            shapePreviewLayer.lineWidth = lineWidth
            redrawShapeDraft()
        }
    }

    var shapeSize: CGFloat = 120 {
        didSet {
            redrawShapeDraft()
        }
    }

    private let previewLayer = CAShapeLayer()
    private let shapePreviewLayer = CAShapeLayer()

    private var currentPage: PDFPage?
    private var viewPoints: [CGPoint] = []
    private var pagePoints: [CGPoint] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        configure()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer.frame = bounds
        shapePreviewLayer.frame = bounds
        redrawShapeDraft()
    }

    private func configure() {
        backgroundColor = .clear
        isOpaque = false
        isHidden = true
        isMultipleTouchEnabled = true

        previewLayer.strokeColor = inkColor.cgColor
        previewLayer.fillColor = UIColor.clear.cgColor
        previewLayer.lineWidth = lineWidth
        previewLayer.lineCap = .round
        previewLayer.lineJoin = .round

        shapePreviewLayer.strokeColor = inkColor.cgColor
        shapePreviewLayer.fillColor = UIColor.clear.cgColor
        shapePreviewLayer.lineWidth = lineWidth
        shapePreviewLayer.lineCap = .round
        shapePreviewLayer.lineJoin = .round
        shapePreviewLayer.lineDashPattern = [8, 6]

        layer.addSublayer(shapePreviewLayer)
        layer.addSublayer(previewLayer)
    }

    func beginInkStroke(in pdfView: PDFView, viewPoint: CGPoint, pdfViewPoint: CGPoint) -> Bool {
        guard let page = pdfView.page(for: pdfViewPoint, nearest: true) else {
            resetStroke()
            return false
        }

        currentPage = page
        viewPoints = [viewPoint]
        pagePoints = [pdfView.convert(pdfViewPoint, to: page)]
        redrawPreview()
        updateVisibility()
        return true
    }

    func appendInkStroke(in pdfView: PDFView, viewPoint: CGPoint, pdfViewPoint: CGPoint) {
        guard
            let currentPage,
            let page = pdfView.page(for: pdfViewPoint, nearest: true),
            page == currentPage
        else {
            return
        }

        viewPoints.append(viewPoint)
        pagePoints.append(pdfView.convert(pdfViewPoint, to: page))
        redrawPreview()
    }

    func finishInkStroke() {
        commitCurrentStroke()
    }

    func cancelInkStroke() {
        resetStroke()
    }

    private func commitCurrentStroke() {
        if let currentPage, pagePoints.count > 1 {
            onInkStrokeCommitted?(currentPage, pagePoints)
        }

        resetStroke()
    }

    private func redrawPreview() {
        let path = UIBezierPath()

        guard let firstPoint = viewPoints.first else {
            previewLayer.path = nil
            return
        }

        path.move(to: firstPoint)

        for point in viewPoints.dropFirst() {
            path.addLine(to: point)
        }

        previewLayer.path = path.cgPath
    }

    private func resetStroke() {
        currentPage = nil
        viewPoints.removeAll(keepingCapacity: true)
        pagePoints.removeAll(keepingCapacity: true)
        previewLayer.path = nil
        updateVisibility()
    }

    private func updateVisibility() {
        isHidden = selectedTool == nil && shapeDraft == nil && previewLayer.path == nil
    }

    private func redrawShapeDraft() {
        guard
            let pdfView,
            let shapeDraft
        else {
            shapePreviewLayer.path = nil
            return
        }

        let draftBounds = draftBounds(for: shapeDraft)
        let viewRect = pdfView.convert(draftBounds, from: shapeDraft.page)

        guard !viewRect.isNull, !viewRect.isEmpty else {
            shapePreviewLayer.path = nil
            return
        }

        let path = UIBezierPath()

        switch shapeDraft.tool {
        case .circle:
            path.append(UIBezierPath(ovalIn: viewRect))
            shapePreviewLayer.fillColor = inkColor.withAlphaComponent(0.08).cgColor
        case .square:
            path.append(UIBezierPath(rect: viewRect))
            shapePreviewLayer.fillColor = inkColor.withAlphaComponent(0.08).cgColor
        case .arrow:
            let midY = viewRect.midY
            path.move(to: CGPoint(x: viewRect.minX + 12, y: midY))
            path.addLine(to: CGPoint(x: viewRect.maxX - 18, y: midY))
            shapePreviewLayer.fillColor = UIColor.clear.cgColor
        default:
            shapePreviewLayer.path = nil
            return
        }

        shapePreviewLayer.strokeColor = inkColor.cgColor
        shapePreviewLayer.lineWidth = lineWidth
        shapePreviewLayer.path = path.cgPath
    }

    private func draftBounds(for draft: PendingShapeDraft) -> CGRect {
        let pageBounds = draft.page.bounds(for: .mediaBox)

        switch draft.tool {
        case .circle, .square:
            return centeredRect(
                at: draft.point,
                inside: pageBounds,
                size: CGSize(width: shapeSize, height: shapeSize)
            )
        case .arrow:
            let width = max(shapeSize * 1.4, 96)
            let height = max(shapeSize * 0.36, 40)
            return centeredRect(
                at: draft.point,
                inside: pageBounds,
                size: CGSize(width: width, height: height)
            )
        default:
            return .null
        }
    }

    private func centeredRect(at point: CGPoint, inside bounds: CGRect, size: CGSize) -> CGRect {
        let minX = bounds.minX
        let minY = bounds.minY
        let maxX = bounds.maxX - size.width
        let maxY = bounds.maxY - size.height

        let originX = min(max(point.x - (size.width / 2), minX), maxX)
        let originY = min(max(point.y - (size.height / 2), minY), maxY)

        return CGRect(origin: CGPoint(x: originX, y: originY), size: size)
    }
}
