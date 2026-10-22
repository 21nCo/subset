import Foundation
@testable import SystemCore
import SystemProcesses
import XCTest

/// What Explain sends for a process group and a process of a real sample, and the suggested origin of an
/// Unattributed group.
@MainActor
final class ProcessExplainTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let redactor = ExplainRedactor(homes: ["/Users/me"], accountNames: ["me"], sendFolderNames: false,
                                           key: Array(repeating: 1, count: 32))
    /// Unsigned, outside any app, Homebrew, or terminal, and started by launchd: no rule identifies it.
    private let syncd = "/Users/me/tools/acme-sync/bin/syncd"

    private func model() throws -> ProcessesWindowModel {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        let processes = ProcessFixtures.workload()
            + [FixtureProcess(pid: 500, path: syncd, memory: 30 * ProcessFixtures.mib, cpu: 2, energy: 1, signature: ProcessFixtures.unsigned)]
        model.apply(try ProcessFixtures.sample(processes, observedAt: t0), memory: nil, cadence: .mainWindowVisible)
        return model
    }

    private func sent(_ request: ExplainRequest) throws -> String {
        String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
    }

    func testAGroupRequestCarriesTheGroupsFacts() throws {
        let model = try model()
        let chrome = RowID.group(OriginGroupID(.app(bundlePath: ProcessFixtures.chrome)))
        let request = try XCTUnwrap(model.explainRequest(for: chrome, redactor: redactor))
        XCTAssertEqual(request.kind, .processGroup)
        XCTAssertEqual(request.name, "Google Chrome")
        XCTAssertEqual(request.type, "Group in the App layer")
        XCTAssertEqual(request.path, ProcessFixtures.chrome)
        XCTAssertEqual(request.teamID, "EQHXZ8M8AV")
        XCTAssertEqual(request.vendor, "Google LLC")
        XCTAssertEqual(request.matchedRule, "Inside an app bundle")
        XCTAssertEqual(request.members, ["Google Chrome", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)"])
        XCTAssertEqual(request.sizes?.hasPrefix("3 processes; memory"), true)
        XCTAssertTrue(request.evidence.contains("Google Chrome: Inside `Google Chrome.app`"), "\(request.evidence)")
        XCTAssertFalse(request.maySuggestOrigin)
        XCTAssertEqual(ProcessesWindowModel.explainKey(for: chrome), ExplainKey("process-group:app:\(ProcessFixtures.chrome)"))
    }

    func testAProcessRequestRedactsItsPathAndEvidence() throws {
        let model = try model()
        let claude = RowID.process(ProcessFixtures.identity(202))
        let request = try XCTUnwrap(model.explainRequest(for: claude, redactor: redactor,
                                                         now: Date(timeIntervalSince1970: 3 * 3_600)))
        XCTAssertEqual(request.kind, .process)
        XCTAssertEqual(request.name, "2.1.304")
        let subset = redactor.placeholder("subset")
        XCTAssertEqual(request.type, "Process in Agent: claude › \(subset) (App layer)")
        XCTAssertEqual(request.matchedRule, "Coding agent session")
        XCTAssertEqual(request.age, "Running for 2 hours")
        XCTAssertEqual(request.path, "~/.local/\(redactor.placeholder("share"))/\(redactor.placeholder("claude"))/"
            + "\(redactor.placeholder("versions"))/2.1.304")
        XCTAssertTrue(request.evidence.contains("Runs claude in ~/dev/\(subset)"), "\(request.evidence)")
        let json = try sent(request)
        XCTAssertFalse(json.contains("/Users/me"), json)
        XCTAssertFalse(json.contains("subset"), json)

        let named = try XCTUnwrap(model.explainRequest(for: claude, redactor: redactor.sendingFolderNames(true)))
        XCTAssertTrue(named.evidence.contains("Runs claude in ~/dev/subset"), "\(named.evidence)")
        XCTAssertEqual(named.type, "Process in Agent: claude › subset (App layer)")
        XCTAssertEqual(named.path, "~/.local/share/claude/versions/2.1.304")
    }

    func testOnlyAnUnattributedGroupMayGetASuggestedOriginAndGroupingIsUnchanged() throws {
        let model = try model()
        let group = OriginGroupID(.unattributed(executable: syncd))
        let request = try XCTUnwrap(model.explainRequest(for: .group(group), redactor: redactor))
        XCTAssertTrue(request.maySuggestOrigin)
        XCTAssertEqual(request.name, "~/tools/\(redactor.placeholder("acme-sync"))/\(redactor.placeholder("bin"))/syncd",
                       "an Unattributed group is named by its executable's path, redacted like any path")
        XCTAssertEqual(request.matchedRule, "No origin found; grouped by executable")
        let draft = ExplanationDraft(summary: "A sync daemon.", whatItIs: "Syncs files.", removalSafety: "review",
                                     howToRemove: "Remove its launch agent.", confidence: "low", suggestedOrigin: "Acme Sync")
        XCTAssertEqual(try Explanation(validating: draft, for: request).suggestedOrigin, "Acme Sync")

        for other in [RowID.group(OriginGroupID(.app(bundlePath: ProcessFixtures.chrome))),
                      .group(OriginGroupID(.unsigned)), .process(ProcessFixtures.identity(500))] {
            let request = try XCTUnwrap(model.explainRequest(for: other, redactor: redactor))
            XCTAssertFalse(request.maySuggestOrigin, "\(other)")
            XCTAssertNil(try Explanation(validating: draft, for: request).suggestedOrigin, "\(other)")
        }
        model.selection = .process(ProcessFixtures.identity(500))
        XCTAssertEqual(model.detail?.placement?.group, syncd, "the rule-based group is the one shown")
    }

    func testARowGoneFromTheSampleHasNoRequest() throws {
        let model = try model()
        XCTAssertNil(model.explainRequest(for: .process(ProcessFixtures.identity(999)), redactor: redactor))
        XCTAssertNil(model.explainRequest(for: .group(OriginGroupID(.agent(name: "nobody"))), redactor: redactor))
    }
}
