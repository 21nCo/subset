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
                       AskOutput(["status": .words("No process sample yet."), "sample": .words("Not observed yet"),
                                  "sampling": .words("Waiting for the first sample")]))
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

    func testGroupToolsSayWhenTheirFiguresAreNotCurrent() throws {
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let model = try model()
        let chrome = OriginGroupID(.app(bundlePath: ProcessFixtures.chrome))
        func sampling(now: Date) throws -> [AskValue?] {
            let top = model.askTopGroups(by: .memory, layer: .app, limit: 3, redactor: redactor, now: now)
            let detail = try XCTUnwrap(model.askGroupDetail(chrome, redactor: redactor, now: now))
            return [top.fields["sampling"], detail.fields["sampling"], model.askMemoryState(now: now).fields["sampling"]]
        }
        XCTAssertEqual(try sampling(now: t0 + 1), Array(repeating: .words("Current"), count: 3))
        XCTAssertEqual(model.askGroupDetail(chrome, redactor: redactor, now: t0 + 1)?.fields["sample"],
                       .words("Observed at \(ProcessFixtures.format.time(t0))"))

        // The window keeps the last good groups after a failed sample, so their figures are the same; only the
        // sampling state tells them apart, without the failure's message.
        let before = model.askTopGroups(by: .memory, layer: .app, limit: 3, redactor: redactor, now: t0 + 1)
        model.applyFailure("Could not list processes: listFailed(1)", memory: nil, at: t0 + 2, cadence: .mainWindowVisible)
        let failed = model.askTopGroups(by: .memory, layer: .app, limit: 3, redactor: redactor, now: t0 + 3)
        XCTAssertEqual(failed.entries, before.entries)
        let failedText = "The latest sample failed; process figures are from the one before"
        XCTAssertEqual(try sampling(now: t0 + 3), Array(repeating: .words(failedText), count: 3))
        XCTAssertFalse(String(describing: failed).contains("listFailed"))

        // No sample for more than three intervals: stale.
        XCTAssertEqual(try sampling(now: t0 + 20), Array(repeating: .words("Stale: no recent sample"), count: 3))

        model.apply(try ProcessFixtures.sample(ProcessFixtures.workload(), observedAt: t0 + 30),
                    memory: ProcessFixtures.memory(level: 2, physical: 16 << 30), cadence: .mainWindowVisible)
        XCTAssertEqual(try sampling(now: t0 + 31), Array(repeating: .words("Current"), count: 3))
    }

    func testMemoryStateIsTheMemoryReadWithTheSample() throws {
        let memory = try model().askMemoryState()
        XCTAssertEqual(memory.fields["pressure"], .words("Warning"))
        XCTAssertEqual(memory.fields["physicalMemory"], .words("16 GB"))
        XCTAssertEqual(memory.fields["used"], .words("–"))
        XCTAssertEqual(ProcessesWindowModel().askMemoryState(),
                       AskOutput(["status": .words("Memory has not been read yet."), "sample": .words("Not observed yet"),
                                  "sampling": .words("Waiting for the first sample")]))
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
