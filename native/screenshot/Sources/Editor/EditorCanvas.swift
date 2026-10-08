import AppKit
import CoreImage
import SwiftUI

struct EditorCanvas: View {
    @ObservedObject var session: EditorSession
    @State private var dragStart: CGPoint?

    var body: some View {
        GeometryReader { proxy in
            let canvas = proxy.size
            Canvas { context, size in
                drawBackground(context: &context, size: size)
                let imageRect = fittedImageRect(canvasSize: size)
                context.draw(Image(nsImage: session.image), in: imageRect)
                for item in session.annotations { draw(item, context: &context, imageRect: imageRect) }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let rect = fittedImageRect(canvasSize: canvas)
                    let normalized = normalize(value.location, in: rect)
                    if dragStart == nil {
                        dragStart = value.location
                        if session.selectedTool == .select { session.beginSelection(at: normalized) }
                        else { session.begin(at: normalized) }
                    } else {
                        if session.selectedTool == .select { session.updateSelection(to: normalized) }
                        else { session.update(to: normalized) }
                    }
                }
                .onEnded { value in
                    let rect = fittedImageRect(canvasSize: canvas)
                    let normalized = normalize(value.location, in: rect)
                    if session.selectedTool == .select { session.endSelection(at: normalized) }
                    else { session.end(at: normalized) }
                    dragStart = nil
                }
            )
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let provider = providers.first else { return false }
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    let data = item as? Data
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil), let image = NSImage(contentsOf: url) {
                        Task { @MainActor in session.combine(with: image) }
                    }
                }
                return true
            }
        }
    }

    private func fittedImageRect(canvasSize: CGSize) -> CGRect {
        let padding = session.background.style == .transparent ? 24 : max(24, session.background.padding)
        let available = CGSize(width: max(1, canvasSize.width - padding * 2), height: max(1, canvasSize.height - padding * 2))
        let ratio = min(available.width / max(1, session.image.size.width), available.height / max(1, session.image.size.height))
        let size = CGSize(width: session.image.size.width * ratio, height: session.image.size.height * ratio)
        return CGRect(x: (canvasSize.width - size.width) / 2, y: (canvasSize.height - size.height) / 2, width: size.width, height: size.height)
    }

    private func normalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(
            x: min(1, max(0, (point.x - rect.minX) / max(1, rect.width))),
            y: min(1, max(0, (point.y - rect.minY) / max(1, rect.height)))
        )
    }

    private func drawBackground(context: inout GraphicsContext, size: CGSize) {
        let rect = CGRect(origin: .zero, size: size)
        switch session.background.style {
        case .transparent:
            context.fill(Path(rect), with: .color(Color(nsColor: .controlBackgroundColor)))
        case .solid:
            context.fill(Path(rect), with: .color(Color(nsColor: session.background.primaryColor.nsColor)))
        case .gradient, .wallpaper:
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [Color(nsColor: session.background.primaryColor.nsColor), Color(nsColor: session.background.secondaryColor.nsColor)]),
                startPoint: CGPoint(x: 0, y: 0),
                endPoint: CGPoint(x: size.width, y: size.height)
            ))
        }
    }

    private func draw(_ item: AnnotationItem, context: inout GraphicsContext, imageRect: CGRect) {
        let color = Color(nsColor: item.color.nsColor)
        let rect = denormalize(item.rect.cgRect, in: imageRect)
        let points = item.points.map { denormalize($0.cgPoint, in: imageRect) }

        switch item.tool {
        case .arrow, .line:
            guard let start = points.first, let end = points.last else { return }
            var path = Path(); path.move(to: start); path.addLine(to: end)
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
            if item.tool == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let length = max(12, item.lineWidth * 4)
                var arrow = Path(); arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - length * cos(angle - .pi / 6), y: end.y - length * sin(angle - .pi / 6)))
                arrow.move(to: end)
                arrow.addLine(to: CGPoint(x: end.x - length * cos(angle + .pi / 6), y: end.y - length * sin(angle + .pi / 6)))
                context.stroke(arrow, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round))
            }
        case .rectangle:
            context.stroke(Path(roundedRect: rect, cornerRadius: 4), with: .color(color), lineWidth: item.lineWidth)
        case .ellipse:
            context.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: item.lineWidth)
        case .pencil:
            guard let first = points.first else { return }
            var path = Path(); path.move(to: first)
            for point in points.dropFirst() { path.addLine(to: point) }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: item.lineWidth, lineCap: .round, lineJoin: .round))
        case .highlighter:
            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color.opacity(0.58)))
        case .text:
            context.draw(Text(item.text).font(.system(size: max(14, item.lineWidth * 6), weight: .semibold)).foregroundStyle(color), at: CGPoint(x: rect.midX, y: rect.midY), anchor: .center)
        case .pixelate:
            if let filtered = pixelatedImage(scale: max(7, item.lineWidth * 3)) {
                context.drawLayer { layer in
                    layer.clip(to: Path(rect))
                    layer.draw(Image(nsImage: filtered), in: imageRect)
                }
            }
        case .blur:
            context.drawLayer { layer in
                layer.clip(to: Path(roundedRect: rect, cornerRadius: 5))
                layer.addFilter(.blur(radius: max(5, item.lineWidth * 2)))
                layer.draw(Image(nsImage: session.image), in: imageRect)
            }
        case .spotlight:
            context.fill(Path(imageRect), with: .color(.black.opacity(0.54)))
            context.fill(Path(roundedRect: rect, cornerRadius: 8), with: .color(.white.opacity(0.12)))
            context.stroke(Path(roundedRect: rect, cornerRadius: 8), with: .color(.white.opacity(0.4)), lineWidth: 1)
        case .counter:
            let diameter = max(28, item.lineWidth * 8)
            let center = points.last ?? CGPoint(x: rect.midX, y: rect.midY)
            let circle = CGRect(x: center.x - diameter / 2, y: center.y - diameter / 2, width: diameter, height: diameter)
            context.fill(Path(ellipseIn: circle), with: .color(color))
            context.draw(Text("\(item.counter ?? 1)").font(.system(size: diameter * 0.5, weight: .bold, design: .rounded)).foregroundStyle(.white), at: center, anchor: .center)
        case .crop:
            context.stroke(Path(rect), with: .color(.white), style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
        case .select, .background:
            break
        }

        if session.selectedAnnotationID == item.id {
            context.stroke(Path(rect.insetBy(dx: -4, dy: -4)), with: .color(.white.opacity(0.8)), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }

    private func denormalize(_ point: CGPoint, in rect: CGRect) -> CGPoint {
        CGPoint(x: rect.minX + point.x * rect.width, y: rect.minY + point.y * rect.height)
    }

    private func denormalize(_ normalized: CGRect, in rect: CGRect) -> CGRect {
        CGRect(x: rect.minX + normalized.minX * rect.width, y: rect.minY + normalized.minY * rect.height, width: normalized.width * rect.width, height: normalized.height * rect.height)
    }

    private func pixelatedImage(scale: CGFloat) -> NSImage? {
        guard let source = session.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let filter = CIFilter(name: "CIPixellate") else { return nil }
        let input = CIImage(cgImage: source)
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(scale, forKey: kCIInputScaleKey)
        filter.setValue(CIVector(x: input.extent.midX, y: input.extent.midY), forKey: kCIInputCenterKey)
        guard let output = filter.outputImage?.cropped(to: input.extent),
              let image = CIContext().createCGImage(output, from: input.extent) else { return nil }
        return NSImage(cgImage: image, size: session.image.size)
    }
}
