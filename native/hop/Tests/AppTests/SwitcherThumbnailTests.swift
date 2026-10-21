import AppKit
@testable import Hop
import HopCore
import XCTest

/// A capture source that lists the windows it is given and captures a blank image of the asked size; it fails the
/// windows it is told to, and can hold every capture until the test releases it.
private final class FakeImageSource: WindowCaptureSource, @unchecked Sendable {
    private let lock = NSLock()
    private let windows: [CaptureWindow]
    private let failing: Set<UInt32>
    private var held: Bool
    private var listed = 0
    private var asked: [UInt32] = []

    init(windows: [CaptureWindow], failing: Set<UInt32> = [], holds: Bool = false) {
        self.windows = windows
        self.failing = failing
        held = holds
    }

    var listings: Int { lock.withLock { listed } }
    var captures: [UInt32] { lock.withLock { asked } }
    func release() { lock.withLock { held = false } }

    struct Refused: Error {}

    func shareableWindows() async throws -> [CaptureWindow] {
        lock.withLock { listed += 1 }
        return windows
    }

    func capture(_ window: CaptureWindow, size: PixelSize) async throws -> CGImage {
        lock.withLock { asked.append(window.id) }
        while lock.withLock({ held }) { try? await Task.sleep(for: .milliseconds(5)) }
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
    private lazy var windows = (0..<3).map { index in
        WindowEntry(
            app: SourceApp(pid: pid_t(10 + index), bundleIdentifier: nil, name: "App \(index)"),
            window: SourceWindow(ref: HopCore.WindowRef(rawValue: UInt64(index)), title: "Window \(index)",
                                 subrole: "AXStandardWindow", frame: frame),
            frame: frame,
            display: nil
        )
    }
    private lazy var captureWindows = windows.enumerated().map { index, entry in
        CaptureWindow(id: UInt32(100 + index), pid: entry.pid, frame: frame, title: entry.title)
    }
    private var lists: [[WindowEntry]] = []
    private var settings = Settings.default
    private var granted = true

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
