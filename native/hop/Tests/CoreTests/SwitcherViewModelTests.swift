import CoreGraphics
import HopCore
import XCTest

/// Windows for the switcher tests: `count` entries with refs 0..<count, two windows per app.
private func entries(_ count: Int) -> [WindowEntry] {
    (0..<count).map { index in
        let app = SourceApp(pid: pid_t(100 + index / 2), bundleIdentifier: "com.example.app\(index / 2)", name: "App \(index / 2)")
        let window = SourceWindow(
            ref: WindowRef(rawValue: UInt64(index)),
            title: "Window \(index)",
            subrole: "AXStandardWindow",
            frame: CGRect(x: 0, y: 0, width: 400, height: 300)
        )
        return WindowEntry(app: app, window: window, frame: window.frame!, display: 1)
    }
}

/// A 1440 × 900 pt usable area (a 14-inch MacBook Pro at its default scale): 7 columns.
private let wide = CGSize(width: 1440, height: 900)
/// A 1024 × 768 pt usable area: 5 columns.
private let narrow = CGSize(width: 1024, height: 768)

final class SwitcherLayoutTests: XCTestCase {
    func testGridForOneSevenAndSixtyWindowsOnAWideScreen() {
        let one = SwitcherLayout(count: 1, available: wide)
        XCTAssertEqual([one.columns, one.rows, one.visibleRows], [1, 1, 1])
        XCTAssertEqual(one.size, CGSize(width: 152 + 32, height: 112 + 32))

        let seven = SwitcherLayout(count: 7, available: wide)
        XCTAssertEqual([seven.columns, seven.rows, seven.visibleRows], [7, 1, 1])
        XCTAssertEqual(seven.size.width, 7 * 152 + 6 * 8 + 32)

        let sixty = SwitcherLayout(count: 60, available: wide)
        XCTAssertEqual([sixty.columns, sixty.rows, sixty.visibleRows], [7, 9, 5], "at most 5 rows show")
        XCTAssertEqual(sixty.size.height, 5 * 112 + 4 * 8 + 32)
        XCTAssertLessThanOrEqual(sixty.size.width, wide.width * 0.9)
    }

    func testGridForOneSevenAndSixtyWindowsOnANarrowScreen() {
        let one = SwitcherLayout(count: 1, available: narrow)
        XCTAssertEqual([one.columns, one.rows, one.visibleRows], [1, 1, 1])

        let seven = SwitcherLayout(count: 7, available: narrow)
        XCTAssertEqual([seven.columns, seven.rows, seven.visibleRows], [5, 2, 2], "the last row holds 2")

        let sixty = SwitcherLayout(count: 60, available: narrow)
        XCTAssertEqual([sixty.columns, sixty.rows, sixty.visibleRows], [5, 12, 5])
        XCTAssertLessThanOrEqual(sixty.size.width, narrow.width * 0.9)
        XCTAssertLessThanOrEqual(sixty.size.height, narrow.height * 0.9)
    }

    func testAShortScreenShowsFewerRowsAndATinyOneStillShowsOne() {
        XCTAssertEqual(SwitcherLayout(count: 60, available: CGSize(width: 1440, height: 400)).visibleRows, 2)
        let tiny = SwitcherLayout(count: 3, available: CGSize(width: 100, height: 100))
        XCTAssertEqual([tiny.columns, tiny.rows, tiny.visibleRows], [1, 3, 1])
    }

    func testAnEmptyListHasNoRows() {
        let empty = SwitcherLayout(count: 0, available: wide)
        XCTAssertEqual([empty.columns, empty.rows, empty.visibleRows], [1, 0, 0])
        XCTAssertEqual(empty.visibleIndices(firstVisibleRow: 0), 0..<0)
        XCTAssertNil(empty.index(at: CGPoint(x: 40, y: 40), firstVisibleRow: 0))
    }

    func testRowMovesAtARaggedLastRow() {
        // 60 windows in 7 columns: rows 0-7 are full and the last row holds 56-59.
        let layout = SwitcherLayout(count: 60, available: wide)
        XCTAssertEqual(layout.index(moving: .down, from: 50), 57, "into the last row, same column")
        XCTAssertEqual(layout.index(moving: .down, from: 54), 59, "past the end of the ragged row: its last cell")
        XCTAssertEqual(layout.index(moving: .down, from: 59), 3, "from the last row: wraps to the top, same column")
        XCTAssertEqual(layout.index(moving: .up, from: 59), 52)
        XCTAssertEqual(layout.index(moving: .up, from: 2), 58, "from the top: wraps into the last row")
        XCTAssertEqual(layout.index(moving: .up, from: 5), 59, "wrapping to a column the last row lacks: its last cell")
        XCTAssertEqual(layout.index(moving: .down, from: 10), 17)

        // 7 windows in 5 columns: the second row holds 5 and 6.
        let seven = SwitcherLayout(count: 7, available: narrow)
        XCTAssertEqual(seven.index(moving: .down, from: 3), 6)
        XCTAssertEqual(seven.index(moving: .down, from: 1), 6)
        XCTAssertEqual(seven.index(moving: .down, from: 0), 5)
        XCTAssertEqual(seven.index(moving: .up, from: 6), 1)
        XCTAssertEqual(seven.index(moving: .down, from: 6), 1)

        // One row: ↑ and ↓ stay put.
        let single = SwitcherLayout(count: 7, available: wide)
        XCTAssertEqual(single.index(moving: .down, from: 4), 4)
        XCTAssertEqual(single.index(moving: .up, from: 4), 4)
    }

