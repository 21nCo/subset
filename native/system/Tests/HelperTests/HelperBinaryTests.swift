import Foundation
import XCTest

/// Runs the built `subset-system` executable, as an agent would, and validates what it prints. The binary is the one
/// next to this test bundle (`swift test`, `xcodebuild test`), or the one `SUBSET_SYSTEM_HELPER` names, such as the
/// copy inside the built app's `Contents/Helpers`.
final class HelperBinaryTests: XCTestCase {
    private func helper() throws -> URL {
        if let path = ProcessInfo.processInfo.environment["SUBSET_SYSTEM_HELPER"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        let products = Bundle(for: Self.self).bundleURL.deletingLastPathComponent()
        let binary = products.appendingPathComponent("subset-system")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw ValidationSetupError("No built subset-system at \(binary.path); build it or set SUBSET_SYSTEM_HELPER.")
        }
        return binary
    }

    private func execute(_ arguments: [String]) throws -> (stdout: String, stderr: String, status: Int32) {
        let process = Process()
        process.executableURL = try helper()
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Read before waiting, so a full pipe never stalls the helper.
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let errors = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: output, as: UTF8.self), String(decoding: errors, as: UTF8.self), process.terminationStatus)
    }

    func testStatusJSONFromTheBuiltHelperValidates() throws {
        let result = try execute(["status", "--json"])
        // Other users' processes are restricted for a normal user, which makes the result partial.
        XCTAssertTrue([0, 3].contains(result.status), "exit \(result.status): \(result.stderr)")
        var validator = SchemaValidator()
        XCTAssertEqual(try validator.errors(json: result.stdout, schemaFile: "status.schema.json"), [])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["command"] as? String, "status")
        XCTAssertGreaterThan((json["topByMemory"] as? [Any])?.count ?? 0, 0)
    }

    func testProcessesJSONFromTheBuiltHelperValidates() throws {
        let result = try execute(["processes", "--layer", "vendor", "--json"])
        XCTAssertTrue([0, 3].contains(result.status), "exit \(result.status): \(result.stderr)")
        var validator = SchemaValidator()
        XCTAssertEqual(try validator.errors(json: result.stdout, schemaFile: "processes.schema.json"), [])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        XCTAssertEqual(json["layer"] as? String, "vendor")
        XCTAssertGreaterThan((json["groups"] as? [Any])?.count ?? 0, 0)
    }

    func testDiskJSONFromTheBuiltHelperValidates() throws {
        let folder = try TemporaryFolder()
        try folder.file("a/b.bin", bytes: 8192)
        try folder.file("c.txt", bytes: 10)
        let result = try execute(["disk", "--path", folder.path, "--json"])
        // Volume or snapshot details can be unavailable on the machine, which makes the result partial.
        XCTAssertTrue([0, 3].contains(result.status), "exit \(result.status): \(result.stderr)")
        var validator = SchemaValidator()
        XCTAssertEqual(try validator.errors(json: result.stdout, schemaFile: "disk.schema.json"), [])
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any])
        let codes = (json["errors"] as? [[String: Any]] ?? []).compactMap { $0["code"] as? String }
        if result.status == 3 {
            // The fixture itself is readable, so only the machine's volume details can be missing.
            XCTAssertFalse(codes.isEmpty)
            XCTAssertEqual(codes.filter { !["volumeUnavailable", "snapshotsUnavailable"].contains($0) }, [], "\(codes)")
        } else {
            XCTAssertEqual(codes, [])
        }
        let tree = try XCTUnwrap(json["tree"] as? [String: Any])
        XCTAssertEqual(tree["kind"] as? String, "directory")
        XCTAssertGreaterThan(tree["allocatedBytes"] as? Int ?? 0, 0)
        let children = (tree["children"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
        XCTAssertEqual(Set(children), ["a", "c.txt"])
    }

    func testTheBuiltHelperReportsUsageErrorsAndItsVersion() throws {
        let usage = try execute(["clean"])
        XCTAssertEqual(usage.status, 2)
        XCTAssertEqual(usage.stdout, "")
        XCTAssertTrue(usage.stderr.contains("Unknown command clean."))
        XCTAssertEqual(try execute(["--version"]).stdout, "subset-system 0.1.0\n")
        // The copy bundled in the app prints the app's version.
        let helpers = try helper().deletingLastPathComponent()
        if helpers.lastPathComponent == "Helpers" {
            let info = try XCTUnwrap(NSDictionary(contentsOf: helpers.deletingLastPathComponent().appendingPathComponent("Info.plist")))
            XCTAssertEqual(try execute(["--version"]).stdout, "subset-system \(info["CFBundleShortVersionString"] ?? "")\n")
        }
    }
}
