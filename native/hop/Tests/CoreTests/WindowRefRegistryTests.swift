import CoreGraphics
import Foundation
import HopCore
import XCTest

final class WindowRefRegistryTests: XCTestCase {
    private let pid: pid_t = 10

    private func read(_ keys: [String], into registry: inout WindowRefRegistry<String>) -> [HopCore.WindowRef] {
        var read = registry.beginRead(of: pid)
        let refs = keys.map { registry.ref(for: $0, in: &read) }
        registry.commit(read)
        return refs
    }

    func testAWindowKeepsItsRefAcrossReadsAndAClosedOneIsDropped() {
        var registry = WindowRefRegistry<String>()
        let first = read(["a", "b"], into: &registry)
        let second = read(["a"], into: &registry)
        XCTAssertEqual(second, [first[0]])
        XCTAssertEqual(registry.refs(of: pid), [first[0]], "b was absent from a completed read: it closed")
        XCTAssertNotEqual(read(["b"], into: &registry), [first[1]], "a window seen again after closing is a new window")
    }

    func testAnOperationReachesAWindowByItsRefUntilAReadFindsItClosed() {
        var registry = WindowRefRegistry<String>()
        let refs = read(["a", "b"], into: &registry)
        XCTAssertEqual(registry.key(for: refs[1], pid: pid), "b")
        XCTAssertNil(registry.key(for: refs[1], pid: pid + 1), "a ref names a window of its own app only")
        _ = read(["a"], into: &registry)
        XCTAssertNil(registry.key(for: refs[1], pid: pid), "b closed")
        XCTAssertEqual(registry.key(for: refs[0], pid: pid), "a")
        registry.forgetApp(pid: pid)
        XCTAssertNil(registry.key(for: refs[0], pid: pid), "the app quit")
    }

