import AppKit
import SwiftUI

@MainActor
final class PinWindowController {
    private let appState: AppState
    private var windows: [UUID: NSPanel] = [:]
    private var pinsVisible = true

    init(appState: AppState) {
        self.appState = appState
    }

    func pin(image: NSImage, title: String) {
        let id = UUID()
        let maxSize = CGSize(width: 620, height: 460)
        let scale = min(1, min(maxSize.width / max(1, image.size.width), maxSize.height / max(1, image.size.height)))
        let size = CGSize(width: max(140, image.size.width * scale), height: max(100, image.size.height * scale))
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let offset = CGFloat(windows.count % 8) * 24
        let frame = CGRect(x: visible.midX - size.width / 2 + offset, y: visible.midY - size.height / 2 - offset, width: size.width, height: size.height)
        var panel: NSPanel!
        panel = NSPanel(contentRect: frame, styleMask: [.borderless, .resizable, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: PinView(
            image: image,
            title: title,
            onLockChanged: { [weak panel] locked in panel?.isMovableByWindowBackground = !locked },
            onClose: { [weak self] in self?.close(id) }
        ))
        panel.orderFrontRegardless()
        windows[id] = panel
    }

    func toggleVisibility() {
        pinsVisible.toggle()
        windows.values.forEach { pinsVisible ? $0.orderFrontRegardless() : $0.orderOut(nil) }
    }

    func closeAll() {
        windows.values.forEach { $0.orderOut(nil) }
        windows = [:]
    }

    private func close(_ id: UUID) {
        windows[id]?.orderOut(nil)
        windows.removeValue(forKey: id)
    }
}

private struct PinView: View {
    let image: NSImage
    let title: String
    let onLockChanged: (Bool) -> Void
    let onClose: () -> Void
    @State private var hovering = false
    @State private var locked = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Image(nsImage: image).resizable().scaledToFit().background(.black.opacity(0.06))
            if hovering {
                HStack(spacing: 4) {
                    Button { toggleLock() } label: { Image(systemName: locked ? "lock.fill" : "lock.open") }
                    Button {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image])
                    } label: { Image(systemName: "doc.on.doc") }
                    Button(action: onClose) { Image(systemName: "xmark") }
                }
                .buttonStyle(.plain)
                .padding(7)
                .background(.ultraThickMaterial, in: Capsule())
                .padding(8)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.white.opacity(0.24)))
        .onHover { hovering = $0 }
        .help(title)
        .contextMenu {
            Button("Copy to Clipboard") { NSPasteboard.general.clearContents(); NSPasteboard.general.writeObjects([image]) }
            Button(locked ? "Unlock" : "Lock", action: toggleLock)
            Divider()
            Button("Close") { onClose() }
        }
    }

    private func toggleLock() {
        locked.toggle()
        onLockChanged(locked)
    }
}
