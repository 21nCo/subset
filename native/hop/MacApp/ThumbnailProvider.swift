import AppKit
import HopCore
import os
import ScreenCaptureKit

/// The Screen Recording permission, as the Settings window and the switcher need it. `live` is the real one; tests
/// replace it. Only `request` and `open` can show anything, and only the Settings window calls them.
struct ScreenRecordingPane {
    /// Whether Hop may capture windows now (`CGPreflightScreenCaptureAccess`, which never prompts).
    var isGranted: () -> Bool
    /// Whether Hop has ever asked.
    var wasRequested: () -> Bool
    /// Asks for access (`CGRequestScreenCaptureAccess`), which lets macOS show its prompt and list Hop in the pane.
    var request: () -> Void
    var open: (URL) -> Void

    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
    /// Records that Hop asked, so a later launch tells denied from not determined. Only this flag and the settings
    /// persist; never an image.
    static let requestedKey = "screenRecording.requested"

    @MainActor static let live = ScreenRecordingPane(
        isGranted: { CGPreflightScreenCaptureAccess() },
        wasRequested: { UserDefaults.standard.bool(forKey: requestedKey) },
        request: {
            UserDefaults.standard.set(true, forKey: requestedKey)
            _ = CGRequestScreenCaptureAccess()
        },
        open: { NSWorkspace.shared.open($0) }
    )
}

/// ScreenCaptureKit as Hop's capture source: the on-screen windows of the current Space, without desktop windows,
/// and one still image of a window at a time.
final class ScreenCaptureSource: WindowCaptureSource, @unchecked Sendable {
    // The last listing's windows by ID, for `capture`. SCWindow is an immutable description, read only under the lock.
    private let lock = NSLock()
    private var listed: [CGWindowID: SCWindow] = [:]

    func shareableWindows() async throws -> [CaptureWindow] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let windows = content.windows.filter { $0.owningApplication != nil }
        lock.withLock {
            listed = Dictionary(windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })
        }
        return windows.map { window in
            CaptureWindow(
                id: window.windowID,
                pid: window.owningApplication?.processID ?? 0,
                frame: window.frame,
                title: window.title
            )
        }
    }

    /// The window was not in the last listing.
    private struct NotListed: Error {}

    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> CGImage {
        guard let scWindow = lock.withLock({ listed[window.id] }) else { throw NotListed() }
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: scWindow),
            configuration: configuration
        )
    }
}

/// The switcher's window thumbnails: captures them when the switcher opens (`ThumbnailLoader`, at most 6 at a time),
/// keeps them in memory by `WindowRef` up to 64 MB with least-recently-used eviction (`ThumbnailCache`), drops a
/// window's once it leaves the list, and tells the switcher (`onUpdate`) as each arrives so its cell swaps the icon
/// for the image. Nothing is written to disk and no title is logged.
@MainActor
final class ThumbnailProvider {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "thumbnails")

    private let source: any WindowCaptureSource<CGImage>
    private let ownPid: pid_t
    private var cache: ThumbnailCache<CGImage>
    private var task: Task<Void, Never>?
    /// Bumped by each load and cancel, so a late image of an earlier load is dropped.
    private var generation = 0
    /// A new thumbnail arrived.
    var onUpdate: () -> Void = {}

    init(
        source: any WindowCaptureSource<CGImage> = ScreenCaptureSource(),
        ownPid: pid_t = ProcessInfo.processInfo.processIdentifier,
        capacity: Int = ThumbnailCache<CGImage>.defaultCapacity
    ) {
        self.source = source
        self.ownPid = ownPid
        cache = ThumbnailCache(capacity: capacity)
    }

    var cachedRefs: Set<HopCore.WindowRef> { cache.refs }
    var cachedBytes: Int { cache.totalCost }

    /// The thumbnails of `refs` that are in memory.
    func images(for refs: some Sequence<HopCore.WindowRef>) -> [HopCore.WindowRef: CGImage] {
        var images: [HopCore.WindowRef: CGImage] = [:]
        for ref in refs {
            if let image = cache.image(for: ref) { images[ref] = image }
        }
        return images
    }

    /// Drops what is in memory for windows that are not in `entries` and captures each of them again, replacing any
    /// earlier load. `scale` is the switcher's display's backing scale.
    func load(_ entries: [WindowEntry], scale: CGFloat) {
        cancel()
        retain(entries)
        let generation = generation
        let source = source
        let ownPid = ownPid
        task = Task {
            let outcome = await ThumbnailLoader.load(entries, from: source, excludingPid: ownPid, scale: scale) { ref, image in
                await self.insert(image, for: ref, generation: generation)
            }
            Self.log.debug("Thumbnails: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Drops the thumbnails of windows not in `entries`: they have left the list.
    func retain(_ entries: [WindowEntry]) {
        cache.retain(Set(entries.map(\.ref)))
    }

    /// Stops the load in progress; what it captured stays.
    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

    /// Stops loading and drops every thumbnail: previews were turned off, or Screen Recording is not granted.
    func clear() {
        cancel()
        cache.removeAll()
    }

    private func insert(_ image: CGImage, for ref: HopCore.WindowRef, generation: Int) {
        guard generation == self.generation else { return }
        cache.insert(image, cost: image.bytesPerRow * image.height, for: ref)
        onUpdate()
    }
}
