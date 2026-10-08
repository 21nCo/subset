import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class VideoEditorWindowController {
    private var controllers: [NSWindowController] = []

    func show(url: URL) {
        let model = VideoEditorModel(url: url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 860, height: 620), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Video Editor"
        window.center()
        window.contentView = NSHostingView(rootView: VideoEditorView(model: model))
        let controller = NSWindowController(window: window)
        controller.showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        controllers.append(controller)
    }
}

@MainActor
private final class VideoEditorModel: ObservableObject {
    let url: URL
    let player: AVPlayer
    @Published var duration: Double = 1
    @Published var start: Double = 0
    @Published var end: Double = 1
    @Published var exporting = false

    init(url: URL) {
        self.url = url
        player = AVPlayer(url: url)
        Task {
            let asset = AVURLAsset(url: url)
            if let seconds = try? await asset.load(.duration).seconds {
                duration = max(0.1, seconds)
                end = duration
            }
        }
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " trimmed.mp4"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        Task {
            defer { exporting = false }
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else { return }
            try? FileManager.default.removeItem(at: output)
            let range = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600)
            )
            session.timeRange = range
            try? await session.export(to: output, as: .mp4)
        }
    }
}

private struct VideoEditorView: View {
    @ObservedObject var model: VideoEditorModel
    var body: some View {
        VStack(spacing: 16) {
            VideoPlayer(player: model.player)
                .background(.black)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 8) {
                HStack {
                    Text("Start \(time(model.start))")
                    Slider(value: $model.start, in: 0...max(0.1, model.end - 0.1))
                    Text("End \(time(model.end))")
                }
                Slider(value: $model.end, in: min(model.duration, model.start + 0.1)...max(model.duration, model.start + 0.1))
                HStack {
                    Button("Play Selection") {
                        model.player.seek(to: CMTime(seconds: model.start, preferredTimescale: 600))
                        model.player.play()
                    }
                    Spacer()
                    if model.exporting { ProgressView().controlSize(.small) }
                    Button("Export Trimmed Video", action: model.export)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.exporting)
                }
            }
        }
        .padding(18)
    }

    private func time(_ seconds: Double) -> String {
        String(format: "%02d:%02d.%01d", Int(seconds) / 60, Int(seconds) % 60, Int(seconds * 10) % 10)
    }
}
