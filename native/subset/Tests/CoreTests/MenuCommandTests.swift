import SubsetCore
import XCTest

final class MenuCommandTests: XCTestCase {
    func testMenuOffersOpenAboutAndQuitInOrder() {
        XCTAssertEqual(MenuCommand.allCases.map(\.title), ["Open Subset", "About Subset", "Quit Subset"])
    }

    func testOpenAndQuitHaveCommandKeys() {
        XCTAssertEqual(MenuCommand.allCases.map(\.keyEquivalent), ["o", nil, "q"])
    }

    /// Open Subset stands alone above a separator; About and Quit share the last group.
    func testSeparatorPrecedesAbout() {
        XCTAssertEqual(MenuCommand.allCases.filter(\.startsGroup), [.about])
    }
}
