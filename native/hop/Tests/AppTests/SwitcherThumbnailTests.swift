import AppKit
@testable import Hop
import HopCore
import XCTest

/// A capture source that lists the windows it is given and captures a blank image of the asked size; it fails the
/// listing or the windows it is told to, and can hold every capture until the test releases it, as ScreenCaptureKit's
/// do not stop when their task is cancelled. The test can change each of these between openings.
private final class FakeImageSource: WindowCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private var listedWindows: [CaptureWindow]
    private var failingIDs: Set<UInt32>
    private var listingRefused = false
    private var held: Bool
    private var listed = 0
    private var asked: [UInt32] = []
    private var running = 0
    private var peak = 0

    init(windows: [CaptureWindow], failing: Set<UInt32> = [], holds: Bool = false) {
        listedWindows = windows
        failingIDs = failing
        held = holds
    }

    var listings: Int { lock.withLock { listed } }
    var captures: [UInt32] { lock.withLock { asked } }
    var maxInFlight: Int { lock.withLock { peak } }
    var windows: [CaptureWindow] {
        get { lock.withLock { listedWindows } }
        set { lock.withLock { listedWindows = newValue } }
    }
    var failing: Set<UInt32> {
        get { lock.withLock { failingIDs } }
        set { lock.withLock { failingIDs = newValue } }
    }
    var listingFails: Bool {
        get { lock.withLock { listingRefused } }
        set { lock.withLock { listingRefused = newValue } }
    }
    func hold() { lock.withLock { held = true } }
    func release() { lock.withLock { held = false } }

    struct Refused: Error {}

    func shareableWindows() async throws -> [ListedWindow<CaptureWindow>] {
        try lock.withLock {
            listed += 1
            if listingRefused { throw Refused() }
            return listedWindows.map { ListedWindow(window: $0, handle: $0) }
        }
    }

    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> CGImage {
        lock.withLock {
            asked.append(window.id)
            running += 1
            peak = max(peak, running)
        }
        while lock.withLock({ held }) { try? await Task.sleep(for: .milliseconds(5)) }
        lock.withLock { running -= 1 }
        if failing.contains(window.id) { throw Refused() }
        let context = CGContext(
            data: nil, width: size.width, height: size.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
        return try XCTUnwrap(context?.makeImage())
    }
}

/// Window previews in the switcher: captured only with previews on and Screen Recording granted, each cell's image
/// independent of the others', dropped when its window leaves or previews go off, and invisible to Accessibility.
@MainActor
final class SwitcherThumbnailTests: XCTestCase {
    private let frame = CGRect(x: 0, y: 0, width: 400, height: 300)
    private lazy var windows = entries(3)
    private lazy var captureWindows = captureWindows(for: windows)
    private var lists: [[WindowEntry]] = []
    private var settings = Settings.default
    private var granted = true

    private func entries(_ count: Int) -> [WindowEntry] {
        (0..<count).map { index in
            WindowEntry(
                app: SourceApp(pid: pid_t(10 + index), bundleIdentifier: nil, name: "App \(index)"),
                window: SourceWindow(ref: HopCore.WindowRef(rawValue: UInt64(index)), title: "Window \(index)",
                                     subrole: "AXStandardWindow", frame: frame),
                frame: frame,
                display: nil
            )
        }
    }

    private func captureWindows(for entries: [WindowEntry]) -> [CaptureWindow] {
        entries.enumerated().map { index, entry in
            CaptureWindow(id: UInt32(100 + index), pid: entry.pid, frame: frame, title: entry.title)
        }
    }

    override func setUp() async throws {
        settings.showWindowPreviews = true
    }

    private func switcher(_ source: FakeImageSource) -> (SwitcherController, ThumbnailProvider) {
        let thumbnails = ThumbnailProvider(source: source, ownPid: 1)
        let switcher = SwitcherController(
            readWindows: { [unowned self] in WindowList(windows: lists.count > 1 ? lists.removeFirst() : lists[0]) },
            windowOperator: RecordingWindowOperator(),
            settings: { [unowned self] in settings },
            thumbnails: thumbnails,
            capturesThumbnails: { [unowned self] in
                ScreenRecordingGate.captures(previewsOn: settings.showWindowPreviews, access: granted ? .granted : .denied)
            }
        )
        return (switcher, thumbnails)
    }

