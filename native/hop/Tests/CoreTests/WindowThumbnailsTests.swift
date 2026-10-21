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

/// A capture source that records its calls, fails where told, and counts captures in flight.
private final class FakeCaptureSource: WindowCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let windows: [CaptureWindow]
    private let listingFails: Bool
    private let failing: Set<UInt32>
    private let delay: Duration
    /// Each capture waits until its task is cancelled.
    private let holdsUntilCancelled: Bool
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var captured: [UInt32] = []
    private(set) var listings = 0

    init(
        windows: [CaptureWindow],
        listingFails: Bool = false,
        failing: Set<UInt32> = [],
        delay: Duration = .zero,
        holdsUntilCancelled: Bool = false
    ) {
        self.windows = windows
        self.listingFails = listingFails
        self.failing = failing
        self.delay = delay
        self.holdsUntilCancelled = holdsUntilCancelled
    }

    struct Refused: Error {}

    func shareableWindows() async throws -> [CaptureWindow] {
        lock.withLock { listings += 1 }
        if listingFails { throw Refused() }
        return windows
    }

    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> String {
        lock.withLock {
            captured.append(window.id)
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
        }
        try? await Task.sleep(for: delay)
        while holdsUntilCancelled, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(1)) }
        lock.withLock { inFlight -= 1 }
        if failing.contains(window.id) { throw Refused() }
        return "image \(window.id) \(size.width)x\(size.height)"
    }
}

private final class Delivered: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UInt64: String] = [:]
    var images: [UInt64: String] { lock.withLock { values } }
    func add(_ ref: HopCore.WindowRef, _ image: String) { lock.withLock { values[ref.rawValue] = image } }
}

final class ThumbnailLoaderTests: XCTestCase {
    private func frame(_ index: Int) -> CGRect { CGRect(x: CGFloat(index) * 10, y: 0, width: 640, height: 480) }

    func testCapturesRunAtMostSixAtATime() async {
        let entries = (0..<20).map { entry(UInt64($0), frame: frame($0)) }
        let source = FakeCaptureSource(windows: (0..<20).map { window(UInt32($0), frame: frame($0)) },
                                       delay: .milliseconds(20))
        let delivered = Delivered()
        let outcome = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { delivered.add($0, $1) }
        XCTAssertEqual(outcome, .finished(captured: 20, failed: 0))
        XCTAssertEqual(delivered.images.count, 20)
        XCTAssertEqual(source.maxInFlight, ThumbnailLoader.maxConcurrent)
        XCTAssertEqual(Set(source.captured.prefix(6)), Set(0..<6), "the most recent windows start first")
    }

    func testAFailedCaptureAffectsOnlyItsWindow() async {
        let entries = (0..<3).map { entry(UInt64($0), frame: frame($0)) }
        let source = FakeCaptureSource(windows: (0..<3).map { window(UInt32($0), frame: frame($0)) }, failing: [1])
        let delivered = Delivered()
        let outcome = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { delivered.add($0, $1) }
        XCTAssertEqual(outcome, .finished(captured: 2, failed: 1))
        XCTAssertEqual(delivered.images, [0: "image 0 171x128", 2: "image 2 171x128"])
    }

    func testMinimizedAndUnmatchedWindowsAreNotCaptured() async {
        let entries = [entry(0, frame: frame(0), minimized: true), entry(1, frame: frame(1)), entry(2, frame: frame(9))]
        let source = FakeCaptureSource(windows: [window(0, frame: frame(0)), window(1, frame: frame(1))])
        let delivered = Delivered()
        _ = await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { delivered.add($0, $1) }
        XCTAssertEqual(source.captured, [1])
        XCTAssertEqual(Array(delivered.images.keys), [1])
    }

    func testAListingThatFailsCapturesNothingAndDoesNotThrow() async {
        let source = FakeCaptureSource(windows: [window(0)], listingFails: true)
        let delivered = Delivered()
        let outcome = await ThumbnailLoader.load([entry(0)], from: source, excludingPid: 99, scale: 2) { delivered.add($0, $1) }
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertEqual(source.captured, [])
        XCTAssertEqual(delivered.images, [:])
    }

    func testACancelledLoadStartsNoMoreCapturesAndDeliversNothingLate() async {
        let entries = (0..<20).map { entry(UInt64($0), frame: frame($0)) }
        let source = FakeCaptureSource(windows: (0..<20).map { window(UInt32($0), frame: frame($0)) },
                                       holdsUntilCancelled: true)
        let delivered = Delivered()
        let task = Task { await ThumbnailLoader.load(entries, from: source, excludingPid: 99, scale: 2) { delivered.add($0, $1) } }
        let deadline = ContinuousClock.now + .seconds(3)
        while source.captured.count < 6, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
        task.cancel()
        let outcome = await task.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.captured.count, 6, "only the first six had started")
        XCTAssertEqual(delivered.images, [:])
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
