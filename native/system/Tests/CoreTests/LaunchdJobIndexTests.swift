import Darwin
import Foundation
@testable import SystemCore
import XCTest

/// Builds launchd folders and a fixture app in a temporary folder.
final class LaunchdJobIndexTests: XCTestCase {
    private var root: URL!
    private var agents: URL { root.appendingPathComponent("LaunchAgents") }
    private var daemons: URL { root.appendingPathComponent("LaunchDaemons") }
    private var applications: URL { root.appendingPathComponent("Applications") }

    override func setUpWithError() throws {
        // Resolve /var to /private/var once, so expected paths match the index's resolved ones.
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("LaunchdJobIndexTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        root = temporary.resolvingSymlinksInPath()
        for folder in [agents, daemons, applications, root.appendingPathComponent("bin")] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    func testProgramAndProgramArgumentsMapToTheJobAndAMissingProgramIsOrphaned() throws {
        let server = try executable("bin/server")
        let worker = try executable("bin/worker")
        let other = try executable("bin/other")
        // Homebrew-style: the plist names a symlink, the kernel reports the real path.
        try FileManager.default.createSymbolicLink(atPath: root.path + "/bin/worker-link", withDestinationPath: worker)
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        try plist(agents, "dev.worker", ["Label": "dev.worker", "ProgramArguments": [root.path + "/bin/worker-link", "--queue"]])
        // Program wins over ProgramArguments[0], which is then only argv[0].
        try plist(daemons, "dev.both", ["Label": "dev.both", "Program": other, "ProgramArguments": ["ignored", "-v"]])
        try plist(daemons, "dev.gone", ["Label": "dev.gone", "ProgramArguments": [root.path + "/bin/removed"]])
        let index = LaunchdJobIndex(folders: folders())

        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server"])
        XCTAssertEqual(index.launchdJobs(forExecutable: worker).value?.jobs.map(\.label), ["dev.worker"])
        XCTAssertEqual(index.launchdJobs(forExecutable: other).value?.jobs.map(\.label), ["dev.both"])
        XCTAssertEqual(index.launchdJobs(forExecutable: root.path + "/bin/unrelated"), .value(LaunchdJobs(jobs: []), source: .launchdPlists))
        XCTAssertEqual(index.launchdJobs(forExecutable: nil), .unavailable(.noExecutablePath, source: .launchdPlists))

        let server_ = try XCTUnwrap(index.jobs.first { $0.label == "dev.server" })
        XCTAssertEqual(server_.plistPath, agents.path + "/dev.server.plist")
        XCTAssertEqual(server_.domain, .userAgent)
        XCTAssertFalse(server_.orphaned)
        let gone = try XCTUnwrap(index.jobs.first { $0.label == "dev.gone" })
        XCTAssertTrue(gone.orphaned)
        XCTAssertEqual(gone.program, root.path + "/bin/removed")
        XCTAssertEqual(gone.domain, .globalDaemon)
        XCTAssertEqual(index.launchdJobs(forExecutable: root.path + "/bin/removed"), .value(LaunchdJobs(jobs: []), source: .launchdPlists))
    }

    func testABareProgramNameIsFoundOnLaunchdsPath() throws {
        try plist(agents, "dev.true", ["Label": "dev.true", "ProgramArguments": ["true"]])
        try plist(agents, "dev.missing", ["Label": "dev.missing", "ProgramArguments": ["subset-no-such-tool"]])
        let index = LaunchdJobIndex(folders: folders())

        let truePath = try XCTUnwrap(LaunchdJobIndex.realPath("/usr/bin/true"))
        XCTAssertEqual(index.launchdJobs(forExecutable: truePath).value?.jobs.map(\.label), ["dev.true"])
        XCTAssertEqual(index.jobs.first { $0.label == "dev.missing" }?.orphaned, true)
        XCTAssertEqual(index.scanFailures, [], "a name on no PATH entry is missing, not a failure")
    }

    func testAgentsEmbeddedInAnInstalledAppAreRead() throws {
        let bundle = applications.appendingPathComponent("Fixture.app")
        let helper = try executable("Applications/Fixture.app/Contents/MacOS/Helper")
        let bundleAgents = bundle.appendingPathComponent("Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: bundleAgents, withIntermediateDirectories: true)
        // SMAppService agents name their program relative to the bundle.
        try plist(bundleAgents, "dev.fixture.helper", ["Label": "dev.fixture.helper", "BundleProgram": "Contents/MacOS/Helper"])
        try plist(bundleAgents, "dev.fixture.stale", ["Label": "dev.fixture.stale", "BundleProgram": "Contents/MacOS/Removed"])
        let index = LaunchdJobIndex(folders: folders())

        let jobs = try XCTUnwrap(index.launchdJobs(forExecutable: helper).value?.jobs)
        XCTAssertEqual(jobs.map(\.label), ["dev.fixture.helper"])
        XCTAssertEqual(jobs.first?.domain, .appBundleAgent(bundlePath: bundle.path))
        XCTAssertEqual(jobs.first?.plistPath, bundleAgents.path + "/dev.fixture.helper.plist")
        XCTAssertEqual(index.jobs.first { $0.label == "dev.fixture.stale" }?.orphaned, true)
    }

    func testAgentsOfAppsInSubfoldersAreReadUpToTwoLevelsDown() throws {
        // /Applications/Utilities and a vendor's folder; a third level is past the scan.
        var helpers: [String: String] = [:]
        for (label, bundle) in [("dev.utility", "Utilities/Utility.app"), ("dev.vendor", "Vendor/Suite/Tool.app"),
                                ("dev.deep", "One/Two/Three/Deep.app")] {
            helpers[label] = try embeddedAgent(label, in: bundle)
        }
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        XCTAssertEqual(index.launchdJobs(forExecutable: helpers["dev.utility"]).value?.jobs.map(\.label), ["dev.utility"])
        XCTAssertEqual(index.launchdJobs(forExecutable: helpers["dev.vendor"]).value?.jobs.map(\.label), ["dev.vendor"])
        XCTAssertEqual(index.launchdJobs(forExecutable: helpers["dev.deep"]).value, LaunchdJobs(jobs: []))

        // An app installed later into a subfolder is found without any change to the top-level folder.
        let later = try embeddedAgent("dev.later", in: "Utilities/Later.app")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: later).value?.jobs.map(\.label), ["dev.later"])
    }

    func testPlistsWithoutALabelOrProgramOrThatDoNotParseAreListedAsUnreadable() throws {
        try Data("not a plist".utf8).write(to: agents.appendingPathComponent("broken.plist"))
        try plist(agents, "no-label", ["Program": "/usr/bin/true"])
        try plist(agents, "no-program", ["Label": "dev.none"])
        try Data().write(to: agents.appendingPathComponent("README.txt"))
        try FileManager.default.createDirectory(at: agents.appendingPathComponent("folder.plist"), withIntermediateDirectories: true)
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        XCTAssertEqual(index.jobs, [])
        XCTAssertEqual(index.unreadablePlists, ["broken", "folder", "no-label", "no-program"].map { agents.path + "/\($0).plist" })
        XCTAssertEqual(index.scanFailures, [], "launchd cannot load these either, so the scan is still complete")
        XCTAssertEqual(index.launchdJobs(forExecutable: "/usr/bin/true"), .value(LaunchdJobs(jobs: []), source: .launchdPlists))
    }

    func testAFIFONamedLikeAPlistIsUnreadableAndDoesNotBlockTheScan() throws {
        let server = try executable("bin/server")
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        let fifo = agents.path + "/fifo.plist"
        let link = agents.path + "/link.plist"
        XCTAssertEqual(mkfifo(fifo, 0o644), 0, String(cString: strerror(errno)))
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: fifo)
        // A blocking open of a FIFO never returns, so a regression fails on the timeout instead of hanging the run.
        // The stuck scan holds the index lock, so the index is not touched after a timeout.
        let index = LaunchdJobIndex(folders: folders())
        let scanned = expectation(description: "scan finished")
        DispatchQueue.global().async {
            index.refreshIfChanged()
            scanned.fulfill()
        }
        guard XCTWaiter.wait(for: [scanned], timeout: 5) == .completed else {
            return XCTFail("the scan blocked on a FIFO named like a plist")
        }

        XCTAssertEqual(index.unreadablePlists, [fifo, link])
        XCTAssertEqual(index.scanFailures, [])
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server"])
    }

