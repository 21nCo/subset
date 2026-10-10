import AppKit
import AVFoundation
import AVKit
import SwiftUI

@MainActor
final class VideoEditorWindowController {
    private var controllers: [ObjectIdentifier: (controller: NSWindowController, observer: NSObjectProtocol)] = [:]

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
        // Stop playback and release the player when the window closes.
        let key = ObjectIdentifier(window)
        let observer = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                model.close()
                guard let self, let entry = self.controllers.removeValue(forKey: key) else { return }
                NotificationCenter.default.removeObserver(entry.observer)
            }
        }
        controllers[key] = (controller, observer)
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
    @Published var exportError: String?
    private var boundaryObserver: Any?

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

    /// Plays from the selection start and pauses at the selection end.
    func playSelection() {
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.player.pause() }
        }
        player.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.play()
    }

    func close() {
        player.pause()
        if let boundaryObserver { player.removeTimeObserver(boundaryObserver) }
        boundaryObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.mpeg4Movie]
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + " trimmed.mp4"
        guard panel.runModal() == .OK, let output = panel.url else { return }
        exporting = true
        exportError = nil
        Task {
            defer { exporting = false }
            let asset = AVURLAsset(url: url)
            guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetHighestQuality) else {
                exportError = "This video cannot be exported."
                return
            }
            session.timeRange = CMTimeRange(
                start: CMTime(seconds: start, preferredTimescale: 600),
                duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600)
            )
            // Export to a temporary file and replace the destination only after success, so a
            // failed export never deletes the file the user chose to overwrite.
            let temporary = output.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).mp4")
            do {
                try await session.export(to: temporary, as: .mp4)
                if FileManager.default.fileExists(atPath: output.path) {
                    _ = try FileManager.default.replaceItemAt(output, withItemAt: temporary)
                } else {
                    try FileManager.default.moveItem(at: temporary, to: output)
                }
            } catch {
                try? FileManager.default.removeItem(at: temporary)
                exportError = error.localizedDescription
            }
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
                    Button("Play Selection", action: model.playSelection)
                    Spacer()
                    if let error = model.exportError {
                        Text("Export failed: \(error)").font(.caption).foregroundStyle(.red).lineLimit(2)
                    }
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
