import AppKit
import CoreImage
import Foundation
import SwiftUI

@MainActor
final class EditorSession: ObservableObject {
    @Published var image: NSImage {
        didSet { pixelatedCache = [:] }
    }
    @Published var annotations: [AnnotationItem] = []
    @Published var selectedTool: AnnotationTool = .arrow
    @Published var selectedColor: Color = .purple
    @Published var lineWidth: Double = 4
    @Published var textDraft = "Text"
    @Published var background = BackgroundConfiguration()
    @Published var selectedAnnotationID: UUID?
    @Published var zoom: Double = 1

    let record: CaptureRecord?
    private struct Snapshot {
        let image: NSImage
        let annotations: [AnnotationItem]
        let background: BackgroundConfiguration
    }
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var activeID: UUID?
    private var selectionStart: CGPoint?
    private var selectionOriginal: AnnotationItem?
    /// The text annotation whose current edit already has an undo entry.
    private var textEditID: UUID?
    private var pixelatedCache: [CGFloat: NSImage] = [:]
    private static let ciContext = CIContext()

    init(image: NSImage, record: CaptureRecord?) {
        self.image = image
        self.record = record
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    func begin(at normalizedPoint: CGPoint) {
        guard selectedTool != .select, selectedTool != .background else { return }
        snapshot()
        let id = UUID()
        let color = RGBAColor(NSColor(selectedColor))
        let item = AnnotationItem(
            id: id,
            tool: selectedTool,
            points: [CodablePoint(normalizedPoint)],
            rect: CodableRect(CGRect(origin: normalizedPoint, size: .zero)),
            color: selectedTool == .highlighter ? .yellow : color,
            lineWidth: lineWidth,
            text: selectedTool == .text ? textDraft : "",
            // Continue after the highest number so deleting an earlier counter cannot duplicate one.
            counter: selectedTool == .counter ? (annotations.compactMap { $0.tool == .counter ? $0.counter : nil }.max() ?? 0) + 1 : nil
        )
        annotations.append(item)
        activeID = id
        selectedAnnotationID = id
    }

    func update(to normalizedPoint: CGPoint) {
        guard let activeID, let index = annotations.firstIndex(where: { $0.id == activeID }), let first = annotations[index].points.first?.cgPoint else { return }
        if selectedTool == .pencil {
            annotations[index].points.append(CodablePoint(normalizedPoint))
            let points = annotations[index].points.map(\.cgPoint)
            let minX = points.map(\.x).min() ?? normalizedPoint.x
            let minY = points.map(\.y).min() ?? normalizedPoint.y
            let maxX = points.map(\.x).max() ?? normalizedPoint.x
            let maxY = points.map(\.y).max() ?? normalizedPoint.y
            annotations[index].rect = CodableRect(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
        } else {
            annotations[index].points = [CodablePoint(first), CodablePoint(normalizedPoint)]
            annotations[index].rect = CodableRect(CGRect(
                x: min(first.x, normalizedPoint.x),
                y: min(first.y, normalizedPoint.y),
                width: abs(normalizedPoint.x - first.x),
                height: abs(normalizedPoint.y - first.y)
            ))
        }
    }

    func end(at normalizedPoint: CGPoint) {
        update(to: normalizedPoint)
        guard let activeID, let index = annotations.firstIndex(where: { $0.id == activeID }) else { return }
        if selectedTool == .crop {
            let rect = annotations[index].rect.cgRect
            annotations.remove(at: index)
            crop(to: rect)
        }
        self.activeID = nil
    }

    func beginSelection(at normalizedPoint: CGPoint) {
        let hit = annotations.last { item in
            let rect = item.rect.cgRect.insetBy(dx: -0.015, dy: -0.015)
            if item.tool == .counter, let point = item.points.last?.cgPoint {
                return hypot(point.x - normalizedPoint.x, point.y - normalizedPoint.y) < 0.045
            }
            return rect.contains(normalizedPoint)
        }
        selectedAnnotationID = hit?.id
        guard let hit else { return }
        snapshot()
        selectionStart = normalizedPoint
        selectionOriginal = hit
    }

    func updateSelection(to normalizedPoint: CGPoint) {
        guard let selectionStart, let original = selectionOriginal,
              let index = annotations.firstIndex(where: { $0.id == original.id }) else { return }
        let requested = CGPoint(x: normalizedPoint.x - selectionStart.x, y: normalizedPoint.y - selectionStart.y)
        let rect = original.rect.cgRect
        let delta = CGPoint(
            x: max(-rect.minX, min(requested.x, 1 - rect.maxX)),
            y: max(-rect.minY, min(requested.y, 1 - rect.maxY))
        )
        var moved = original
        moved.points = original.points.map { point in
            CodablePoint(CGPoint(x: point.x + delta.x, y: point.y + delta.y))
        }
        moved.rect = CodableRect(rect.offsetBy(dx: delta.x, dy: delta.y))
        annotations[index] = moved
    }

    func endSelection(at normalizedPoint: CGPoint) {
        updateSelection(to: normalizedPoint)
        selectionStart = nil
        selectionOriginal = nil
    }

    func removeSelected() {
        guard let selectedAnnotationID else { return }
        snapshot()
        annotations.removeAll { $0.id == selectedAnnotationID }
        self.selectedAnnotationID = nil
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot())
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot())
        restore(next)
    }

