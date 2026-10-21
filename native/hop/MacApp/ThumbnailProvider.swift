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

/// A window of one ScreenCaptureKit listing. `SCWindow` is an immutable description of the window, so the load that
/// listed it may hand it to its own captures.
struct ShareableWindow: @unchecked Sendable {
    let window: SCWindow
}

/// ScreenCaptureKit as Hop's capture source: the on-screen windows of the current Space, without desktop windows,
/// and one still image of a window at a time. It keeps no listing of its own: each capture is of a window its load
/// listed.
final class ScreenCaptureSource: WindowCaptureSource {
    func shareableWindows() async throws -> [ListedWindow<ShareableWindow>] {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        return content.windows.compactMap { window in
            guard let app = window.owningApplication else { return nil }
            return ListedWindow(
                window: CaptureWindow(id: window.windowID, pid: app.processID, frame: window.frame, title: window.title),
                handle: ShareableWindow(window: window)
            )
        }
    }

    func capture(_ handle: ShareableWindow, size: PixelSize) async throws -> CGImage {
        let configuration = SCStreamConfiguration()
        configuration.width = size.width
        configuration.height = size.height
        configuration.scalesToFit = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        return try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: handle.window),
            configuration: configuration
        )
    }
}

/// The switcher's window thumbnails: captures them when the switcher opens (`ThumbnailLoader`, at most 6 at a time across
/// openings, counting captures of an earlier opening that are still running), keeps them in memory by `WindowRef` up to
/// 64 MB with least-recently-used eviction (`ThumbnailCache`), and tells the switcher (`onUpdate`) as each arrives or
/// goes so its cell swaps between the icon and the image. Nothing is written to disk and no title is logged.
///
/// An image is kept only for a window that is listed now and that the latest load matched: a listed window may show
/// its earlier image until its new one arrives, but loses it when the load does not match it or its capture fails, and
/// every image goes when the listing fails. A window that leaves the list loses its image, and a capture of it still
/// running is dropped when it returns.
@MainActor
final class ThumbnailProvider {
    private static let log = Logger(subsystem: HopIdentity.bundleIdentifier, category: "thumbnails")

    private let source: any WindowCaptureSource<CGImage>
    private let ownPid: pid_t
    private let limiter = CaptureLimiter(limit: ThumbnailLoader.maxConcurrent)
    private var cache: ThumbnailCache<CGImage>
    private var task: Task<Void, Never>?
    /// Bumped by each load and cancel, so a late event of an earlier load is dropped.
    private var generation = 0
    /// The windows the load in progress may still deliver an image for: listed now, and once the listing is back,
    /// matched and not yet delivered.
    private var pending: Set<HopCore.WindowRef> = []
    /// A thumbnail arrived or went.
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
    /// Captures running now, including those of a load that was replaced or cancelled.
    var capturesInFlight: Int { limiter.inFlight }

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
        pending = Set(entries.map(\.ref))
        let generation = generation
        let source = source
        let ownPid = ownPid
        let limiter = limiter
        task = Task {
            let outcome = await ThumbnailLoader.load(
                entries, from: source, excludingPid: ownPid, scale: scale, limiter: limiter
            ) { event in
                await self.handle(event, generation: generation)
            }
            if outcome == .unavailable { listingFailed(generation: generation) }
            Self.log.debug("Thumbnails: \(String(describing: outcome), privacy: .public)")
        }
    }

    /// Drops the thumbnails of windows not in `entries`, and any image of theirs still being captured: they have left
    /// the list.
    func retain(_ entries: [WindowEntry]) {
        let refs = Set(entries.map(\.ref))
        cache.retain(refs)
        pending.formIntersection(refs)
    }

    /// Stops the load in progress; what it captured stays, and nothing it still captures is kept.
    func cancel() {
        generation += 1
        pending = []
        task?.cancel()
        task = nil
    }

    /// Stops loading and drops every thumbnail: previews were turned off, or Screen Recording is not granted.
    func clear() {
        cancel()
        cache.removeAll()
    }

    private func handle(_ event: ThumbnailEvent<CGImage>, generation: Int) {
        guard generation == self.generation else { return }
        switch event {
        case let .listed(matched):
            // A listed window this load does not match shows its icon from now on.
            pending.formIntersection(matched)
            let before = cache.count
            cache.retain(pending)
            if cache.count != before { onUpdate() }
        case let .captured(ref, image):
            guard pending.remove(ref) != nil else { return }
            cache.insert(image, cost: image.bytesPerRow * image.height, for: ref)
            onUpdate()
        case let .failed(ref):
            pending.remove(ref)
            guard cache.refs.contains(ref) else { return }
            cache.remove(ref)
            onUpdate()
        }
    }

    /// The windows could not be listed (for example, Screen Recording was refused although it read as granted), so
    /// every cell shows its icon.
    private func listingFailed(generation: Int) {
        guard generation == self.generation else { return }
        pending = []
        guard cache.count > 0 else { return }
        cache.removeAll()
        onUpdate()
    }
}
