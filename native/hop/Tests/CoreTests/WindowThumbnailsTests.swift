import CoreGraphics
import Foundation
@testable import HopCore
import XCTest

private func entry(
    _ ref: UInt64,
    pid: pid_t = 10,
    title: String = "",
    frame: CGRect = CGRect(x: 100, y: 50, width: 800, height: 600),
    minimized: Bool = false
) -> WindowEntry {
    WindowEntry(
        app: SourceApp(pid: pid, bundleIdentifier: "com.example.app", name: "App"),
        window: SourceWindow(ref: HopCore.WindowRef(rawValue: ref), title: title, subrole: "AXStandardWindow",
                             isMinimized: minimized, frame: frame),
        frame: frame,
        display: 1
    )
}

private func window(
    _ id: UInt32,
    pid: pid_t = 10,
    title: String? = nil,
    frame: CGRect = CGRect(x: 100, y: 50, width: 800, height: 600)
) -> CaptureWindow {
    CaptureWindow(id: id, pid: pid, frame: frame, title: title)
}

/// The closed matching rules, one vector each.
final class ThumbnailMatcherTests: XCTestCase {
    private let hop: pid_t = 99

    private func matched(_ entries: [WindowEntry], _ windows: [CaptureWindow]) -> [UInt64: UInt32] {
        Dictionary(uniqueKeysWithValues: ThumbnailMatcher.matches(entries, among: windows, excludingPid: hop)
            .map { ($0.key.rawValue, $0.value.id) })
    }

    func testSamePidAndAFrameEqualWithinOnePointMatch() {
        let shifted = CGRect(x: 101, y: 49, width: 799, height: 601)
        XCTAssertEqual(matched([entry(1)], [window(7, frame: shifted)]), [1: 7])
    }

    func testAFrameMoreThanOnePointOffDoesNotMatch() {
        let off = CGRect(x: 101.5, y: 50, width: 800, height: 600)
        XCTAssertEqual(matched([entry(1)], [window(7, frame: off)]), [:])
    }

    func testAnotherProcessWithTheSameFrameDoesNotMatch() {
        XCTAssertEqual(matched([entry(1, pid: 10)], [window(7, pid: 11)]), [:])
    }

    func testSeveralWindowsWithTheFrameAreResolvedByTitle() {
        let windows = [window(7, title: "Notes"), window(8, title: "Report"), window(9, title: nil)]
        XCTAssertEqual(matched([entry(1, title: "Report")], windows), [1: 8])
    }

    func testSeveralWindowsWithTheFrameAndNoSingleTitleMatchShowTheIcon() {
        XCTAssertEqual(matched([entry(1, title: "Report")], [window(7, title: "Notes"), window(8, title: "Mail")]), [:])
        XCTAssertEqual(matched([entry(1, title: "Report")], [window(7, title: "Report"), window(8, title: "Report")]), [:])
    }

    func testAnEntryWithNoCaptureWindowIsUnmatched() {
        let elsewhere = CGRect(x: 0, y: 0, width: 300, height: 200)
        XCTAssertEqual(matched([entry(1), entry(2, frame: elsewhere)], [window(7)]), [1: 7])
        XCTAssertEqual(matched([entry(1)], []), [:])
    }

    func testAMinimizedWindowNeverMatches() {
        XCTAssertEqual(matched([entry(1, minimized: true)], [window(7)]), [:])
    }

    func testHopsOwnWindowsNeverMatch() {
        XCTAssertEqual(matched([entry(1, pid: hop)], [window(7, pid: hop)]), [:])
    }

    func testOneCaptureWindowClaimedByTwoEntriesGoesToTheOneWithItsTitleOrToNone() {
        let entries = [entry(1, title: "Report"), entry(2, title: "Notes")]
        XCTAssertEqual(matched(entries, [window(7, title: "Notes")]), [2: 7])
        XCTAssertEqual(matched(entries, [window(7, title: "Mail")]), [:], "neither is known to be the one captured")
    }
}

