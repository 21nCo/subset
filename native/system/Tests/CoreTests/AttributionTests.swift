import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// One recorded-process fixture per App rule, the precedence between conflicting signals, the other three layers,
/// group totals and identity, and the linear-time bound.
final class AttributionTests: XCTestCase {
    private let chrome = "/Applications/Google Chrome.app"
    private let ghostty = "/Applications/Ghostty.app"
    private let terminal = "/System/Applications/Utilities/Terminal.app"
    private let vscode = "/Applications/Visual Studio Code.app"

    // MARK: Rule 1, inside an app bundle

    func testChromeRendererHelpersBelongToGoogleChrome() {
        let helpers = "\(chrome)/Contents/Frameworks/Google Chrome Framework.framework/Versions/131.0/Helpers"
        let processes = [
            fact(100, path: "\(chrome)/Contents/MacOS/Google Chrome", signature: google),
            fact(101, ppid: 100, path: "\(helpers)/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", signature: google),
            fact(102, ppid: 100, path: "\(helpers)/Google Chrome Helper (GPU).app/Contents/MacOS/Google Chrome Helper (GPU)", signature: google)
        ]

        let result = attribute(processes)

        for pid: Int32 in [100, 101, 102] {
            let app = placement(result, pid).app
            XCTAssertEqual(app.group, OriginGroupID(.app(bundlePath: chrome)), "pid \(pid)")
            XCTAssertEqual(app.rule, .appBundle)
            XCTAssertEqual(app.confidence, .rule)
            XCTAssertEqual(app.evidence, [.appBundle(path: chrome)])
            XCTAssertEqual(placement(result, pid).vendor.group, OriginGroupID(.vendor(teamID: "EQHXZ8M8AV")))
        }
        XCTAssertEqual(result.app.map(\.name), ["Google Chrome"])
        XCTAssertEqual(result.vendor.map(\.name), ["Google LLC"])
        XCTAssertEqual(placement(result, 101).launchSource.group, OriginGroupID(.appLaunched))
    }

    func testAnXPCServiceAndALoginItemBelongToTheirApp() {
        let app = "/Applications/Docker.app"
        let result = attribute([
            fact(200, path: "\(app)/Contents/MacOS/Docker Desktop.app/Contents/MacOS/Docker Desktop", signature: docker),
            fact(201, path: "\(app)/Contents/XPCServices/com.docker.helper.xpc/Contents/MacOS/com.docker.helper", signature: docker),
            fact(202, path: "\(app)/Contents/Library/LoginItems/DockerHelper.app/Contents/MacOS/DockerHelper", signature: docker),
            // A folder that merely ends in .app, with no bundle Contents, is not a bundle.
            fact(203, ppid: 1, path: "/Users/me/dev/my.app/bin/server", signature: unsigned)
        ])

        for pid: Int32 in [200, 201, 202] {
            XCTAssertEqual(placement(result, pid).app.group, OriginGroupID(.app(bundlePath: app)), "pid \(pid)")
        }
        XCTAssertEqual(placement(result, 202).launchSource.group, OriginGroupID(.loginItem(bundlePath: app)))
        XCTAssertEqual(placement(result, 202).launchSource.rule, .loginItem)
        XCTAssertEqual(result.launchSource.first { $0.id.origin == .loginItem(bundlePath: app) }?.name, "Login item: Docker")
        XCTAssertEqual(placement(result, 203).app.rule, .unattributed)
    }

    // MARK: Rule 2, macOS

    func testAppleBinariesInSystemLocationsAreMacOS() {
        let job = LaunchdJob(label: "com.apple.example", plistPath: "/Library/LaunchDaemons/com.apple.example.plist",
                             domain: .globalDaemon, program: "/usr/libexec/exampled", resolution: .resolved("/usr/libexec/exampled"))
        let result = attribute([
            fact(300, path: "/usr/libexec/exampled", signature: apple, jobs: [job]),
            fact(301, path: "/System/Library/CoreServices/launchservicesd", signature: apple),
            fact(302, path: "/usr/sbin/notifyd", signature: nil),
            fact(303, path: "/bin/zsh", signature: apple),
            fact(304, path: "/usr/bin/tool", signature: CodeSignature(signingID: "tool", teamID: nil, isPlatformBinary: false))
        ])

        XCTAssertEqual(placement(result, 300).app.group, OriginGroupID(.macOS))
        XCTAssertEqual(placement(result, 300).app.confidence, .rule)
        // A plist naming a platform binary does not make it that job's process (`LaunchdMatch.sharedExecutable`), and
        // Apple's own jobs are not indexed, so no label is known and there is no subgroup.
        XCTAssertNil(placement(result, 300).app.subgroup)
        XCTAssertEqual(result.app.first { $0.id == OriginGroupID(.macOS) }?.subgroups, [])
        XCTAssertEqual(placement(result, 301).app.evidence, [.systemLocation(prefix: "/System", platformBinary: true)])
        XCTAssertEqual(placement(result, 302).app.evidence, [.systemLocation(prefix: "/usr/sbin", platformBinary: nil)],
                       "an unread signature does not contradict the sealed system volume")
        XCTAssertNotEqual(placement(result, 303).app.rule, .macOS, "/bin is not one of the rule's locations")
        XCTAssertNotEqual(placement(result, 304).app.rule, .macOS, "a signature that is not Apple's contradicts the location")
        XCTAssertEqual(placement(result, 300).vendor.group, OriginGroupID(.apple))
        XCTAssertEqual(placement(result, 300).launchSource.group, OriginGroupID(.system))
    }

