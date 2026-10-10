import AppKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var onCapture: ((ClipboardItem) -> Void)?
    private var lastChangeCount: Int
    private var isPaused = false

    init() {
        lastChangeCount = pasteboard.changeCount
    }

    func start(onCapture: @escaping (ClipboardItem) -> Void) {
        stop()
        self.onCapture = onCapture
        lastChangeCount = pasteboard.changeCount

        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        // Re-baseline on both pause and resume, so a change made while paused is never captured.
        lastChangeCount = pasteboard.changeCount
    }

    /// Skips the pasteboard change with this count (Clipboard's own write when it pastes an
    /// item back). Bound to the change itself, so a failed or skipped write leaves nothing
    /// behind to swallow a later copy.
    func ignoreChange(_ changeCount: Int) {
        if lastChangeCount != changeCount { lastChangeCount = changeCount }
    }

    /// Pasteboard markers from the nspasteboard.org convention. Password managers mark secrets as
    /// concealed, and apps mark short-lived or generated content as transient or auto-generated.
    /// Clipboard never stores these, matching Maccy and Paste.
    static func shouldIgnore(types: [NSPasteboard.PasteboardType]) -> Bool {
        ClipboardPrivacy.shouldIgnore(typeIdentifiers: types.map(\.rawValue))
    }

    private func poll() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        guard !isPaused else { return }
        guard !Self.shouldIgnore(types: pasteboard.types ?? []) else { return }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        guard let capturedItem = ClipboardItem.fromPasteboard(pasteboard, sourceApp: sourceApp) else {
            return
        }

        onCapture?(capturedItem)
    }
}
