import AppKit
import Foundation

enum CaptureKind: String, Codable, CaseIterable, Identifiable {
    case area
    case window
    case fullscreen
    case previousArea
    case scrolling
    case recording
    case gif
    case imported

    var id: String { rawValue }

    var title: String {
        switch self {
        case .area: "Capture Area"
        case .window: "Capture Window"
        case .fullscreen: "Capture Fullscreen"
        case .previousArea: "Capture Previous Area"
        case .scrolling: "Scrolling Capture"
        case .recording: "Screen Recording"
        case .gif: "GIF Recording"
        case .imported: "Imported Media"
        }
    }
}

struct CaptureRecord: Codable, Identifiable, Hashable {
    let id: UUID
    var kind: CaptureKind
    var createdAt: Date
    var fileURL: URL
    var projectURL: URL?
    var thumbnailURL: URL?
    var width: Int
    var height: Int
    var sourceApplication: String?
    var sourceWindow: String?
    var cloudShareURL: URL?
    var cloudID: String?
    var tags: [String]
    var isFavorite: Bool

    var displayName: String {
        fileURL.deletingPathExtension().lastPathComponent
    }
}

enum AfterCaptureAction: String, Codable, CaseIterable, Identifiable {
    case quickAccess
    case copy
    case save
    case annotate
    case upload
    case pin

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quickAccess: "Show Quick Access"
        case .copy: "Copy to Clipboard"
        case .save: "Save to Export Location"
        case .annotate: "Open Annotate"
        case .upload: "Upload and Copy Link"
        case .pin: "Pin to the Screen"
        }
    }
}

enum RecordingFormat: String, Codable, CaseIterable, Identifiable {
    case mp4
    case gif
    var id: String { rawValue }
}

enum AnnotationTool: String, Codable, CaseIterable, Identifiable {
    case select
    case arrow
    case line
    case rectangle
    case ellipse
    case pencil
    case highlighter
    case text
    case pixelate
    case blur
    case spotlight
    case counter
    case crop
    case background

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .arrow: "arrow.up.right"
        case .line: "line.diagonal"
        case .rectangle: "rectangle"
        case .ellipse: "circle"
        case .pencil: "pencil.tip"
        case .highlighter: "highlighter"
        case .text: "textformat"
        case .pixelate: "square.grid.3x3.fill"
        case .blur: "drop.halffull"
        case .spotlight: "light.max"
        case .counter: "1.circle"
        case .crop: "crop"
        case .background: "sparkles.rectangle.stack"
        }
    }
}

struct CodablePoint: Codable, Hashable {
    var x: Double
    var y: Double

    init(_ point: CGPoint) {
        x = point.x
        y = point.y
    }

    var cgPoint: CGPoint { CGPoint(x: x, y: y) }
}

struct CodableRect: Codable, Hashable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct RGBAColor: Codable, Hashable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    static let accent = RGBAColor(red: 0.41, green: 0.20, blue: 0.98, alpha: 1)
    static let yellow = RGBAColor(red: 1, green: 0.82, blue: 0.18, alpha: 0.72)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.deviceRGB) ?? .systemPurple
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}

struct AnnotationItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var tool: AnnotationTool
    var points: [CodablePoint]
    var rect: CodableRect
    var color: RGBAColor
    var lineWidth: Double
    var text: String
    var counter: Int?

    /// The area the item covers in normalized image coordinates (points and rect).
    var boundingRect: CGRect {
        points.reduce(rect.cgRect.standardized) { $0.union(CGRect(origin: $1.cgPoint, size: .zero)) }
    }

    /// Returns a copy whose points and rect are moved by `transform`, an axis-aligned
    /// scale-and-offset in normalized image coordinates.
    func mapped(_ transform: (CGPoint) -> CGPoint) -> AnnotationItem {
        var copy = self
        copy.points = points.map { CodablePoint(transform($0.cgPoint)) }
        let r = rect.cgRect
        let a = transform(CGPoint(x: r.minX, y: r.minY))
        let b = transform(CGPoint(x: r.maxX, y: r.maxY))
        copy.rect = CodableRect(CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y)))
        return copy
    }
}

struct EditorProject: Codable {
    var version = 1
    var imageData: Data
    var annotations: [AnnotationItem]
    var background: BackgroundConfiguration
    var canvasCrop: CodableRect?
}

struct BackgroundConfiguration: Codable, Hashable {
    enum Style: String, Codable, CaseIterable, Identifiable {
        case transparent
        case solid
        case gradient
        case wallpaper
        var id: String { rawValue }
    }

    var style: Style = .transparent
    var primaryColor = RGBAColor(red: 0.45, green: 0.25, blue: 0.98)
    var secondaryColor = RGBAColor(red: 0.07, green: 0.73, blue: 0.88)
    var padding: Double = 64
    var cornerRadius: Double = 18
    var shadowRadius: Double = 24
    var aspectRatio: Double? = nil
}
