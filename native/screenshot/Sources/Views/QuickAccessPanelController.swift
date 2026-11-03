import AppKit
import SwiftUI

@MainActor
final class QuickAccessPanelController: ObservableObject {
    private let appState: AppState
    private var panel: NSPanel?
    @Published private(set) var record: CaptureRecord?
    @Published private(set) var image: NSImage?
    @Published private(set) var uploadedURL: URL?
    /// When the running auto-close countdown ends; nil when it is off or paused.
    @Published private(set) var autoCloseDeadline: Date?
    /// Length of the countdown in seconds; 0 when auto-close is off.
    @Published private(set) var autoCloseDuration: TimeInterval = 0
    private var autoCloseWork: DispatchWorkItem?

    init(appState: AppState) {
        self.appState = appState
    }

    /// Shows the overlay on the display that holds most of `area` (the captured region, in
    /// Cocoa global coordinates). Without an area it uses the display under the pointer.
    func show(record: CaptureRecord, image: NSImage?, near area: CGRect? = nil) {
        self.record = record
        self.image = image
        uploadedURL = record.cloudShareURL
        panel?.orderOut(nil)

        let scale = appState.preferences.quickAccessSize
        let width = 250 + (scale - 1) * 34
        let height = 210 + (scale - 1) * 28
        let visible = (Self.screen(for: area, pointer: NSEvent.mouseLocation, screens: NSScreen.screens) ?? NSScreen.main)?.visibleFrame ?? .zero
        let frame = CGRect(x: visible.maxX - width - 22, y: visible.minY + 22, width: width, height: height)
        let panel = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = NSHostingView(rootView: QuickAccessView(controller: self, appState: appState))
        panel.orderFrontRegardless()
        self.panel = panel
        scheduleAutoClose()
    }

    /// The screen with the largest share of `area`; the screen under `pointer` when there is no
    /// area or it lies off every screen.
    static func screen(for area: CGRect?, pointer: CGPoint, screens: [NSScreen]) -> NSScreen? {
        let frames = screens.map(\.frame)
        return screenIndex(for: area, pointer: pointer, frames: frames).map { screens[$0] }
    }

    static func screenIndex(for area: CGRect?, pointer: CGPoint, frames: [CGRect]) -> Int? {
        if let area {
            let overlaps = frames.enumerated().map { index, frame -> (Int, CGFloat) in
                let shared = frame.intersection(area)
                return (index, shared.isNull ? 0 : shared.width * shared.height)
            }
            if let best = overlaps.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        }
        return frames.firstIndex { $0.contains(pointer) }
    }

    func hide() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        autoCloseDeadline = nil
        panel?.orderOut(nil)
        panel = nil
    }

    /// Hovering pauses auto-close; leaving the overlay restarts the countdown.
    func setHovering(_ hovering: Bool) {
        if hovering {
            autoCloseWork?.cancel()
            autoCloseWork = nil
            autoCloseDeadline = nil
        } else {
            scheduleAutoClose()
        }
    }

    private func scheduleAutoClose() {
        autoCloseWork?.cancel()
        autoCloseWork = nil
        autoCloseDeadline = nil
        let seconds = appState.preferences.quickAccessAutoCloseSeconds
        autoCloseDuration = TimeInterval(max(0, seconds))
        guard seconds > 0, panel != nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.hide() }
        autoCloseWork = work
        autoCloseDeadline = Date().addingTimeInterval(TimeInterval(seconds))
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds), execute: work)
    }

    func markUploaded(recordID: UUID, url: URL) {
        guard record?.id == recordID else { return }
        uploadedURL = url
    }
}

