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
        XCTAssertEqual(request.path?.value, ProcessFixtures.chrome)
        XCTAssertEqual(request.teamID, "EQHXZ8M8AV")
        XCTAssertEqual(request.vendor, "Google LLC")
        XCTAssertEqual(request.matchedRule, "Inside an app bundle")
        XCTAssertEqual(request.members, ["Google Chrome", "Google Chrome Helper (Renderer)", "Google Chrome Helper (GPU)"])
        XCTAssertEqual(request.sizes?.hasPrefix("3 processes; memory"), true)
        XCTAssertTrue(request.evidence.contains { $0.kind == .appBundle && $0.path?.value == ProcessFixtures.chrome },
                      "\(request.evidence)")
        XCTAssertFalse(request.maySuggestOrigin)
        XCTAssertEqual(model.explainKey(for: chrome), ExplainKey("process-group:app:\(ProcessFixtures.chrome)"))
    }

    func testAProcessRequestRedactsItsPathAndEvidence() throws {
        let model = try model()
        let claude = RowID.process(ProcessFixtures.identity(202))
        let request = try XCTUnwrap(model.explainRequest(for: claude, redactor: redactor,
                                                         now: Date(timeIntervalSince1970: 3 * 3_600)))
        XCTAssertEqual(request.kind, .process)
        XCTAssertEqual(request.name, "2.1.304")
        let subset = redactor.placeholder("subset")
        XCTAssertEqual(request.type, "Process placed in the App layer")
        XCTAssertEqual(request.group, "Agent: claude › \(subset)", "the group is a name of its own, withheld as the group's is")
        XCTAssertEqual(request.matchedRule, "Coding agent session")
        XCTAssertEqual(request.age, "Running for 2 hours")
        XCTAssertEqual(request.path?.value, "~/.local/\(redactor.placeholder("share"))/\(redactor.placeholder("claude"))/"
            + "\(redactor.placeholder("versions"))/\(redactor.placeholder("2.1.304"))")
        XCTAssertTrue(request.evidence.contains { $0.kind == .runsCodingAgent && $0.name == "claude"
            && $0.path?.value == "~/dev/\(subset)" }, "\(request.evidence)")
        let json = try sent(request)
        XCTAssertFalse(json.contains("/Users/me"), json)
        XCTAssertFalse(json.contains("subset"), json)

        let named = try XCTUnwrap(model.explainRequest(for: claude, redactor: redactor.sendingFolderNames(true)))
        XCTAssertTrue(named.evidence.contains { $0.kind == .runsCodingAgent && $0.path?.value == "~/dev/subset" },
                      "\(named.evidence)")
        XCTAssertEqual(named.group, "Agent: claude › subset")
        XCTAssertEqual(named.path?.value, "~/.local/share/claude/versions/2.1.304")
    }

    func testAProjectOrAppGroupInTheHomeFolderIsNamedAsItsPathIsSent() throws {
        let model = try model()
        let project = try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.project(path: "/Users/me/dev/subset"))),
                                                         redactor: redactor))
        XCTAssertEqual(project.name, redactor.placeholder("subset"))
        XCTAssertEqual(project.path?.value, "~/dev/\(redactor.placeholder("subset"))")
        let app = try XCTUnwrap(model.explainRequest(for: .group(OriginGroupID(.app(bundlePath: notes))), redactor: redactor))
        XCTAssertEqual(app.name, redactor.placeholder("Acme Notes.app"))
        XCTAssertEqual(app.path?.value, "~/Applications/\(redactor.placeholder("Acme Notes.app"))")
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
            XCTAssertTrue(request.evidence.contains { $0.kind == .projectMarkersSkipped
                && $0.path?.value == "~/Mounts/\(redactor.placeholder("Acme Merger"))" }, "\(request.evidence)")
            let text = try sent(request) + request.promptText
            for word in ["Acme", "Merger", "web", "client"] { XCTAssertFalse(text.contains(word), "\(row): \(text)") }

            let named = try XCTUnwrap(model.explainRequest(for: row, redactor: redactor.sendingFolderNames(true)))
            XCTAssertTrue(named.evidence.contains { $0.kind == .projectMarkersSkipped && $0.path?.value == "~/Mounts/Acme Merger" },
                          "\(named.evidence)")
        }
    }

    /// Every kind of evidence is sent as a closed kind with its paths as path values, redacted, and an unavailable
    /// signal's reason as a category: no word of a withheld folder name with spaces is sent, and the paths a failure's
    /// text names are not sent even with folder names on.
    func testEveryKindOfEvidenceIsSentAsAKindWithItsPathsRedacted() throws {
        let deep = "/Users/me/dev/Acme Merger/web client"
        let bundle = "/Users/me/Applications/Secret Notes.app"
        let process = try XCTUnwrap(try model().sample?.snapshot.processes.first { $0.pid == 600 })
        let job = LaunchdJob(label: "com.example.agent", plistPath: "/Users/me/Library/LaunchAgents/Acme Merger/agent.plist",
                             domain: .userAgent, program: deep + "/agent", resolution: .missing)
        let unreadPlists = "/Users/me/Hidden Plists/agent.plist"
        let scan = SignalFailure.incompleteScan([LaunchdScanFailure(path: unreadPlists, code: EACCES)])
        let evidence: [AttributionEvidence] = [
            .executable(path: deep + "/tool", name: "tool"), .executable(path: nil, name: "tool"), .appBundle(path: bundle),
            .systemLocation(prefix: "/System", platformBinary: true), .containerVM(ContainerVM(name: "Podman", detail: "vfkit")),
            .codingAgent(name: "claude", pid: process.pid), .terminalApp(name: "Terminal", pid: 2, bundlePath: bundle),
            .controllingTerminal(device: "/dev/ttys001"), .responsibleProcess(pid: 2, bundlePath: bundle),
            .coalitionLeader(coalition: 3, pid: 2, bundlePath: bundle), .launchdJob(job), .orphanedLaunchdJob(job),
            .homebrew(formula: "wget"), .signature(ProcessFixtures.google), .signatureUnavailable(scan),
            .signatureUnavailable(nil), .loginItem(bundlePath: bundle), .parentIsLaunchd, .inheritedFrom(pid: 2),
            .parentNotSampled(ppid: 9), .workingDirectory(deep),
            .workingDirectoryUnavailable(.unexpectedResult("cwd at \(deep) is gone")), .workingDirectoryUnavailable(nil),
            .projectMarker(directory: deep, marker: ".git"), .projectMarkersSkipped(volume: deep)
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
        var facts = ExplainFacts(kind: .process, name: "tool")
        facts.evidence = evidence.map { ExplainFacts.Evidence($0, of: process) { _ in "helper" } }
        // Every piece, without the evidence cap.
        let requests = facts.evidence.map { item in
            ExplainRequest(ExplainFacts(kind: .process, name: "tool").with { $0.evidence = [item] }, redactor: redactor)
        }
        XCTAssertEqual(requests.flatMap(\.evidence).map(\.kind), [
            .executable, .noExecutablePath, .appBundle, .appleBinaryInSystemLocation, .containerVM, .runsCodingAgent,
            .startedInTerminal, .controllingTerminal, .responsibleApp, .coalitionLeader, .launchdJob, .orphanedLaunchdJob,
            .homebrew, .signedByTeam, .signatureUnavailable, .signatureNotRead, .loginItem, .startedByLaunchd,
            .inheritsLaunchSource, .parentNotSampled, .workingDirectory, .workingDirectoryUnavailable,
            .workingDirectoryNotRead, .projectMarker, .projectMarkersSkipped
        ])
        let sent = try requests.map { try self.sent($0) + $0.promptText }.joined(separator: "\n")
        for word in ["Acme", "Merger", "web", "client", "Secret", "Notes", "subset", "/Users/me", "Hidden", "gone"] {
            XCTAssertFalse(sent.contains(word), "\(word): \(sent)")
        }
        let named = try facts.evidence.map { item in
            let request = ExplainRequest(ExplainFacts(kind: .process, name: "tool").with { $0.evidence = [item] },
                                         redactor: redactor.sendingFolderNames(true))
            return try self.sent(request) + request.promptText
        }.joined(separator: "\n")
        for name in ["Acme Merger/web client", "Secret Notes.app", "~/dev/subset/webclient-x", "Google LLC", "EQHXZ8M8AV",
                     "no readable launchd plist", "macOS returned a result System cannot use"] {
            XCTAssertTrue(named.contains(name), "\(name) in \(named)")
        }
        XCTAssertFalse(named.contains("Hidden") || named.contains("gone"), "a failure's text is never sent: \(named)")
    }

    func testOnlyAnUnattributedGroupMayGetASuggestedOriginAndGroupingIsUnchanged() throws {
        let model = try model()
        let group = OriginGroupID(.unattributed(executable: syncd))
        let request = try XCTUnwrap(model.explainRequest(for: .group(group), redactor: redactor))
        XCTAssertTrue(request.maySuggestOrigin)
        let path = "~/tools/\(redactor.placeholder("acme-sync"))/\(redactor.placeholder("bin"))/\(redactor.placeholder("syncd"))"
        XCTAssertEqual(request.path?.value, path)
        XCTAssertEqual(request.name, redactor.placeholder("syncd"),
                       "an Unattributed group, named by its executable's path, is named as that path's last name is sent")
        let process = try XCTUnwrap(model.explainRequest(for: .process(ProcessFixtures.identity(500)), redactor: redactor))
        XCTAssertEqual(process.group, request.name, "a process names its group as the group is named")
        XCTAssertEqual(process.path?.value, path)
        XCTAssertEqual(model.explainRequest(for: .process(ProcessFixtures.identity(500)),
                                            redactor: redactor.sendingFolderNames(true))?.group, "syncd")
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

    /// A group is sent with a Team ID and vendor only when every member's signature was read and names that identity:
    /// Apple platform code and unsigned or ad hoc code both have no Team ID, and an unread signature says nothing.
    func testAGroupIsSentWithAVendorOnlyWhenEveryMembersSignatureNamesIt() throws {
        let project = "/Users/me/dev/subset"
        func request(_ members: [(path: String, memory: UInt64, signature: CodeSignature?)]) throws -> ExplainRequest {
            let model = ProcessesWindowModel(format: ProcessFixtures.format)
            let processes = members.enumerated().map { index, member in
                FixtureProcess(pid: Int32(700 + index), path: member.path, memory: member.memory * ProcessFixtures.mib, cpu: 1,
                               energy: 1, signature: member.signature, cwd: project)
            }
            model.apply(try ProcessFixtures.sample(processes), memory: nil, cadence: .mainWindowVisible)
            model.layer = .project
            let group = RowID.group(OriginGroupID(.project(path: project)))
            let request = try XCTUnwrap(model.explainRequest(for: group, redactor: redactor))
            XCTAssertEqual(request.members.count, members.count, "\(request.members)")
            return request
        }
        let zsh = "/bin/zsh", node = "/opt/homebrew/bin/node"
        for (zshMemory, nodeMemory) in [(UInt64(40), UInt64(4)), (4, 40)] {
            let mixed = try request([(zsh, zshMemory, ProcessFixtures.apple), (node, nodeMemory, ProcessFixtures.unsigned)])
            XCTAssertNil(mixed.vendor, "Apple and unsigned, the larger \(zshMemory > nodeMemory ? "Apple" : "unsigned")")
            XCTAssertNil(mixed.teamID)
        }
        let apple = try request([(zsh, 40, ProcessFixtures.apple), ("/usr/bin/vim", 4, ProcessFixtures.apple)])
        XCTAssertEqual(apple.vendor, "Apple")
        XCTAssertNil(apple.teamID)
        let chrome = ProcessFixtures.chrome + "/Contents/MacOS/Google Chrome"
        let google = try request([(chrome, 40, ProcessFixtures.google), (chrome + " Helper", 4, ProcessFixtures.google)])
        XCTAssertEqual(google.teamID, "EQHXZ8M8AV")
        XCTAssertEqual(google.vendor, "Google LLC")
        let unread = try request([(chrome, 40, ProcessFixtures.google), (chrome + " Helper", 4, nil)])
        XCTAssertNil(unread.vendor, "one member's signature was not read")
        XCTAssertNil(unread.teamID)
        let unsigned = try request([(node, 40, ProcessFixtures.unsigned), ("/opt/homebrew/bin/npm", 4, ProcessFixtures.unsigned)])
        XCTAssertNil(unsigned.vendor)
        XCTAssertNil(unsigned.teamID)
    }

    /// Each layer places a process by its own rules, so an answer about it in one layer is not the answer in another.
    func testAProcessIsExplainedPerLayer() throws {
        let model = try model()
        let claude = RowID.process(ProcessFixtures.identity(202))
        model.layer = .app
        let appKey = model.explainKey(for: claude)
        let app = try XCTUnwrap(model.explainRequest(for: claude, key: appKey, redactor: redactor))
        let group = RowID.group(OriginGroupID(.app(bundlePath: ProcessFixtures.chrome)))
        let groupKey = model.explainKey(for: group)
        model.layer = .vendor
        XCTAssertNotEqual(model.explainKey(for: claude), appKey)
        XCTAssertNil(model.explainRequest(for: claude, key: appKey, redactor: redactor),
                     "a panel opened in the App layer does not send the Vendor layer's facts under its key")
        let vendor = try XCTUnwrap(model.explainRequest(for: claude, key: model.explainKey(for: claude), redactor: redactor))
        XCTAssertNotEqual(vendor.type, app.type)
        XCTAssertEqual(model.explainKey(for: group), groupKey, "a group's ID holds its layer")
    }

    /// `exec` keeps a process's PID and start time, so a process that now runs another executable is another item: the
    /// shell's answer is not served for node.
    func testAProcessThatRunsAnotherExecutableIsExplainedAgain() throws {
        let model = ProcessesWindowModel(format: ProcessFixtures.format)
        func apply(_ path: String) throws {
            model.apply(try ProcessFixtures.sample([FixtureProcess(pid: 800, path: path, memory: ProcessFixtures.mib, cpu: 1,
                                                                   energy: 1, signature: ProcessFixtures.apple)]),
                        memory: nil, cadence: .mainWindowVisible)
        }
        let row = RowID.process(ProcessFixtures.identity(800))
        try apply("/bin/sh")
        let shell = model.explainKey(for: row)
        XCTAssertNotNil(model.explainRequest(for: row, key: shell, redactor: redactor))
        try apply("/usr/local/bin/node")
        let node = model.explainKey(for: row)
        XCTAssertNotEqual(node, shell)
        XCTAssertNil(model.explainRequest(for: row, key: shell, redactor: redactor), "a panel opened on the shell finds it gone")
        XCTAssertEqual(model.explainRequest(for: row, key: node, redactor: redactor)?.path?.value, "/usr/local/bin/node")
        try apply("/usr/local/bin/node")
        XCTAssertEqual(model.explainKey(for: row), node, "the same executable in the next sample keeps its answer")
    }

    func testARowGoneFromTheSampleHasNoRequest() throws {
        let model = try model()
        XCTAssertNil(model.explainRequest(for: .process(ProcessFixtures.identity(999)), redactor: redactor))
        XCTAssertNil(model.explainRequest(for: .group(OriginGroupID(.agent(name: "nobody"))), redactor: redactor))
    }
}

private extension ExplainFacts {
    func with(_ change: (inout ExplainFacts) -> Void) -> ExplainFacts {
        var facts = self
        change(&facts)
        return facts
    }
}