    func testAPlistLargerThanAnyJobIsNotReadAndMakesTheScanIncomplete() throws {
        let server = try executable("bin/server")
        let hidden = try executable("bin/hidden")
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        // Sparse, so the test writes nothing; a symlink to an oversized file outside the folders counts as well.
        let huge = agents.path + "/huge.plist"
        let target = root.path + "/huge-target"
        let link = daemons.path + "/link.plist"
        for path in [huge, target] {
            XCTAssertTrue(FileManager.default.createFile(atPath: path, contents: nil))
            XCTAssertEqual(truncate(path, off_t(LaunchdJobIndex.maximumPlistSize + 1)), 0)
        }
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: target)
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        let failures = [LaunchdScanFailure(path: huge, code: EFBIG), LaunchdScanFailure(path: link, code: EFBIG)]
        XCTAssertEqual(index.scanFailures, failures)
        XCTAssertEqual(index.unreadablePlists, [])
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, LaunchdJobs(jobs: index.jobs, scanFailures: failures))
        XCTAssertEqual(index.launchdJobs(forExecutable: hidden), .unavailable(.incompleteScan(failures), source: .launchdPlists))

        try FileManager.default.removeItem(atPath: huge)
        try plist(agents, "huge", ["Label": "dev.hidden", "Program": hidden])
        try FileManager.default.removeItem(atPath: link)
        index.refreshIfChanged()

        XCTAssertEqual(index.scanFailures, [])
        XCTAssertEqual(index.launchdJobs(forExecutable: hidden).value?.jobs.map(\.label), ["dev.hidden"])
    }

    func testAChangedIndexReachesProcessesAlreadyReadWithoutNewOnes() throws {
        try XCTSkipIf(getuid() == 0, "root reads a plist without permission")
        let server = try executable("bin/server")
        let other = try executable("bin/other")
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        let fixtures = FixtureSignalReaders()
        fixtures.signatures[100] = .value(CodeSignature(signingID: "server", teamID: "ABCDE12345", isPlatformBinary: false), source: .codeSigning)
        let reader = OriginSignalReader(
            responsible: fixtures, coalition: fixtures, codeSignature: fixtures,
            launchd: LaunchdJobIndex(folders: folders()), context: fixtures, check: { _, _ in .unchanged }
        )
        // The same process, started by launchd, in every sample.
        func annotated() -> ProcessFacts {
            let record = RawProcessRecord(identity: ProcessIdentity(pid: 100, startTime: 1), ppid: 1, uid: 501,
                                          executablePath: server, name: "server", usage: .unavailable)
            var processes = [ProcessFacts(record: record, timebase: MachTimebase(numer: 1, denom: 1))]
            reader.annotate(&processes)
            return processes[0]
        }

        XCTAssertEqual(annotated().launchdLabel, "dev.server")

        try plist(daemons, "dev.copy", ["Label": "dev.copy", "Program": server])
        XCTAssertEqual(annotated().launchdMatch, .executableOnly(.conflictingLabels))

        try FileManager.default.removeItem(atPath: daemons.path + "/dev.copy.plist")
        let locked = agents.path + "/dev.other.plist"
        try plist(agents, "dev.other", ["Label": "dev.other", "Program": other])
        try Self.setPermissions(0o000, locked)
        addTeardownBlock { try? Self.setPermissions(0o644, locked) }
        let incomplete = annotated()
        XCTAssertEqual(incomplete.launchdMatch, .executableOnly(.incompleteScan))
        XCTAssertNil(incomplete.launchdLabel)
        XCTAssertEqual(incomplete.origin?.launchdJobs.value?.scanFailures, [LaunchdScanFailure(path: locked, code: EACCES)])

        try Self.setPermissions(0o644, locked)
        XCTAssertEqual(annotated().launchdLabel, "dev.server")

        try FileManager.default.removeItem(atPath: agents.path + "/dev.server.plist")
        let removed = annotated()
        XCTAssertEqual(removed.launchdMatch, LaunchdMatch.none)
        XCTAssertNil(removed.launchdLabel)
        XCTAssertEqual(fixtures.calls(.codeSignature, pid: 100), 1, "only the launchd lookup is repeated")
    }

    func testTheIndexIsRebuiltWhenAFolderOrPlistChanges() throws {
        let server = try executable("bin/server")
        let index = LaunchdJobIndex(folders: folders())
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, LaunchdJobs(jobs: []))

        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, LaunchdJobs(jobs: []), "a lookup alone does not rescan")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server"])

        // An edit in place, which leaves the folder's own modification time alone.
        try plist(agents, "dev.server", ["Label": "dev.server.renamed", "Program": server])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: agents.path + "/dev.server.plist")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server.renamed"])

        // An app installed later, with an embedded agent.
        let helper = try executable("Applications/Later.app/Contents/MacOS/Helper")
        let bundleAgents = applications.appendingPathComponent("Later.app/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: bundleAgents, withIntermediateDirectories: true)
        try plist(bundleAgents, "dev.later", ["Label": "dev.later", "BundleProgram": "Contents/MacOS/Helper"])
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: helper).value?.jobs.map(\.label), ["dev.later"])

        try FileManager.default.removeItem(atPath: agents.path + "/dev.server.plist")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, LaunchdJobs(jobs: []))
    }

    func testAProgramDeletedOrCreatedWithItsPlistUnchangedIsResolvedAgain() throws {
        // The program lives outside every watched folder, so only the program changes.
        let server = try executable("bin/server")
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()
        XCTAssertEqual(index.jobs.first?.orphaned, false)

        try FileManager.default.removeItem(atPath: server)
        index.refreshIfChanged()
        XCTAssertEqual(index.jobs.first?.orphaned, true)

        _ = try executable("bin/server")
        index.refreshIfChanged()
        XCTAssertEqual(index.jobs.first?.orphaned, false)
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server"])
    }

    func testRetargetingOnlyTheProgramsSymlinkMovesTheJobToTheNewExecutable() throws {
        // Homebrew-style: `brew upgrade` points opt/postgres at a new versioned folder and leaves the plist alone.
        let v1 = try executable("Cellar/postgres/1/bin/postgres")
        let v2 = try executable("Cellar/postgres/2/bin/postgres")
        let link = root.path + "/opt/postgres"
        try FileManager.default.createDirectory(atPath: root.path + "/opt", withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.path + "/Cellar/postgres/1")
        try plist(agents, "dev.postgres", ["Label": "dev.postgres", "ProgramArguments": [link + "/bin/postgres", "-D", "/data"]])
        let index = LaunchdJobIndex(folders: folders())
        XCTAssertEqual(index.launchdJobs(forExecutable: v1).value?.jobs.map(\.label), ["dev.postgres"])

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.path + "/Cellar/postgres/2")
        index.refreshIfChanged()

        XCTAssertEqual(index.launchdJobs(forExecutable: v2).value?.jobs.map(\.label), ["dev.postgres"])
        XCTAssertEqual(index.launchdJobs(forExecutable: v1).value, LaunchdJobs(jobs: []))
        XCTAssertEqual(index.jobs.first?.resolvedProgram, LaunchdJobIndex.realPath(v2))
    }

    func testAFolderOrPlistThatCannotBeReadIsRecordedAndAnAbsentJobIsUnavailable() throws {
        try XCTSkipIf(getuid() == 0, "root reads a folder without permission")
        let server = try executable("bin/server")
        let hidden = try executable("bin/hidden")
        let secret = try executable("bin/secret")
        let unrelated = try executable("bin/unrelated")
        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        try plist(agents, "dev.secret", ["Label": "dev.secret", "Program": secret])
        try plist(daemons, "dev.hidden", ["Label": "dev.hidden", "Program": hidden])
        let secretPlist = agents.path + "/dev.secret.plist"
        try Self.setPermissions(0o000, daemons.path, secretPlist)
        addTeardownBlock { [daemons] in try? Self.setPermissions(0o755, daemons.path, secretPlist) }
        let missing = root.path + "/NoSuchLaunchAgents"
        let index = LaunchdJobIndex(folders: LaunchdFolders(
            plistFolders: [(agents.path, .userAgent), (daemons.path, .globalDaemon), (missing, .globalAgent)],
            applicationFolders: [applications.path, root.path + "/NoSuchApplications"]
        ))
        index.refreshIfChanged()

        let failures = [LaunchdScanFailure(path: secretPlist, code: EACCES), LaunchdScanFailure(path: daemons.path, code: EACCES)]
        XCTAssertEqual(index.scanFailures, failures, "a missing folder is not a failure")
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.server"])
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.scanFailures, failures)
        for executable in [hidden, secret, unrelated] {
            XCTAssertEqual(index.launchdJobs(forExecutable: executable), .unavailable(.incompleteScan(failures), source: .launchdPlists))
        }
        let reason = try XCTUnwrap(index.launchdJobs(forExecutable: unrelated).failure?.reason)
        XCTAssertTrue(reason.contains(daemons.path) && reason.contains("errno \(EACCES)"), reason)

        try Self.setPermissions(0o755, daemons.path)
        try Self.setPermissions(0o644, secretPlist)
        index.refreshIfChanged()

        XCTAssertEqual(index.scanFailures, [])
        XCTAssertEqual(index.launchdJobs(forExecutable: hidden).value?.jobs.map(\.label), ["dev.hidden"])
        XCTAssertEqual(index.launchdJobs(forExecutable: secret).value?.jobs.map(\.label), ["dev.secret"])
        XCTAssertEqual(index.launchdJobs(forExecutable: unrelated), .value(LaunchdJobs(jobs: []), source: .launchdPlists))
    }

    func testAJobFoundWhileAPlistCannotBeReadCarriesTheFailureAndIdentifiesNoProcess() throws {
        try XCTSkipIf(getuid() == 0, "root reads a plist without permission")
        let server = try executable("bin/server")
        let other = try executable("bin/other")
        try plist(agents, "dev.a", ["Label": "dev.a", "Program": server])
        // An unreadable plist that names the same executable with another label.
        try plist(agents, "dev.b", ["Label": "dev.b", "Program": server])
        let hidden = agents.path + "/dev.b.plist"
        try Self.setPermissions(0o000, hidden)
        addTeardownBlock { try? Self.setPermissions(0o644, hidden) }
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()
        let failures = [LaunchdScanFailure(path: hidden, code: EACCES)]
        let signed = CodeSignature(signingID: "dev.server", teamID: "ABCDE12345", isPlatformBinary: false)
        let platform = CodeSignature(signingID: "com.apple.server", teamID: nil, isPlatformBinary: true)

        let found = try XCTUnwrap(index.launchdJobs(forExecutable: server).value)
        XCTAssertEqual(found.jobs.map(\.label), ["dev.a"])
        XCTAssertEqual(found.scanFailures, failures)
        XCTAssertEqual(LaunchdMatch(jobs: found, ppid: 1, signature: signed), .executableOnly(.incompleteScan))
        XCTAssertNil(facts(ppid: 1, signature: signed, launchdJobs: found).launchdLabel)
        // The reasons that hold whatever the unread plist says still come first.
        XCTAssertEqual(LaunchdMatch(jobs: found, ppid: 900, signature: signed), .executableOnly(.notStartedByLaunchd))
        XCTAssertEqual(LaunchdMatch(jobs: found, ppid: 1, signature: platform), .executableOnly(.sharedExecutable))
        XCTAssertEqual(index.launchdJobs(forExecutable: other), .unavailable(.incompleteScan(failures), source: .launchdPlists))

        try Self.setPermissions(0o644, hidden)
        index.refreshIfChanged()
        let both = try XCTUnwrap(index.launchdJobs(forExecutable: server).value)
        XCTAssertEqual(both, LaunchdJobs(jobs: index.jobs))
        XCTAssertEqual(LaunchdMatch(jobs: both, ppid: 1, signature: signed), .executableOnly(.conflictingLabels))

        try plist(agents, "dev.b", ["Label": "dev.b", "Program": other])
        index.refreshIfChanged()
        let one = try XCTUnwrap(index.launchdJobs(forExecutable: server).value)
        XCTAssertEqual(one.jobs.map(\.label), ["dev.a"])
        XCTAssertTrue(one.isComplete)
        XCTAssertEqual(LaunchdMatch(jobs: one, ppid: 1, signature: signed), .job(label: "dev.a"))
        XCTAssertEqual(facts(ppid: 1, signature: signed, launchdJobs: one).launchdLabel, "dev.a")
    }

    func testAProgramThatCannotBeCheckedIsNotOrphanedAndMakesTheScanIncomplete() throws {
        try XCTSkipIf(getuid() == 0, "root searches a folder without permission")
        // A root daemon whose program sits under a folder the user cannot search.
        let locked = root.path + "/locked"
        let server = try executable("locked/bin/server")
        let other = try executable("bin/other")
        let unrelated = try executable("bin/unrelated")
        try plist(daemons, "dev.locked", ["Label": "dev.locked", "Program": server])
        try plist(agents, "dev.a", ["Label": "dev.a", "Program": other])
        // Programs that are not there: ENOENT, ENOTDIR (a file on the path), and ELOOP.
        try FileManager.default.createSymbolicLink(atPath: root.path + "/bin/loop", withDestinationPath: root.path + "/bin/loop")
        try plist(agents, "dev.gone", ["Label": "dev.gone", "ProgramArguments": [root.path + "/bin/removed"]])
        try plist(agents, "dev.notdir", ["Label": "dev.notdir", "Program": other + "/server"])
        try plist(agents, "dev.loop", ["Label": "dev.loop", "Program": root.path + "/bin/loop"])
        try Self.setPermissions(0o000, locked)
        addTeardownBlock { try? Self.setPermissions(0o755, locked) }
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()
        let failures = [LaunchdScanFailure(path: server, code: EACCES)]
        let signed = CodeSignature(signingID: "dev.a", teamID: "ABCDE12345", isPlatformBinary: false)

        let lockedJob = try XCTUnwrap(index.jobs.first { $0.label == "dev.locked" })
        XCTAssertFalse(lockedJob.orphaned)
        XCTAssertEqual(lockedJob.resolution, .unchecked(failures[0]))
        XCTAssertNil(lockedJob.resolvedProgram)
        for label in ["dev.gone", "dev.notdir", "dev.loop"] {
            XCTAssertEqual(index.jobs.first { $0.label == label }?.resolution, .missing, label)
        }
        XCTAssertEqual(index.scanFailures, failures, "only the unchecked program is a failure")
        XCTAssertEqual(index.launchdJobs(forExecutable: unrelated), .unavailable(.incompleteScan(failures), source: .launchdPlists))
        let found = try XCTUnwrap(index.launchdJobs(forExecutable: other).value)
        XCTAssertEqual(found.jobs.map(\.label), ["dev.a"])
        XCTAssertEqual(found.scanFailures, failures)
        XCTAssertEqual(LaunchdMatch(jobs: found, ppid: 1, signature: signed), .executableOnly(.incompleteScan))

        try Self.setPermissions(0o755, locked)
        index.refreshIfChanged()

        XCTAssertEqual(index.scanFailures, [])
        XCTAssertEqual(index.jobs.first { $0.label == "dev.locked" }?.resolution, .resolved(try XCTUnwrap(LaunchdJobIndex.realPath(server))))
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.locked"])
        let complete = try XCTUnwrap(index.launchdJobs(forExecutable: other).value)
        XCTAssertTrue(complete.isComplete)
        XCTAssertEqual(LaunchdMatch(jobs: complete, ppid: 1, signature: signed), .job(label: "dev.a"))
        XCTAssertEqual(index.launchdJobs(forExecutable: unrelated), .value(LaunchdJobs(jobs: []), source: .launchdPlists))
    }

    func testABareNameIsUncheckedOnlyWhenNoPathEntryHasItAndOneCouldNotBeChecked() throws {
        try XCTSkipIf(getuid() == 0, "root searches a folder without permission")
        let locked = root.path + "/locked"
        let empty = root.path + "/empty"
        let tool = try executable("tools/tool")
        _ = try executable("locked/tool")
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        try Self.setPermissions(0o000, locked)
        addTeardownBlock { try? Self.setPermissions(0o755, locked) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["Label": "dev.tool", "ProgramArguments": ["tool"]],
                                                      format: .xml, options: 0)
        let definition = try XCTUnwrap(LaunchdJobIndex.Definition(plistPath: "/dev.tool.plist", data: data,
                                                                  domain: .userAgent, bundlePath: nil))

        XCTAssertEqual(definition.job(searchPath: [locked, root.path + "/tools"]).resolution,
                       .resolved(try XCTUnwrap(LaunchdJobIndex.realPath(tool))),
                       "a later entry that has it wins, as with execvp")
        XCTAssertEqual(definition.job(searchPath: [empty, locked]).resolution,
                       .unchecked(LaunchdScanFailure(path: locked + "/tool", code: EACCES)))
        XCTAssertEqual(definition.job(searchPath: [empty]).resolution, .missing)
    }

    func testOnlyProgramArgumentsMayNameARelativeProgram() throws {
        // launchd requires an absolute Program but looks ProgramArguments[0] up like execvp, from WorkingDirectory.
        let server = try executable("bin/server")
        try plist(agents, "dev.relative-program", ["Label": "dev.relative-program", "Program": "bin/server", "WorkingDirectory": root.path])
        try plist(agents, "dev.relative-arguments", ["Label": "dev.relative-arguments", "ProgramArguments": ["bin/server"], "WorkingDirectory": root.path])
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.jobs.map(\.label), ["dev.relative-arguments"])
        XCTAssertEqual(index.unreadablePlists, [agents.path + "/dev.relative-program.plist"])
        XCTAssertEqual(index.scanFailures, [])
    }

    func testAnApplicationSubfolderThatCannotBeListedIsRecorded() throws {
        try XCTSkipIf(getuid() == 0, "root reads a folder without permission")
        let helper = try embeddedAgent("dev.vendor", in: "Vendor/Tool.app")
        let vendor = applications.path + "/Vendor"
        try Self.setPermissions(0o000, vendor)
        addTeardownBlock { try? Self.setPermissions(0o755, vendor) }
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        XCTAssertEqual(index.scanFailures, [LaunchdScanFailure(path: vendor, code: EACCES)])
        XCTAssertEqual(index.launchdJobs(forExecutable: helper).failure, .incompleteScan(index.scanFailures))

        try Self.setPermissions(0o755, vendor)
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: helper).value?.jobs.map(\.label), ["dev.vendor"])
    }

    func testTheLiveFoldersAreReadWithoutFailing() {
        let index = LaunchdJobIndex()
        index.refreshIfChanged()
        // A Mac may have a root-only plist (this development Mac has a mode 700 one in /Library/LaunchDaemons);
        // then an executable no plist names reads as an incomplete scan instead of no job.
        let signal = index.launchdJobs(forExecutable: "/usr/bin/true")
        if index.scanFailures.isEmpty {
            XCTAssertNotNil(signal.value)
        } else {
            XCTAssertEqual(signal, .unavailable(.incompleteScan(index.scanFailures), source: .launchdPlists))
        }
    }

    /// A process with this parent and signature, its launchd jobs read as given.
    private func facts(ppid: Int32, signature: CodeSignature, launchdJobs: LaunchdJobs) -> ProcessFacts {
        let record = RawProcessRecord(identity: ProcessIdentity(pid: 100, startTime: 1), ppid: ppid, uid: 501,
                                      executablePath: launchdJobs.jobs.first?.resolvedProgram, name: "server", usage: .unavailable)
        var facts = ProcessFacts(record: record, timebase: MachTimebase(numer: 1, denom: 1))
        facts.origin = OriginSignals(
            responsibleProcess: .value(100, source: .responsibility),
            coalition: .value(1, source: .coalitionInfo),
            codeSignature: .value(signature, source: .codeSigning),
            launchdJobs: .value(launchdJobs, source: .launchdPlists),
            workingDirectory: .value("/", source: .vnodePathInfo),
            terminal: .value(.none, source: .bsdInfo)
        )
        return facts
    }

    private func folders() -> LaunchdFolders {
        LaunchdFolders(
            plistFolders: [(agents.path, .userAgent), (daemons.path, .globalDaemon)],
            applicationFolders: [applications.path]
        )
    }

    private static func setPermissions(_ permissions: Int, _ paths: String...) throws {
        for path in paths { try FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: path) }
    }

    /// Creates an executable file and returns its path.
    private func executable(_ relativePath: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Creates an app bundle below the applications folder with one agent running its helper, and returns the
    /// helper's path.
    private func embeddedAgent(_ label: String, in bundle: String) throws -> String {
        let helper = try executable("Applications/\(bundle)/Contents/MacOS/Helper")
        let bundleAgents = applications.appendingPathComponent(bundle + "/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: bundleAgents, withIntermediateDirectories: true)
        try plist(bundleAgents, label, ["Label": label, "BundleProgram": "Contents/MacOS/Helper"])
        return helper
    }

    private func plist(_ folder: URL, _ name: String, _ contents: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent(name + ".plist"))
    }
}