    func testHitTestingFindsOnlyVisibleCells() {
        let layout = SwitcherLayout(count: 60, available: wide)
        // The first cell spans 16...168 by 16...128.
        XCTAssertEqual(layout.index(at: CGPoint(x: 20, y: 20), firstVisibleRow: 0), 0)
        XCTAssertEqual(layout.index(at: CGPoint(x: 180, y: 20), firstVisibleRow: 0), 1)
        XCTAssertNil(layout.index(at: CGPoint(x: 170, y: 20), firstVisibleRow: 0), "the spacing between cells")
        XCTAssertNil(layout.index(at: CGPoint(x: 8, y: 20), firstVisibleRow: 0), "the padding")
        XCTAssertEqual(layout.index(at: CGPoint(x: 20, y: 20 + 120), firstVisibleRow: 0), 7)
        XCTAssertEqual(layout.index(at: CGPoint(x: 20, y: 20), firstVisibleRow: 4), 28, "scrolled down 4 rows")
        // Scrolled to the bottom, the last visible row is the ragged one (56-59).
        let lastRow = CGPoint(x: 16 + 4 * 160 + 10, y: 16 + 4 * 120 + 10)
        XCTAssertNil(layout.index(at: lastRow, firstVisibleRow: 4), "an empty place in the ragged row")
        XCTAssertEqual(layout.index(at: CGPoint(x: 20, y: lastRow.y), firstVisibleRow: 4), 56)
        XCTAssertNil(layout.index(at: CGPoint(x: 20, y: 16 + 5 * 120 + 10), firstVisibleRow: 0), "below the visible rows")
        XCTAssertNil(layout.frame(of: 35, firstVisibleRow: 0))
        XCTAssertEqual(layout.frame(of: 35, firstVisibleRow: 1), CGRect(x: 16, y: 16 + 4 * 120, width: 152, height: 112))
    }
}

final class SwitcherViewModelTests: XCTestCase {
    func testOpensOnThePreviousWindowOrTheOnlyOne() {
        XCTAssertEqual(SwitcherViewModel(entries: entries(5), available: wide).selection, 1)
        XCTAssertEqual(SwitcherViewModel(entries: entries(1), available: wide).selection, 0)
        XCTAssertNil(SwitcherViewModel(entries: [], available: wide).selection, "an empty list shows No windows")
    }

    func testStepsWrapBothWays() {
        var model = SwitcherViewModel(entries: entries(3), available: wide)
        model.handle(.step(.forward))
        XCTAssertEqual(model.selection, 2)
        model.handle(.trigger(.forward))
        XCTAssertEqual(model.selection, 0, "a repeated shortcut steps like Tab")
        model.handle(.step(.backward))
        XCTAssertEqual(model.selection, 2)
        var empty = SwitcherViewModel(entries: [], available: wide)
        XCTAssertNil(empty.handle(.step(.forward)))
        XCTAssertNil(empty.handle(.row(.down)))
        XCTAssertNil(empty.selection)
    }

    func testRowKeysMoveTheSelectionThroughTheRaggedLastRow() {
        var model = SwitcherViewModel(entries: entries(7), available: narrow)
        model.select(3)
        model.handle(.row(.down))
        XCTAssertEqual(model.selection, 6)
        model.handle(.row(.up))
        XCTAssertEqual(model.selection, 1)
        model.handle(.row(.up))
        XCTAssertEqual(model.selection, 6)
    }

