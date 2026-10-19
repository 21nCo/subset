import Foundation

/// Assigns `WindowRef`s to a source's own window identifiers (`Key`, such as an Accessibility element compared with
/// `CFEqual`): a window keeps its ref for as long as the source reports an equal key for it, whatever order reads and
/// focus changes complete in.
///
/// Every change carries a stamp from one counter, and each ref records when its window was last confirmed present. A
/// read starts with `beginRead(of:)`, takes a ref for each window it sees with `ref(for:in:)`, and ends with
/// `commit(_:)`, which drops only the app's refs that were last confirmed before the read began and that the read did
/// not see: those windows closed. A current read confirms what it sees as of its start; a focus change
/// (`ref(for:pid:)`) confirms its window as of now, whether the window's ref is new or known. So
/// - a window focused after a read began keeps its ref through that read's commit, whichever read assigned the ref;
/// - a read that began before the app's last committed read is stale: it never stores or confirms a ref and does not
///   commit, so a late read never restores older refs, and a ref an older read stored but no later read or focus change
///   confirmed is dropped by a newer read's commit;
/// - a read that began before its app was forgotten (`forgetApp(pid:)`, `retainApps(_:)`) is stale too, so an app that
///   quit is not brought back.
/// A window focused just before it closed can keep its ref until the next read that completes; it is never listed,
/// because only a read lists windows.
public struct WindowRefRegistry<Key: Hashable & Sendable>: Sendable {
    /// One read of an app's windows, from `beginRead(of:)` to `commit(_:)`.
    public struct Read: Sendable {
        public let pid: pid_t
        fileprivate let stamp: UInt64
        fileprivate var seen: Set<Key> = []
    }

    private struct App: Sendable {
        /// When the app's refs were first kept; a read that began earlier belongs to an app that was forgotten.
        let since: UInt64
        /// When the app's last committed read began.
        var committed: UInt64 = 0
        /// Each window's ref and when the window was last confirmed present.
        var refs: [Key: (ref: WindowRef, confirmed: UInt64)] = [:]
    }

    private var apps: [pid_t: App] = [:]
    private var clock: UInt64 = 0
    private var lastRef: UInt64 = 0

    public init() {}

    /// Starts a read of the app's windows.
    public mutating func beginRead(of pid: pid_t) -> Read {
        _ = app(pid)
        return Read(pid: pid, stamp: tick())
    }

    /// The ref of a window the read saw, assigning one if the window has none. A current read confirms the window as
    /// of the read's start. A stale read changes nothing: it returns a known ref, or a ref that is not kept for a window
    /// the registry does not know.
    public mutating func ref(for key: Key, in read: inout Read) -> WindowRef {
        read.seen.insert(key)
        let known = apps[read.pid]?.refs[key]?.ref
        guard isCurrent(read) else { return known ?? nextRef() }
        return confirm(key, pid: read.pid, at: read.stamp)
    }

    /// The ref of a window outside a read, such as one that a focus change reported, assigning one if it has none.
    /// The window is confirmed present now.
    public mutating func ref(for key: Key, pid: pid_t) -> WindowRef {
        _ = app(pid)
        return confirm(key, pid: pid, at: tick())
    }

    /// Ends a read that completed: the app's refs last confirmed before it began and that it did not see are dropped.
    /// A stale read changes nothing.
    public mutating func commit(_ read: Read) {
        guard isCurrent(read), var app = apps[read.pid] else { return }
        app.committed = read.stamp
        app.refs = app.refs.filter { key, value in value.confirmed > read.stamp || read.seen.contains(key) }
        apps[read.pid] = app
    }

    /// Forgets an app's refs: it quit.
    public mutating func forgetApp(pid: pid_t) {
        apps.removeValue(forKey: pid)
    }

    /// Forgets the refs of every app not in `live`.
    public mutating func retainApps(_ live: Set<pid_t>) {
        apps = apps.filter { live.contains($0.key) }
    }

    /// The refs the registry keeps for an app, for tests.
    public func refs(of pid: pid_t) -> Set<WindowRef> {
        Set(apps[pid]?.refs.values.map(\.ref) ?? [])
    }

    /// Whether the read began after its app's refs were first kept and after the app's last committed read began.
    private func isCurrent(_ read: Read) -> Bool {
        apps[read.pid].map { $0.since < read.stamp && $0.committed < read.stamp } ?? false
    }

    /// The window's ref, assigning one if it has none, confirmed present at `stamp` unless it was confirmed later.
    private mutating func confirm(_ key: Key, pid: pid_t, at stamp: UInt64) -> WindowRef {
        if let known = apps[pid]?.refs[key] {
            apps[pid]?.refs[key]?.confirmed = max(known.confirmed, stamp)
            return known.ref
        }
        let ref = nextRef()
        apps[pid]?.refs[key] = (ref, stamp)
        return ref
    }

    private mutating func app(_ pid: pid_t) -> App {
        if let app = apps[pid] { return app }
        let app = App(since: tick())
        apps[pid] = app
        return app
    }

    private mutating func tick() -> UInt64 {
        clock += 1
        return clock
    }

    private mutating func nextRef() -> WindowRef {
        lastRef += 1
        return WindowRef(rawValue: lastRef)
    }
}
