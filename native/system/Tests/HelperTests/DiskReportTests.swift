import Darwin
import Foundation
import os
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

    /// The smallest timeout accepted is reported as applied, positive, and both disk results still validate.
    func testTheSmallestTimeoutIsReportedExactly() async throws {
        let folder = try TemporaryFolder()
        try folder.file("a.txt", bytes: 10)
        let environment = HelperFixtures.environment(disk: HelperFixtures.diskProbe(slow: true, home: folder.path),
                                                     home: folder.path)
        for timeout in ["0.001", "0.004"] {
            let disk = await run(["disk", "--path", folder.path, "--timeout", timeout, "--json"], environment)
            try assertValid(disk, "disk.schema.json")
            XCTAssertEqual(disk.exit, .timeout)
            XCTAssertTrue(disk.stdout.contains("\"timeoutSeconds\": \(timeout),"), disk.stdout)
            let suggestions = await run(["disk", "--suggestions", "--path", folder.path, "--timeout", timeout, "--json"],
                                        environment)
            try assertValid(suggestions, "disk-suggestions.schema.json")
            XCTAssertTrue(suggestions.stdout.contains("\"timeoutSeconds\": \(timeout),"), suggestions.stdout)
        }
    }

    /// Volume values and a snapshot count that could not be read keep the scan's data but make the result partial.
    func testUnreadableVolumeValuesAndSnapshotsMakeAPartialResult() async throws {
        let folder = try TemporaryFolder()
        try folder.file("a.txt", bytes: 10)
        let volume = VolumeSummary(values: VolumeCapacityValues(mountPoint: "/", name: "Macintosh HD"),
                                   snapshots: .unavailable("tmutil did not answer within 5 seconds."))
        let output = await run(["disk", "--path", folder.path, "--json"],
                               HelperFixtures.environment(disk: HelperFixtures.diskProbe(home: folder.path, volume: volume),
                                                          home: folder.path))
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(output.exit, .partial)
        let json = try object(output)
        XCTAssertEqual(json["complete"] as? Bool, false)
        XCTAssertEqual(json["outcome"] as? String, "completed")
        XCTAssertNotNil(json["tree"] as? [String: Any])
        XCTAssertTrue((json["volume"] as? [String: Any])?["capacityBytes"] is NSNull)
        let errors = try XCTUnwrap(json["errors"] as? [[String: String]])
        XCTAssertEqual(errors.map { $0["code"] }, ["volumeUnavailable", "snapshotsUnavailable"])
        XCTAssertEqual(errors[0]["message"],
                       "Could not read the volume's capacity, available space, space available for important use.")
        XCTAssertEqual(errors[1]["message"], "Could not count local snapshots: tmutil did not answer within 5 seconds.")

        let text = await run(["disk", "--path", folder.path],
                             HelperFixtures.environment(disk: HelperFixtures.diskProbe(home: folder.path, volume: volume),
                                                        home: folder.path))
        XCTAssertEqual(text.exit, .partial)
        XCTAssertTrue(text.stdout.contains("Note: Could not count local snapshots"))
    }

    /// A folder replaced between being listed and being opened is not read, with nothing unreadable to count, so the
    /// result is partial with a `scanIncomplete` error rather than complete.
    func testAFolderReplacedDuringTheScanMakesAPartialResult() async throws {
        let folder = try TemporaryFolder()
        for name in ["a", "b", "z"] { try folder.file("\(name)/old", bytes: 10_000) }
        let moved = try TemporaryFolder()
        // The scanner reports the real path (`/private/var/…` for a temporary folder).
        let root = try XCTUnwrap(realpath(folder.path, nil).map { pointer in
            defer { free(pointer) }
            return String(cString: pointer)
        })
        let movedTo = moved.url.appendingPathComponent("b")
        let swapped = OSAllocatedUnfairLock(initialState: false)
        // One worker reports the root's only batch before it opens the folders listed in it.
        let probe = HelperFixtures.diskProbe(home: HelperFixtures.home, onProgress: { progress in
            guard progress.currentPath == root, !swapped.withLock({ $0 }) else { return }
            swapped.withLock { $0 = true }
            let b = URL(fileURLWithPath: root).appendingPathComponent("b")
            try? FileManager.default.moveItem(at: b, to: movedTo)
            try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: false)
        })
        let output = await run(["disk", "--path", folder.path, "--json", "--absolute"], HelperFixtures.environment(disk: probe))
        XCTAssertTrue(swapped.withLock { $0 })
        try assertValid(output, "disk.schema.json")
        XCTAssertEqual(output.exit, .partial)
        let json = try object(output)
        XCTAssertEqual(json["restricted"] as? [String: Int], ["unreadablePaths": 0])
        let errors = try XCTUnwrap(json["errors"] as? [[String: String]])
        XCTAssertEqual(errors.map { $0["code"] }, ["scanIncomplete"], output.stdout)
        XCTAssertTrue(errors.first?["message"]?.hasSuffix("/b changed while the scan read them and were not read; sizes are lower bounds.") ?? false,
                      "\(errors)")
    }

    /// Docker asked for and installed but unreadable is a failed read; Docker not installed, or not asked for, is not.
    func testAFailedDockerReadMakesSuggestionsPartial() async throws {
        let home = try TemporaryFolder()
        try home.file("Documents/notes.txt", bytes: 10)
        func suggestions(_ docker: DockerImageUsage, apps: InstalledApps = InstalledApps([]),
                         path: String? = nil) async throws -> (HelperOutput, [String]) {
            let environment = HelperFixtures.environment(
                disk: HelperFixtures.diskProbe(home: home.path, docker: docker, apps: apps), home: home.path)
            let output = await run(["disk", "--suggestions", "--path", path ?? home.path, "--json"], environment)
            try assertValid(output, "disk-suggestions.schema.json")
            let codes = (try object(output)["errors"] as? [[String: Any]])?.compactMap { $0["code"] as? String } ?? []
            return (output, codes)
        }
        let stopped = DockerImageUsage.unavailable(.daemonNotRunning(message: ""))
        let (failed, failedCodes) = try await suggestions(stopped)
        XCTAssertEqual(failed.exit, .partial)
        XCTAssertEqual(failedCodes, ["dockerUnavailable"])
        XCTAssertEqual((try object(failed)["complete"] as? Bool), false)

        let unreported = DockerImageUsage.reported(DockerImageSpace(count: 1, active: 0, size: 100, reclaimable: nil),
                                                   observedAt: HelperFixtures.observedAt)
        let (partly, partlyCodes) = try await suggestions(unreported)
        XCTAssertEqual(partly.exit, .partial)
        XCTAssertEqual(partlyCodes, ["dockerUnavailable"])

        let (notInstalled, notInstalledCodes) = try await suggestions(.unavailable(.cliNotFound))
        XCTAssertEqual(notInstalled.exit, .ok)
        XCTAssertEqual(notInstalledCodes, [])

        let (notAsked, notAskedCodes) = try await suggestions(stopped, path: home.path + "/Documents")
        XCTAssertEqual(notAsked.exit, .ok)
        XCTAssertEqual(notAskedCodes, [])

        let (unreadApps, unreadAppsCodes) = try await suggestions(.unavailable(.cliNotFound),
                                                                  apps: InstalledApps([], unread: ["/Applications/Locked.app"]))
        XCTAssertEqual(unreadApps.exit, .partial)
        XCTAssertEqual(unreadAppsCodes, ["installedAppsUnread"])
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
