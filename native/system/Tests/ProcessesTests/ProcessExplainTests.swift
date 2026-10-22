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
    /// An app in the home folder's own Applications folder.
    private let notes = "/Users/me/Applications/Acme Notes.app"

    private func model() throws -> ProcessesWindowModel {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        let processes = ProcessFixtures.workload()
            + [FixtureProcess(pid: 500, path: syncd, memory: 30 * ProcessFixtures.mib, cpu: 2, energy: 1, signature: ProcessFixtures.unsigned),
               FixtureProcess(pid: 600, path: notes + "/Contents/MacOS/notesd", memory: 10 * ProcessFixtures.mib, cpu: 1,
                              energy: 1, signature: ProcessFixtures.unsigned, cwd: "/Users/me/dev/subset/webclient-x")]
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
            + "\(redactor.placeholder("versions"))/\(redactor.placeholder("2.1.304"))")
        XCTAssertTrue(request.evidence.contains("Runs claude in ~/dev/\(subset)"), "\(request.evidence)")
        let json = try sent(request)
        XCTAssertFalse(json.contains("/Users/me"), json)
        XCTAssertFalse(json.contains("subset"), json)

        let named = try XCTUnwrap(model.explainRequest(for: claude, redactor: redactor.sendingFolderNames(true)))
        XCTAssertTrue(named.evidence.contains("Runs claude in ~/dev/subset"), "\(named.evidence)")
        XCTAssertEqual(named.type, "Process in Agent: claude › subset (App layer)")
        XCTAssertEqual(named.path, "~/.local/share/claude/versions/2.1.304")
    }

    func testAProjectOrAppGroupInTheHomeFolderIsNamedAsItsPathIsSent() throws {
        let model = try model()
        let project = try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.project(path: "/Users/me/dev/subset"))),
                                                         redactor: redactor))
        XCTAssertEqual(project.name, redactor.placeholder("subset"))
        XCTAssertEqual(project.path, "~/dev/\(redactor.placeholder("subset"))")
        let app = try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.app(bundlePath: notes))), redactor: redactor))
        XCTAssertEqual(app.name, redactor.placeholder("Acme Notes.app"))
        XCTAssertEqual(app.path, "~/Applications/\(redactor.placeholder("Acme Notes.app"))")
        XCTAssertEqual(app.members, ["notesd"], "a process is named by its executable, not a folder")

        let named = redactor.sendingFolderNames(true)
        let shown = try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.project(path: "/Users/me/dev/subset"))),
                                                       redactor: named))
        XCTAssertEqual(shown.name, "subset")
        XCTAssertEqual(try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.app(bundlePath: notes))), redactor: named)).name,
                       "Acme Notes")
    }

    func testWithFolderNamesOffNoGroupOrProcessRequestInAnyLayerCarriesADeepFolderName() throws {
        let model = try model()
        let attribution = try XCTUnwrap(model.sample?.attribution)
        let processes = try XCTUnwrap(model.sample?.snapshot.processes)
        let deep = ["subset", "Acme Notes", "acme-sync", "versions", "webclient-x"]
        var checked = 0
        for layer in AttributionLayer.allCases {
            model.layer = layer
            let groups = attribution.groups(layer).flatMap { [$0] + $0.subgroups }
            for row in groups.map({ RowID.group($0.id) }) + processes.map({ RowID.process($0.identity) }) {
                let request = try XCTUnwrap(model.explainRequest(for: row, redactor: redactor), "\(row)")
                let text = try sent(request) + request.promptText
                for name in deep {
                    XCTAssertFalse(text.contains(name), "\(layer) \(row): \(text)")
                }
                XCTAssertFalse(text.contains("/Users/me"), text)
                checked += 1
            }
        }
        XCTAssertGreaterThan(checked, 40)
    }

    func testAProjectOnANetworkVolumeWithASpaceInItsNameIsWithheldInEveryField() throws {
        let volume = "/Users/me/Mounts/Acme Merger"
        let cwd = volume + "/web client"
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        let mounts = FixtureMountTable([MountPoint(path: "/", isLocal: true), MountPoint(path: volume, isLocal: false)])
        model.apply(try ProcessFixtures.sample([FixtureProcess(pid: 700, path: "/usr/local/bin/node", memory: ProcessFixtures.mib,
                                                               cpu: 1, energy: 1, signature: ProcessFixtures.unsigned, cwd: cwd)],
                                               mounts: mounts),
                    memory: nil, cadence: .mainWindowVisible)
        model.layer = .project
        let group = RowID.group(OriginGroupID(.project(path: cwd)))
        let process = RowID.process(ProcessFixtures.identity(700))
        for row in [group, process] {
            let request = try XCTUnwrap(model.explainRequest(for: row, redactor: redactor), "\(row)")
            XCTAssertTrue(request.evidence.contains { $0.contains("network volume at ~/Mounts/\(redactor.placeholder("Acme Merger"))") },
                          "\(request.evidence)")
            let text = try sent(request) + request.promptText
            for word in ["Acme", "Merger", "web", "client"] { XCTAssertFalse(text.contains(word), "\(row): \(text)") }

            let named = try XCTUnwrap(model.explainRequest(for: row, redactor: redactor.sendingFolderNames(true)))
            XCTAssertTrue(named.evidence.contains { $0.hasSuffix("network volume at ~/Mounts/Acme Merger") }, "\(named.evidence)")
        }
    }

    /// Every kind of evidence that holds a path shows it through the redactor where its text is built, so no word of a
    /// withheld folder name with spaces is left for the last line of defense; with folder names sent, the names appear.
    func testEveryKindOfEvidenceShowsItsPathsAsTheRedactorSendsThem() throws {
        let deep = "/Users/me/dev/Acme Merger/web client"
        let bundle = "/Users/me/Applications/Secret Notes.app"
        let process = try XCTUnwrap(try model().sample?.snapshot.processes.first { $0.pid == 600 })
        let job = LaunchdJob(label: "com.example.agent", plistPath: "/Users/me/Library/LaunchAgents/Acme Merger/agent.plist",
                             domain: .userAgent, program: deep + "/agent", resolution: .missing)
        let scan = SignalFailure.incompleteScan([LaunchdScanFailure(path: deep + "/plists", code: EACCES)])
        let evidence: [AttributionEvidence] = [
            .executable(path: deep + "/tool", name: "tool"), .executable(path: nil, name: "tool"), .appBundle(path: bundle),
            .systemLocation(prefix: "/System", platformBinary: true), .containerVM(ContainerVM(name: "Podman", detail: "vfkit")),
            .codingAgent(name: "claude", pid: process.pid), .terminalApp(name: "Terminal", pid: 2, bundlePath: bundle),
            .controllingTerminal(device: "/dev/ttys001"), .responsibleProcess(pid: 2, bundlePath: bundle),
            .coalitionLeader(coalition: 3, pid: 2, bundlePath: bundle), .launchdJob(job), .orphanedLaunchdJob(job),
            .homebrew(formula: "wget"), .signature(ProcessFixtures.google), .signatureUnavailable(scan),
            .signatureUnavailable(nil), .loginItem(bundlePath: bundle), .parentIsLaunchd, .inheritedFrom(pid: 2),
            .parentNotSampled(ppid: 9), .workingDirectory(deep), .workingDirectoryUnavailable(scan),
            .workingDirectoryUnavailable(nil), .projectMarker(directory: deep, marker: ".git"),
            .projectMarkersSkipped(volume: deep)
        ]
        // Fails to compile when a kind of evidence is added, so this list is extended with it.
        func listed(_ evidence: AttributionEvidence) -> Bool {
            switch evidence {
            case .executable, .appBundle, .systemLocation, .containerVM, .codingAgent, .terminalApp, .controllingTerminal,
                 .responsibleProcess, .coalitionLeader, .launchdJob, .orphanedLaunchdJob, .homebrew, .signature,
                 .signatureUnavailable, .loginItem, .parentIsLaunchd, .inheritedFrom, .parentNotSampled, .workingDirectory,
                 .workingDirectoryUnavailable, .projectMarker, .projectMarkersSkipped: true
            }
        }
        XCTAssertTrue(evidence.allSatisfy(listed))
        let withheld = OriginExplanation(process: process, format: ProcessFixtures.format, path: { [redactor] in redactor.path($0) }) { _ in "helper" }
        let named = redactor.sendingFolderNames(true)
        let shown = OriginExplanation(process: process, format: ProcessFixtures.format, path: { named.path($0) }) { _ in "helper" }
        var withNames = ""
        for item in evidence {
            let text = withheld.describe(item)
            for word in ["Acme", "Merger", "web", "client", "Secret", "Notes", "subset"] {
                XCTAssertFalse(text.contains(word), "\(item): \(text)")
            }
            XCTAssertFalse(text.contains("/Users/me"), text)
            withNames += shown.describe(item) + "\n"
        }
        for name in ["Acme Merger/web client", "Secret Notes.app", "~/dev/subset/webclient-x"] {
            XCTAssertTrue(withNames.contains(name), "\(name) in \(withNames)")
        }
    }

    func testOnlyAnUnattributedGroupMayGetASuggestedOriginAndGroupingIsUnchanged() throws {
        let model = try model()
        let group = OriginGroupID(.unattributed(executable: syncd))
        let request = try XCTUnwrap(model.explainRequest(for: .group(group), redactor: redactor))
        XCTAssertTrue(request.maySuggestOrigin)
        XCTAssertEqual(request.name, "~/tools/\(redactor.placeholder("acme-sync"))/\(redactor.placeholder("bin"))/"
            + redactor.placeholder("syncd"),
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
