import SwiftUI

enum WaveformDisplayMode {
    case recording
    case playback
}

struct WaveformView: View {
    let samples: [CGFloat]
    var mode: WaveformDisplayMode = .recording
    var waveformColor: Color = Color(red: 0.20, green: 0.44, blue: 0.95)
    var baselineColor: Color = Color(red: 0.20, green: 0.44, blue: 0.95).opacity(0.22)
    var borderColor: Color = Color(red: 0.20, green: 0.44, blue: 0.95).opacity(0.12)
    var backgroundColor: Color = Color.primary.opacity(0.03)
    var showPlayhead: Bool = true
    var playheadPosition: CGFloat = 0.50
    var showsBorder: Bool = false
    var cornerRadius: CGFloat = 0
    var onScrub: ((CGFloat) -> Void)? = nil

    private var normalizedSamples: [CGFloat] {
        samples.map { min(max($0, 0.01), 1.0) }
    }

    var body: some View {
        GeometryReader { geometry in
            let canvas = Canvas { context, size in
                let backgroundRect = CGRect(origin: .zero, size: size)
                let roundedBackground = Path(roundedRect: backgroundRect, cornerRadius: cornerRadius)
                context.fill(roundedBackground, with: .color(backgroundColor))

                switch mode {
                case .recording:
                    drawRecordingWaveform(in: &context, size: size)
                case .playback:
                    drawPlaybackWaveform(in: &context, size: size)
                }

                if showsBorder {
                    context.stroke(roundedBackground, with: .color(borderColor), lineWidth: 1)
                }
            }

            if let onScrub {
                canvas
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let progress = min(max(value.location.x / max(geometry.size.width, 1), 0), 1)
                                onScrub(progress)
                            }
                    )
            } else {
                canvas
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    private func drawRecordingWaveform(in context: inout GraphicsContext, size: CGSize) {
        let preferredBarWidth: CGFloat = 3.2
        let preferredGap: CGFloat = 1.4
        let incomingInset = min(max(size.width * 0.04, preferredBarWidth * 2), 18)
        let trailingPlayheadPosition = min(max(playheadPosition, 0.82), 0.98)
        let playheadX = showPlayhead ? min(size.width - incomingInset, size.width * trailingPlayheadPosition) : size.width
        let historyWidth = max(0, playheadX)
        let barWidth = preferredBarWidth
        let gap = preferredGap
        let slotWidth = barWidth + gap
        let visibleCapacity = max(1, Int(floor((historyWidth + gap) / slotWidth)))
        let visibleSamples = Array(normalizedSamples.suffix(visibleCapacity))
        let count = visibleSamples.count
        let totalBarWidth = CGFloat(count) * barWidth + CGFloat(max(count - 1, 0)) * gap
        let startX = max(0, playheadX - totalBarWidth)
        let midY = size.height / 2
        let maxBarHeight = size.height * 0.68

        var baseline = Path()
        baseline.move(to: CGPoint(x: 0, y: midY))
        baseline.addLine(to: CGPoint(x: playheadX, y: midY))
        context.stroke(baseline, with: .color(baselineColor), lineWidth: 0.8)

        if count > 0 {
            for (index, sample) in visibleSamples.enumerated() {
                let progress = CGFloat(index) / CGFloat(max(count - 1, 1))
                let visualSample = pow(sample, 0.58)
                let height = max(3, maxBarHeight * visualSample)
                let x = startX + CGFloat(index) * slotWidth
                let rect = CGRect(x: x, y: midY - (height / 2), width: barWidth, height: height)
                let alpha = 0.58 + Double(progress) * 0.42
                context.fill(
                    Path(roundedRect: rect, cornerRadius: barWidth / 1.7),
                    with: .color(waveformColor.opacity(alpha))
                )
            }
        }

        if showPlayhead {
            let playheadRect = CGRect(x: playheadX, y: size.height * 0.04, width: 2.4, height: size.height * 0.92)
            context.fill(Path(playheadRect), with: .color(waveformColor))
        }
    }

    private func drawPlaybackWaveform(in context: inout GraphicsContext, size: CGSize) {
        let count = max(normalizedSamples.count, 1)
        let progressX = size.width * min(max(playheadPosition, 0), 1)
        let gap = min(1.5, size.width / CGFloat(max(count * 6, 1)))
        let totalGap = CGFloat(max(count - 1, 0)) * gap
        let barWidth = max(1.8, (size.width - totalGap) / CGFloat(count))
        let midY = size.height / 2
        let maxBarHeight = size.height * 0.68

        for index in 0..<count {
            let sample = normalizedSamples.indices.contains(index) ? normalizedSamples[index] : 0.08
            let visualSample = pow(sample, 0.62)
            let height = max(4, maxBarHeight * visualSample)
            let x = CGFloat(index) * (barWidth + gap)
            let rect = CGRect(x: x, y: midY - (height / 2), width: barWidth, height: height)
            let isPlayed = rect.midX <= progressX
            let color = isPlayed ? waveformColor : baselineColor
            context.fill(
                Path(roundedRect: rect, cornerRadius: barWidth / 1.6),
                with: .color(color)
            )
        }

        if showPlayhead {
            let playheadRect = CGRect(x: progressX, y: size.height * 0.04, width: 2.2, height: size.height * 0.92)
            context.fill(Path(playheadRect), with: .color(waveformColor))
        }
    }
}