    private func refs(_ indices: Int...) -> Set<HopCore.WindowRef> {
        Set(indices.map { windows[$0].ref })
    }

    private func wait(until condition: () -> Bool, _ message: String = "") async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("timed out: \(message)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func labels(_ switcher: SwitcherController) -> [String] {
        (switcher.panel.switcherView.accessibilityListElement.accessibilityChildren() ?? [])
            .compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
    }

    func testEachListedWindowGetsItsImageAndAccessibilityReadsTheSame() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        let before = labels(switcher)
        try await wait(until: { thumbnails.cachedRefs == refs(0, 1, 2) }, "every window's image arrives")
        XCTAssertEqual(source.listings, 1, "one listing per opening")
        XCTAssertEqual(labels(switcher), before, "images are decorative")
        XCTAssertEqual(before, ["Window 0, App 0", "Window 1, App 1", "Window 2, App 2"])
    }

    func testDeniedAccessListsAndCapturesNothing() async throws {
        granted = false
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(source.listings, 0, "nothing that could prompt runs while switching")
        XCTAssertTrue(thumbnails.cachedRefs.isEmpty)
        XCTAssertEqual(switcher.model?.items.count, 3, "the switcher works as before, with icons")
    }

    func testRevokedAccessDropsTheImagesKeptAndCapturesNoMore() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs.count == 3 })
        switcher.cancel()
        granted = false
        switcher.open()
        XCTAssertTrue(thumbnails.cachedRefs.isEmpty)
        XCTAssertEqual(thumbnails.cachedBytes, 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(source.listings, 1)
    }

    func testAFailedCaptureLeavesOnlyItsCellOnTheIcon() async throws {
        let source = FakeImageSource(windows: captureWindows, failing: [101])
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { source.captures.count == 3 })
        try await wait(until: { thumbnails.cachedRefs == refs(0, 2) })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(thumbnails.cachedRefs, refs(0, 2))
    }

    func testAWindowThatLeavesTheListLosesItsImage() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows, [windows[0], windows[2]]]
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs.count == 3 })
        // ⌘W closes the selected window 1; the read after it no longer lists it.
        switcher.apply(.operation(.close))
        try await wait(until: { switcher.model?.windows.count == 2 }, "the read after the close")
        XCTAssertEqual(thumbnails.cachedRefs, refs(0, 2))
    }

    func testAWindowClosedWhileItsCaptureRunsNeverGetsItsImageBack() async throws {
        let source = FakeImageSource(windows: captureWindows, holds: true)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows, [windows[0], windows[2]]]
        switcher.open()
        try await wait(until: { source.captures.count == 3 })
        // ⌘W closes the selected window 1 while its capture is still running.
        switcher.apply(.operation(.close))
        try await wait(until: { switcher.model?.windows.count == 2 }, "the read after the close")
        source.release()
        try await wait(until: { thumbnails.cachedRefs == refs(0, 2) })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(thumbnails.cachedRefs, refs(0, 2), "the closed window's late image is dropped")
    }

    /// Opens, waits for every window's image, and closes again.
    private func openAndCapture(_ switcher: SwitcherController, _ thumbnails: ThumbnailProvider) async throws {
        lists = [windows]
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs == refs(0, 1, 2) }, "the first opening's images")
        switcher.cancel()
    }

    func testAListingThatFailsOnReopeningDropsEveryImage() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        try await openAndCapture(switcher, thumbnails)
        // Screen Recording still reads as granted, but ScreenCaptureKit refuses.
        source.listingFails = true
        switcher.open()
        try await wait(until: { source.listings == 2 })
        try await wait(until: { thumbnails.cachedRefs.isEmpty }, "every cell back on its icon")
        XCTAssertEqual(switcher.currentThumbnails().count, 0)
        XCTAssertEqual(thumbnails.cachedBytes, 0)
    }

    func testAWindowNoLongerMatchedOnReopeningShowsItsIconAndTheOthersKeepTheirImages() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        try await openAndCapture(switcher, thumbnails)
        // Window 1's captured frame is now 5 pt off the listed one, so it no longer matches.
        var moved = captureWindows
        moved[1].frame = frame.offsetBy(dx: 5, dy: 0)
        source.windows = moved
        source.hold()
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs == refs(0, 2) }, "the unmatched window's image goes")
        XCTAssertEqual(Set(switcher.currentThumbnails().keys), refs(0, 2), "the matched ones show their earlier images")
        XCTAssertEqual(source.captures.count, 5, "the matched windows are being captured again")
        source.release()
        try await wait(until: { thumbnails.capturesInFlight == 0 })
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(thumbnails.cachedRefs, refs(0, 2))
    }

    func testACaptureThatFailsOnReopeningLeavesOnlyItsCellOnTheIcon() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        try await openAndCapture(switcher, thumbnails)
        source.failing = [101]
        switcher.open()
        try await wait(until: { source.captures.count == 6 })
        try await wait(until: { thumbnails.cachedRefs == refs(0, 2) }, "the failed window's earlier image goes")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(thumbnails.cachedRefs, refs(0, 2))
    }

    func testReopeningWhileCapturesStillRunKeepsAtMostSixInFlight() async throws {
        windows = entries(8)
        captureWindows = captureWindows(for: windows)
        let source = FakeImageSource(windows: captureWindows, holds: true)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { source.captures.count == 6 })
        // A quick close and reopen: the six captures of the first opening are still running.
        switcher.cancel()
        switcher.open()
        try await wait(until: { source.listings == 2 })
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(source.captures.count, 6, "no capture starts until a slot is free")
        XCTAssertEqual(thumbnails.capturesInFlight, 6)
        source.release()
        try await wait(until: { thumbnails.cachedRefs.count == 8 }, "the reopened switcher's images")
        XCTAssertEqual(source.maxInFlight, ThumbnailLoader.maxConcurrent)
        XCTAssertEqual(source.captures.count, 14, "the first opening started no more after it closed")
    }

    func testAWindowMinimizedWhileTheSwitcherIsOpenShowsItsIcon() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs.count == 3 })
        XCTAssertEqual(Set(switcher.currentThumbnails().keys), refs(0, 1, 2))
        // ⌘M minimizes the selected window 1.
        switcher.apply(.operation(.minimize))
        try await wait(until: { switcher.model?.windows.first { $0.ref == self.windows[1].ref }?.isMinimized == true })
        XCTAssertEqual(Set(switcher.currentThumbnails().keys), refs(0, 2))
    }

    func testTurningPreviewsOffMidLoadStopsItAndKeepsNoImage() async throws {
        let source = FakeImageSource(windows: captureWindows, holds: true)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { source.captures.count == 3 })
        settings.showWindowPreviews = false
        switcher.settingsChanged()
        source.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(thumbnails.cachedRefs.isEmpty)
    }

    func testTurningPreviewsOffDropsEveryImageAtOnce() async throws {
        let source = FakeImageSource(windows: captureWindows)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { thumbnails.cachedRefs.count == 3 })
        settings.showWindowPreviews = false
        switcher.settingsChanged()
        XCTAssertTrue(thumbnails.cachedRefs.isEmpty)
        XCTAssertTrue(switcher.isOpen)
    }

    func testImagesThatArriveAfterTheSwitcherClosesAreDropped() async throws {
        let source = FakeImageSource(windows: captureWindows, holds: true)
        let (switcher, thumbnails) = switcher(source)
        lists = [windows]
        switcher.open()
        try await wait(until: { source.captures.count == 3 })
        switcher.cancel()
        source.release()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(thumbnails.cachedRefs.isEmpty)
    }
}
