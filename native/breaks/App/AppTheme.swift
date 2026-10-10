import SwiftUI
import UIKit

enum BreakPalette {
    static let ink = Color(red: 0.055, green: 0.047, blue: 0.082)
    static let surface = Color.white.opacity(0.075)
    static let stroke = Color.white.opacity(0.12)
    static let coral = Color(red: 0.98, green: 0.35, blue: 0.47)
    static let magenta = Color(red: 0.82, green: 0.24, blue: 0.68)
    static let violet = Color(red: 0.43, green: 0.29, blue: 0.92)
    static let amber = Color(red: 1.0, green: 0.72, blue: 0.25)
    static let teal = Color(red: 0.20, green: 0.72, blue: 0.78)
    static let accentGradient = LinearGradient(
        colors: [amber, coral, magenta, violet],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )
}

struct AmbientBackground: View {
    var style: BreakBackground = .ambient
    var showArtwork = false
    /// The custom background's file, when the caller already has the settings.
    var customFilename: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            BreakPalette.ink
            if style == .custom,
               let filename = customFilename ?? BreakRepository().loadSettings().customization.customBackgroundFilename,
               let image = CustomBackgroundCache.image(filename: filename) {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if showArtwork && style == .ambient {
                Image("AmbientBreak")
                    .resizable()
                    .scaledToFill()
                    .opacity(0.82)
                    .blur(radius: 2)
            } else {
                // With Reduce Motion on, the gradient is drawn once instead of drifting continuously.
                TimelineView(.animation(minimumInterval: 1 / 24, paused: reduceMotion)) { context in
                    Canvas { drawing, size in
                        let t = context.date.timeIntervalSinceReferenceDate
                        let colors = palette(for: style)
                        drawing.addFilter(.blur(radius: 90))
                        for index in colors.indices {
                            let phase = t * (0.055 + Double(index) * 0.008) + Double(index) * 2.1
                            let x = size.width * (0.5 + 0.38 * sin(phase))
                            let y = size.height * (0.46 + 0.34 * cos(phase * 0.83))
                            let radius = max(size.width, size.height) * (0.38 + CGFloat(index) * 0.04)
                            drawing.fill(
                                Path(ellipseIn: CGRect(x: x - radius, y: y - radius, width: radius * 2, height: radius * 2)),
                                with: .color(colors[index].opacity(0.30))
                            )
                        }
                    }
                }
            }
            LinearGradient(colors: [.black.opacity(0.08), .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private func palette(for style: BreakBackground) -> [Color] {
        switch style {
        case .ambient: [BreakPalette.coral, BreakPalette.amber, BreakPalette.violet, BreakPalette.teal]
        case .aurora: [BreakPalette.teal, .blue, BreakPalette.violet, .mint]
        case .dusk: [BreakPalette.amber, BreakPalette.coral, BreakPalette.magenta, .indigo]
        case .classic: [.gray.opacity(0.3), .black, .gray.opacity(0.15), .black]
        case .custom: [BreakPalette.coral, BreakPalette.magenta, BreakPalette.violet, BreakPalette.teal]
        }
    }
}

/// Keeps the decoded custom background, so a view that redraws every second does not reload the photo.
/// The file's modification date is part of the key because a new import reuses the same filename.
@MainActor
enum CustomBackgroundCache {
    private static var cached: (path: String, modified: Date?, image: UIImage)?

    static func image(filename: String) -> UIImage? {
        guard let url = AppGroupAssets.url(for: filename) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        if let cached, cached.path == url.path, cached.modified == modified { return cached.image }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cached = (url.path, modified, image)
        return image
    }
}

struct RestMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(Color.black.opacity(0.74))
            UnevenRoundedRectangle(
                topLeadingRadius: size * 0.23,
                bottomLeadingRadius: size * 0.34,
                bottomTrailingRadius: size * 0.21,
                topTrailingRadius: size * 0.36
            )
            .fill(BreakPalette.accentGradient)
            .padding(size * 0.18)
            HStack(spacing: size * 0.13) {
                ClosedEye().stroke(BreakPalette.ink, style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round))
                ClosedEye().stroke(BreakPalette.ink, style: StrokeStyle(lineWidth: max(2, size * 0.055), lineCap: .round))
            }
            .frame(width: size * 0.43, height: size * 0.14)
            .offset(y: size * 0.05)
        }
        .frame(width: size, height: size)
        .shadow(color: BreakPalette.magenta.opacity(0.22), radius: size * 0.18, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

private struct ClosedEye: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.midY),
            control: CGPoint(x: rect.midX, y: rect.maxY)
        )
        return path
    }
}

struct GlassCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .background(BreakPalette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(BreakPalette.stroke, lineWidth: 1)
            }
    }
}

extension View {
    func glassCard(padding: CGFloat = 16) -> some View {
        modifier(GlassCardModifier(padding: padding))
    }
}

struct ScoreRing: View {
    let score: Int
    var size: CGFloat = 180

    var body: some View {
        ZStack {
            Circle()
                .trim(from: 0.08, to: 0.92)
                .stroke(Color.white.opacity(0.09), style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(90))
            Circle()
                .trim(from: 0.08, to: 0.08 + 0.84 * CGFloat(score) / 100)
                .stroke(BreakPalette.accentGradient, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(90))
                .shadow(color: BreakPalette.magenta.opacity(0.3), radius: 12)
            VStack(spacing: 0) {
                Text("\(score)")
                    .font(.system(size: size * 0.26, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("SCREEN SCORE")
                    .font(.system(size: size * 0.055, weight: .semibold, design: .rounded))
                    .tracking(1.2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Screen score \(score) out of 100")
    }
}

struct MetricRow: View {
    let icon: String
    let color: Color
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(color.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            Text(title)
            Spacer()
            Text(value)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}
