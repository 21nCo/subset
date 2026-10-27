import Darwin
import Foundation
import SystemCore
import SystemHelper
import XCTest

final class DiskReportTests: XCTestCase {
    func testDiskReportsTheTreeToTheDepthAskedWithTheVolumeSummary() async throws {
        let folder = try TemporaryFolder()
        try folder.file("big/a.bin", bytes: 64 << 10)
        try folder.file("big/inner/b.bin", bytes: 32 << 10)
        try folder.file("small.txt", bytes: 100)
        for index in 0..<22 { try folder.file("many/f\(index)", bytes: 4096 * (index + 1)) }

        let output = await run(["disk", "--path", folder.path, "--json"], HelperFixtures.environment(home: folder.path))
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(output.exit, .ok)
        let json = try object(output)
        XCTAssertEqual(json["path"] as? String, "~")
        XCTAssertEqual(json["outcome"] as? String, "completed")
        XCTAssertEqual(json["timeoutSeconds"] as? Double, 60)
        XCTAssertEqual(json["restricted"] as? [String: Int], ["unreadablePaths": 0])
        let tree = try XCTUnwrap(json["tree"] as? [String: Any])
        let children = try XCTUnwrap(tree["children"] as? [[String: Any]])
        // Largest first; at depth 1 the children's own children are counted, not listed.
        XCTAssertEqual(children.map { $0["name"] as? String }, ["many", "big", "small.txt"])
        XCTAssertEqual(children[1]["path"] as? String, "~/big")
        XCTAssertEqual((children[1]["children"] as? [Any])?.count, 0)
        XCTAssertEqual(children[1]["omittedChildren"] as? Int, 2)
        let volume = try XCTUnwrap(json["volume"] as? [String: Any])
        XCTAssertEqual(volume["purgeableBytes"] as? Int, 20_000_000_000)
        XCTAssertEqual(volume["localSnapshotCount"] as? Int, 2)

        let deeper = try object(await run(["disk", "--path", folder.path, "--depth", "2", "--json"],
                                          HelperFixtures.environment(home: folder.path)))
        let many = try XCTUnwrap(((deeper["tree"] as? [String: Any])?["children"] as? [[String: Any]])?.first)
        XCTAssertEqual((many["children"] as? [Any])?.count, 20)
        XCTAssertEqual(many["omittedChildren"] as? Int, 2)
        XCTAssertGreaterThan(many["omittedAllocatedBytes"] as? Int ?? 0, 0)
    }

    func testAbsoluteKeepsTheHomeFolderInPaths() async throws {
        let folder = try TemporaryFolder()
        try folder.file("a.txt", bytes: 10)
        let real = try XCTUnwrap(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let output = await run(["disk", "--path", folder.path, "--json", "--absolute"], HelperFixtures.environment(home: folder.path))
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(try object(output)["path"] as? String, real)
        XCTAssertFalse(output.stdout.contains("\"~"))
    }

    func testUnreadableFoldersMakeAPartialResult() async throws {
        try XCTSkipIf(geteuid() == 0, "root reads every folder")
        let folder = try TemporaryFolder()
        try folder.file("open/a.txt", bytes: 10)
        let locked = try folder.folder("locked")
        try folder.file("locked/secret.txt", bytes: 10)
        chmod(locked.path, 0)

        let output = await run(["disk", "--path", folder.path, "--json"], HelperFixtures.environment(home: folder.path))
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(output.exit, .partial)
        XCTAssertEqual(output.exit.rawValue, 3)
        let json = try object(output)
        XCTAssertEqual(json["complete"] as? Bool, false)
        XCTAssertEqual(json["restricted"] as? [String: Int], ["unreadablePaths": 1])
        XCTAssertEqual(json["unreadablePaths"] as? [String], ["~/locked"])
    }

    func testASlowScanStopsAtTheTimeoutWithWhatItRead() async throws {
        let folder = try TemporaryFolder()
        try folder.file("a.txt", bytes: 10)
        let environment = HelperFixtures.environment(disk: HelperFixtures.diskProbe(slow: true, home: folder.path),
                                                     home: folder.path)
        let started = ContinuousClock.now
        let output = await run(["disk", "--path", folder.path, "--timeout", "0.2", "--json"], environment)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10))
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(output.exit, .timeout)
        XCTAssertEqual(output.exit.rawValue, 4)
        let json = try object(output)
        XCTAssertEqual(json["outcome"] as? String, "timedOut")
        XCTAssertEqual(json["timeoutSeconds"] as? Double, 0.2)
        XCTAssertEqual((json["errors"] as? [[String: Any]])?.map { $0["code"] as? String }, ["timedOut"])
        XCTAssertNotNil(json["tree"] as? [String: Any])