    // MARK: Rule 3, container VM hook

    func testAContainerVMFallsThroughToItsResponsibleAppUntilTheHookRecognizesIt() {
        let podman = "/Applications/Podman Desktop.app"
        let processes = [
            fact(400, path: "\(podman)/Contents/MacOS/Podman Desktop", signature: unsigned, coalition: 40),
            fact(401, ppid: 1, path: "/opt/podman/bin/vfkit", signature: unsigned, responsible: 400, coalition: 41)
        ]

        let without = attribute(processes)
        let with = Attribution(projectMarkers: FixtureProjectMarkers(), containerVM: VMRecognizer()).attribute(processes)

        XCTAssertEqual(placement(without, 401).app.group, OriginGroupID(.app(bundlePath: podman)))
        XCTAssertEqual(placement(without, 401).app.rule, .responsibleProcess)
        XCTAssertEqual(placement(with, 401).app.group, OriginGroupID(.containerVM(name: "Podman machine")))
        XCTAssertEqual(placement(with, 401).app.rule, .containerVM)
        XCTAssertEqual(placement(with, 401).app.conflicts.map(\.group), [OriginGroupID(.app(bundlePath: podman))])
    }

    // MARK: Rules 4 and 5, coding agent and terminal session

    func testNodeUnderClaudeUnderZshUnderGhosttyIsAgentClaudeInItsProject() {
        let markers = FixtureProjectMarkers(["/Users/me/dev/x": [".git"]])
        let processes = ghosttySession() + [
            // Claude Code's native installer: the kernel name is the version, and `claude` is only in the path.
            fact(503, ppid: 502, path: "/Users/me/.local/share/claude/versions/2.1.304", signature: anthropic,
                 responsible: 500, cwd: "/Users/me/dev/x", tty: "ttys001"),
            fact(504, ppid: 503, path: "/opt/homebrew/Cellar/node/22.1.0/bin/node", signature: unsigned,
                 responsible: 500, cwd: "/Users/me/dev/x/web", tty: "ttys001")
        ]

        let result = Attribution(projectMarkers: markers).attribute(processes)
        let node = placement(result, 504)

        XCTAssertEqual(node.app.group, OriginGroupID(.agent(name: "claude")))
        XCTAssertEqual(node.app.subgroup, OriginGroupID(.agent(name: "claude"), subgroup: "/Users/me/dev/x"))
        XCTAssertEqual(node.app.rule, .codingAgent)
        XCTAssertEqual(node.app.confidence, .rule)
        XCTAssertEqual(node.app.evidence, [.codingAgent(name: "claude", pid: 503)])
        XCTAssertEqual(node.app.conflicts.map(\.group), [OriginGroupID(.app(bundlePath: ghostty))],
                       "the responsible terminal app is recorded, not followed")
        XCTAssertEqual(node.launchSource.group, OriginGroupID(.codingAgentSession(name: "claude")))
        XCTAssertEqual(node.project.group, OriginGroupID(.project(path: "/Users/me/dev/x")))
        XCTAssertEqual(node.project.rule, .marker)

        // The agent's own process is the agent's, though a terminal started it.
        XCTAssertEqual(placement(result, 503).app.group, OriginGroupID(.agent(name: "claude")))
        XCTAssertEqual(placement(result, 503).launchSource.group, OriginGroupID(.terminalSession))
        XCTAssertEqual(placement(result, 502).app.group, OriginGroupID(.terminal), "the shell is the terminal's")
        XCTAssertEqual(placement(result, 501).app.group, OriginGroupID(.macOS), "login is a platform binary in /usr/bin")
        XCTAssertEqual(placement(result, 500).app.group, OriginGroupID(.app(bundlePath: ghostty)), "the terminal's own process is the app's")
        let agent = result.app.first { $0.id == OriginGroupID(.agent(name: "claude")) }
        XCTAssertEqual(agent?.name, "Agent: claude")
        XCTAssertEqual(agent?.subgroups.map(\.name), ["x"])
        XCTAssertEqual(agent?.subgroups.first?.members.map(\.pid), [503, 504])
    }

