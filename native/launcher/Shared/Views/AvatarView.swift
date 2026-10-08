import AppKit
import SwiftUI

struct AvatarView: View {
    @ObservedObject var appState: LauncherAppState

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.white)
            Circle()
                .stroke(Color.black.opacity(0.12), lineWidth: 1)
            LauncherSMark(size: 32)
            AvatarDragLayer {
                appState.toggleLauncher(mode: .search)
            }
        }
        .frame(width: 48, height: 48)
        .contentShape(Circle())
        .help("Drag or click to open Launcher")
    }
}

private struct AvatarDragLayer: NSViewRepresentable {
    let onClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        AvatarDragView(onClick: onClick)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let nsView = nsView as? AvatarDragView else { return }
        nsView.onClick = onClick
    }
}

private final class AvatarDragView: NSView {
    var onClick: () -> Void
    private var mouseDownScreenPoint: CGPoint?
    private var windowStartOrigin: CGPoint?

    init(onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        return nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = NSEvent.mouseLocation
        windowStartOrigin = window?.frame.origin
    }

    override func mouseDragged(with event: NSEvent) {
        guard
            let window,
            let mouseDownScreenPoint,
            let windowStartOrigin
        else { return }

        let currentPoint = NSEvent.mouseLocation
        window.setFrameOrigin(
            CGPoint(
                x: windowStartOrigin.x + currentPoint.x - mouseDownScreenPoint.x,
                y: windowStartOrigin.y + currentPoint.y - mouseDownScreenPoint.y
            )
        )
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreenPoint = nil
            windowStartOrigin = nil
        }

        guard let mouseDownScreenPoint else {
            onClick()
            return
        }

        let currentPoint = NSEvent.mouseLocation
        let distance = hypot(currentPoint.x - mouseDownScreenPoint.x, currentPoint.y - mouseDownScreenPoint.y)
        if distance < 4 {
            onClick()
        }
    }
}

struct LauncherSMark: View {
    let size: CGFloat

    var body: some View {
        Text("S")
            .font(.system(size: size, weight: .heavy, design: .serif).italic())
            .foregroundStyle(.black)
            .offset(x: -1, y: -1)
        .frame(width: size, height: size)
    }
}