final class ThumbnailSizingTests: XCTestCase {
    func testTheWindowsShapeFitsTheCellAreaAtTheBackingScale() {
        let wide = CGRect(x: 0, y: 0, width: 1600, height: 900)
        XCTAssertEqual(ThumbnailSizing.pixelSize(for: wide, scale: 2), PixelSize(width: 228, height: 128))
        XCTAssertEqual(ThumbnailSizing.pixelSize(for: wide, scale: 1), PixelSize(width: 114, height: 64))
        let tall = CGRect(x: 0, y: 0, width: 400, height: 1000)
        XCTAssertEqual(ThumbnailSizing.pixelSize(for: tall, scale: 2), PixelSize(width: 51, height: 128))
        XCTAssertNil(ThumbnailSizing.pixelSize(for: .zero, scale: 2))
    }
}

final class ThumbnailCacheTests: XCTestCase {
    private func ref(_ value: UInt64) -> HopCore.WindowRef { HopCore.WindowRef(rawValue: value) }

    func testTheCapIs64MB() {
        XCTAssertEqual(ThumbnailCache<Int>().capacity, 64 * 1024 * 1024)
    }

    func testAddingPastTheCapEvictsTheLeastRecentlyUsed() {
        var cache = ThumbnailCache<String>(capacity: 300)
        cache.insert("a", cost: 100, for: ref(1))
        cache.insert("b", cost: 100, for: ref(2))
        cache.insert("c", cost: 100, for: ref(3))
        XCTAssertEqual(cache.image(for: ref(1)), "a", "using 1 makes 2 the least recently used")
        cache.insert("d", cost: 100, for: ref(4))
        XCTAssertEqual(cache.refs, [ref(1), ref(3), ref(4)])
        XCTAssertEqual(cache.totalCost, 300)
        cache.insert("e", cost: 250, for: ref(5))
        XCTAssertEqual(cache.refs, [ref(5)], "evicts as many as it takes, oldest first")
        XCTAssertEqual(cache.totalCost, 250)
    }

    func testReplacingAThumbnailCountsOnlyTheNewOne() {
        var cache = ThumbnailCache<String>(capacity: 300)
        cache.insert("a", cost: 200, for: ref(1))
        cache.insert("a2", cost: 250, for: ref(1))
        XCTAssertEqual(cache.totalCost, 250)
        XCTAssertEqual(cache.image(for: ref(1)), "a2")
    }

    func testAnImageLargerThanTheCapIsNotKept() {
        var cache = ThumbnailCache<String>(capacity: 300)
        cache.insert("a", cost: 100, for: ref(1))
        cache.insert("huge", cost: 301, for: ref(1))
        XCTAssertEqual(cache.count, 0, "the window's older image goes too")
        XCTAssertEqual(cache.totalCost, 0)
    }

    func testWindowsThatLeftTheListAreDropped() {
        var cache = ThumbnailCache<String>(capacity: 300)
        cache.insert("a", cost: 100, for: ref(1))
        cache.insert("b", cost: 100, for: ref(2))
        cache.retain([ref(2), ref(3)])
        XCTAssertEqual(cache.refs, [ref(2)])
        XCTAssertEqual(cache.totalCost, 100)
    }
}

