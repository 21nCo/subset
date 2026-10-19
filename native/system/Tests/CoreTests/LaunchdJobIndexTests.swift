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

        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.map(\.label), ["dev.server"])
        XCTAssertEqual(index.launchdJobs(forExecutable: worker).value?.map(\.label), ["dev.worker"])
        XCTAssertEqual(index.launchdJobs(forExecutable: other).value?.map(\.label), ["dev.both"])
        XCTAssertEqual(index.launchdJobs(forExecutable: root.path + "/bin/unrelated"), .value([], source: .launchdPlists))
        XCTAssertEqual(index.launchdJobs(forExecutable: nil), .unavailable(.noExecutablePath, source: .launchdPlists))

        let server_ = try XCTUnwrap(index.jobs.first { $0.label == "dev.server" })
        XCTAssertEqual(server_.plistPath, agents.path + "/dev.server.plist")
        XCTAssertEqual(server_.domain, .userAgent)
        XCTAssertFalse(server_.orphaned)
        let gone = try XCTUnwrap(index.jobs.first { $0.label == "dev.gone" })
        XCTAssertTrue(gone.orphaned)
        XCTAssertEqual(gone.program, root.path + "/bin/removed")
        XCTAssertEqual(gone.domain, .globalDaemon)
        XCTAssertEqual(index.launchdJobs(forExecutable: root.path + "/bin/removed"), .value([], source: .launchdPlists))
    }

    func testABareProgramNameIsFoundOnLaunchdsPath() throws {
        try plist(agents, "dev.true", ["Label": "dev.true", "ProgramArguments": ["true"]])
        try plist(agents, "dev.missing", ["Label": "dev.missing", "ProgramArguments": ["subset-no-such-tool"]])
        let index = LaunchdJobIndex(folders: folders())

        let truePath = try XCTUnwrap(LaunchdJobIndex.realPath("/usr/bin/true"))
        XCTAssertEqual(index.launchdJobs(forExecutable: truePath).value?.map(\.label), ["dev.true"])
        XCTAssertEqual(index.jobs.first { $0.label == "dev.missing" }?.orphaned, true)
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

        let jobs = try XCTUnwrap(index.launchdJobs(forExecutable: helper).value)
        XCTAssertEqual(jobs.map(\.label), ["dev.fixture.helper"])
        XCTAssertEqual(jobs.first?.domain, .appBundleAgent(bundlePath: bundle.path))
        XCTAssertEqual(jobs.first?.plistPath, bundleAgents.path + "/dev.fixture.helper.plist")
        XCTAssertEqual(index.jobs.first { $0.label == "dev.fixture.stale" }?.orphaned, true)
    }

    func testPlistsWithoutALabelOrProgramOrThatDoNotParseAreListedAsUnreadable() throws {
        try Data("not a plist".utf8).write(to: agents.appendingPathComponent("broken.plist"))
        try plist(agents, "no-label", ["Program": "/usr/bin/true"])
        try plist(agents, "no-program", ["Label": "dev.none"])
        try Data().write(to: agents.appendingPathComponent("README.txt"))
        let index = LaunchdJobIndex(folders: folders())
        index.refreshIfChanged()

        XCTAssertEqual(index.jobs, [])
        XCTAssertEqual(index.unreadablePlists, ["broken", "no-label", "no-program"].map { agents.path + "/\($0).plist" })
    }

    func testTheIndexIsRebuiltWhenAFolderOrPlistChanges() throws {
        let server = try executable("bin/server")
        let index = LaunchdJobIndex(folders: folders())
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, [])

        try plist(agents, "dev.server", ["Label": "dev.server", "Program": server])
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, [], "a lookup alone does not rescan")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.map(\.label), ["dev.server"])

        // An edit in place, which leaves the folder's own modification time alone.
        try plist(agents, "dev.server", ["Label": "dev.server.renamed", "Program": server])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: agents.path + "/dev.server.plist")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.map(\.label), ["dev.server.renamed"])

        // An app installed later, with an embedded agent.
        let helper = try executable("Applications/Later.app/Contents/MacOS/Helper")
        let bundleAgents = applications.appendingPathComponent("Later.app/Contents/Library/LaunchAgents")
        try FileManager.default.createDirectory(at: bundleAgents, withIntermediateDirectories: true)
        try plist(bundleAgents, "dev.later", ["Label": "dev.later", "BundleProgram": "Contents/MacOS/Helper"])
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: helper).value?.map(\.label), ["dev.later"])

        try FileManager.default.removeItem(atPath: agents.path + "/dev.server.plist")
        index.refreshIfChanged()
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value, [])
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
        XCTAssertEqual(index.launchdJobs(forExecutable: server).value?.map(\.label), ["dev.server"])
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
        XCTAssertEqual(index.launchdJobs(forExecutable: v1).value?.map(\.label), ["dev.postgres"])

        try FileManager.default.removeItem(atPath: link)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: root.path + "/Cellar/postgres/2")
        index.refreshIfChanged()

        XCTAssertEqual(index.launchdJobs(forExecutable: v2).value?.map(\.label), ["dev.postgres"])
        XCTAssertEqual(index.launchdJobs(forExecutable: v1).value, [])
        XCTAssertEqual(index.jobs.first?.resolvedProgram, LaunchdJobIndex.realPath(v2))
    }

    func testTheLiveFoldersAreReadWithoutFailing() {
        let index = LaunchdJobIndex()
        index.refreshIfChanged()
        XCTAssertNotNil(index.launchdJobs(forExecutable: "/usr/bin/true").value)
    }

    private func folders() -> LaunchdFolders {
        LaunchdFolders(
            plistFolders: [(agents.path, .userAgent), (daemons.path, .globalDaemon)],
            applicationFolders: [applications.path]
        )
    }

    /// Creates an executable file and returns its path.
    private func executable(_ relativePath: String) throws -> String {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    private func plist(_ folder: URL, _ name: String, _ contents: [String: Any]) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: contents, format: .xml, options: 0)
        try data.write(to: folder.appendingPathComponent(name + ".plist"))
    }
}
