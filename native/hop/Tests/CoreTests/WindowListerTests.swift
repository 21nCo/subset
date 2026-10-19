import CoreGraphics
import Foundation
import HopCore
import XCTest

/// Fixture helpers shared by the window list tests.
enum WindowFixture {
    static let ownProcess: pid_t = 1
    static let mainDisplay = SourceDisplay(id: 1, bounds: CGRect(x: 0, y: 0, width: 1512, height: 982))
    static let sideDisplay = SourceDisplay(id: 2, bounds: CGRect(x: 1512, y: 0, width: 1920, height: 1080))

    static func app(_ pid: pid_t, _ name: String, policy: AppActivationPolicy = .regular, hidden: Bool = false) -> SourceApp {
        SourceApp(pid: pid, bundleIdentifier: "com.example.\(name.lowercased())", name: name, activationPolicy: policy, isHidden: hidden)
    }

    static func window(
        _ ref: UInt64,
        subrole: String? = "AXStandardWindow",
        frame: CGRect? = CGRect(x: 100, y: 100, width: 800, height: 600),
        minimized: Bool = false,
        fullscreen: Bool = false
    ) -> SourceWindow {
        SourceWindow(
            ref: WindowRef(rawValue: ref),
            title: "Window \(ref)",
            subrole: subrole,
            isMinimized: minimized,
            isFullscreen: fullscreen,
            frame: frame
        )
    }

    static func lister(_ apps: [FixtureWindowSource.App]) -> (WindowLister, FixtureWindowSource) {
        let source = FixtureWindowSource(apps, displays: [mainDisplay, sideDisplay])
        return (WindowLister(source: source, ownProcess: ownProcess), source)
    }
}

final class WindowListerTests: XCTestCase {
    private typealias F = WindowFixture

    private func refs(_ list: WindowList) -> [UInt64] {
        list.windows.map(\.ref.rawValue)
    }

    func testListsOnlyTheWindowsTheRulesInclude() {
        var (lister, source) = F.lister([
            .init(F.app(10, "Editor"), windows: [
                F.window(1),
                F.window(2, subrole: "AXFloatingWindow"),
                F.window(3, subrole: "AXDialog"),
                F.window(4, subrole: "AXSystemDialog"),
                F.window(5, subrole: nil),
                F.window(6, frame: CGRect(x: 0, y: 0, width: 30, height: 30)),
            ]),
            .init(F.app(20, "Agent", policy: .accessory), windows: [F.window(7)]),
            .init(SourceApp(pid: F.ownProcess, bundleIdentifier: HopIdentity.bundleIdentifier, name: "Hop"), windows: [F.window(8)]),
        ])
        let list = lister.refresh()
        XCTAssertEqual(refs(list), [1, 3])
        XCTAssertEqual(list.windowlessApps, [], "neither Hop nor a non-regular app is a windowless app")
        XCTAssertEqual(source.queriedApps, [10], "excluded apps are not asked for their windows")
    }

    func testEntriesCarryTheAppIdentityStateAndDisplay() throws {
        var (lister, _) = F.lister([
            .init(F.app(10, "Editor", hidden: true), windows: [
                F.window(1, frame: CGRect(x: 1600, y: 50, width: 800, height: 600), minimized: true),
                F.window(2, frame: CGRect(x: 1400, y: 50, width: 400, height: 300), fullscreen: true),
                F.window(3, frame: CGRect(x: -5000, y: 0, width: 400, height: 300)),
            ]),
        ])
        let list = lister.refresh()
        XCTAssertEqual(list.windows.count, 3)
        let minimized = list.windows[0]
        XCTAssertEqual(minimized.pid, 10)
        XCTAssertEqual(minimized.bundleIdentifier, "com.example.editor")
        XCTAssertEqual(minimized.appName, "Editor")
        XCTAssertEqual(minimized.title, "Window 1")
        XCTAssertTrue(minimized.isMinimized)
        XCTAssertTrue(minimized.isAppHidden, "a hidden app's windows are listed and flagged")
        XCTAssertFalse(minimized.isFullscreen)
        XCTAssertEqual(minimized.frame, CGRect(x: 1600, y: 50, width: 800, height: 600))
        XCTAssertEqual(minimized.display, 2)
        XCTAssertTrue(list.windows[1].isFullscreen)
        XCTAssertFalse(list.windows[1].isMinimized)
        XCTAssertEqual(list.windows[1].display, 2, "a window spanning two displays is on the one it overlaps most")
        XCTAssertNil(list.windows[2].display, "a window on no display has none")
    }