/// A capture source that records its calls, fails where told, and counts captures in flight. A held capture waits until
/// its task is cancelled, or, like ScreenCaptureKit's, until the test releases it whether or not it was cancelled; one
/// held until released is suspended, not polling, so once cancelled it takes no thread from the cooperative pool.
private final class FakeCaptureSource: WindowCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let windows: [CaptureWindow]
    private let listingFails: Bool
    private let failing: Set<UInt32>
    private let delay: Duration
    private let holdsUntilCancelled: Bool
    private var held: Bool
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var running = 0
    private var peak = 0
    private var asked: [UInt32] = []
    private var listed = 0

    init(
        windows: [CaptureWindow],
        listingFails: Bool = false,
        failing: Set<UInt32> = [],
        delay: Duration = .zero,
        holdsUntilCancelled: Bool = false,
        holdsUntilReleased: Bool = false
    ) {
        self.windows = windows
        self.listingFails = listingFails
        self.failing = failing
        self.delay = delay
        self.holdsUntilCancelled = holdsUntilCancelled
        held = holdsUntilReleased
    }

    var inFlight: Int { lock.withLock { running } }
    var maxInFlight: Int { lock.withLock { peak } }
    var captured: [UInt32] { lock.withLock { asked } }
    var listings: Int { lock.withLock { listed } }
    func release() {
        let waiting = lock.withLock {
            held = false
            defer { self.waiting = [] }
            return self.waiting
        }
        for capture in waiting { capture.resume() }
    }

    struct Refused: Error {}

    func shareableWindows() async throws -> [ListedWindow<CaptureWindow>] {
        lock.withLock { listed += 1 }
        if listingFails { throw Refused() }
        return windows.map { ListedWindow(window: $0, handle: $0) }
    }

    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> String {
        lock.withLock {
            asked.append(window.id)
            running += 1
            peak = max(peak, running)
        }
        try? await Task.sleep(for: delay)
        while holdsUntilCancelled, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        await withCheckedContinuation { capture in
            let holds = lock.withLock {
                if held { waiting.append(capture) }
                return held
            }
            if !holds { capture.resume() }
        }
        lock.withLock { running -= 1 }
        if failing.contains(window.id) { throw Refused() }
        return "image \(window.id) \(size.width)x\(size.height)"
    }
}

/// A capture source whose listings each return only when the test releases them, in any order, with handles tagged by
/// the listing they came from; a capture records the handle it was given. A held listing is suspended, not polling.
private final class OutOfOrderListingSource: WindowCaptureSource, @unchecked Sendable {
    struct Handle: Sendable, Equatable {
        var listing: Int
        var id: UInt32
    }

    private let lock = NSLock()
    private let windowsByListing: [Int: [CaptureWindow]]
    private var started = 0
    private var released: Set<Int> = []
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var asked: [Handle] = []

    /// `windowsByListing[n]` is what the nth listing (from 1) returns.
    init(windowsByListing: [Int: [CaptureWindow]]) {
        self.windowsByListing = windowsByListing
    }

    var listingsStarted: Int { lock.withLock { started } }
    var captured: [Handle] { lock.withLock { asked } }
    func releaseListing(_ number: Int) {
        let listing = lock.withLock {
            released.insert(number)
            return waiting.removeValue(forKey: number)
        }
        listing?.resume()
    }

    func shareableWindows() async throws -> [ListedWindow<Handle>] {
        let number = lock.withLock {
            started += 1
            return started
        }
        // Like ScreenCaptureKit's, a listing does not stop when its task is cancelled.
        await withCheckedContinuation { listing in
            let holds = lock.withLock {
                let holds = !released.contains(number)
                if holds { waiting[number] = listing }
                return holds
            }
            if !holds { listing.resume() }
        }
        return (windowsByListing[number] ?? []).map { ListedWindow(window: $0, handle: Handle(listing: number, id: $0.id)) }
    }

    func capture(_ handle: Handle, size: PixelSize) async throws -> String {
        lock.withLock { asked.append(handle) }
        return "image \(handle.id) from listing \(handle.listing)"
    }
}

/// What a load reported, in order.
private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64: String] = [:]
    private var failures: [UInt64] = []
    private var matched: [Set<UInt64>] = []
    var images: [UInt64: String] { lock.withLock { values } }
    var failed: [UInt64] { lock.withLock { failures } }
    var listed: [Set<UInt64>] { lock.withLock { matched } }

    func add(_ event: ThumbnailEvent<String>) {
        lock.withLock {
            switch event {
            case let .listed(refs): matched.append(Set(refs.map(\.rawValue)))
            case let .captured(ref, image): values[ref.rawValue] = image
            case let .failed(ref): failures.append(ref.rawValue)
            }
        }
    }
}