    func testTheSelectionIsScrolledIntoView() {
        var model = SwitcherViewModel(entries: entries(60), available: wide)
        XCTAssertEqual(model.firstVisibleRow, 0)
        XCTAssertEqual(model.visibleIndices, 0..<35)
        model.select(40) // row 5, just below the visible rows
        XCTAssertEqual(model.firstVisibleRow, 1)
        model.select(30) // row 4, already visible
        XCTAssertEqual(model.firstVisibleRow, 1)
        model.select(0)
        model.handle(.step(.backward)) // wraps to 59, in the last row
        XCTAssertEqual(model.selection, 59)
        XCTAssertEqual(model.firstVisibleRow, 4)
        XCTAssertEqual(model.visibleIndices, 28..<60)
        model.handle(.row(.down)) // wraps to the top row
        XCTAssertEqual(model.selection, 3)
        XCTAssertEqual(model.firstVisibleRow, 0)
    }

    func testScrollingIsClampedAndKeepsTheSelection() {
        var model = SwitcherViewModel(entries: entries(60), available: wide)
        model.scroll(byRows: 3)
        XCTAssertEqual(model.firstVisibleRow, 3)
        model.scroll(byRows: 10)
        XCTAssertEqual(model.firstVisibleRow, 4, "the last row stays at the bottom")
        model.scroll(byRows: -10)
        XCTAssertEqual(model.firstVisibleRow, 0)
        XCTAssertEqual(model.selection, 1)
        var short = SwitcherViewModel(entries: entries(3), available: wide)
        short.scroll(byRows: 1)
        XCTAssertEqual(short.firstVisibleRow, 0)
    }

    func testHoveringSelectsOnlyAListedWindow() {
        var model = SwitcherViewModel(entries: entries(4), available: wide)
        model.select(3)
        XCTAssertEqual(model.selection, 3)
        model.select(4)
        model.select(-1)
        XCTAssertEqual(model.selection, 3)
    }

    func testOperationKeysActOnTheSelectedWindow() {
        let windows = entries(4)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.select(2)
        for operation in [WindowOperation.minimize, .close, .hideApp, .quitApp] {
            XCTAssertEqual(model.handle(.operation(operation)), .init(operation, on: windows[2]))
        }
        XCTAssertEqual(model.selection, 2, "asking for an operation moves nothing")
        var empty = SwitcherViewModel(entries: [], available: wide)
        XCTAssertNil(empty.handle(.operation(.close)), "nothing to act on")
    }

    func testClosingTheSelectedWindowSelectsTheNextOne() {
        let windows = entries(4)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.select(1)
        let request = model.handle(.operation(.close))!
        model.finished(request, result: .done)
        XCTAssertEqual(model.entries, windows, "a delivered close may be waiting on a save prompt")
        XCTAssertEqual(model.selectedEntry?.ref, windows[1].ref)
        XCTAssertNil(model.message)
        // The refresh that follows no longer lists it; the selection moves to the window that followed it.
        model.refreshed([windows[0], windows[2], windows[3]])
        XCTAssertEqual(model.selectedEntry?.ref, windows[2].ref)
    }

    func testARefreshKeepsTheSelectedWindowWhereverItMoved() {
        let windows = entries(4)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.select(1)
        // An app asked to save instead of closing: the window is still listed, now first.
        model.refreshed([windows[1], windows[0], windows[2], windows[3]])
        XCTAssertEqual(model.selection, 0)
        XCTAssertEqual(model.selectedEntry?.ref, windows[1].ref)
    }

    func testARefreshWithoutTheSelectedWindowOrItsFollowersSelectsTheOneBefore() {
        let windows = entries(4)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.select(2)
        model.refreshed([windows[0], windows[1]])
        XCTAssertEqual(model.selectedEntry?.ref, windows[1].ref)
        model.refreshed([])
        XCTAssertNil(model.selection)
        XCTAssertEqual(model.layout.rows, 0)
        model.refreshed(windows)
        XCTAssertEqual(model.selection, 1, "a list that fills again opens on the previous window")
    }

    func testARefreshKeepsTheWindowsOfAppsThatDidNotAnswerWhereTheyWere() {
        let windows = entries(6)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.select(2)
        // App 1 (windows 2 and 3) timed out; App 0's window 1 closed.
        model.refreshed([windows[0], windows[4], windows[5]], unread: [windows[2].pid])
        XCTAssertEqual(model.entries, [windows[0], windows[2], windows[3], windows[4], windows[5]])
        XCTAssertEqual(model.selectedEntry?.ref, windows[2].ref, "an unread window is not taken as gone")
        // A read that answers for App 1 settles it.
        model.refreshed([windows[0], windows[4], windows[5]])
        XCTAssertEqual(model.entries, [windows[0], windows[4], windows[5]])
        XCTAssertEqual(model.selectedEntry?.ref, windows[4].ref)
    }

    func testARefreshRelaysOutTheGrid() {
        var model = SwitcherViewModel(entries: entries(60), available: wide)
        model.select(59)
        XCTAssertEqual(model.firstVisibleRow, 4)
        model.refreshed(Array(entries(60).prefix(10)))
        XCTAssertEqual([model.layout.columns, model.layout.rows], [7, 2])
        XCTAssertEqual(model.firstVisibleRow, 0)
        XCTAssertEqual(model.selection, 9)
    }