/// A bar that shrinks from full to empty as the auto-close countdown runs. While the
/// countdown is paused (pointer over the overlay) it stays full, because leaving restarts it.
struct AutoCloseCountdownBar: View {
    let deadline: Date?
    let duration: TimeInterval
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // With Reduce Motion the bar steps once per second instead of animating continuously.
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : nil, paused: deadline == nil)) { context in
            let remaining = Self.remaining(until: deadline, at: context.date, duration: duration)
            let fraction = duration > 0 ? remaining / duration : 0
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.black.opacity(0.35))
                    Capsule().fill(.white.opacity(0.9))
                        .frame(width: proxy.size.width * fraction)
                }
            }
            .frame(height: 4)
            .accessibilityElement()
            .accessibilityLabel("Closes automatically")
            .accessibilityValue(deadline == nil ? "Paused" : "\(Int(remaining.rounded(.up))) seconds left")
        }
        .allowsHitTesting(false)
    }

    /// Seconds left in the countdown; the full duration while paused.
    static func remaining(until deadline: Date?, at date: Date, duration: TimeInterval) -> TimeInterval {
        guard let deadline else { return duration }
        return min(duration, max(0, deadline.timeIntervalSince(date)))
    }
}

private struct QuickAccessView: View {
    @ObservedObject var controller: QuickAccessPanelController
    @ObservedObject var appState: AppState
    @State private var isHovering = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack(alignment: .topTrailing) {
                if let image = controller.image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Color.black.opacity(0.16))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .onDrag { fileProvider }
                } else {
                    RoundedRectangle(cornerRadius: 12).fill(.quaternary)
                        .overlay(Image(systemName: "film").font(.title).foregroundStyle(.secondary))
                }
                Button { controller.hide() } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).frame(width: 22, height: 22).background(.black.opacity(0.72), in: Circle()).foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Close")
                .accessibilityLabel("Close Quick Access")
                .padding(8)
            }
            .overlay(alignment: .bottom) {
                if controller.autoCloseDuration > 0 {
                    AutoCloseCountdownBar(deadline: controller.autoCloseDeadline, duration: controller.autoCloseDuration)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 8)
                }
            }
            HStack(spacing: 8) {
                quickButton("folder", "Show", help: "Show the saved file in Finder") { reveal() }
                quickButton("doc.on.doc", "Copy", help: "Copy the capture to the clipboard") { withRecord(appState.copy) }
                quickButton("pencil.and.outline", "Annotate", help: "Open the capture in Annotate") { withRecord(appState.openEditor) }
                if controller.uploadedURL != nil {
                    quickButton("link", "Link", help: "Copy the share link") {
                        guard let url = controller.uploadedURL else { return }
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                } else if appState.preferences.isCloudConfigured {
                    quickButton("icloud.and.arrow.up", "Upload", help: "Upload to your share Worker and copy the link") { withRecord(appState.upload) }
                } else {
                    quickButton("icloud.slash", "Share", help: "Hosted sharing is not set up. Open Cloud settings.") { appState.showSettings(.cloud) }
                }
                quickButton("pin", "Pin", help: "Pin the capture above other windows") { withRecord(appState.pin) }
                quickButton("xmark.circle", "Dismiss", help: "Close this overlay; the capture stays in History") { controller.hide() }
            }
        }
        .padding(10)
        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(isHovering ? 0.30 : 0.14)))
        .onHover { hovering in
            isHovering = hovering
            controller.setHovering(hovering)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Access")
        .contextMenu {
            Button("Copy to Clipboard") { withRecord(appState.copy) }
            Button("Open Annotate") { withRecord(appState.openEditor) }
            if let url = controller.uploadedURL {
                // Already shared: copy the link instead of creating a second hosted copy.
                Button("Copy Share Link") {
                    NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            } else if appState.preferences.isCloudConfigured {
                Button("Upload and Copy Link") { withRecord(appState.upload) }
            } else {
                Button("Set Up Hosted Sharing…") { appState.showSettings(.cloud) }
            }
            Button("Pin to the Screen") { withRecord(appState.pin) }
            Divider()
            Button("Show in Finder") { reveal() }
            Button("Close") { controller.hide() }
        }
    }

    private func quickButton(_ symbol: String, _ title: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).frame(width: 26, height: 22)
                Text(title).font(.system(size: 9, weight: .medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }

    private func withRecord(_ action: (CaptureRecord) -> Void) {
        guard let record = controller.record else { return }
        action(record)
    }

    private func reveal() {
        guard let url = controller.record?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private var fileProvider: NSItemProvider {
        guard let url = controller.record?.fileURL else { return NSItemProvider() }
        return NSItemProvider(contentsOf: url) ?? NSItemProvider()
    }
}
