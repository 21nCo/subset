import Foundation
@testable import SystemCore
import SystemProcesses
import XCTest

/// What Ask's process tools (SET-51) read from a real sample: groups in the window's order, redacted as Explain redacts,
/// a group's facts as Explain sends them, and the memory read with the sample.
@MainActor
final class ProcessAskTests: XCTestCase {
    private let redactor = ExplainRedactor(homes: ["/Users/me"], accountNames: ["me"], sendFolderNames: false,
                                           key: Array(repeating: 1, count: 32))

    private func model() throws -> ProcessesWindowModel {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload()),
                    memory: ProcessFixtures.memory(level: 2, physical: 16 << 30), cadence: .mainWindowVisible)
        return model
    }

    func testTopGroupsAreTheWindowsGroupsInItsOrder() throws {
        let model = try model()
        for (metric, key) in [(AskMetric.cpu, UsageSortKey.cpu), (.memory, .memory), (.energy, .energy)] {
            let output = model.askTopGroups(by: metric, layer: .app, limit: 3, redactor: redactor)
            model.sortKey = key
            let shown = model.rows.filter { $0.depth == 0 }.prefix(3).map { row -> AskTarget? in
                if case let .group(id) = row.id { .group(id) } else { nil }
            }
            XCTAssertEqual(output.entries.map(\.target), Array(shown), "\(metric)")
        }
        let chrome = try XCTUnwrap(model.askTopGroups(by: .memory, layer: .app, limit: 10, redactor: redactor).entries
            .first { $0.target == .group(OriginGroupID(.app(bundlePath: ProcessFixtures.chrome))) })
        XCTAssertEqual(chrome.fields["name"], .name("Google Chrome"))
        XCTAssertEqual(chrome.fields["processes"], .count(3))
        XCTAssertEqual(chrome.fields["path"], .path(redactor.path(ProcessFixtures.chrome)))
        XCTAssertEqual(chrome.fields["memory"], .words("about 1.27 GB"))

        XCTAssertEqual(ProcessesWindowModel().askTopGroups(by: .cpu, layer: .app, limit: 5, redactor: redactor),
                       AskOutput(["status": .words("No process sample yet.")]))
    }

    func testAProjectGroupIsNamedAndPlacedAsExplainSendsIt() throws {
        let model = try model()
        let project = try XCTUnwrap(model.askTopGroups(by: .cpu, layer: .project, limit: 10, redactor: redactor).entries
            .first { $0.target == .group(OriginGroupID(.project(path: "/Users/me/dev/subset"))) })
        let subset = redactor.placeholder("subset")
        XCTAssertEqual(project.fields["name"], .name(subset))
        XCTAssertEqual(project.fields["path"]?.text, "~/dev/\(subset)")
    }

    func testGroupDetailIsWhatExplainSendsWithItsSubgroups() throws {
        let model = try model()
        let chrome = OriginGroupID(.app(bundlePath: ProcessFixtures.chrome))
        let detail = try XCTUnwrap(model.askGroupDetail(chrome, redactor: redactor))
        XCTAssertEqual(detail.fields["group"], .facts(try XCTUnwrap(model.explainRequest(for: .group(chrome), redactor: redactor))))
        XCTAssertEqual(detail.fields["subgroups"], .count(0))
        XCTAssertNil(model.askGroupDetail(OriginGroupID(.app(bundlePath: "/Applications/Gone.app")), redactor: redactor))
    }

    func testMemoryStateIsTheMemoryReadWithTheSample() throws {
        let memory = try model().askMemoryState()
        XCTAssertEqual(memory.fields["pressure"], .words("Warning"))
        XCTAssertEqual(memory.fields["physicalMemory"], .words("16 GB"))
        XCTAssertEqual(memory.fields["used"], .words("–"))
        XCTAssertEqual(ProcessesWindowModel().askMemoryState(), AskOutput(["status": .words("Memory has not been read yet.")]))
    }
}

private extension AskValue {
    var text: String? {
        switch self {
        case let .path(path): path.value
        case let .name(text), let .words(text): text
        default: nil
        }
    }
}