private func waitFor(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
}

final class ThumbnailLoaderTests: XCTestCase {
    private func frame(_ index: Int) -> CGRect { CGRect(x: CGFloat(index) * 10, y: 0, width: 640, height: 480) }

    private func twenty() -> ([WindowEntry], [CaptureWindow]) {
        ((0..<20).map { entry(UInt64($0), frame: frame($0)) }, (0..<20).map { window(UInt32($0), frame: frame($0)) })
    }

    func testCapturesRunAtMostSixAtATime() async {
        let (entries, windows) = twenty()
        let source = FakeCaptureSource(windows: windows, delay: .milliseconds(20))
        let reported = Reported()
        let outcome = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { reported.add($0) }
        XCTAssertEqual(outcome, .finished(captured: 20, failed: 0))
        XCTAssertEqual(reported.images.count, 20)
        XCTAssertEqual(source.maxInFlight, ThumbnailLoader.maxConcurrent)
        XCTAssertEqual(Set(source.captured.prefix(6)), Set(0..<6), "the most recent windows start first")
    }

    func testCapturesStillRunningFromACancelledLoadCountTowardTheLimitOfTheNext() async {
        let (entries, windows) = twenty()
        let source = FakeCaptureSource(windows: windows, holdsUntilReleased: true)
        let limiter = CaptureLimiter()
        let reported = Reported()
        let first = Task { await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2, limiter: limiter) { _ in } }
        await waitFor { source.captured.count == 6 }
        first.cancel()
        let second = Task {
            await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2, limiter: limiter) { reported.add($0) }
        }
        await waitFor { source.listings == 2 }
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(source.captured.count, 6, "the reopened load waits for the earlier captures still running")
        XCTAssertEqual(limiter.inFlight, 6)
        source.release()
        let outcomes = await (first.value, second.value)
        XCTAssertEqual(outcomes.0, .cancelled)
        XCTAssertEqual(outcomes.1, .finished(captured: 20, failed: 0))
        XCTAssertEqual(source.maxInFlight, ThumbnailLoader.maxConcurrent)
        XCTAssertEqual(source.captured.count, 26, "the cancelled load started no more after its first six")
        XCTAssertEqual(limiter.inFlight, 0)
    }

    func testAnEarlierListingThatReturnsLateDoesNotChangeWhatALaterLoadCaptures() async {
        // The earlier load's listing no longer has window 0; the later load's does.
        let source = OutOfOrderListingSource(windowsByListing: [1: [], 2: [window(0, frame: frame(0))]])
        let limiter = CaptureLimiter(limit: 1)
        let occupied = await limiter.acquire()
        XCTAssertTrue(occupied, "a capture still running holds the only slot")
        let entries = [entry(0, frame: frame(0))]
        let reported = Reported()
        let first = Task { await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2, limiter: limiter) { _ in } }
        await waitFor { source.listingsStarted == 1 }
        first.cancel()
        let second = Task {
            await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2, limiter: limiter) { reported.add($0) }
        }
        await waitFor { source.listingsStarted == 2 }
        source.releaseListing(2)
        await waitFor { reported.listed == [[0]] }
        // The later load's capture is queued for a slot when the earlier listing comes back.
        source.releaseListing(1)
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .cancelled)
        XCTAssertEqual(source.captured, [])
        limiter.release()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .finished(captured: 1, failed: 0))
        XCTAssertEqual(source.captured, [.init(listing: 2, id: 0)], "captured with its own listing's window")
        XCTAssertEqual(reported.images, [0: "image 0 from listing 2"])
        XCTAssertEqual(reported.failed, [])
    }

    func testAFailedCaptureAffectsOnlyItsWindow() async {
        let entries = (0..<3).map { entry(UInt64($0), frame: frame($0)) }
        let source = FakeCaptureSource(windows: (0..<3).map { window(UInt32($0), frame: frame($0)) }, failing: [1])
        let reported = Reported()
        let outcome = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { reported.add($0) }
        XCTAssertEqual(outcome, .finished(captured: 2, failed: 1))
        XCTAssertEqual(reported.images, [0: "image 0 171x128", 2: "image 2 171x128"])
        XCTAssertEqual(reported.failed, [1])
    }

    func testMinimizedAndUnmatchedWindowsAreNotCapturedAndAreReportedAsSuch() async {
        let entries = [entry(0, frame: frame(0), minimized: true), entry(1, frame: frame(1)), entry(2, frame: frame(9))]
        let source = FakeCaptureSource(windows: [window(0, frame: frame(0)), window(1, frame: frame(1))])
        let reported = Reported()
        _ = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { reported.add($0) }
        XCTAssertEqual(source.captured, [1])
        XCTAssertEqual(reported.listed, [[1]], "only the matched window will be captured")
        XCTAssertEqual(Array(reported.images.keys), [1])
    }

    func testAListingThatFailsCapturesNothingAndDoesNotThrow() async {
        let source = FakeCaptureSource(windows: [window(0)], listingFails: true)
        let reported = Reported()
        let outcome = await ThumbnailLoader.load([entry(0)], from: source, excludingPid: 99, scale: 2) { reported.add($0) }
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(source.captured, [])
        XCTAssertEqual(reported.images, [:])
        XCTAssertEqual(reported.listed, [])
    }

    func testACancelledLoadStartsNoMoreCapturesAndDeliversNothingLate() async {
        let (entries, windows) = twenty()
        let source = FakeCaptureSource(windows: windows, holdsUntilCancelled: true)
        let reported = Reported()
        let task = Task { await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { reported.add($0) } }
        await waitFor { source.captured.count == 6 }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.captured.count, 6, "only the first six had started")
        XCTAssertEqual(reported.images, [:])
        XCTAssertEqual(reported.failed, [])
    }
}

