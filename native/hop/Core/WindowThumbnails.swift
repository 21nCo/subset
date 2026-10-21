import CoreGraphics
import Foundation

/// A window the capture source can capture (ScreenCaptureKit's `SCWindow`), as matching needs it.
public struct CaptureWindow: Sendable, Equatable {
    /// The window server's ID for the window (`CGWindowID`).
    public var id: UInt32
    /// The pid of the app that owns it.
    public var pid: pid_t
    /// Its frame in global screen points with the origin at the top left of the main display, as `WindowEntry.frame`.
    public var frame: CGRect
    /// Its title, or nil when the source reports none. Used only to tell apart windows with the same frame; never
    /// logged or persisted.
    public var title: String?

    public init(id: UInt32, pid: pid_t, frame: CGRect, title: String?) {
        self.id = id
        self.pid = pid
        self.frame = frame
        self.title = title
    }
}

/// Where thumbnails come from: ScreenCaptureKit in the app, a fake in tests. Neither call may show a permission prompt
/// by itself being called; the caller only calls them while Screen Recording is granted.
public protocol WindowCaptureSource<Image>: Sendable {
    associatedtype Image: Sendable

    /// The windows on the current Space that can be captured now.
    func shareableWindows() async throws -> [CaptureWindow]

    /// An image of `window` at `size` pixels.
    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> Image
}

/// A size in whole pixels.
public struct PixelSize: Sendable, Equatable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }
}

/// Which captured window shows in which cell. The rules are closed:
///
/// - a minimized window never matches: it always shows its icon;
/// - a window of Hop's own process never matches;
/// - an entry matches a capture window of the same pid whose frame is equal within 1 pt on each edge and size;
/// - when several capture windows match an entry, only one whose title equals the entry's title matches;
/// - when several entries match one capture window, only the entry whose title equals the window's title keeps it;
/// - anything else matches nothing, and the cell keeps its icon.
public enum ThumbnailMatcher {
    public static let frameTolerance: CGFloat = 1

    /// The capture window for each entry that has exactly one, by the entry's ref.
    public static func matches(
        _ entries: [WindowEntry],
        among windows: [CaptureWindow],
        excludingPid ownPid: pid_t
    ) -> [WindowRef: CaptureWindow] {
        let windows = windows.filter { $0.pid != ownPid }
        var chosen: [WindowRef: CaptureWindow] = [:]
        for entry in entries where !entry.isMinimized {
            let candidates = windows.filter { $0.pid == entry.pid && framesMatch($0.frame, entry.frame) }
            let match = candidates.count == 1 ? candidates[0] : unique(candidates.filter { $0.title == entry.title })
            if let match { chosen[entry.ref] = match }
        }
        // One capture window claimed by several entries goes only to the one with its title, or to none.
        var claims: [UInt32: [WindowRef]] = [:]
        for (ref, window) in chosen { claims[window.id, default: []].append(ref) }
        let titles = Dictionary(entries.map { ($0.ref, $0.title) }, uniquingKeysWith: { first, _ in first })
        for (_, refs) in claims where refs.count > 1 {
            let keeper = unique(refs.filter { titles[$0] == chosen[$0]?.title })
            for ref in refs where ref != keeper { chosen[ref] = nil }
        }
        return chosen
    }

    public static func framesMatch(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }

    private static func unique<T>(_ values: [T]) -> T? {
        values.count == 1 ? values[0] : nil
    }
}

/// How big a thumbnail is captured: the window's shape fitted into the cell's preview area, times the display's
/// backing scale, so it is drawn at one pixel per pixel.
public enum ThumbnailSizing {
    /// The preview area of a switcher cell, in points: the cell's width without its padding, and the height its 64 pt
    /// icon takes.
    public static let cellArea = CGSize(width: 136, height: 64)

    /// `frame`'s aspect fitted into `area` at `scale`, at least one pixel each way; nil for an empty frame.
    public static func pixelSize(for frame: CGRect, in area: CGSize = cellArea, scale: CGFloat) -> PixelSize? {
        guard frame.width > 0, frame.height > 0, area.width > 0, area.height > 0, scale > 0 else { return nil }
        let fit = min(area.width / frame.width, area.height / frame.height)
        return PixelSize(
            width: max(1, Int((frame.width * fit * scale).rounded())),
            height: max(1, Int((frame.height * fit * scale).rounded()))
        )
    }
}

/// Thumbnails in memory, by window, up to `capacity` bytes. Adding one past the cap evicts the least recently used
/// (added or looked up) until it fits; one larger than the cap is not kept. Nothing is written to disk.
public struct ThumbnailCache<Image> {
    /// 64 MB.
    public static var defaultCapacity: Int { 64 * 1024 * 1024 }

    public let capacity: Int
    public private(set) var totalCost = 0
    private var entries: [WindowRef: (image: Image, cost: Int, used: UInt64)] = [:]
    private var clock: UInt64 = 0

    public init(capacity: Int = Self.defaultCapacity) {
        self.capacity = capacity
    }

    public var count: Int { entries.count }
    public var refs: Set<WindowRef> { Set(entries.keys) }

    /// The thumbnail of `ref`, marking it used.
    public mutating func image(for ref: WindowRef) -> Image? {
        guard var entry = entries[ref] else { return nil }
        clock += 1
        entry.used = clock
        entries[ref] = entry
        return entry.image
    }