    func testDisplayTieGoesToTheFirstListedDisplay() {
        let straddling = CGRect(x: 1412, y: 0, width: 200, height: 100)
        XCTAssertEqual(SourceDisplay.display(for: straddling, among: [F.mainDisplay, F.sideDisplay]), 1)
        XCTAssertEqual(SourceDisplay.display(for: straddling, among: [F.sideDisplay, F.mainDisplay]), 2)
        XCTAssertNil(SourceDisplay.display(for: straddling, among: []))
    }

    func testAnAppThatTimesOutIsSkippedAndTheOthersAreListed() {
        var (lister, _) = F.lister([
            .init(F.app(10, "Editor"), windows: [F.window(1)]),
            .init(F.app(20, "Stuck"), failure: .timedOut),
            .init(F.app(30, "Broken"), failure: .failed),
            .init(F.app(40, "Browser"), windows: [F.window(4)]),
        ])
        let list = lister.refresh()
        XCTAssertEqual(refs(list), [1, 4])
        XCTAssertEqual(list.skippedApps, [SkippedApp(pid: 20, reason: .timedOut), SkippedApp(pid: 30, reason: .failed)])
        XCTAssertEqual(list.windowlessApps, [], "a skipped app's windows are unknown, not absent")
        XCTAssertEqual(lister.skippedAppCount, 2)
        _ = lister.refresh()
        XCTAssertEqual(lister.skippedAppCount, 4, "the debug counter accumulates across refreshes")
    }

    func testAppsWithoutSwitchableWindowsAreWindowlessApps() {
        var (lister, _) = F.lister([
            .init(F.app(10, "Finder"), windows: []),
            .init(F.app(20, "Palette"), windows: [F.window(2, subrole: "AXFloatingWindow")]),
            .init(F.app(30, "Editor"), windows: [F.window(3)]),
        ])
        let list = lister.refresh()
        XCTAssertEqual(refs(list), [3])
        XCTAssertEqual(list.windowlessApps.map(\.pid), [10, 20])
        XCTAssertEqual(list.windowlessApps.first?.name, "Finder")
        XCTAssertEqual(list.windowlessApps.first?.bundleIdentifier, "com.example.finder")
    }

    func testARepeatedRefIsListedOnce() {
        var (lister, _) = F.lister([
            .init(F.app(10, "Editor"), windows: [F.window(1), F.window(1, frame: CGRect(x: 0, y: 0, width: 50, height: 50))]),
        ])
        let list = lister.refresh()
        XCTAssertEqual(refs(list), [1])
        XCTAssertEqual(list.windows.first?.frame, CGRect(x: 100, y: 100, width: 800, height: 600), "the first report stands")
    }

    func testListOrderFollowsTheSourceWhenNothingIsKnown() {
        var (lister, _) = F.lister((0 ..< 6).map { app in
            .init(F.app(pid_t(10 + app), "App\(app)"), windows: (0 ..< 3).map { F.window(UInt64(app * 3 + $0)) })
        })
        XCTAssertEqual(refs(lister.refresh()), Array(0 ..< 18), "parallel reads keep the apps' order")
    }

    /// Soft performance check: logs the time and fails only above 50 ms; the target is under 10 ms.
    func testBuildingA200WindowListIsFast() {
        var nextRef: UInt64 = 0
        let apps: [FixtureWindowSource.App] = (0 ..< 20).map { app in
            .init(F.app(pid_t(100 + app), "App\(app)", hidden: app % 5 == 0), windows: (0 ..< 10).map { index in
                nextRef += 1
                let frame = CGRect(x: Double(index * 20), y: Double(app * 10), width: 640, height: 480)
                return F.window(nextRef, frame: frame, minimized: index == 9)
            })
        }
        var (lister, _) = F.lister(apps)
        let onScreen = (0 ..< 20).reversed().map { OnScreenWindow(pid: pid_t(100 + $0), frame: CGRect(x: 0, y: Double($0 * 10), width: 640, height: 480)) }
        _ = lister.seed(frontToBack: onScreen)
        for ref in stride(from: UInt64(1), through: 200, by: 7) { lister.noteFocused(WindowRef(rawValue: ref), pid: pid_t(100 + Int(ref - 1) / 10)) }

        let clock = ContinuousClock()
        var list = WindowList()
        let elapsed = clock.measure { list = lister.refresh() }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("Built a \(list.windows.count)-window list in \(String(format: "%.3f", milliseconds)) ms (target < 10 ms)")
        XCTAssertEqual(list.windows.count, 200)
        XCTAssertLessThan(milliseconds, 50)
    }
}