    func updateSelectedText(_ text: String) {
        guard let selectedAnnotationID, let index = annotations.firstIndex(where: { $0.id == selectedAnnotationID }),
              annotations[index].text != text else { return }
        // One undo entry per editing pass on an annotation, not one per keystroke.
        if textEditID != selectedAnnotationID {
            snapshot()
            textEditID = selectedAnnotationID
        }
        annotations[index].text = text
    }

    /// The image run through CIPixellate, cached per scale because the canvas redraws often.
    func pixelatedImage(scale: CGFloat) -> NSImage? {
        if let cached = pixelatedCache[scale] { return cached }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: source)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: input.extent.midX, y: input.extent.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let cgImage = Self.ciContext.createCGImage(output, from: input.extent) else { return nil }
        let result = NSImage(cgImage: cgImage, size: image.size)
        pixelatedCache[scale] = result
        return result
    }

    func combine(with other: NSImage) {
        snapshot()
        let gap: CGFloat = 20
        let newSize = CGSize(width: max(image.size.width, other.size.width), height: image.size.height + gap + other.size.height)
        let combined = NSImage(size: newSize)
        combined.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: newSize).fill()
        other.draw(at: CGPoint(x: (newSize.width - other.size.width) / 2, y: 0), from: .zero, operation: .copy, fraction: 1)
        image.draw(at: CGPoint(x: (newSize.width - image.size.width) / 2, y: other.size.height + gap), from: .zero, operation: .copy, fraction: 1)
        combined.unlockFocus()
        // Keep annotations (including blur and pixelate redactions) on the original image,
        // which now occupies the top of the combined canvas.
        let scaleX = image.size.width / newSize.width
        let scaleY = image.size.height / newSize.height
        let offsetX = (newSize.width - image.size.width) / 2 / newSize.width
        annotations = annotations.map { $0.mapped { CGPoint(x: offsetX + $0.x * scaleX, y: $0.y * scaleY) } }
        image = combined
    }

    func makeProject() throws -> EditorProject {
        EditorProject(
            imageData: try image.encodedData(format: "png"),
            annotations: annotations,
            background: background,
            canvasCrop: nil
        )
    }

    private func snapshot() {
        textEditID = nil
        undoStack.append(currentSnapshot())
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack = []
    }

    private func currentSnapshot() -> Snapshot {
        Snapshot(image: image.copy() as? NSImage ?? image, annotations: annotations, background: background)
    }

    private func restore(_ snapshot: Snapshot) {
        image = snapshot.image.copy() as? NSImage ?? snapshot.image
        textEditID = nil
        annotations = snapshot.annotations
        background = snapshot.background
        selectedAnnotationID = nil
    }

    func crop(to normalizedRect: CGRect) {
        guard normalizedRect.width > 0.01, normalizedRect.height > 0.01,
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        let pixelRect = CGRect(
            x: normalizedRect.minX * CGFloat(cgImage.width),
            // Normalized editor coordinates and CGImage rows both start at the top.
            y: normalizedRect.minY * CGFloat(cgImage.height),
            width: normalizedRect.width * CGFloat(cgImage.width),
            height: normalizedRect.height * CGFloat(cgImage.height)
        ).integral
        guard let cropped = cgImage.cropping(to: pixelRect) else { return }
        image = NSImage(cgImage: cropped, size: .zero)
        // Move annotations into the cropped space so redactions inside the kept area survive.
        let kept = CGRect(
            x: pixelRect.minX / CGFloat(cgImage.width),
            y: pixelRect.minY / CGFloat(cgImage.height),
            width: pixelRect.width / CGFloat(cgImage.width),
            height: pixelRect.height / CGFloat(cgImage.height)
        )
        annotations = annotations
            .filter { kept.intersects($0.boundingRect.insetBy(dx: -0.001, dy: -0.001)) }
            .map { $0.mapped { CGPoint(x: ($0.x - kept.minX) / kept.width, y: ($0.y - kept.minY) / kept.height) } }
        selectedAnnotationID = nil
    }
}
