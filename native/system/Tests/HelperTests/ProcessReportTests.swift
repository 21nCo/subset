import Foundation
import SystemCore
import SystemHelper
import XCTest

final class ProcessReportTests: XCTestCase {
    func testStatusReportsMemoryCPUAndTheTenLargestAppGroupsEach() async throws {
        let output = await run(["status", "--json"], HelperFixtures.environment(
            processes: HelperFixtures.probe(HelperFixtures.workload(restricted: false))))
        try assertValid(output, "status.schema.json")
        XCTAssertEqual(output.exit, .ok)
        let json = try object(output)
        XCTAssertEqual(json["complete"] as? Bool, true)
        XCTAssertEqual(json["observedAt"] as? String, "2027-01-15T08:00:00.000Z")
        XCTAssertEqual(json["restricted"] as? [String: Int], ["processes": 0])
        let cpu = try XCTUnwrap(json["cpu"] as? [String: Any])
        // 200 busy ticks of 800 between the two readings.
        XCTAssertEqual(cpu["percent"] as? Double, 25)
        let memory = try XCTUnwrap(json["memory"] as? [String: Any])
        XCTAssertEqual(memory["pressure"] as? String, "normal")
        XCTAssertEqual(memory["swapUsedBytes"] as? Int, 1 << 30)
        XCTAssertEqual(memory["compressedBytes"] as? Int, 1000 * 4096)
        XCTAssertEqual(memory["usedBytes"] as? Int, (4000 + 2000 + 1000) * 4096)

        let byCPU = try XCTUnwrap(json["topByCPU"] as? [[String: Any]])
        XCTAssertEqual(byCPU.count, 10)
        XCTAssertEqual(byCPU.map { $0["name"] as? String }.prefix(3), ["App1", "App2", "App3"])
        XCTAssertEqual(byCPU.first?["cpuPercent"] as? Double, 12)
        let byMemory = try XCTUnwrap(json["topByMemory"] as? [[String: Any]])
        XCTAssertEqual(byMemory.count, 10)
        XCTAssertEqual(byMemory.first?["id"] as? String, "app:/Applications/App12.app")
        XCTAssertEqual(byMemory.first?["memoryBytes"] as? Int, 1200 * Int(HelperFixtures.mib))
    }

    func testRestrictedProcessesMakeAPartialResultThatStillValidates() async throws {
        let output = await run(["status", "--json"], HelperFixtures.environment())
        try assertValid(output, "status.schema.json")
        XCTAssertEqual(output.exit, .partial)
        let json = try object(output)
        XCTAssertEqual(json["complete"] as? Bool, false)
        XCTAssertEqual(json["restricted"] as? [String: Int], ["processes": 2])
        XCTAssertEqual((json["errors"] as? [Any])?.count, 0)

        let text = await run(["status"], HelperFixtures.environment())
        XCTAssertEqual(text.exit, .partial)
        XCTAssertTrue(text.stdout.contains("2 processes are restricted by macOS; their usage is not in any total."))
        XCTAssertTrue(text.stdout.hasPrefix("CPU: 25.0% of"))
    }

    func testUnreadableCPUAndMemoryAreNullWithErrorsNotZero() async throws {
        let probe = HelperFixtures.probe(HelperFixtures.workload(restricted: false), ticks: false,
                                         memory: HelperFixtures.unreadableMemory)
        let output = await run(["status", "--json"], HelperFixtures.environment(processes: probe))
        try assertValid(output, "status.schema.json")
        XCTAssertEqual(output.exit, .partial)
        let json = try object(output)
        XCTAssertTrue((json["cpu"] as? [String: Any])?["percent"] is NSNull)
        XCTAssertTrue((json["memory"] as? [String: Any])?["pressure"] is NSNull)
        XCTAssertTrue((json["memory"] as? [String: Any])?["swapUsedBytes"] is NSNull)
        let codes = (json["errors"] as? [[String: Any]])?.compactMap { $0["code"] as? String }
        XCTAssertEqual(codes, ["cpuUnavailable", "memoryUnavailable"])
    }