    func testEachListedAgentNameIsRecognizedByProcessOrFileName() {
        for (offset, name) in AttributionNames.codingAgents.sorted().enumerated() {
            let base = Int32(5000 + offset * 10)
            let byName = attribute([fact(base, path: "/Users/me/.bin/\(name)-wrapper", name: name, signature: unsigned),
                                    fact(base + 1, ppid: base, path: "/usr/local/bin/tool", signature: unsigned)])
            XCTAssertEqual(placement(byName, base + 1).app.group, OriginGroupID(.agent(name: name)))
            let byFile = attribute([fact(base, path: "/usr/local/bin/\(name)", name: "node", signature: unsigned)])
            XCTAssertEqual(placement(byFile, base).app.group, OriginGroupID(.agent(name: name)))
        }
        let versioned = attribute([fact(80, path: "/Users/me/.local/share/notes/versions/1.0", signature: unsigned)])
        XCTAssertNotEqual(placement(versioned, 80).app.rule, .codingAgent, "a versioned install of another name is no agent")
        let lookalike = attribute([fact(90, path: "/Applications/Claude.app/Contents/MacOS/Claude", name: "Claude", signature: anthropic),
                                   fact(91, ppid: 90, path: "/usr/local/bin/tool", signature: unsigned)])
        XCTAssertNotEqual(placement(lookalike, 91).app.rule, .codingAgent, "names match exactly, with case")
    }

    func testADevServerInATerminalIsTerminalInItsProjectEvenWhenTheTerminalIsResponsible() {
        let markers = FixtureProjectMarkers(["/Users/me/dev/y": ["package.json"]])
        let processes = [
            fact(600, path: "\(terminal)/Contents/MacOS/Terminal", signature: apple, coalition: 60),
            fact(601, ppid: 600, path: "/bin/zsh", signature: apple, responsible: 600, coalition: 60, cwd: "/Users/me/dev/y", tty: "ttys002"),
            fact(602, ppid: 601, path: "/opt/homebrew/Cellar/node/22.1.0/bin/node", signature: unsigned,
                 responsible: 600, coalition: 60, cwd: "/Users/me/dev/y", tty: "ttys002")
        ]

        let result = Attribution(projectMarkers: markers).attribute(processes)
        let server = placement(result, 602)

        XCTAssertEqual(server.app.group, OriginGroupID(.terminal))
        XCTAssertEqual(server.app.subgroup, OriginGroupID(.terminal, subgroup: "/Users/me/dev/y"))
        XCTAssertEqual(server.app.rule, .terminalSession)
        XCTAssertEqual(server.app.evidence, [.terminalApp(name: "Terminal", pid: 600, bundlePath: terminal), .controllingTerminal(device: "ttys002")])
        XCTAssertEqual(server.app.conflicts, [
            AttributionConflict(rule: .responsibleProcess, group: OriginGroupID(.app(bundlePath: terminal)),
                                evidence: [.responsibleProcess(pid: 600, bundlePath: terminal)]),
            AttributionConflict(rule: .responsibleProcess, group: OriginGroupID(.app(bundlePath: terminal)),
                                evidence: [.coalitionLeader(coalition: 60, pid: 600, bundlePath: terminal)])
        ], "the responsible app and coalition are evidence, and Homebrew's path is not a conflict")
        XCTAssertEqual(server.launchSource.group, OriginGroupID(.terminalSession))
        XCTAssertEqual(result.app.first { $0.id == OriginGroupID(.terminal) }?.subgroups.map(\.name), ["y"])
    }

    func testAnEditorsIntegratedTerminalNeedsAControllingTerminal() {
        let helper = "\(vscode)/Contents/Frameworks/Code Helper (Plugin).app/Contents/MacOS/Code Helper (Plugin)"
        let result = attribute([
            fact(700, path: "\(vscode)/Contents/MacOS/Electron", signature: microsoft),
            fact(701, ppid: 700, path: helper, signature: microsoft),
            fact(702, ppid: 701, path: "/bin/zsh", signature: apple, responsible: 700, tty: "ttys004"),
            fact(703, ppid: 701, path: "/Users/me/go/bin/gopls", signature: unsigned, responsible: 700)
        ])

        XCTAssertEqual(placement(result, 702).app.group, OriginGroupID(.terminal))
        XCTAssertEqual(placement(result, 702).app.evidence.first, .terminalApp(name: "VS Code", pid: 701, bundlePath: vscode))
        XCTAssertEqual(placement(result, 703).app.group, OriginGroupID(.app(bundlePath: vscode)), "a language server is the editor's")
        XCTAssertEqual(placement(result, 703).app.rule, .responsibleProcess)
        XCTAssertEqual(placement(result, 703).launchSource.group, OriginGroupID(.appLaunched))
    }

    // MARK: Rule 6, responsible process or coalition

