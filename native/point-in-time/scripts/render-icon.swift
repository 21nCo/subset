// Renders the app icon PNGs into MacApp/Assets.xcassets/AppIcon.appiconset.
// Run from native/point-in-time: swift scripts/render-icon.swift
import AppKit

let sizes: [(points: Int, scale: Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
let output = URL(fileURLWithPath: "MacApp/Assets.xcassets/AppIcon.appiconset", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)
    let context = NSGraphicsContext.current!.cgContext
    // Background tile inset like other macOS icons.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: tile.width * 0.22, cornerHeight: tile.width * 0.22, transform: nil))
    context.setFillColor(NSColor(srgbRed: 0.10, green: 0.12, blue: 0.16, alpha: 1).cgColor)
    context.fillPath()
    // Three arcs: focus, neutral, drift.
    let center = CGPoint(x: size / 2, y: size / 2)
    let radius = tile.width * 0.30
    let width = tile.width * 0.12
    let arcs: [(CGFloat, CGFloat, NSColor)] = [
        (90, -150, NSColor(srgbRed: 0.24, green: 0.80, blue: 0.62, alpha: 1)),
        (-160, -230, NSColor(srgbRed: 0.62, green: 0.66, blue: 0.72, alpha: 1)),
        (-240, -262, NSColor(srgbRed: 0.98, green: 0.58, blue: 0.24, alpha: 1))
    ]
    context.setLineWidth(width)
    context.setLineCap(.butt)
    for (start, end, color) in arcs {
        context.addArc(center: center, radius: radius, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: true)
        context.setStrokeColor(color.cgColor)
        context.strokePath()
    }
    context.setFillColor(NSColor.white.cgColor)
    context.fillEllipse(in: CGRect(x: center.x - width * 0.45, y: center.y - width * 0.45, width: width * 0.9, height: width * 0.9))
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

var images: [[String: String]] = []
for (points, scale) in sizes {
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try render(pixels: points * scale).write(to: output.appendingPathComponent(name))
    images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
}
let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("Contents.json"))
let root: [String: Any] = ["info": ["author": "xcode", "version": 1]]
try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]).write(to: output.deletingLastPathComponent().appendingPathComponent("Contents.json"))
print("Rendered \(sizes.count) icon sizes")
