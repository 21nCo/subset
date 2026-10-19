import CoreGraphics
import Foundation
import HopCore
import XCTest

final class RecencyTrackerTests: XCTestCase {
    private typealias F = WindowFixture

    private let left = CGRect(x: 0, y: 25, width: 700, height: 800)
    private let right = CGRect(x: 720, y: 25, width: 700, height: 800)
    private let centered = CGRect(x: 300, y: 100, width: 900, height: 700)

    private func refs(_ list: WindowList) -> [UInt64] {
        list.windows.map(\.ref.rawValue)
    }

    private func editorAndBrowser() -> (WindowLister, FixtureWindowSource) {
        F.lister([
            .init(F.app(10, "Editor"), windows: [F.window(1, frame: left), F.window(2, frame: right)]),
            .init(F.app(20, "Browser"), windows: [F.window(3, frame: centered), F.window(4, frame: left)]),
        ])
    }

    func testSeedingOrdersWindowsByTheOnScreenOrderMatchedByProcessAndFrame() {
        var (lister, _) = editorAndBrowser()
        let list = lister.seed(frontToBack: [
            OnScreenWindow(pid: 20, frame: left), // the browser's window 4, not the editor's window 1 with the same frame
            OnScreenWindow(pid: 10, frame: right.offsetBy(dx: 0.5, dy: -1)), // within 1 pt
            OnScreenWindow(pid: 10, frame: left),
        ])
        XCTAssertEqual(refs(list), [4, 2, 1, 3], "window 3 was not on screen and follows in source order")
    }

    func testFramesMoreThanOnePointApartDoNotMatch() {
        var (lister, _) = editorAndBrowser()
        let list = lister.seed(frontToBack: [
            OnScreenWindow(pid: 20, frame: centered.offsetBy(dx: 1.5, dy: 0)),
            OnScreenWindow(pid: 10, frame: CGRect(x: 720, y: 25, width: 702, height: 800)),
            OnScreenWindow(pid: 10, frame: left),
        ])
        XCTAssertEqual(refs(list), [1, 2, 3, 4])
    }

    func testTwoWindowsWithTheSameFrameSeedInSourceOrder() {
        var (lister, _) = F.lister([
            .init(F.app(10, "Terminal"), windows: [F.window(1, frame: centered), F.window(2, frame: centered), F.window(3, frame: left)]),
        ])
        let list = lister.seed(frontToBack: [
            OnScreenWindow(pid: 10, frame: left),
            OnScreenWindow(pid: 10, frame: centered),
            OnScreenWindow(pid: 10, frame: centered),
        ])
        XCTAssertEqual(refs(list), [3, 1, 2], "the first on-screen match takes the first window in source order")
    }

    func testTwoSameSizedWindowsAtDifferentPositionsSeedByPosition() {
        var (lister, _) = F.lister([
            .init(F.app(10, "Editor"), windows: [F.window(1, frame: left), F.window(2, frame: right)]),
        ])
        let list = lister.seed(frontToBack: [OnScreenWindow(pid: 10, frame: right), OnScreenWindow(pid: 10, frame: left)])
        XCTAssertEqual(refs(list), [2, 1])
    }

    func testAFocusChangeMovesTheWindowToTheFront() {
        var (lister, _) = editorAndBrowser()
        _ = lister.seed(frontToBack: [OnScreenWindow(pid: 10, frame: left), OnScreenWindow(pid: 20, frame: centered)])
        lister.noteFocused(WindowRef(rawValue: 4), pid: 20)
        XCTAssertEqual(refs(lister.refresh()), [4, 1, 3, 2], "focused first, then seeded, then never-seen in source order")
        lister.noteFocused(WindowRef(rawValue: 3), pid: 20)
        lister.noteFocused(WindowRef(rawValue: 1), pid: 10)
        XCTAssertEqual(refs(lister.refresh()), [1, 3, 4, 2])
    }

