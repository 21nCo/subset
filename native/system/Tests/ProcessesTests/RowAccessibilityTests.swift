import Foundation
import SystemCore
import SystemProcesses
import XCTest

/// Every row the window can show, in every layer and with every group open, has a spoken label and value. Runs in
/// `xcodebuild test` (the SystemProcessesTests bundle) as well as `swift test`, without any UI.
@MainActor
final class RowAccessibilityTests: XCTestCase {
    func testEveryRowViewModelHasANonEmptyAccessibilityLabelAndValue() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload()), memory: nil, cadence: .mainWindowVisible)
        var checked = 0

        for layer in AttributionLayer.allCases {
            model.layer = layer
            // Open every group and subgroup, repeating until no row is closed, so process rows are checked too.
            while let closed = model.rows.first(where: { $0.isExpandable && !$0.isExpanded }), case let .group(id) = closed.id {
                model.setExpanded(id, true)
            }
            XCTAssertTrue(model.rows.contains { !$0.isExpandable }, "\(layer): process rows are visible")
            for row in model.rows {
                XCTAssertFalse(row.accessibilityLabel.trimmingCharacters(in: .whitespaces).isEmpty, "\(layer) \(row.id)")
                XCTAssertFalse(row.accessibilityValue.trimmingCharacters(in: .whitespaces).isEmpty, "\(layer) \(row.id)")
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 4 * 10, "every layer shows its groups and all ten processes")

        let top = TopGroups(attribution: model.sample?.attribution, samplingFailed: false, format: ProcessFixtures.format)
        XCTAssertFalse(top.entries.isEmpty)
        XCTAssertTrue(top.entries.allSatisfy { !$0.accessibilityLabel.isEmpty })
    }

    func testAnUnnamedProcessStillHasALabel() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample([FixtureProcess(pid: 9, path: nil, name: "", memory: 1 << 20)]),
                    memory: nil, cadence: .mainWindowVisible)
        model.setExpanded(try XCTUnwrap(model.rows.first.flatMap { row -> OriginGroupID? in
            if case let .group(id) = row.id { return id }
            return nil
        }), true)

        for row in model.rows {
            XCTAssertFalse(row.accessibilityLabel.isEmpty)
            XCTAssertFalse(row.accessibilityLabel.hasPrefix(","), row.accessibilityLabel)
        }
    }
}
