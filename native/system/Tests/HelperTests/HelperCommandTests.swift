import Foundation
import SystemHelper
import XCTest

final class HelperCommandTests: XCTestCase {
    private let home = HelperFixtures.home

    func testCommandsParseWithTheirDefaults() throws {
        XCTAssertEqual(try HelperInvocation.parse(["status", "--json"], home: home),
                       HelperInvocation(command: .status, json: true))
        XCTAssertEqual(try HelperInvocation.parse(["processes"], home: home).command, .processes(layer: .app))
        XCTAssertEqual(try HelperInvocation.parse(["processes", "--layer", "launch"], home: home).command,
                       .processes(layer: .launch))
        XCTAssertEqual(try HelperInvocation.parse(["disk", "--path", "/tmp"], home: home).command,
                       .disk(path: "/tmp", depth: 1, timeout: .seconds(60)))
        XCTAssertEqual(try HelperInvocation.parse(["disk", "--path=~/dev", "--depth", "3", "--timeout", "1.5"], home: home).command,
                       .disk(path: "/Users/me/dev", depth: 3, timeout: .milliseconds(1500)))
        XCTAssertEqual(try HelperInvocation.parse(["disk", "--suggestions", "--path", "~", "--absolute"], home: home),
                       HelperInvocation(command: .suggestions(path: "/Users/me", timeout: .seconds(60)), absolute: true))
        XCTAssertEqual(try HelperInvocation.parse(["--version"], home: home).command, .version)
    }

    func testUsageErrorsExitTwoWithAMessageAndNoOutput() async {
        let cases: [([String], String)] = [
            ([], "No command given."),
            (["clean"], "Unknown command clean."),
            (["status", "--force"], "Unknown option --force."),
            (["status", "--path", "/tmp"], "--path does not apply to status."),
            (["processes", "--layer", "team"], "--layer must be app, vendor, launch, or project, not team."),
            (["disk"], "disk needs --path <dir>."),
            (["disk", "--path"], "--path needs a value."),
            (["disk", "--path", "/a", "--path", "/b"], "--path is given more than once."),
            (["disk", "--path", "/tmp", "--depth", "-1"], "--depth must be a whole number from 0 to 64, not -1."),
            (["disk", "--path", "/tmp", "--depth", "x"], "--depth must be a whole number from 0 to 64, not x."),
            (["disk", "--path", "/tmp", "--timeout", "0"], "--timeout must be a number of seconds above 0, not 0."),
            (["disk", "--suggestions", "--path", "/tmp", "--depth", "2"], "--depth does not apply to disk --suggestions."),
            (["status", "extra"], "Unexpected argument extra.")
        ]
        for (arguments, message) in cases {
            let output = await run(arguments, HelperFixtures.environment())
            XCTAssertEqual(output.exit, .usage, "\(arguments)")
            XCTAssertEqual(output.exit.rawValue, 2)
            XCTAssertEqual(output.stdout, "", "\(arguments)")
            XCTAssertEqual(output.stderr, "subset-system: \(message)\nRun subset-system --help for usage.\n", "\(arguments)")
        }
    }

    func testVersionAndHelpExitZero() async throws {
        let version = await run(["--version"], HelperFixtures.environment())
        XCTAssertEqual(version.exit, .ok)
        XCTAssertEqual(version.stdout, "subset-system 0.1.0\n")

        let help = await run(["--help"], HelperFixtures.environment())
        XCTAssertEqual(help.exit, .ok)
        XCTAssertTrue(help.stdout.contains("Exit codes: 0 ok, 2 usage error, 3 partial result, 4 timeout, 5 internal error."))
    }

    func testExitCodesAreTheDocumentedOnes() {
        XCTAssertEqual([HelperExit.ok, .usage, .partial, .timeout, .internalError].map(\.rawValue), [0, 2, 3, 4, 5])
    }

    func testHomeFolderPathsPrintWithATildeUnlessAbsolute() {
        let paths = PathDisplay(home: "/Users/me", absolute: false)
        XCTAssertEqual(paths("/Users/me"), "~")
        XCTAssertEqual(paths("/Users/me/dev/a"), "~/dev/a")
        XCTAssertEqual(paths("/Users/me2/dev"), "/Users/me2/dev")
        XCTAssertEqual(paths("/Applications/A.app"), "/Applications/A.app")
        XCTAssertEqual(PathDisplay(home: "/Users/me", absolute: true)("/Users/me/dev"), "/Users/me/dev")
    }

    /// The validator itself must reject what the schemas forbid, or every passing schema test would prove nothing.
    func testTheValidatorRejectsDocumentsTheSchemasForbid() throws {
        var validator = SchemaValidator()
        let valid = #"{"code": "timedOut", "message": "m"}"#
        let errorsSchema: [String: Any] = ["$ref": "common.schema.json#/$defs/errors"]
        func errors(_ text: String) throws -> [String] {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return try validator.errors(value, schema: errorsSchema)
        }
        XCTAssertEqual(try errors("[\(valid)]"), [])
        XCTAssertFalse(try errors(#"[{"code": "timedOut"}]"#).isEmpty, "missing message")
        XCTAssertFalse(try errors(#"[{"code": "deleted", "message": "m"}]"#).isEmpty, "unknown code")
        XCTAssertFalse(try errors(#"[{"code": "timedOut", "message": "m", "extra": 1}]"#).isEmpty, "extra key")
        XCTAssertFalse(try errors(#"[{"code": "timedOut", "message": 1}]"#).isEmpty, "wrong type")

        XCTAssertFalse(try validator.errors(json: #"{"schemaVersion": 1}"#, schemaFile: "status.schema.json").isEmpty)
        XCTAssertFalse(try validator.errors(json: #"{"schemaVersion": true}"#, schemaFile: "status.schema.json")
            .filter { $0.hasPrefix("$.schemaVersion") }.isEmpty, "true is not the constant 1")
    }
}