    func testOperationsShowTheirEffectUntilTheRefresh() {
        let windows = entries(6) // apps: pid 100 (0, 1), 101 (2, 3), 102 (4, 5)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.finished(.init(.minimize, on: windows[0]), result: .done)
        XCTAssertEqual(model.entries.map(\.isMinimized), [true, false, false, false, false, false])
        model.finished(.init(.hideApp, on: windows[2]), result: .done)
        XCTAssertEqual(model.entries.map(\.isAppHidden), [false, false, true, true, false, false])
        model.select(4)
        model.finished(.init(.quitApp, on: windows[4]), result: .done)
        XCTAssertEqual(model.entries.map(\.ref), windows.map(\.ref), "a delivered quit may be waiting on a save prompt")
        model.finished(.init(.quitApp, on: windows[4]), result: .appGone)
        XCTAssertEqual(model.entries.map(\.ref), windows.prefix(4).map(\.ref))
        XCTAssertEqual(model.selectedEntry?.ref, windows[3].ref, "nothing follows the quit app's windows")
    }

    func testAFailedOperationChangesNoWindowAndSaysWhy() {
        let windows = entries(3)
        var model = SwitcherViewModel(entries: windows, available: wide)
        model.finished(.init(.close, on: windows[1]), result: .refused("can't be closed"))
        XCTAssertEqual(model.entries, windows)
        XCTAssertEqual(model.message, "Couldn't close the App 0 window")
        model.finished(.init(.minimize, on: windows[1]), result: .done)
        XCTAssertNil(model.message, "a later success clears it")
        model.finished(.init(.minimize, on: windows[2]), result: .windowGone)
        XCTAssertEqual(model.message, "That App 1 window has closed")
        XCTAssertEqual(model.entries.count, 2, "a window found gone leaves the list")
        model.clearMessage()
        XCTAssertNil(model.message)
    }

    func testResultMessagesNameTheAppNeverTheWindow() {
        let cases: [(OperationResult, WindowOperation, String?)] = [
            (.done, .focus, nil),
            (.done, .quitApp, nil),
            (.refused("did not come to front"), .focus, "Couldn't bring Xcode forward"),
            (.refused("can't be minimized"), .minimize, "Couldn't minimize the Xcode window"),
            (.refused("can't be closed"), .close, "Couldn't close the Xcode window"),
            (.refused("did not hide"), .hideApp, "Couldn't hide Xcode"),
            (.refused("did not quit"), .quitApp, "Couldn't quit Xcode"),
            (.windowGone, .focus, "That Xcode window has closed"),
            (.windowGone, .minimize, "That Xcode window has closed"),
            (.windowGone, .close, nil),
            (.appGone, .focus, "Xcode has quit"),
            (.appGone, .hideApp, "Xcode has quit"),
            (.appGone, .quitApp, nil),
            (.notPermitted, .focus, "Hop needs Accessibility access"),
            (.notPermitted, .close, "Hop needs Accessibility access"),
        ]
        for (result, operation, expected) in cases {
            XCTAssertEqual(SwitcherViewModel.message(for: result, of: operation, appName: "Xcode"), expected,
                           "\(result) after \(operation)")
        }
        let secret = WindowEntry(
            app: SourceApp(pid: 1, bundleIdentifier: nil, name: "Notes"),
            window: SourceWindow(ref: WindowRef(rawValue: 9), title: "Secret plan", subrole: "AXStandardWindow", frame: .zero),
            frame: .zero,
            display: nil
        )
        var model = SwitcherViewModel(entries: [secret], available: wide)
        for result in [OperationResult.refused("x"), .windowGone, .appGone] {
            model.finished(.init(.focus, on: secret), result: result)
            XCTAssertFalse(model.message?.contains("Secret") ?? false)
        }
    }

    func testTheCellNamesTheWindowItsAppAndItsBadges() {
        var entry = entries(1)[0]
        XCTAssertEqual(entry.displayTitle, "Window 0")
        XCTAssertEqual(entry.accessibilityLabel, "Window 0, App 0")
        entry.isMinimized = true
        entry.isAppHidden = true
        XCTAssertEqual(entry.badges, ["minimized", "hidden"])
        XCTAssertEqual(entry.accessibilityLabel, "Window 0, App 0, minimized, hidden")
        entry.title = ""
        XCTAssertEqual(entry.displayTitle, "App 0", "a window without a title shows its app's name")
        XCTAssertEqual(entry.accessibilityLabel, "App 0, minimized, hidden")
    }
}
