import Foundation

/// Assigns `WindowRef`s to a source's own window identifiers (`Key`, such as an Accessibility element compared with
/// `CFEqual`): a window keeps its ref for as long as the source reports an equal key for it, whatever order reads and
/// focus changes complete in.
///
/// Every change carries a stamp from one counter. A read starts with `beginRead(of:)`, takes a ref for each window it
/// sees with `ref(for:in:)`, and ends with `commit(_:)`, which drops only the app's refs that existed when the read
/// began and that the read did not see: those windows closed. A ref a read assigns carries the read's start, so it
/// counts as existing for every read that began later. So
/// - a ref a focus change assigns while a read is under way (`ref(for:pid:)`) survives that read's commit;
/// - a read that began before the app's last committed read neither stores refs nor commits, so a late read never
///   restores older refs, and a ref an older read stored before a newer read committed is dropped by that commit;
/// - a read that began before its app was forgotten (`forgetApp(pid:)`, `retainApps(_:)`) neither commits nor stores
///   refs, so an app that quit is not brought back.
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
        var refs: [Key: (ref: WindowRef, assigned: UInt64)] = [:]
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

    /// The ref of a window the read saw, assigning one if the window has none. A read whose app was forgotten after
    /// it began, or that began before the app's last committed read, gets a ref that is not kept for a window the
    /// registry does not know.
    public mutating func ref(for key: Key, in read: inout Read) -> WindowRef {
        read.seen.insert(key)
        if let known = apps[read.pid]?.refs[key] { return known.ref }
        guard isCurrent(read), let app = apps[read.pid], read.stamp > app.committed else { return nextRef() }
        return assign(key, pid: read.pid, at: read.stamp)
    }

    /// The ref of a window outside a read, such as one that a focus change reported, assigning one if it has none.
    public mutating func ref(for key: Key, pid: pid_t) -> WindowRef {
        if let known = apps[pid]?.refs[key] { return known.ref }
        _ = app(pid)
        return assign(key, pid: pid, at: tick())
    }

    /// Ends a read that completed: the app's refs that existed when it began and that it did not see are dropped. A
    /// read older than the app's last committed one, or than the app's forgetting, changes nothing.
    public mutating func commit(_ read: Read) {
        guard isCurrent(read), var app = apps[read.pid], read.stamp > app.committed else { return }
        app.committed = read.stamp
        app.refs = app.refs.filter { key, value in value.assigned > read.stamp || read.seen.contains(key) }
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

    private func isCurrent(_ read: Read) -> Bool {
        apps[read.pid].map { $0.since < read.stamp } ?? false
    }

    private mutating func assign(_ key: Key, pid: pid_t, at stamp: UInt64) -> WindowRef {
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