        let suggestions = await run(["disk", "--suggestions", "--path", folder.path, "--timeout", "0.2", "--json"], environment)
        try assertValid(suggestions, "disk-suggestions.schema.json")
        XCTAssertEqual(suggestions.exit, .timeout)
    }

    func testAPathThatIsNotAFolderIsAnErroredResultThatValidates() async throws {
        let folder = try TemporaryFolder()
        try folder.file("a.txt", bytes: 10)
        let missing = await run(["disk", "--path", folder.path + "/missing", "--json"], HelperFixtures.environment(home: folder.path))
        try assertValid(missing, "disk.schema.json")
        XCTAssertEqual(missing.exit, .usage)
        let json = try object(missing)
        XCTAssertEqual(json["outcome"] as? String, "failed")
        XCTAssertTrue(json["tree"] is NSNull)
        XCTAssertEqual((json["errors"] as? [[String: Any]])?.first?["code"] as? String, "cannotResolve")
        XCTAssertEqual((json["errors"] as? [[String: Any]])?.first?["message"] as? String,
                       "Cannot open ~/missing: No such file or directory.")

        let file = await run(["disk", "--suggestions", "--path", folder.path + "/a.txt", "--json"],
                             HelperFixtures.environment(home: folder.path))
        try assertValid(file, "disk-suggestions.schema.json")
        XCTAssertEqual(file.exit, .usage)
        XCTAssertEqual((try object(file)["errors"] as? [[String: Any]])?.first?["code"] as? String, "notADirectory")
    }

    func testSuggestionsReportRuleMatchesWithTheCatalogVersion() async throws {
        let home = try TemporaryFolder()
        try home.file("Library/Caches/Homebrew/bottle.tar.gz", bytes: 128 << 10)
        try home.file(".npm/_cacache/index", bytes: 16 << 10)
        try home.file("Documents/notes.txt", bytes: 10)
        let docker = DockerFlags()
        let environment = HelperFixtures.environment(disk: HelperFixtures.diskProbe(includedDocker: docker, home: home.path),
                                                     home: home.path)

        let output = await run(["disk", "--suggestions", "--path", home.path, "--json"], environment)
        try assertValid(output, "disk-suggestions.schema.json")
        XCTAssertEqual(output.exit, .ok)
        let json = try object(output)
        XCTAssertEqual(json["catalogVersion"] as? Int, ReclaimRules.catalogVersion)
        let suggestions = try XCTUnwrap(json["suggestions"] as? [[String: Any]])
        let homebrew = try XCTUnwrap(suggestions.first { $0["ruleId"] as? String == "homebrewCache" })
        XCTAssertEqual(homebrew["risk"] as? String, "safe")
        XCTAssertEqual((homebrew["items"] as? [[String: Any]])?.map { $0["path"] as? String }, ["~/Library/Caches/Homebrew"])
        XCTAssertEqual((homebrew["bytes"] as? [String: Any])?["kind"] as? String, "scanned")
        // The app's cleanup is described, never run.
        let cleanup = homebrew["cleanup"] as? [String: Any]
        XCTAssertEqual(cleanup?["kind"] as? String, "command")
        XCTAssertEqual(cleanup?["command"] as? [String], ["brew", "cleanup"])
        XCTAssertNotNil(suggestions.first { $0["ruleId"] as? String == "npmCache" })
        // Scanning the home folder asks Docker, as the app does; its image space is unavailable here.
        let dockerImages = try XCTUnwrap(suggestions.first { $0["ruleId"] as? String == "dockerImages" })
        XCTAssertEqual((dockerImages["bytes"] as? [String: Any])?["kind"] as? String, "unavailable")
        XCTAssertEqual(docker.values, [true])

        let documents = await run(["disk", "--suggestions", "--path", home.path + "/Documents"], environment)
        XCTAssertEqual(documents.exit, .ok)
        XCTAssertTrue(documents.stdout.contains("reclaim suggestions for ~/Documents (catalog version \(ReclaimRules.catalogVersion))"))
        XCTAssertEqual(docker.values, [true, false])
    }
}