final class CaptureLimiterTests: XCTestCase {
    func testAWaiterCancelledBeforeASlotFreesGetsNone() async {
        let limiter = CaptureLimiter(limit: 1)
        let first = await limiter.acquire()
        XCTAssertTrue(first)
        let waiter = Task { await limiter.acquire() }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        let second = await waiter.value
        XCTAssertFalse(second)
        XCTAssertEqual(limiter.inFlight, 1)
        limiter.release()
        XCTAssertEqual(limiter.inFlight, 0, "the cancelled waiter took no slot")
    }
}

/// The permission states: only granted captures; not determined, denied and revoked show icons with a notice.
final class ScreenRecordingGateTests: XCTestCase {
    func testEachStateFromItsSamples() {
        var gate = ScreenRecordingGate()
        XCTAssertEqual(gate.update(granted: false, requested: false), .notDetermined)
        XCTAssertEqual(gate.update(granted: false, requested: true), .denied)
        XCTAssertEqual(gate.update(granted: true, requested: true), .granted)
        XCTAssertEqual(gate.update(granted: false, requested: true), .revoked, "granted earlier while running")
        XCTAssertEqual(gate.update(granted: true, requested: true), .granted)
    }

    func testOnlyGrantedAccessWithPreviewsOnCaptures() {
        for access in [ScreenRecordingAccess.notDetermined, .denied, .revoked] {
            XCTAssertFalse(ScreenRecordingGate.captures(previewsOn: true, access: access), "\(access)")
            XCTAssertNotNil(access.notice, "\(access) says the switcher shows icons")
            XCTAssertFalse(access.notice?.contains("\n") ?? true)
        }
        XCTAssertTrue(ScreenRecordingGate.captures(previewsOn: true, access: .granted))
        XCTAssertFalse(ScreenRecordingGate.captures(previewsOn: false, access: .granted))
        XCTAssertNil(ScreenRecordingAccess.granted.notice)
    }
}