    /// A process whose usage read failed without macOS restricting it is not restricted, but its usage is unknown, so
    /// the result is partial with an error rather than complete.
    func testAFailedUsageReadOfAnUnrestrictedProcessIsAPartialResult() async throws {
        var processes = HelperFixtures.workload(restricted: false)
        let complete = await run(["status", "--json"], HelperFixtures.environment(processes: HelperFixtures.probe(processes)))
        XCTAssertEqual(complete.exit, .ok)

        processes.append(HelperProcess(pid: 500, path: "/Applications/Gone.app/Contents/MacOS/Gone", memory: nil))
        for command in [["status", "--json"], ["processes", "--json"]] {
            let output = await run(command, HelperFixtures.environment(processes: HelperFixtures.probe(processes)))
            try assertValid(output, command[0] == "status" ? "status.schema.json" : "processes.schema.json")
            XCTAssertEqual(output.exit, .partial, "\(command)")
            let json = try object(output)
            XCTAssertEqual(json["complete"] as? Bool, false)
            XCTAssertEqual(json["restricted"] as? [String: Int], ["processes": 0])
            XCTAssertEqual((json["errors"] as? [[String: Any]])?.compactMap { $0["code"] as? String }, ["usageUnavailable"])
        }
    }

    func testAFailedProcessListIsAnInternalErrorThatStillValidates() async throws {
        let probe = HelperFixtures.probe([], listFails: true)
        for (arguments, schema) in [(["status", "--json"], "status.schema.json"), (["processes", "--json"], "processes.schema.json")] {
            let output = await run(arguments, HelperFixtures.environment(processes: probe))
            try assertValid(output, schema)
            XCTAssertEqual(output.exit, .internalError)
            XCTAssertEqual(output.exit.rawValue, 5)
            let json = try object(output)
            XCTAssertTrue(json["processCount"] is NSNull)
            XCTAssertEqual((json["errors"] as? [[String: Any]])?.first?["code"] as? String, "processListFailed")
        }
    }

    func testEveryLayerWithoutRestrictedProcessesIsACompleteResult() async throws {
        for layer in HelperLayer.allCases {
            let output = await run(["processes", "--layer", layer.rawValue, "--json"], HelperFixtures.environment(
                processes: HelperFixtures.probe(HelperFixtures.workload(restricted: false))))
            try assertValid(output, "processes.schema.json")
            XCTAssertEqual(output.exit, .ok, layer.rawValue)
            let json = try object(output)
            XCTAssertEqual(json["complete"] as? Bool, true, layer.rawValue)
            XCTAssertEqual(json["restricted"] as? [String: Int], ["processes": 0], layer.rawValue)
            XCTAssertEqual((json["errors"] as? [Any])?.count, 0, layer.rawValue)
            XCTAssertFalse((json["groups"] as? [Any])?.isEmpty ?? true, layer.rawValue)
        }
    }

    func testEveryLayerValidatesWithMembersAndTheirRule() async throws {
        for layer in HelperLayer.allCases {
            let output = await run(["processes", "--layer", layer.rawValue, "--json"], HelperFixtures.environment())
            try assertValid(output, "processes.schema.json")
            XCTAssertEqual(output.exit, .partial, layer.rawValue)
            let json = try object(output)
            XCTAssertEqual(json["layer"] as? String, layer.rawValue)
            let groups = try XCTUnwrap(json["groups"] as? [[String: Any]])
            let members = groups.flatMap { $0["members"] as? [[String: Any]] ?? [] }
            XCTAssertEqual(members.count, 16, layer.rawValue)
            XCTAssertTrue(members.allSatisfy { $0["rule"] is String && $0["confidence"] is String }, layer.rawValue)
        }
    }

    func testProcessPathsUseATildeForTheHomeFolderUnlessAbsolute() async throws {
        let output = await run(["processes", "--layer", "project", "--json"], HelperFixtures.environment())
        let groups = try XCTUnwrap(try object(output)["groups"] as? [[String: Any]])
        let project = try XCTUnwrap(groups.first { $0["kind"] as? String == "project" })
        XCTAssertEqual(project["id"] as? String, "project:~/dev/project")
        XCTAssertEqual(project["path"] as? String, "~/dev/project")
        XCTAssertEqual((project["members"] as? [[String: Any]])?.first?["executable"] as? String, "~/bin/tool")
        XCTAssertFalse(output.stdout.contains("/Users/me"))

        let absolute = await run(["processes", "--layer", "project", "--json", "--absolute"], HelperFixtures.environment())
        XCTAssertTrue(absolute.stdout.contains("\"path\": \"/Users/me/dev/project\""))
        XCTAssertTrue(absolute.stdout.contains("\"executable\": \"/Users/me/bin/tool\""))

        let apps = await run(["processes", "--json"], HelperFixtures.environment())
        XCTAssertTrue(apps.stdout.contains("\"id\": \"app:~/Applications/Local.app\""))
    }
}