    /// Keeps `image` as `ref`'s thumbnail in place of any earlier one, evicting the least recently used to stay within
    /// the cap. An image that costs more than the whole cap is not kept, and `ref`'s earlier one goes too.
    public mutating func insert(_ image: Image, cost: Int, for ref: WindowRef) {
        remove(ref)
        guard cost <= capacity else { return }
        while totalCost + cost > capacity, let oldest = entries.min(by: { $0.value.used < $1.value.used })?.key {
            remove(oldest)
        }
        clock += 1
        entries[ref] = (image, cost, clock)
        totalCost += cost
    }

    /// Drops the thumbnails of windows not in `refs`: they have left the list.
    public mutating func retain(_ refs: Set<WindowRef>) {
        for ref in entries.keys where !refs.contains(ref) { remove(ref) }
    }

    public mutating func removeAll() {
        entries.removeAll()
        totalCost = 0
    }

    private mutating func remove(_ ref: WindowRef) {
        if let old = entries.removeValue(forKey: ref) { totalCost -= old.cost }
    }
}

/// Captures thumbnails for a switcher's windows: lists the capturable windows once, matches them to the entries
/// (`ThumbnailMatcher`), and captures each match, at most `maxConcurrent` at a time, in the entries' order. Each image
/// is handed to `deliver` as it arrives; a window whose capture fails is skipped and the others go on.
public enum ThumbnailLoader {
    public static let maxConcurrent = 6

    /// How a load ended.
    public enum Outcome: Sendable, Equatable {
        /// The windows were listed; `captured` images were delivered and `failed` captures were skipped.
        case finished(captured: Int, failed: Int)
        /// Listing the capturable windows failed (for example, Screen Recording was refused): nothing was captured.
        case unavailable
        case cancelled
    }

    public static func load<Source: WindowCaptureSource>(
        _ entries: [WindowEntry],
        from source: Source,
        excludingPid ownPid: pid_t,
        scale: CGFloat,
        maxConcurrent: Int = maxConcurrent,
        deliver: @escaping @Sendable (WindowRef, Source.Image) async -> Void
    ) async -> Outcome {
        guard let windows = try? await source.shareableWindows() else {
            return Task.isCancelled ? .cancelled : .unavailable
        }
        let matches = ThumbnailMatcher.matches(entries, among: windows, excludingPid: ownPid)
        let jobs: [(WindowRef, CaptureWindow, PixelSize)] = entries.compactMap { entry in
            guard let window = matches[entry.ref],
                  let size = ThumbnailSizing.pixelSize(for: window.frame, scale: scale)
            else { return nil }
            return (entry.ref, window, size)
        }
        var captured = 0
        var failed = 0
        await withTaskGroup(of: Bool.self) { group in
            var next = jobs.makeIterator()
            func start() -> Bool {
                guard !Task.isCancelled, let (ref, window, size) = next.next() else { return false }
                group.addTask {
                    guard let image = try? await source.capture(window, size: size), !Task.isCancelled else { return false }
                    await deliver(ref, image)
                    return true
                }
                return true
            }
            for _ in 0..<max(1, maxConcurrent) {
                guard start() else { break }
            }
            while let delivered = await group.next() {
                if delivered { captured += 1 } else { failed += 1 }
                _ = start()
            }
        }
        return Task.isCancelled ? .cancelled : .finished(captured: captured, failed: failed)
    }
}

/// Whether Hop may capture windows, as far as it can tell from public API: macOS reports only whether access is
/// granted, so whether Hop ever asked tells not determined from denied, and having seen it granted while running tells
/// denied from revoked.
public enum ScreenRecordingAccess: Sendable, Equatable {
    /// Hop has never asked.
    case notDetermined
    case granted
    /// Hop asked and it is not granted.
    case denied
    /// It was granted while Hop ran and no longer is.
    case revoked

    /// The one line the Settings window shows while previews are on and the switcher shows icons; nil when granted.
    public var notice: String? {
        switch self {
        case .granted: nil
        case .notDetermined: "Hop hasn't asked for Screen Recording yet, so the switcher shows app icons."
        case .denied: "Screen Recording isn't allowed for Hop, so the switcher shows app icons."
        case .revoked: "Screen Recording was turned off for Hop, so the switcher shows app icons."
        }
    }
}

/// Follows the Screen Recording permission across samples. The host samples it when the Settings window shows, when
/// Hop becomes active, when previews are turned on, and each time the switcher opens with previews on; a sample never
/// prompts.
public struct ScreenRecordingGate: Sendable, Equatable {
    public private(set) var access = ScreenRecordingAccess.notDetermined
    private var wasGranted = false

    public init() {}

    /// Records a sample: whether access is granted now, and whether Hop has ever asked for it.
    @discardableResult
    public mutating func update(granted: Bool, requested: Bool) -> ScreenRecordingAccess {
        if granted {
            wasGranted = true
            access = .granted
        } else {
            access = wasGranted ? .revoked : (requested ? .denied : .notDetermined)
        }
        return access
    }

    /// Whether the switcher captures thumbnails: only with previews on and access granted. Otherwise it shows icons.
    public static func captures(previewsOn: Bool, access: ScreenRecordingAccess) -> Bool {
        previewsOn && access == .granted
    }
}