    func testTheResponsibleProcessThenTheCoalitionLeaderNameTheApp() {
        let foo = "/Applications/Foo.app", bar = "/Applications/Bar.app"
        let result = attribute([
            fact(800, start: 10, path: "\(foo)/Contents/MacOS/Foo", signature: unsigned, coalition: 80),
            fact(801, start: 5, path: "\(bar)/Contents/MacOS/Bar", signature: unsigned, coalition: 81),
            fact(802, start: 20, path: "/Library/Application Support/Foo/agent", signature: unsigned, responsible: 800, coalition: 81),
            fact(803, start: 20, path: "/Library/Application Support/Foo/worker", signature: unsigned,
                 responsibleSignal: .unavailable(.denied, source: .responsibility), coalition: 80),
            // The responsible PID now belongs to a process that started later: it was reused.
            fact(804, start: 1, path: "/Library/Application Support/Foo/old", signature: unsigned, responsible: 800)
        ])

        let agent = placement(result, 802).app
        XCTAssertEqual(agent.group, OriginGroupID(.app(bundlePath: foo)))
        XCTAssertEqual(agent.rule, .responsibleProcess)
        XCTAssertEqual(agent.confidence, .signal)
        XCTAssertEqual(agent.evidence, [.responsibleProcess(pid: 800, bundlePath: foo)])
        XCTAssertEqual(agent.conflicts.map(\.group), [OriginGroupID(.app(bundlePath: bar))], "the coalition disagrees and is recorded")
        XCTAssertEqual(placement(result, 803).app.group, OriginGroupID(.app(bundlePath: foo)))
        XCTAssertEqual(placement(result, 803).app.evidence, [.coalitionLeader(coalition: 80, pid: 800, bundlePath: foo)])
        XCTAssertEqual(placement(result, 804).app.rule, .unattributed)
    }

    func testAConflictingResponsibleProcessDoesNotMoveAnAppsOwnHelper() {
        let result = attribute([
            fact(810, path: "/Applications/Finder2.app/Contents/MacOS/Finder2", signature: unsigned),
            fact(811, path: "\(chrome)/Contents/MacOS/Google Chrome", signature: google, responsible: 810)
        ])

        XCTAssertEqual(placement(result, 811).app.group, OriginGroupID(.app(bundlePath: chrome)))
        XCTAssertEqual(placement(result, 811).app.conflicts.map(\.rule), [.responsibleProcess])
    }

    // MARK: Rule 7, launchd job

    func testALaunchAgentGoesToItsOwningAppOrTeamAndAnOrphanedPlistWithItsLabelIsFlagged() {
        let syncJob = LaunchdJob(label: "com.example.sync", plistPath: "/Users/me/Library/LaunchAgents/com.example.sync.plist",
                                 domain: .userAgent, program: "/Library/Example/sync", resolution: .resolved("/Library/Example/sync"))
        let stale = LaunchdJob(label: "com.example.sync", plistPath: "/Library/LaunchAgents/com.example.sync.plist",
                               domain: .globalAgent, program: "/Library/Example/old/sync", resolution: .missing)
        let unrelated = LaunchdJob(label: "com.gone.agent", plistPath: "/Users/me/Library/LaunchAgents/com.gone.agent.plist",
                                   domain: .userAgent, program: "/Applications/Gone.app/Contents/MacOS/agent", resolution: .missing)
        let bundled = LaunchdJob(label: "com.example.bundled", plistPath: "/Applications/Example.app/Contents/Library/LaunchAgents/b.plist",
                                 domain: .appBundleAgent(bundlePath: "/Applications/Example.app"), program: "/Library/Example/bundled",
                                 resolution: .resolved("/Library/Example/bundled"))
        let processes = [
            fact(900, path: "/Library/Example/sync", signature: example, jobs: [syncJob]),
            fact(901, path: "/Library/Example/bundled", signature: example, jobs: [bundled]),
            fact(902, ppid: 900, path: "/Library/Example/child", signature: unsigned)
        ]

        let result = attribute(processes, launchdJobs: [syncJob, stale, unrelated, bundled])

        let sync = placement(result, 900)
        XCTAssertEqual(sync.app.group, OriginGroupID(.team(id: "EX4MPLE123")))
        XCTAssertEqual(sync.app.rule, .launchdJob)
        XCTAssertEqual(sync.app.confidence, .signal)
        XCTAssertEqual(sync.app.evidence, [.launchdJob(syncJob), .orphanedLaunchdJob(stale), .signature(example)])
        XCTAssertEqual(sync.launchSource.group, OriginGroupID(.launchdJob(label: "com.example.sync")))
        XCTAssertEqual(placement(result, 901).app.group, OriginGroupID(.app(bundlePath: "/Applications/Example.app")))
        XCTAssertEqual(placement(result, 902).launchSource.group, OriginGroupID(.launchdJob(label: "com.example.sync")))
        XCTAssertEqual(placement(result, 902).launchSource.evidence.first, .inheritedFrom(pid: 900))
        XCTAssertEqual(result.orphanedLaunchdJobs, [stale, unrelated])
        XCTAssertEqual(result.app.first { $0.id == OriginGroupID(.team(id: "EX4MPLE123")) }?.name, "Example Inc")
    }

    // MARK: Rule 8, Homebrew

