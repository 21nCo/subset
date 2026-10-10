import AppKit
import ApplicationServices
import Foundation

@MainActor
final class ScrollingCaptureService {
    private let captureService: ScreenCaptureService

    init(captureService: ScreenCaptureService) {
        self.captureService = captureService
    }

    /// Fraction of the selection that each synthetic scroll advances. Stitching uses the same
    /// fraction, so each frame contributes exactly the content the scroll revealed.
    private let stepRatio: CGFloat = 0.66

    func capture(area: CGRect, maximumFrames: Int = 40) async -> NSImage? {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { return nil }

        var frames: [NSImage] = []
        guard let first = await captureService.capture(area: area) else { return nil }
        frames.append(first)
        var previousData = first.tiffRepresentation
        let center = CGPoint(x: area.midX, y: area.midY)
        let scrollPoints = max(1, (area.height * stepRatio).rounded(.down))

        // Scroll until the content stops changing (the bottom was reached) or the cap is hit.
        while frames.count < max(2, maximumFrames) {
            guard let event = CGEvent(
                scrollWheelEvent2Source: nil,
                units: .pixel,
                wheelCount: 1,
                wheel1: -Int32(scrollPoints),
                wheel2: 0,
                wheel3: 0
            ) else { break }
            event.location = CGPoint(x: center.x, y: ScreenCaptureService.primaryDisplayHeight - center.y)
            event.post(tap: .cghidEventTap)
            try? await Task.sleep(for: .milliseconds(360))
            guard let frame = await captureService.capture(area: area, remember: false) else { break }
            let data = frame.tiffRepresentation
            if data != nil, data == previousData { break }
            previousData = data
            frames.append(frame)
        }
        return stitchVertically(frames, overlapRatio: 1 - stepRatio)
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
