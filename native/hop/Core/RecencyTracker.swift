import CoreGraphics
import Foundation

/// A window in the window server's front-to-back order, reduced to what seeding needs: its owner and frame. Window
/// names are never read.
public struct OnScreenWindow: Sendable, Equatable {
    public var pid: pid_t
    public var frame: CGRect

    public init(pid: pid_t, frame: CGRect) {
        self.pid = pid
        self.frame = frame
    }

    /// The normal-layer windows in a `CGWindowListCopyWindowInfo` result, in its front-to-back order. Entries
    /// without an owner, bounds, or layer 0 (menus, the Dock, panels above windows) are dropped.
    public static func frontToBack(windowInfo: [[String: Any]]) -> [OnScreenWindow] {
        windowInfo.compactMap { info in
            guard
                (info["kCGWindowLayer"] as? NSNumber)?.intValue == 0,
                let pid = (info["kCGWindowOwnerPID"] as? NSNumber)?.int32Value,
                let bounds = info["kCGWindowBounds"] as? [String: Any],
                let x = (bounds["X"] as? NSNumber)?.doubleValue,
                let y = (bounds["Y"] as? NSNumber)?.doubleValue,
                let width = (bounds["Width"] as? NSNumber)?.doubleValue,
                let height = (bounds["Height"] as? NSNumber)?.doubleValue
            else { return nil }
            return OnScreenWindow(pid: pid, frame: CGRect(x: x, y: y, width: width, height: height))
        }
    }
}

/// Most-recently-used order of windows, keyed by `WindowRef`.
///
/// It is seeded from the window server's front-to-back order, matched to listed windows by owner and frame, and
/// updated as windows gain focus. Windows it has never seen (not on screen when it was seeded, never focused since)
/// follow the known ones in source order. It holds only refs and their owners, never titles.
public struct RecencyTracker: Sendable {
    /// How far apart two frames' edges may be and still match, in points.
    public static let frameTolerance: CGFloat = 1

    /// Known windows, most recent first.
    public private(set) var order: [WindowRef] = []
    private var owners: [WindowRef: pid_t] = [:]

    public init() {}

    /// Puts the listed windows that appear on screen first, in the on-screen front-to-back order; windows known
    /// before follow in their previous order. Each on-screen window matches the first listed window, in source order,
    /// of the same process whose frame is within `frameTolerance` and that no earlier on-screen window matched, so two
    /// windows with the same frame keep their source order. Minimized windows and windows of hidden apps are not on
    /// screen, so they never match.
    public mutating func seed(_ entries: [WindowEntry], frontToBack onScreen: [OnScreenWindow]) {
        var unmatched = entries.filter { !$0.isMinimized && !$0.isAppHidden }
        var seeded: [WindowRef] = []
        for window in onScreen {
            guard let index = unmatched.firstIndex(where: { $0.pid == window.pid && Self.matches($0.frame, window.frame) })
            else { continue }
            let entry = unmatched.remove(at: index)
            seeded.append(entry.ref)
            owners[entry.ref] = entry.pid
        }
        let seededSet = Set(seeded)
        order = seeded + order.filter { !seededSet.contains($0) }
    }

    /// Moves a window to the front: it was focused or became its app's main window.
    public mutating func noteFocused(_ ref: WindowRef, pid: pid_t) {
        order.removeAll { $0 == ref }
        order.insert(ref, at: 0)
        owners[ref] = pid
    }

    /// An app became active without a focused window Hop could read: its most recent known window moves to the
    /// front. Returns false when the tracker knows no window of the app.
    @discardableResult
    public mutating func noteActivated(pid: pid_t) -> Bool {
        guard let ref = order.first(where: { owners[$0] == pid }) else { return false }
        noteFocused(ref, pid: pid)
        return true
    }

    /// Forgets windows that are no longer listed (closed, or no longer switchable), except those of apps that were
    /// skipped this time, whose windows are unknown rather than gone.
    public mutating func retain(_ entries: [WindowEntry], keepingAppsOf skipped: Set<pid_t> = []) {
        let listed = Set(entries.map(\.ref))
        order.removeAll { ref in
            !listed.contains(ref) && !(owners[ref].map(skipped.contains) ?? false)
        }
        let kept = Set(order)
        owners = owners.filter { kept.contains($0.key) }
    }

    /// Forgets every window of an app that quit.
    public mutating func forgetApp(pid: pid_t) {
        order.removeAll { owners[$0] == pid }
        owners = owners.filter { $0.value != pid }
    }

    /// The entries in recency order: known windows first, most recent first, then the rest in their given order.
    public func ordered(_ entries: [WindowEntry]) -> [WindowEntry] {
        var rank: [WindowRef: Int] = [:]
        for (index, ref) in order.enumerated() { rank[ref] = index }
        let known = entries.compactMap { entry in rank[entry.ref].map { (rank: $0, entry: entry) } }
            .sorted { $0.rank < $1.rank }
            .map(\.entry)
        return known + entries.filter { rank[$0.ref] == nil }
    }

    private static func matches(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= frameTolerance && abs(a.minY - b.minY) <= frameTolerance
            && abs(a.width - b.width) <= frameTolerance && abs(a.height - b.height) <= frameTolerance
    }
}