    func testAHomebrewServiceAndItsWorkersAreGroupedByFormula() {
        let job = LaunchdJob(label: "homebrew.mxcl.postgresql@16", plistPath: "/Users/me/Library/LaunchAgents/homebrew.mxcl.postgresql@16.plist",
                             domain: .userAgent, program: "/opt/homebrew/opt/postgresql@16/bin/postgres",
                             resolution: .resolved("/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres"))
        let postgres = "/opt/homebrew/Cellar/postgresql@16/16.4/bin/postgres"
        let result = attribute([
            fact(1000, path: postgres, signature: adHoc, jobs: [job]),
            fact(1001, ppid: 1000, path: postgres, signature: adHoc),
            fact(1002, ppid: 1, path: "/usr/local/Cellar/redis/7.2/bin/redis-server", signature: adHoc),
            fact(1003, ppid: 1, path: "/opt/homebrew/bin/custom", signature: adHoc)
        ])

        XCTAssertEqual(placement(result, 1000).app.group, OriginGroupID(.homebrew(formula: "postgresql@16")),
                       "a job without an owning app or Team ID does not place the process")
        XCTAssertEqual(placement(result, 1000).app.rule, .homebrew)
        XCTAssertEqual(placement(result, 1000).app.confidence, .rule)
        XCTAssertEqual(placement(result, 1000).launchSource.group, OriginGroupID(.launchdJob(label: "homebrew.mxcl.postgresql@16")))
        XCTAssertEqual(placement(result, 1001).app.group, OriginGroupID(.homebrew(formula: "postgresql@16")))
        XCTAssertEqual(placement(result, 1002).app.group, OriginGroupID(.homebrew(formula: "redis")))
        XCTAssertEqual(placement(result, 1003).app.group, OriginGroupID(.homebrew(formula: nil)))
        XCTAssertEqual(result.app.map(\.name), ["Homebrew", "Homebrew: postgresql@16", "Homebrew: redis"])
        XCTAssertEqual(placement(result, 1000).vendor.group, OriginGroupID(.unsigned), "ad hoc signing names no vendor")
    }

    // MARK: Rules 9 and 10, signing team and unattributed

    func testASignedToolGoesToItsTeamAndAnUnsignedBinaryIsUnattributedWithItsPath() {
        let result = attribute([
            fact(1100, ppid: 1, path: "/usr/local/bin/tool", signature: example),
            fact(1101, ppid: 1, path: "/Users/me/bin/thing", signature: unsigned),
            fact(1102, ppid: 1, path: nil, name: "mystery", signature: nil),
            fact(1103, ppid: 1, path: "/Users/me/bin/replaced", signature: nil, signatureSignal: .unavailable(.unexpectedResult("replaced"), source: .codeSigning))
        ])

        XCTAssertEqual(placement(result, 1100).app.group, OriginGroupID(.team(id: "EX4MPLE123")))
        XCTAssertEqual(placement(result, 1100).app.rule, .signingTeam)
        XCTAssertEqual(placement(result, 1100).app.confidence, .signal)
        let thing = placement(result, 1101)
        XCTAssertEqual(thing.app.group, OriginGroupID(.unattributed(executable: "/Users/me/bin/thing")))
        XCTAssertEqual(thing.app.rule, .unattributed)
        XCTAssertEqual(thing.app.confidence, .fallback)
        XCTAssertEqual(thing.app.evidence, [.executable(path: "/Users/me/bin/thing", name: "thing"), .signature(unsigned)])
        XCTAssertEqual(thing.vendor.group, OriginGroupID(.unsigned))
        XCTAssertEqual(placement(result, 1102).app.group, OriginGroupID(.unattributed(executable: "mystery")))
        XCTAssertEqual(placement(result, 1102).vendor.group, OriginGroupID(.signatureUnavailable), "an unread signature is not unsigned")
        XCTAssertEqual(placement(result, 1103).vendor.evidence, [.signatureUnavailable(.unexpectedResult("replaced"))])
        XCTAssertEqual(result.app.first { $0.id.origin == .unattributed(executable: "/Users/me/bin/thing") }?.name, "/Users/me/bin/thing")
        XCTAssertEqual(result.app.first { $0.id.origin == .team(id: "EX4MPLE123") }?.name, "Example Inc")
    }

    // MARK: Project and launch source layers

