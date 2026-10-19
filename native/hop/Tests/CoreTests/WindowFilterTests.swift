import CoreGraphics
import HopCore
import XCTest

/// One vector per rule of the closed inclusion set.
final class WindowFilterTests: XCTestCase {
    private let ownProcess: pid_t = 99
    private let app = SourceApp(pid: 10, bundleIdentifier: "com.example.editor", name: "Editor")

    private func window(subrole: String?, frame: CGRect? = CGRect(x: 0, y: 0, width: 800, height: 600)) -> SourceWindow {
        SourceWindow(ref: WindowRef(rawValue: 1), title: "Notes", subrole: subrole, frame: frame)
    }

    func testStandardWindowsAreIncluded() {
        XCTAssertNil(WindowFilter.exclusion(for: window(subrole: "AXStandardWindow")))
    }

    func testDialogsAreIncluded() {
        XCTAssertNil(WindowFilter.exclusion(for: window(subrole: "AXDialog")))
    }

    func testFloatingWindowsAreExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXFloatingWindow")), .subrole("AXFloatingWindow"))
    }

    func testSystemDialogsAreExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXSystemDialog")), .subrole("AXSystemDialog"))
    }

    func testUnknownSubrolesAreExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXUnknown")), .subrole("AXUnknown"))
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXSomethingNew")), .subrole("AXSomethingNew"))
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: nil)), .subrole(nil), "a missing subrole is unknown")
    }

    func testWindowsSmallerThan40PointsOnEitherSideAreExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 39.5, height: 600))), .tooSmall)
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXDialog", frame: CGRect(x: 0, y: 0, width: 600, height: 39))), .tooSmall)
        XCTAssertNil(WindowFilter.exclusion(for: window(subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: 40, height: 40))), "40×40 is large enough")
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXStandardWindow", frame: nil)), .tooSmall, "an unknown size cannot be shown to be large enough")
        XCTAssertEqual(WindowFilter.exclusion(for: window(subrole: "AXStandardWindow", frame: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 600))), .tooSmall)
    }

    func testHopsOwnWindowsAreExcluded() {
        XCTAssertEqual(WindowFilter.exclusion(for: SourceApp(pid: ownProcess, bundleIdentifier: nil, name: "Hop"), ownProcess: ownProcess), .ownApp)
        let otherCopy = SourceApp(pid: 11, bundleIdentifier: HopIdentity.bundleIdentifier, name: "Hop")
        XCTAssertEqual(WindowFilter.exclusion(for: otherCopy, ownProcess: ownProcess), .ownApp, "another copy of Hop")
    }

    func testAppsThatAreNotRegularAreExcluded() {
        for policy in [AppActivationPolicy.accessory, .prohibited] {
            var background = app
            background.activationPolicy = policy
            XCTAssertEqual(WindowFilter.exclusion(for: background, ownProcess: ownProcess), .appNotRegular)
        }
        XCTAssertNil(WindowFilter.exclusion(for: app, ownProcess: ownProcess))
    }

    func testMinimizedWindowsAndHiddenAppsAreIncluded() {
        var minimized = window(subrole: "AXStandardWindow")
        minimized.isMinimized = true
        XCTAssertNil(WindowFilter.exclusion(for: minimized))
        var hidden = app
        hidden.isHidden = true
        XCTAssertNil(WindowFilter.exclusion(for: hidden, ownProcess: ownProcess))
    }
}
