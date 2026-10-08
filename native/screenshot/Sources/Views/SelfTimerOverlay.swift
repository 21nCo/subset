import AppKit
import SwiftUI

@MainActor
final class SelfTimerOverlay: ObservableObject {
    static let shared = SelfTimerOverlay()
    @Published private(set) var remaining = 0
    private var panel: NSPanel?

    func start(seconds: Int, completion: @escaping () -> Void) {
        remaining = seconds
        let size = CGSize(width: 128, height: 128)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.midX - 64, y: visible.midY - 64, width: size.width, height: size.height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .screenSaver
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.contentView = NSHostingView(rootView: SelfTimerView(model: self))
        panel.orderFrontRegardless()
        self.panel = panel

        Task {
            while remaining > 0 {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            panel.orderOut(nil)
            self.panel = nil
            try? await Task.sleep(for: .milliseconds(100))
            completion()
        }
    }
}

private struct SelfTimerView: View {
    @ObservedObject var model: SelfTimerOverlay
    var body: some View {
        Text("\(model.remaining)")
            .font(.system(size: 62, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: 120, height: 120)
            .background(.black.opacity(0.82), in: Circle())
            .overlay(Circle().stroke(.white.opacity(0.28), lineWidth: 2))
    }
}