    func testARefAFocusChangeAssignsDuringAReadSurvivesItsCommit() {
        var registry = WindowRefRegistry<String>()
        let a = read(["a"], into: &registry)[0]
        var pending = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &pending), a)
        // Window b opens after the read listed the app's windows and is focused before the read commits.
        let b = registry.ref(for: "b", pid: pid)
        registry.commit(pending)
        XCTAssertEqual(registry.refs(of: pid), [a, b])
        XCTAssertEqual(read(["a", "b"], into: &registry), [a, b], "the next read finds b's ref")
    }

    func testALateReadDoesNotReplaceTheRefsOfANewerOne() {
        var registry = WindowRefRegistry<String>()
        var late = registry.beginRead(of: pid)
        let a = registry.ref(for: "a", in: &late)
        _ = registry.ref(for: "b", in: &late)
        // A newer read starts and completes while the first is still waiting on the app: b closed, c opened.
        let newer = read(["a", "c"], into: &registry)
        XCTAssertEqual(newer[0], a)
        let focused = registry.ref(for: "d", pid: pid)
        registry.commit(late)
        XCTAssertEqual(registry.refs(of: pid), [a, newer[1], focused], "b is not restored, and c and d are kept")
    }

    func testALateReadStoresNoRefForAWindowANewerReadFoundClosed() {
        var registry = WindowRefRegistry<String>()
        let a = read(["a", "b"], into: &registry)[0]
        var late = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &late), a)
        // A newer read finds b closed and commits; then the late read reaches b, which it listed before b closed.
        _ = read(["a"], into: &registry)
        let focused = registry.ref(for: "c", pid: pid)
        _ = registry.ref(for: "b", in: &late)
        XCTAssertEqual(registry.refs(of: pid), [a, focused], "the late read does not bring b back")
        registry.commit(late)
        XCTAssertEqual(registry.refs(of: pid), [a, focused])
    }

    func testARefALateReadStoredBeforeANewerReadCommittedIsDroppedByThatCommit() {
        var registry = WindowRefRegistry<String>()
        let a = read(["a", "b"], into: &registry)[0]
        var late = registry.beginRead(of: pid)
        var newer = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &newer), a)
        // The late read listed x, which closed before the newer read listed the windows.
        _ = registry.ref(for: "x", in: &late)
        let focused = registry.ref(for: "c", pid: pid)
        registry.commit(newer)
        XCTAssertEqual(registry.refs(of: pid), [a, focused], "x and b are gone; the focus ref is kept")
    }

    func testAWindowFocusedAfterANewerReadBeganKeepsTheRefAnOlderReadAssigned() {
        var registry = WindowRefRegistry<String>()
        let a = read(["a"], into: &registry)[0]
        var older = registry.beginRead(of: pid)
        var newer = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &newer), a)
        // The older read lists x, which opened after the newer read listed the windows; then x is focused.
        let x = registry.ref(for: "x", in: &older)
        XCTAssertEqual(registry.ref(for: "x", pid: pid), x)
        registry.commit(newer)
        XCTAssertEqual(registry.refs(of: pid), [a, x], "the focus change confirmed x after the newer read began")
        registry.commit(older)
        XCTAssertEqual(read(["a", "x"], into: &registry), [a, x])
    }

    func testAKnownWindowFocusedAfterAReadBeganSurvivesThatReadsCommit() {
        var registry = WindowRefRegistry<String>()
        let refs = read(["a", "b"], into: &registry)
        var pending = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &pending), refs[0])
        // b is missing from the read's list but is focused after the read began: it is still open.
        XCTAssertEqual(registry.ref(for: "b", pid: pid), refs[1])
        registry.commit(pending)
        XCTAssertEqual(registry.refs(of: pid), Set(refs))
        XCTAssertEqual(read(["a", "b"], into: &registry), refs, "the next read finds b's ref")
    }

    func testAReadConfirmsWhatItSawOnlyAsOfItsStart() {
        var registry = WindowRefRegistry<String>()
        let refs = read(["a", "k"], into: &registry)
        var slower = registry.beginRead(of: pid)
        var newer = registry.beginRead(of: pid)
        XCTAssertEqual(registry.ref(for: "a", in: &newer), refs[0])
        // The slower read reaches k after the newer read found k closed: its sighting is older than the newer listing.
        XCTAssertEqual(registry.ref(for: "k", in: &slower), refs[1])
        registry.commit(newer)
        XCTAssertEqual(registry.refs(of: pid), [refs[0]], "k closed")

        let m = read(["a", "m"], into: &registry)[1]
        var stale = registry.beginRead(of: pid)
        _ = read(["a", "m"], into: &registry)
        var current = registry.beginRead(of: pid)
        // A stale read sights m after a current read began; it confirms nothing, so the current read still drops m.
        XCTAssertEqual(registry.ref(for: "m", in: &stale), m)
        XCTAssertEqual(registry.ref(for: "a", in: &current), refs[0])
        registry.commit(current)
        XCTAssertEqual(registry.refs(of: pid), [refs[0]], "m closed")
        registry.commit(stale)
        XCTAssertEqual(registry.refs(of: pid), [refs[0]])
    }

    func testAReadOfAnAppForgottenAfterItBeganKeepsNothing() {
        var registry = WindowRefRegistry<String>()
        _ = read(["a"], into: &registry)
        var late = registry.beginRead(of: pid)
        registry.forgetApp(pid: pid)
        _ = registry.ref(for: "a", in: &late)
        registry.commit(late)
        XCTAssertEqual(registry.refs(of: pid), [], "the app quit; the late read does not bring its refs back")

        var other = registry.beginRead(of: pid)
        registry.retainApps([20])
        // A new process with the same pid is focused before the old read commits.
        let focused = registry.ref(for: "z", pid: pid)
        _ = registry.ref(for: "a", in: &other)
        registry.commit(other)
        XCTAssertEqual(registry.refs(of: pid), [focused], "the read from before the app was forgotten drops nothing")
    }

    func testAReadThatNeverCompletesDropsNothing() {
        var registry = WindowRefRegistry<String>()
        let refs = read(["a", "b"], into: &registry)
        var abandoned = registry.beginRead(of: pid)
        _ = registry.ref(for: "a", in: &abandoned)
        XCTAssertEqual(registry.refs(of: pid), Set(refs))
    }

    /// A refresh that gives up on an app whose read then completes late, after a newer window was focused, keeps that
    /// window first on the next refresh.
    func testAFocusedWindowKeepsItsPlaceWhenAnAbandonedReadCompletesLate() {
        let source = RegistryWindowSource(app: WindowFixture.app(pid, "Editor"), windows: ["a"])
        var lister = WindowLister(source: source, ownProcess: WindowFixture.ownProcess, appBudget: .milliseconds(20))
        XCTAssertEqual(lister.refresh().windows.count, 1)

        let gate = DispatchSemaphore(value: 0)
        let committed = DispatchSemaphore(value: 0)
        source.hold(until: gate, signalling: committed)
        XCTAssertEqual(lister.refresh().skippedApps.map(\.pid), [pid], "the held read is abandoned at the cutoff")

        source.open("b")
        let b = source.focus("b")
        lister.noteFocused(b, pid: pid)
        gate.signal()
        XCTAssertEqual(committed.wait(timeout: .now() + 5), .success)

        let list = lister.refresh()
        XCTAssertEqual(list.windows.count, 2)
        XCTAssertEqual(list.windows.first?.ref, b, "b keeps its ref and stays most recent")
    }

    /// Two refreshes give up on an app. The older read lists x, a window the newer read missed, and x is focused before
    /// the newer read commits: x keeps its ref and is first on the next refresh.
    func testAWindowFocusedBetweenTwoAbandonedReadsKeepsItsPlace() {
        let source = RegistryWindowSource(app: WindowFixture.app(pid, "Editor"), windows: ["a"])
        var lister = WindowLister(source: source, ownProcess: WindowFixture.ownProcess, appBudget: .milliseconds(20))
        XCTAssertEqual(lister.refresh().windows.count, 1)

        let olderGate = DispatchSemaphore(value: 0)
        let olderDone = DispatchSemaphore(value: 0)
        source.hold(until: olderGate, signalling: olderDone, beforeListing: true)
        XCTAssertEqual(lister.refresh().skippedApps.map(\.pid), [pid], "the older read is abandoned before it lists")
        let newerGate = DispatchSemaphore(value: 0)
        let newerDone = DispatchSemaphore(value: 0)
        source.hold(until: newerGate, signalling: newerDone)
        XCTAssertEqual(lister.refresh().skippedApps.map(\.pid), [pid], "the newer read lists a and is abandoned")

        source.open("x")
        olderGate.signal()
        XCTAssertEqual(olderDone.wait(timeout: .now() + 5), .success)
        let x = source.focus("x")
        lister.noteFocused(x, pid: pid)
        newerGate.signal()
        XCTAssertEqual(newerDone.wait(timeout: .now() + 5), .success)

        let list = lister.refresh()
        XCTAssertEqual(list.windows.count, 2)
        XCTAssertEqual(list.windows.first?.ref, x, "x keeps its ref and stays most recent")
    }
}