    func testTheProjectIsTheNearestMarkedFolderElseTheWorkingDirectory() {
        let markers = FixtureProjectMarkers(["/Users/me/dev/mono": [".git"], "/Users/me/dev/mono/packages/api": ["package.json", "Gemfile"]])
        let result = Attribution(projectMarkers: markers).attribute([
            fact(1200, path: "/x/a", signature: unsigned, cwd: "/Users/me/dev/mono/packages/api/src"),
            fact(1201, path: "/x/b", signature: unsigned, cwd: "/Users/me/dev/mono/docs/"),
            fact(1202, path: "/x/c", signature: unsigned, cwd: "/Users/me/scratch"),
            fact(1203, path: "/x/d", signature: unsigned, cwd: "/"),
            fact(1204, path: "/x/e", signature: unsigned, cwdSignal: .unavailable(.denied, source: .vnodePathInfo)),
            fact(1205, path: "/x/f", signature: unsigned, cwd: "/Users/me/dev/mono/packages/api/test")
        ])

        XCTAssertEqual(placement(result, 1200).project.group, OriginGroupID(.project(path: "/Users/me/dev/mono/packages/api")))
        XCTAssertEqual(placement(result, 1200).project.evidence.last, .projectMarker(directory: "/Users/me/dev/mono/packages/api", marker: "package.json"))
        XCTAssertEqual(placement(result, 1201).project.group, OriginGroupID(.project(path: "/Users/me/dev/mono")))
        XCTAssertEqual(placement(result, 1202).project.group, OriginGroupID(.project(path: "/Users/me/scratch")))
        XCTAssertEqual(placement(result, 1202).project.rule, .workingDirectory)
        XCTAssertEqual(placement(result, 1203).project.group, OriginGroupID(.noProject))
        XCTAssertEqual(placement(result, 1204).project.group, OriginGroupID(.noProject))
        XCTAssertEqual(placement(result, 1204).project.evidence, [.workingDirectoryUnavailable(.denied)])
        XCTAssertEqual(markers.lookups.values.max(), 1, "each folder is looked in once")
        XCTAssertNil(markers.lookups["/"], "the walk stops below /")
        XCTAssertEqual(result.project.map(\.name), ["No project", "mono", "api", "scratch"])
    }

    func testTheFileSystemLookupFindsMarkersOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("attribution-\(UUID().uuidString)")
        let nested = root.appendingPathComponent("Sources/App")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        FileManager.default.createFile(atPath: root.appendingPathComponent("Package.swift").path, contents: Data())

        let lookup = FileSystemProjectMarkers()

