import AppKit
import SwiftUI

@MainActor
final class OCRResultPanel {
    static let shared = OCRResultPanel()
    private var panel: NSPanel?

    func show(text: String) {
        panel?.orderOut(nil)
        let visible = NSScreen.main?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.maxX - 430, y: visible.minY + 28, width: 400, height: 240)
        let panel = NSPanel(contentRect: frame, styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "Recognized Text"
        panel.level = .floating
        panel.contentView = NSHostingView(rootView: OCRResultView(text: text))
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.panel = panel
    }
}

private struct OCRResultView: View {
    @State var text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Copied to clipboard", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
            TextEditor(text: $text)
                .font(.system(.body, design: .rounded))
                .scrollContentBackground(.hidden)
                .padding(8)
                .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
        }
        .padding(16)
    }
}