/// One app whose windows are named by strings, with refs from a `WindowRefRegistry` as `AXWindowSource` assigns
/// them. A read can be held before it lists the windows, or after it has listed them and before it commits.
private final class RegistryWindowSource: WindowSource, @unchecked Sendable {
    private let lock = NSLock()
    private let app: SourceApp
    private var keys: [String]
    private var registry = WindowRefRegistry<String>()
    private var held: (gate: DispatchSemaphore, committed: DispatchSemaphore, beforeListing: Bool)?

    init(app: SourceApp, windows: [String]) {
        self.app = app
        keys = windows
    }

    func hold(until gate: DispatchSemaphore, signalling committed: DispatchSemaphore, beforeListing: Bool = false) {
        lock.withLock { held = (gate, committed, beforeListing) }
    }

    func open(_ key: String) {
        lock.withLock { keys.append(key) }
    }

    func focus(_ key: String) -> HopCore.WindowRef {
        lock.withLock { registry.ref(for: key, pid: app.pid) }
    }

    func apps() -> [SourceApp] { [app] }

    func displays() -> [SourceDisplay] { [WindowFixture.mainDisplay] }

    func windows(of app: SourceApp, until _: ContinuousClock.Instant) throws(WindowSourceError) -> [SourceWindow] {
        let (start, held) = lock.withLock {
            let held = self.held
            self.held = nil
            return (registry.beginRead(of: app.pid), held)
        }
        if held?.beforeListing == true { held?.gate.wait() }
        let (windows, read) = lock.withLock {
            var read = start
            let windows = keys.map { key in
                SourceWindow(
                    ref: registry.ref(for: key, in: &read),
                    title: "",
                    subrole: "AXStandardWindow",
                    isMinimized: false,
                    isFullscreen: false,
                    frame: CGRect(x: 0, y: 0, width: 800, height: 600)
                )
            }
            return (windows, read)
        }
        if held?.beforeListing == false { held?.gate.wait() }
        lock.withLock { registry.commit(read) }
        held?.committed.signal()
        return windows
    }
}