        XCTAssertEqual(lookup.marker(in: root.path), "Package.swift")
        XCTAssertNil(lookup.marker(in: nested.path))
    }

    func testALaunchChainEndingOutsideTheSampleIsNotGuessed() {
        let result = attribute([
            fact(1300, ppid: 9999, path: "/x/orphan", signature: unsigned),
            // The parent PID belongs to a process that started after this one: it was reused.
            fact(1301, start: 1, ppid: 1300, path: "/x/early", signature: unsigned),
            fact(1302, ppid: 1, path: "/x/daemon", signature: unsigned)
        ])

        XCTAssertEqual(placement(result, 1300).launchSource.rule, .parentNotSampled)
        XCTAssertEqual(placement(result, 1300).launchSource.evidence, [.parentNotSampled(ppid: 9999)])
        XCTAssertEqual(placement(result, 1300).launchSource.confidence, .fallback)
        XCTAssertEqual(placement(result, 1301).launchSource.evidence, [.parentNotSampled(ppid: 1300)])
        XCTAssertEqual(placement(result, 1302).launchSource.rule, .startedByLaunchd)
    }

    // MARK: Totals and identity

    func testTotalsSumMembersAndCountRestrictedMembersSeparately() {
        let app = "/Applications/Foo.app"
        let result = attribute([
            fact(1400, path: "\(app)/Contents/MacOS/Foo", signature: unsigned,
                 usage: usage(memory: 100, energy: 1_000, billed: 10), cpu: 12.5),
            fact(1401, path: "\(app)/Contents/XPCServices/a.xpc/Contents/MacOS/a", signature: unsigned,
                 usage: usage(memory: 50, energy: 500, billed: 5), cpu: nil),
            fact(1402, path: "\(app)/Contents/XPCServices/b.xpc/Contents/MacOS/b", signature: unsigned, usage: .restricted),
            fact(1403, path: "/Applications/Locked.app/Contents/MacOS/Locked", signature: unsigned, usage: .restricted),
            fact(1404, path: "/Applications/Big.app/Contents/MacOS/Big", signature: unsigned,
                 usage: usage(memory: .max, energy: 0, billed: 0), cpu: 1),
            fact(1405, path: "/Applications/Big.app/Contents/MacOS/Big2", signature: unsigned,
                 usage: usage(memory: 2, energy: 0, billed: 0), cpu: 1)
        ])

        let foo = result.app.first { $0.id == OriginGroupID(.app(bundlePath: app)) }
        XCTAssertEqual(foo?.totals.processCount, 3)
        XCTAssertEqual(foo?.totals.restrictedCount, 1)
        XCTAssertEqual(foo?.totals.memory, MetricTotal(sum: 150, measuredCount: 2, unmeasuredCount: 1, isApproximate: true))
        XCTAssertEqual(foo?.totals.cpuPercent, MetricTotal(sum: 12.5, measuredCount: 1, unmeasuredCount: 2, isApproximate: false))
        XCTAssertEqual(foo?.totals.energy.sum, 1_500)
        XCTAssertEqual(foo?.totals.billedEnergy.sum, 15)
        XCTAssertEqual(foo?.totals.memory.isComplete, false)

        let locked = result.app.first { $0.id == OriginGroupID(.app(bundlePath: "/Applications/Locked.app")) }
        XCTAssertNil(locked?.totals.memory.sum, "a group of restricted members has no total, not zero")
        XCTAssertNil(locked?.totals.cpuPercent.sum)
        XCTAssertEqual(locked?.totals.restrictedCount, 1)

        let big = result.app.first { $0.id == OriginGroupID(.app(bundlePath: "/Applications/Big.app")) }
        XCTAssertEqual(big?.totals.memory.sum, .max, "sums saturate")
        XCTAssertEqual(big?.totals.cpuPercent.sum, 2)
    }

    func testEveryProcessIsInExactlyOneGroupPerLayerAndGroupIdentityIsStableAcrossSamples() {
        let markers = FixtureProjectMarkers(["/Users/me/dev/x": [".git"]])
        func sample(pidOffset: Int32, start: UInt64) -> [ProcessFacts] {
            let p = { (pid: Int32) in pid + pidOffset }
            return [
                fact(p(500), start: start, path: "\(ghostty)/Contents/MacOS/ghostty", signature: ghosttySignature),
                fact(p(502), start: start, ppid: p(500), path: "/bin/zsh", signature: apple, cwd: "/Users/me/dev/x", tty: "ttys001"),
                fact(p(503), start: start, ppid: p(502), path: "/usr/local/bin/claude", signature: anthropic, cwd: "/Users/me/dev/x", tty: "ttys001"),
                fact(p(504), start: start, ppid: p(503), path: "/usr/local/bin/node", signature: unsigned, cwd: "/Users/me/dev/x/sub", tty: "ttys001"),
                fact(p(510), start: start, path: "\(chrome)/Contents/MacOS/Google Chrome", signature: google),
                fact(p(520), start: start, path: "/usr/libexec/exampled", signature: apple),
                fact(p(530), start: start, path: "/Users/me/bin/thing", signature: unsigned)
            ]
        }
        let first = Attribution(projectMarkers: markers).attribute(sample(pidOffset: 0, start: 10))
        let second = Attribution(projectMarkers: markers).attribute(sample(pidOffset: 7000, start: 99).reversed())

        for layer in AttributionLayer.allCases {
            let groups = first.groups(layer)
            let members = groups.flatMap(\.members)
            XCTAssertEqual(members.count, 7, "\(layer)")
            XCTAssertEqual(Set(members).count, 7, "\(layer): no process is in two groups")
            XCTAssertEqual(groups.map(\.id), second.groups(layer).map(\.id), "\(layer)")
            XCTAssertEqual(groups.map(\.name), second.groups(layer).map(\.name), "\(layer)")
            XCTAssertEqual(groups.flatMap(\.subgroups).map(\.id), second.groups(layer).flatMap(\.subgroups).map(\.id), "\(layer)")
            XCTAssertEqual(groups.map(\.id), groups.map(\.id).sorted(), "\(layer): groups are ordered by identity")
        }
        XCTAssertEqual(first.processes.map(\.identity), sample(pidOffset: 0, start: 10).map(\.identity))
    }

    func testARepeatedIdentityIsAttributedOnce() {
        let process = fact(1500, path: "/x/a", signature: unsigned)
        let result = attribute([process, process])

        XCTAssertEqual(result.processes.count, 1)
        XCTAssertEqual(result.app.first?.members, [process.identity])
    }

    // MARK: Linear time

    func testTwoThousandProcessesAreAttributedInLinearTime() {
        // A 2,000-deep chain is the worst case for walking each process's ancestors separately (about two million
        // parent links); a pre-built parent index answers each ancestor question for the whole sample at once.
        let count = 2_000
        let markers = FixtureProjectMarkers(["/Users/me/dev/deep": [".git"]])
        var processes = [fact(1, ppid: 0, path: "/sbin/launchd", signature: apple)]
        processes += (2...Int32(count)).map { pid in
            fact(pid, ppid: pid - 1, path: pid % 3 == 0 ? "/usr/local/bin/tool\(pid % 50)" : "/Users/me/bin/w\(pid % 50)",
                 signature: unsigned, responsible: pid - 1, coalition: UInt64(pid % 40),
                 cwd: "/Users/me/dev/deep/a/b/c\(pid % 7)", tty: "ttys009")
        }

        let start = ContinuousClock.now
        let result = Attribution(projectMarkers: markers).attribute(processes)
        let elapsed = ContinuousClock.now - start

        XCTAssertEqual(result.processes.count, count)
        XCTAssertLessThanOrEqual(result.steps, 3 * count, "each of the three ancestor queries visits a process once")
        XCTAssertLessThanOrEqual(markers.lookups.count, 10, "each folder is looked in once")
        XCTAssertEqual(placement(result, Int32(count)).launchSource.evidence.last, .parentIsLaunchd)
        XCTAssertLessThan(elapsed, .seconds(5), "a generous ceiling; the step count is the real bound")
    }

    // MARK: Fixtures

    private var google: CodeSignature { CodeSignature(signingID: "com.google.Chrome", teamID: "EQHXZ8M8AV", isPlatformBinary: false, teamName: "Google LLC") }
    private var docker: CodeSignature { CodeSignature(signingID: "com.docker.docker", teamID: "9BNSXJN65R", isPlatformBinary: false) }
    private var microsoft: CodeSignature { CodeSignature(signingID: "com.microsoft.VSCode", teamID: "UBF8T346G9", isPlatformBinary: false) }
    private var anthropic: CodeSignature { CodeSignature(signingID: "com.anthropic.claude-code", teamID: "Q6L2SF6YDW", isPlatformBinary: false) }
    private var ghosttySignature: CodeSignature { CodeSignature(signingID: "com.mitchellh.ghostty", teamID: "24VZTF6M5V", isPlatformBinary: false) }
    private var example: CodeSignature { CodeSignature(signingID: "com.example.sync", teamID: "EX4MPLE123", isPlatformBinary: false, teamName: "Example Inc") }
    private var apple: CodeSignature { CodeSignature(signingID: "com.apple.x", teamID: nil, isPlatformBinary: true) }
    private var adHoc: CodeSignature { CodeSignature(signingID: "postgres-55554944", teamID: nil, isPlatformBinary: false) }
    private var unsigned: CodeSignature { CodeSignature(signingID: nil, teamID: nil, isPlatformBinary: false) }

    /// Ghostty (500), `login` (501), and a shell (502) in its first tab.
    private func ghosttySession() -> [ProcessFacts] {
        [
            fact(500, path: "\(ghostty)/Contents/MacOS/ghostty", signature: ghosttySignature),
            fact(501, ppid: 500, path: "/usr/bin/login", signature: apple, responsible: 500, tty: "ttys001"),
            fact(502, ppid: 501, path: "/bin/zsh", signature: apple, responsible: 500, cwd: "/Users/me", tty: "ttys001")
        ]
    }

    private func attribute(_ processes: [ProcessFacts], launchdJobs: [LaunchdJob] = []) -> AttributionResult {
        Attribution(projectMarkers: FixtureProjectMarkers()).attribute(processes, launchdJobs: launchdJobs)
    }

    private func placement(_ result: AttributionResult, _ pid: Int32, file: StaticString = #filePath, line: UInt = #line) -> ProcessAttribution {
        guard let found = result.processes.first(where: { $0.identity.pid == pid }) else {
            XCTFail("no attribution for pid \(pid)", file: file, line: line)
            return result.processes[0]
        }
        return found
    }

    private func usage(memory: UInt64, energy: UInt64, billed: UInt64) -> UsageReading {
        .available(RawProcessUsage(physFootprint: memory, userTime: 0, systemTime: 0, energy: energy, billedEnergy: billed))
    }

    /// A recorded process with its origin signals. A parent of 1 is launchd; responsibility defaults to the process
    /// itself and the coalition to one of its own.
    private func fact(
        _ pid: Int32, start: UInt64 = 10, ppid: Int32 = 1, path: String?, name: String? = nil,
        signature: CodeSignature?, signatureSignal: Signal<CodeSignature>? = nil,
        responsible: Int32? = nil, responsibleSignal: Signal<Int32>? = nil, coalition: UInt64? = nil,
        jobs: [LaunchdJob] = [], cwd: String? = nil, cwdSignal: Signal<String>? = nil, tty: String? = nil,
        usage: UsageReading = .unavailable, cpu: Double? = nil
    ) -> ProcessFacts {
        let record = RawProcessRecord(
            identity: ProcessIdentity(pid: pid, startTime: start), ppid: ppid, uid: 501, executablePath: path,
            name: name ?? path.map { ($0 as NSString).lastPathComponent } ?? "p\(pid)", usage: usage
        )
        var facts = ProcessFacts(record: record, timebase: MachTimebase(numer: 1, denom: 1), cpuPercent: cpu)
        facts.origin = OriginSignals(
            responsibleProcess: responsibleSignal ?? .value(responsible ?? pid, source: .responsibility),
            coalition: .value(coalition ?? UInt64(pid) + 100_000, source: .coalitionInfo),
            codeSignature: signatureSignal ?? signature.map { .value($0, source: .codeSigning) }
                ?? .unavailable(.processExited, source: .codeSigning),
            launchdJobs: .value(LaunchdJobs(jobs: jobs), source: .launchdPlists),
            workingDirectory: cwdSignal ?? cwd.map { .value($0, source: .vnodePathInfo) } ?? .unavailable(.denied, source: .vnodePathInfo),
            terminal: .value(tty.map { .device($0) } ?? ControllingTerminal.none, source: .bsdInfo)
        )
        return facts
    }
}

/// A stand-in for SET-43's recognizer: Podman's `vfkit` runs the machine VM.
private struct VMRecognizer: ContainerVMRecognizing {
    func containerVM(for process: ProcessFacts) -> ContainerVM? {
        process.executablePath == "/opt/podman/bin/vfkit" ? ContainerVM(name: "Podman machine", detail: "vfkit") : nil
    }
}
