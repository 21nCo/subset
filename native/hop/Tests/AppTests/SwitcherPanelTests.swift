import AppKit
@testable import Hop
import HopCore
import XCTest

@MainActor
final class SwitcherPanelTests: XCTestCase {
    private func entry(_ ref: UInt64, title: String, app: String, minimized: Bool = false, hidden: Bool = false) -> WindowEntry {
        WindowEntry(
            app: SourceApp(pid: pid_t(ref), bundleIdentifier: nil, name: app, isHidden: hidden),
            window: SourceWindow(
                ref: HopCore.WindowRef(rawValue: ref),
                title: title,
                subrole: "AXStandardWindow",
                isMinimized: minimized,
                frame: CGRect(x: 0, y: 0, width: 400, height: 300)
            ),
            frame: CGRect(x: 0, y: 0, width: 400, height: 300),
            display: nil
        )
    }

    private func children(of element: Any?) -> [NSAccessibilityElement] {
        ((element as? NSAccessibilityElement)?.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
    }

    func testTheGridIsAnAccessibilityListOfLabelledCells() throws {
        let view = SwitcherContentView()
        let windows = [
            entry(1, title: "Budget.numbers", app: "Numbers"),
            entry(2, title: "Inbox", app: "Mail", minimized: true),
            entry(3, title: "", app: "Finder", hidden: true),
        ]
        view.update(.switcher(SwitcherViewModel(items: windows.map(SwitcherItem.window), available: CGSize(width: 1440, height: 900)), icons: [:]))

        let list = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(list.accessibilityRole(), .list)
        let cells = children(of: list)
        XCTAssertEqual(cells.map { $0.accessibilityLabel() ?? "" }, [
            "Budget.numbers, Numbers",
            "Inbox, Mail, minimized",
            "Finder, hidden",
        ])
        XCTAssertEqual(cells.map { $0.isAccessibilitySelected() }, [false, true, false], "the switcher opens on the previous window")
        XCTAssertEqual(list.accessibilitySelectedChildren()?.count, 1)
    }

    func testTheSelectionAndTheListFollowTheModel() throws {
        let view = SwitcherContentView()
        let windows = [entry(1, title: "One", app: "A"), entry(2, title: "Two", app: "B"), entry(3, title: "Three", app: "C")]
        var model = SwitcherViewModel(items: windows.map(SwitcherItem.window), available: CGSize(width: 1440, height: 900))
        view.update(.switcher(model, icons: [:]))
        let list = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        let before = children(of: list)
        model.handle(.step(.forward))
        view.update(.switcher(model, icons: [:]))
        let after = children(of: list)
        XCTAssertTrue(after.elementsEqual(before, by: ===), "the same window keeps its element")
        XCTAssertEqual(after.map { $0.isAccessibilitySelected() }, [false, false, true])
        model.refreshed(windows.prefix(2).map(SwitcherItem.window))
        view.update(.switcher(model, icons: [:]))
        XCTAssertEqual(children(of: list).map { $0.accessibilityLabel() ?? "" }, ["One, A", "Two, B"])
    }

    func testAnEmptyListSaysNoWindows() throws {
        let view = SwitcherContentView()
        let size = view.update(.switcher(SwitcherViewModel(items: [], available: CGSize(width: 1440, height: 900)), icons: [:]))
        let text = try XCTUnwrap(view.accessibilityChildren()?.first as? NSAccessibilityElement)
        XCTAssertEqual(view.accessibilityChildren()?.count, 1, "no list without windows")
        XCTAssertEqual(text.accessibilityRole(), .staticText)
        XCTAssertEqual(text.accessibilityLabel(), "No windows")
        XCTAssertGreaterThan(size.width, 0)
    }

    func testAMessageIsReadWithTheList() throws {
        let view = SwitcherContentView()
        let windows = [entry(1, title: "One", app: "Xcode"), entry(2, title: "Two", app: "Mail")]
        var model = SwitcherViewModel(items: windows.map(SwitcherItem.window), available: CGSize(width: 1440, height: 900))
        let plain = view.update(.switcher(model, icons: [:]))
        model.finished(.init(.minimize, on: .window(windows[0])), result: .refused("can't be minimized"))
        let withMessage = view.update(.switcher(model, icons: [:]))
        XCTAssertEqual(withMessage.height, plain.height + SwitcherContentView.footerHeight)
        let labels = view.accessibilityChildren()?.compactMap { ($0 as? NSAccessibilityElement)?.accessibilityLabel() }
        XCTAssertEqual(labels, ["Windows", "Couldn't minimize the Xcode window"])
    }
}
