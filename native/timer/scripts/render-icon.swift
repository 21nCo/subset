// Renders the app icon PNGs into MacApp/Assets.xcassets/AppIcon.appiconset: the SF Symbol "timer" the menu bar
// item shows when no timer runs, on a dark tile. Run from native/timer: swift scripts/render-icon.swift
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
    // Background tile inset like other macOS icons.
    let inset = size * 0.1
    let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    NSColor(srgbRed: 0.11, green: 0.13, blue: 0.17, alpha: 1).setFill()
    NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.22, yRadius: tile.width * 0.22).fill()
    let configuration = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .semibold)
        .applying(.init(paletteColors: [NSColor(srgbRed: 1, green: 0.62, blue: 0.26, alpha: 1)]))
    let symbol = NSImage(systemSymbolName: "timer", accessibilityDescription: nil)!.withSymbolConfiguration(configuration)!
    let glyph = CGRect(x: (size - symbol.size.width) / 2, y: (size - symbol.size.height) / 2, width: symbol.size.width, height: symbol.size.height)
    symbol.draw(in: glyph)
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
