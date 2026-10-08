import AppKit
@preconcurrency import AVFoundation

@MainActor
final class CameraOverlayController {
    private var panel: NSPanel?
    private var session: AVCaptureSession?

    func show() {
        hide()
        guard AVCaptureDevice.authorizationStatus(for: .video) != .denied else { return }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard granted else { return }
            Task { @MainActor in self?.startSession() }
        }
    }

    func hide() {
        session?.stopRunning()
        session = nil
        panel?.orderOut(nil)
        panel = nil
    }

    private func startSession() {
        guard let device = AVCaptureDevice.default(for: .video),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard session.canAddInput(input) else { return }
        session.addInput(input)

        let frame = CGRect(x: (NSScreen.main?.visibleFrame.maxX ?? 1300) - 220, y: (NSScreen.main?.visibleFrame.minY ?? 0) + 28, width: 190, height: 190)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let view = CameraPreviewView(frame: CGRect(origin: .zero, size: frame.size))
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        layer.frame = view.bounds
        layer.cornerRadius = 95
        layer.masksToBounds = true
        view.wantsLayer = true
        view.layer?.addSublayer(layer)
        panel.contentView = view
        panel.orderFrontRegardless()
        DispatchQueue.global(qos: .userInitiated).async { session.startRunning() }
        self.session = session
        self.panel = panel
    }
}

private final class CameraPreviewView: NSView {
    override func layout() {
        super.layout()
        layer?.sublayers?.forEach { $0.frame = bounds }
    }
}
