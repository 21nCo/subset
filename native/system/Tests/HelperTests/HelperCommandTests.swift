import Foundation
import SystemHelper
import XCTest

final class HelperCommandTests: XCTestCase {
    func testCommandsParseWithTheirDefaults() throws {
        XCTAssertEqual(try HelperInvocation.parse(["status", "--json"]),
                       HelperInvocation(command: .status, json: true))
        XCTAssertEqual(try HelperInvocation.parse(["processes"]).command, .processes(layer: .app))
        XCTAssertEqual(try HelperInvocation.parse(["processes", "--layer", "launch"]).command,
                       .processes(layer: .launch))
        XCTAssertEqual(try HelperInvocation.parse(["--version"]).command, .version)
    }

    func testUsageErrorsExitTwoWithAMessageAndNoOutput() async {
        let cases: [([String], String)] = [
            ([], "No command given."),
            (["clean"], "Unknown command clean."),
            (["status", "--force"], "Unknown option --force."),
            (["status", "--layer", "app"], "--layer does not apply to status."),
            (["processes", "--layer", "team"], "--layer must be app, vendor, launch, or project, not team."),
            (["status", "extra"], "Unexpected argument extra."),
            // An empty or `=`-only argument is a usage error, not a crash.
            (["status", ""], "An argument is empty."),
            (["status", "="], "Unexpected argument =."),
            (["processes", "--layer"], "--layer needs a value."),
            (["processes", "--layer", "app", "--layer", "vendor"], "--layer is given more than once."),
            (["processes", "--layer="], "--layer must be app, vendor, launch, or project, not ."),
            (["disk", "--path", "/tmp"], "Unknown option --path."),
            (["status", "--json="], "Unknown option --json=.")
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

    /// A message names the home folder bare as often as a path inside it, followed by prose or punctuation.
    func testMessagesRedactTheHomeFolderWhereverItIsAWholePath() {
        let paths = PathDisplay(home: "/Users/me", absolute: false)
        let redacted: [(String, String)] = [
            ("/Users/me was not read in full.", "~ was not read in full."),
            ("/Users/me 22 more places could not be searched in full.", "~ 22 more places could not be searched in full."),
            ("Could not read /Users/me.", "Could not read ~."),
            ("Could not read /Users/me: denied, or (/Users/me), \"/Users/me\"; /Users/me/a and /Users/me",
             "Could not read ~: denied, or (~), \"~\"; ~/a and ~"),
            ("/Users/me/", "~/"),
            ("Cannot connect at unix:///Users/me/.docker/run/docker.sock.", "Cannot connect at unix://~/.docker/run/docker.sock.")
        ]
        for (text, expected) in redacted { XCTAssertEqual(paths.message(text), expected, text) }
        for kept in ["/Users/me2 was not read.", "/Users/me.old was not read.", "/Users/me-x/a", "/Volumes/b/Users/me was not read."] {
            XCTAssertEqual(paths.message(kept), kept)
        }
        let absolute = PathDisplay(home: "/Users/me", absolute: true)
        XCTAssertEqual(absolute.message("/Users/me was not read in full."), "/Users/me was not read in full.")
    }

    /// The validator itself must reject what the schemas forbid, or every passing schema test would prove nothing.
    func testTheValidatorRejectsDocumentsTheSchemasForbid() throws {
        var validator = SchemaValidator()
        let valid = #"{"code": "cpuUnavailable", "message": "m"}"#
        let errorsSchema: [String: Any] = ["$ref": "common.schema.json#/$defs/errors"]
        func errors(_ text: String) throws -> [String] {
            let value = try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
            return try validator.errors(value, schema: errorsSchema)
        }
        XCTAssertEqual(try errors("[\(valid)]"), [])
        XCTAssertFalse(try errors(#"[{"code": "cpuUnavailable"}]"#).isEmpty, "missing message")
        XCTAssertFalse(try errors(#"[{"code": "deleted", "message": "m"}]"#).isEmpty, "unknown code")
        XCTAssertFalse(try errors(#"[{"code": "cpuUnavailable", "message": "m", "extra": 1}]"#).isEmpty, "extra key")
        XCTAssertFalse(try errors(#"[{"code": "cpuUnavailable", "message": 1}]"#).isEmpty, "wrong type")

        XCTAssertFalse(try validator.errors(json: #"{"schemaVersion": 1}"#, schemaFile: "status.schema.json").isEmpty)
        XCTAssertFalse(try validator.errors(json: #"{"schemaVersion": true}"#, schemaFile: "status.schema.json")
            .filter { $0.hasPrefix("$.schemaVersion") }.isEmpty, "true is not the constant 1")
    }
}