    func testActivationWithoutAFocusedWindowRaisesTheAppsMostRecentWindow() {
        var (lister, _) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 2), pid: 10)
        lister.noteFocused(WindowRef(rawValue: 1), pid: 10)
        lister.noteFocused(WindowRef(rawValue: 3), pid: 20)
        XCTAssertTrue(lister.noteActivated(pid: 10))
        XCTAssertEqual(refs(lister.refresh()), [1, 3, 2, 4])
        XCTAssertFalse(lister.noteActivated(pid: 30), "an app with no known window changes nothing")
        XCTAssertEqual(refs(lister.refresh()), [1, 3, 2, 4])
    }

    func testAClosedWindowIsDroppedOnTheNextRefresh() {
        var (lister, source) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 2), pid: 10)
        lister.noteFocused(WindowRef(rawValue: 3), pid: 20)
        XCTAssertEqual(refs(lister.refresh()), [3, 2, 1, 4])
        source.update([
            .init(F.app(10, "Editor"), windows: [F.window(1, frame: left)]),
            .init(F.app(20, "Browser"), windows: [F.window(3, frame: centered), F.window(4, frame: left)]),
        ])
        XCTAssertEqual(refs(lister.refresh()), [3, 1, 4])
        XCTAssertEqual(lister.recency.order, [WindowRef(rawValue: 3)], "the closed window left the recency order")
    }

    func testASkippedAppKeepsItsRecencyUntilItAnswersAgain() {
        var (lister, source) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 1), pid: 10)
        lister.noteFocused(WindowRef(rawValue: 3), pid: 20)
        source.update([
            .init(F.app(10, "Editor"), failure: .timedOut),
            .init(F.app(20, "Browser"), windows: [F.window(3, frame: centered), F.window(4, frame: left)]),
        ])
        XCTAssertEqual(refs(lister.refresh()), [3, 4])
        source.update([
            .init(F.app(10, "Editor"), windows: [F.window(1, frame: left), F.window(2, frame: right)]),
            .init(F.app(20, "Browser"), windows: [F.window(3, frame: centered), F.window(4, frame: left)]),
        ])
        XCTAssertEqual(refs(lister.refresh()), [3, 1, 2, 4], "window 1 kept its place behind window 3")
    }

    func testWindowsOfAnAppThatQuitAreForgotten() {
        var (lister, _) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 1), pid: 10)
        lister.noteFocused(WindowRef(rawValue: 3), pid: 20)
        lister.forgetApp(pid: 10)
        XCTAssertEqual(lister.recency.order, [WindowRef(rawValue: 3)])
    }

    func testFocusedWindowsThatAreNotListedAreDroppedOnRefresh() {
        var (lister, _) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 99), pid: 10) // a palette the rules exclude
        lister.noteFocused(WindowRef(rawValue: 2), pid: 10)
        XCTAssertEqual(refs(lister.refresh()), [2, 1, 3, 4])
        XCTAssertEqual(lister.recency.order, [WindowRef(rawValue: 2)])
    }

    func testReseedingPutsOnScreenWindowsAheadOfEarlierFocus() {
        var (lister, _) = editorAndBrowser()
        lister.noteFocused(WindowRef(rawValue: 4), pid: 20)
        lister.noteFocused(WindowRef(rawValue: 1), pid: 10)
        let list = lister.seed(frontToBack: [OnScreenWindow(pid: 20, frame: centered)])
        XCTAssertEqual(refs(list), [3, 1, 4, 2])
    }

    func testOnScreenOrderIsReadFromWindowInfo() {
        let info: [[String: Any]] = [
            ["kCGWindowLayer": 25, "kCGWindowOwnerPID": 5, "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 1512, "Height": 33]],
            ["kCGWindowLayer": 0, "kCGWindowOwnerPID": 10, "kCGWindowBounds": ["X": 720, "Y": 25, "Width": 700.5, "Height": 800]],
            ["kCGWindowLayer": 0, "kCGWindowOwnerPID": 20],
            ["kCGWindowLayer": 0, "kCGWindowBounds": ["X": 0, "Y": 0, "Width": 10, "Height": 10]],
            ["kCGWindowLayer": 0, "kCGWindowOwnerPID": 20, "kCGWindowBounds": ["X": 300, "Y": 100, "Width": 900, "Height": 700]],
        ]
        XCTAssertEqual(OnScreenWindow.frontToBack(windowInfo: info), [
            OnScreenWindow(pid: 10, frame: CGRect(x: 720, y: 25, width: 700.5, height: 800)),
            OnScreenWindow(pid: 20, frame: centered),
        ])
    }
}
