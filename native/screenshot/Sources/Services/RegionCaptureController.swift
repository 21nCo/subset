import AppKit
import Foundation

@MainActor
final class RegionCaptureController {
    enum Mode {
        case area
        case window
        case scrolling
        case recording
        case text

        var instruction: String {
            switch self {
            case .area: "Drag to select capture area"
            case .window: "Click a window to capture it"
            case .scrolling: "Select only the scrollable content"
            case .recording: "Drag to select recording area"
            case .text: "Drag around the text to recognize"
            }
        }
    }

    private var panels: [NSPanel] = []
    private var completion: ((CGRect?) -> Void)?
    private let screenCaptureService: ScreenCaptureService

    init(screenCaptureService: ScreenCaptureService) {
        self.screenCaptureService = screenCaptureService
    }

    func select(mode: Mode, completion: @escaping (CGRect?) -> Void) {
        cancel()
        self.completion = completion

        for screen in NSScreen.screens {
            let panel = SelectionPanel(
                contentRect: screen.frame,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            panel.hasShadow = false
            panel.ignoresMouseEvents = false
            panel.hidesOnDeactivate = false

            let view = RegionSelectionView(mode: mode, instruction: mode.instruction)
            // A capture targets one display, so a window spanning displays is clipped to this one.
            let screenFrame = screen.frame
            view.resolveWindow = { [weak self] point in
                guard let rect = self?.screenCaptureService.windowRect(at: point)?.intersection(screenFrame),
                      !rect.isNull, !rect.isEmpty else { return nil }
                return rect
            }
            view.onComplete = { [weak self] rect in self?.finish(rect) }
            view.onCancel = { [weak self] in self?.finish(nil) }
            panel.contentView = view
            panels.append(panel)
            panel.orderFrontRegardless()
            panel.makeFirstResponder(view)
        }
        NSApp.activate(ignoringOtherApps: true)
        // Make the panel under the pointer key so Escape reaches its view.
        let pointer = NSEvent.mouseLocation
        (panels.first(where: { $0.frame.contains(pointer) }) ?? panels.first)?.makeKey()
    }

    func cancel() {
        panels.forEach { $0.orderOut(nil) }
        panels = []
        completion = nil
    }

    private func finish(_ rect: CGRect?) {
        let callback = completion
        panels.forEach { $0.orderOut(nil) }
        panels = []
        completion = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            callback?(rect)
        }
    }
}

/// Borderless windows cannot become key by default, which would keep Escape from cancelling.
private final class SelectionPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private final class RegionSelectionView: NSView {
    let mode: RegionCaptureController.Mode
    let instruction: String
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?
    var resolveWindow: ((CGPoint) -> CGRect?)?

    private var dragStart: CGPoint?
    private var currentPoint: CGPoint?
    private var snappedGlobalRect: CGRect?
    private var tracking: NSTrackingArea?

    init(mode: RegionCaptureController.Mode, instruction: String) {
        self.mode = mode
        self.instruction = instruction
        super.init(frame: .zero)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let next = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .inVisibleRect], owner: self)
        addTrackingArea(next)
        tracking = next
    }

    override func mouseMoved(with event: NSEvent) {
        guard mode == .window else { return }
        let global = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
        snappedGlobalRect = resolveWindow?(global)
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        if mode == .window {
            // Resolve at the click point: the pointer may not have moved since the overlay opened.
            let global = window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
            if let rect = resolveWindow?(global) { onComplete?(rect) }
            return
        }
        window?.makeKey()
        dragStart = event.locationInWindow
        currentPoint = event.locationInWindow
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        // One panel covers one display and a capture targets one display, so keep the
        // selection on the display where the drag started.
        let point = event.locationInWindow
        currentPoint = CGPoint(x: min(max(point.x, bounds.minX), bounds.maxX), y: min(max(point.y, bounds.minY), bounds.maxY))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let localRect = normalizedSelection, localRect.width >= 4, localRect.height >= 4 else { return }
        let origin = window?.convertPoint(toScreen: localRect.origin) ?? localRect.origin
        onComplete?(CGRect(origin: origin, size: localRect.size))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() }
        else { super.keyDown(with: event) }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.black.withAlphaComponent(0.52).setFill()
        bounds.fill()

        let selection: CGRect? = {
            if mode == .window, let snappedGlobalRect, let window {
                return CGRect(origin: window.convertPoint(fromScreen: snappedGlobalRect.origin), size: snappedGlobalRect.size)
            }
            return normalizedSelection
        }()

        if let selection {
            NSGraphicsContext.current?.saveGraphicsState()
            NSGraphicsContext.current?.compositingOperation = .clear
            selection.fill()
            NSGraphicsContext.current?.restoreGraphicsState()
            NSColor.white.withAlphaComponent(0.95).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: -0.5, dy: -0.5))
            border.lineWidth = 1
            border.stroke()
            drawDimensions(for: selection)
        }

        drawInstruction(selection: selection)
        if let mouse = window?.mouseLocationOutsideOfEventStream { drawCrosshair(at: mouse) }
    }

    private var normalizedSelection: CGRect? {
        guard let dragStart, let currentPoint else { return nil }
        return CGRect(
            x: min(dragStart.x, currentPoint.x),
            y: min(dragStart.y, currentPoint.y),
            width: abs(currentPoint.x - dragStart.x),
            height: abs(currentPoint.y - dragStart.y)
        )
    }

    private func drawInstruction(selection: CGRect?) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: instruction, attributes: attributes)
        let size = text.size()
        let x = selection.map { $0.midX - size.width / 2 } ?? bounds.midX - size.width / 2
        let y = selection.map { max(24, $0.minY - 44) } ?? bounds.midY - 18
        let bubble = CGRect(x: x - 14, y: y - 9, width: size.width + 28, height: size.height + 18)
        NSColor.black.withAlphaComponent(0.78).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 10, yRadius: 10).fill()
        text.draw(at: CGPoint(x: x, y: y))
    }

    private func drawDimensions(for rect: CGRect) {
        let value = "\(Int(rect.width)) × \(Int(rect.height))"
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let text = NSAttributedString(string: value, attributes: attributes)
        let size = text.size()
        let bubble = CGRect(x: rect.maxX - size.width - 12, y: rect.maxY + 7, width: size.width + 12, height: size.height + 6)
        NSColor.black.withAlphaComponent(0.76).setFill()
        NSBezierPath(roundedRect: bubble, xRadius: 5, yRadius: 5).fill()
        text.draw(at: CGPoint(x: bubble.minX + 6, y: bubble.minY + 3))
    }

    private func drawCrosshair(at point: CGPoint) {
        NSColor.white.withAlphaComponent(0.6).setStroke()
        let path = NSBezierPath()
        path.move(to: CGPoint(x: 0, y: point.y))
        path.line(to: CGPoint(x: bounds.maxX, y: point.y))
        path.move(to: CGPoint(x: point.x, y: 0))
        path.line(to: CGPoint(x: point.x, y: bounds.maxY))
        path.lineWidth = 0.5
        path.stroke()
    }
}
