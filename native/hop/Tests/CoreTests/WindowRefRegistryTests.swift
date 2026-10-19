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
}

/// One app whose windows are named by strings, with refs from a `WindowRefRegistry` as `AXWindowSource` assigns
/// them. A read can be held after it has listed the windows and before it commits.
private final class RegistryWindowSource: WindowSource, @unchecked Sendable {
    private let lock = NSLock()
    private let app: SourceApp
    private var keys: [String]
    private var registry = WindowRefRegistry<String>()
    private var held: (gate: DispatchSemaphore, committed: DispatchSemaphore)?

    init(app: SourceApp, windows: [String]) {
        self.app = app
        keys = windows
    }

    func hold(until gate: DispatchSemaphore, signalling committed: DispatchSemaphore) {
        lock.withLock { held = (gate, committed) }
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
        let (windows, read, held) = lock.withLock {
            var read = registry.beginRead(of: app.pid)
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
            let held = self.held
            self.held = nil
            return (windows, read, held)
        }
        held?.gate.wait()
        lock.withLock { registry.commit(read) }
        held?.committed.signal()
        return windows
    }
}
