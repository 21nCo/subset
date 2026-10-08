import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ScrollingCaptureService {
    private let captureService: ScreenCaptureService

    init(captureService: ScreenCaptureService) {
        self.captureService = captureService
    }

    func capture(area: CGRect, frameCount: Int = 7) async -> NSImage? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }

        var frames: [NSImage] = []
        if let first = await captureService.capture(area: area) { frames.append(first) }
        let center = CGPoint(x: area.midX, y: area.midY)

        for _ in 1..<max(2, frameCount) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -Int32(max(180, area.height * 0.62)),
                wheel2: 0,
                wheel3: 0
            ) else { continue }
            event.location = CGPoint(x: center.x, y: (NSScreen.screens.map(\.frame.maxY).max() ?? area.maxY) - center.y)
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(360))
            if let frame = await captureService.capture(area: area, remember: false) { frames.append(frame) }
        }
        return stitchVertically(frames, overlapRatio: 0.34)
    }

    private func stitchVertically(_ images: [NSImage], overlapRatio: CGFloat) -> NSImage? {
        guard let first = images.first else { return nil }
        let size = first.size
        let overlap = size.height * overlapRatio
        let step = size.height - overlap
        let totalHeight = size.height + step * CGFloat(images.count - 1)
        let output = NSImage(size: CGSize(width: size.width, height: totalHeight))
        output.lockFocus()
        NSColor.clear.setFill()
        CGRect(origin: .zero, size: output.size).fill()

        for (index, image) in images.enumerated() {
            let source = index == 0
                ? CGRect(origin: .zero, size: image.size)
                : CGRect(x: 0, y: 0, width: image.size.width, height: step)
            let destinationY = totalHeight - size.height - CGFloat(index) * step
            let destination = CGRect(x: 0, y: destinationY, width: size.width, height: source.height)
            image.draw(in: destination, from: source, operation: .copy, fraction: 1)
        }
        output.unlockFocus()
        return output
    }
}
