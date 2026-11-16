import Foundation
@testable import SubsetCore
import XCTest

/// The feed and receipt readers against the contract fixtures in packages/catalog/feed/fixtures, which the `subset`
/// command's tests read too, so both readers accept and refuse the same files.
final class CatalogFeedTests: XCTestCase {
    static let feedFolder = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../packages/catalog/feed").standardized

    private func fixtures(_ prefix: String) throws -> [URL] {
        let folder = Self.feedFolder.appendingPathComponent("fixtures")
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func name(_ url: URL) -> String { url.deletingPathExtension().lastPathComponent }

    // Each refused fixture names the part of the document that is wrong. A new invalid fixture needs a line here.
    private let catalogReasons = [
        "catalog-invalid-dot-segment": "/apps/0/channels/live/url: does not match",
        "catalog-invalid-duplicate-app": "app id \"breaks\" appears more than once",
        "catalog-invalid-impossible-date": "/generatedAt: does not match",
        "catalog-invalid-missing-sha256": "/apps/0/channels/beta: missing required property \"sha256\"",
        "catalog-invalid-oversize": "the feed is larger than 262144 bytes",
        "catalog-invalid-unknown-field": "/apps/0: unknown property",
        "catalog-invalid-wrong-host": "/apps/0/channels/live/url: does not match",
        "catalog-invalid-wrong-schema": "/schema: must be \"subset.catalog@1\""
    ]

    private let receiptReasons = [
        "receipt-invalid-beta-without-build": "a beta receipt must have a build",
        "receipt-invalid-control-character": "/path: does not match",
        "receipt-invalid-impossible-date": "/installedAt: does not match",
        "receipt-invalid-live-with-build": "/build: a live receipt must not have a build",
        "receipt-invalid-other-applications-folder": "/path: does not match",
        "receipt-invalid-parent-segment": "/path: does not match",
        "receipt-invalid-relative-path": "/path: does not match",
        "receipt-invalid-unknown-field": "/: unknown property"
    ]

    func testEveryValidCatalogFixtureDecodes() throws {
        let valid = try fixtures("catalog-valid-")
        XCTAssertEqual(valid.map(name), ["catalog-valid-live-and-beta", "catalog-valid-live-only", "catalog-valid-tools-only"])
        for file in valid {
            if case .failure(let refusal) = Catalog.parse(try Data(contentsOf: file)) {
                XCTFail("\(name(file)) is refused: \(refusal.problems)")
            }
        }
    }

    func testTheLiveAndBetaFixtureDecodesEveryField() throws {
        let file = Self.feedFolder.appendingPathComponent("fixtures/catalog-valid-live-and-beta.json")
        let catalog = try Catalog.parse(try Data(contentsOf: file)).get()
        XCTAssertEqual(catalog.generatedAt, "2026-11-12T00:00:00Z")
        XCTAssertEqual(catalog.apps.map(\.id), ["breaks", "timer"])
        let breaks = catalog.apps[0]
        XCTAssertEqual(breaks.bundleID, "dev.subset.breaks")
        XCTAssertEqual(breaks.appName, "Breaks")
        XCTAssertEqual(breaks.live?.version, "0.1.0")
        XCTAssertEqual(breaks.live?.releaseURL, "https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0")
        XCTAssertEqual(breaks.beta?.label, "0.1.1-beta.4")
        let timer = catalog.apps[1]
        XCTAssertNil(timer.live)
        XCTAssertEqual(timer.beta?.build, 2)
        XCTAssertEqual(timer.helpers, [CatalogHelper(command: "timer", path: "Contents/Resources/timer-cli/dist/cli.mjs", kind: "node")])
        XCTAssertEqual(catalog.tools.map(\.id), ["usage"])
        XCTAssertEqual(catalog.tools[0].beta, "0.2.1-beta.1")
    }

    func testEveryInvalidCatalogFixtureIsRefusedWithItsReason() throws {
        let invalid = try fixtures("catalog-invalid-")
        XCTAssertEqual(Set(invalid.map(name)), Set(catalogReasons.keys), "every invalid fixture needs an expected reason")
        for file in invalid {
            assertRefused(Catalog.parse(try Data(contentsOf: file)), name(file), because: catalogReasons[name(file)] ?? "")
        }
    }

    func testEveryValidReceiptFixtureDecodes() throws {
        let valid = try fixtures("receipt-valid-")
        XCTAssertEqual(valid.map(name), ["receipt-valid-beta", "receipt-valid-live"])
        let beta = try Receipt.parse(try Data(contentsOf: valid[0])).get()
        XCTAssertEqual(beta.channel, .beta)
        XCTAssertEqual(beta.build, 2)
        XCTAssertEqual(beta.path, "/Users/alex/Applications/Timer.app")
        let live = try Receipt.parse(try Data(contentsOf: valid[1])).get()
        XCTAssertEqual(live.channel, .live)
        XCTAssertNil(live.build)
    }

    func testEveryInvalidReceiptFixtureIsRefusedWithItsReason() throws {
        let invalid = try fixtures("receipt-invalid-")
        XCTAssertEqual(Set(invalid.map(name)), Set(receiptReasons.keys), "every invalid fixture needs an expected reason")
        for file in invalid {
            assertRefused(Receipt.parse(try Data(contentsOf: file)), name(file), because: receiptReasons[name(file)] ?? "")
        }
    }

    /// The Swift patterns are the schemas' patterns, with \d spelled [0-9], so a schema change fails here.
    func testPatternsAreTheSchemasPatterns() throws {
        var patterns = Set<String>()
        func collect(_ value: Any) {
            if let object = value as? [String: Any] {
                if let pattern = object["pattern"] as? String { patterns.insert(pattern) }
                object.values.forEach(collect)
            } else if let array = value as? [Any] {
                array.forEach(collect)
            }
        }
        for schema in ["catalog.schema.json", "receipt.schema.json"] {
            collect(try JSONSerialization.jsonObject(with: Data(contentsOf: Self.feedFolder.appendingPathComponent(schema))))
        }
        let ascii = Set(patterns.map { $0.replacingOccurrences(of: #"\d"#, with: "[0-9]") })
        XCTAssertEqual(ascii, Set(FeedPattern.allCases.map(\.rawValue)))
    }

    /// Differences between ICU and JavaScript regular expressions that would let a value through.
    func testPatternsMatchAsJavaScriptDoes() {
        XCTAssertTrue(FeedPattern.version.matches("0.1.0"))
        XCTAssertFalse(FeedPattern.version.matches("0.1.0\n"), "ICU's $ matches before a final line break")
        XCTAssertFalse(FeedPattern.version.matches("٠.١.٠"), "ICU's \\d matches Arabic-Indic digits")
        XCTAssertTrue(FeedPattern.nodeHelperPath.matches("Contents/cli.mjs"))
        XCTAssertFalse(FeedPattern.nodeHelperPath.matches("Contents/cli.mjs.txt"))
    }

    func testValuesOfTheWrongJSONTypeAreRefused() throws {
        let file = Self.feedFolder.appendingPathComponent("fixtures/catalog-valid-live-and-beta.json")
        let text = try String(contentsOf: file, encoding: .utf8)
        let cases = [
            ("\"build\": 4", "\"build\": true", "/apps/0/channels/beta/build: must be an integer"),
            ("\"build\": 4", "\"build\": \"4\"", "/apps/0/channels/beta/build: must be an integer"),
            ("\"build\": 4", "\"build\": 4.5", "/apps/0/channels/beta/build: must be an integer from 1 to 999999999"),
            ("\"build\": 4", "\"build\": 0", "/apps/0/channels/beta/build: must be an integer from 1 to 999999999"),
            ("\"helpers\": []", "\"helpers\": {}", "/apps/0/helpers: must be an array")
        ]
        for (original, replacement, reason) in cases {
            let changed = text.replacingOccurrences(of: original, with: replacement)
            XCTAssertNotEqual(changed, text)
            assertRefused(Catalog.parse(Data(changed.utf8)), replacement, because: reason)
        }
        XCTAssertNoThrow(try Catalog.parse(Data(text.replacingOccurrences(of: "\"build\": 4", with: "\"build\": 4.0").utf8)).get())
    }

    func testEmptyChannelsAndNonJSONAreRefused() {
        let app = #"{"id":"a","name":"A","summary":"S","appName":"A","bundleId":"dev.a","helpers":[],"channels":{}}"#
        let feed = #"{"schema":"subset.catalog@1","generatedAt":"2026-11-12T00:00:00Z","apps":[\#(app)],"tools":[]}"#
        assertRefused(Catalog.parse(Data(feed.utf8)), "empty channels", because: "/apps/0/channels: must have at least 1 property")
        assertRefused(Catalog.parse(Data("{".utf8)), "truncated", because: "not JSON")
        assertRefused(Catalog.parse(Data([0xEF, 0xBB, 0xBF] + Array("{}".utf8))), "byte order mark", because: "byte order mark")
        assertRefused(Catalog.parse(Data([0x22, 0xFF, 0x22])), "not UTF-8", because: "not UTF-8")
    }

    // JSONSerialization reads all of these; `subset` (TextDecoder with fatal, then JSON.parse) refuses each.
    func testAFeedThatOnlyFoundationWouldReadIsRefused() throws {
        let text = String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self)
        XCTAssertNoThrow(try Catalog.parse(Data(text.utf8)).get())
        for (label, data, reason) in lenientVariants(of: text, property: "\"schema\": \"subset.catalog@0\"") {
            assertRefused(Catalog.parse(data), label, because: reason)
        }
        let array = text.replacingOccurrences(of: "}\n  ],\n  \"tools\"", with: "},\n  ],\n  \"tools\"")
        XCTAssertNotEqual(array, text)
        assertRefused(Catalog.parse(Data(array.utf8)), "a trailing comma in an array", because: "not JSON: a trailing comma")
    }

    // JSON.parse keeps an unpaired surrogate in the string, so subset reads these; the app refuses them on purpose (see
    // StrictJSON), with its own reason rather than whatever Foundation says.
    func testAnUnpairedSurrogateEscapeIsRefusedAndAPairIsRead() throws {
        let text = String(decoding: try fixture("catalog-valid-live-only"), as: UTF8.self)
        for lone in [#"\ud800"#, #"\udc00"#, #"\uDBFF\u0041"#, #"\udc00\ud800"#, #"\ud800\n"#] {
            let changed = text.replacingOccurrences(of: "Take well-timed", with: "Take \(lone) well-timed")
            XCTAssertNotEqual(changed, text)
            assertRefused(Catalog.parse(Data(changed.utf8)), lone, because: "not JSON: an unpaired surrogate escape")
        }
        let ending = text.replacingOccurrences(of: "on-device history.", with: #"on-device history.\ud800"#)
        XCTAssertNotEqual(ending, text)
        assertRefused(Catalog.parse(Data(ending.utf8)), "at the end", because: "not JSON: an unpaired surrogate escape")
        let paired = text.replacingOccurrences(of: "Take well-timed", with: #"Take \ud83d\uDE00 well-timed"#)
        XCTAssertNotEqual(paired, text)
        XCTAssertEqual(try Catalog.parse(Data(paired.utf8)).get().apps.first?.summary.hasPrefix("Take \u{1F600} well-timed"), true)

        let receipt = String(decoding: try fixture("receipt-valid-live"), as: UTF8.self)
        let loneReceipt = receipt.replacingOccurrences(of: "Breaks.app", with: #"Breaks\ud800.app"#)
        XCTAssertNotEqual(loneReceipt, receipt)
        assertRefused(Receipt.parse(Data(loneReceipt.utf8)), "a receipt", because: "not JSON: an unpaired surrogate escape")
    }

    func testAReceiptThatOnlyFoundationWouldReadIsRefused() throws {
        let text = String(decoding: try fixture("receipt-valid-live"), as: UTF8.self)
        for (label, data, reason) in lenientVariants(of: text, property: "\"channel\": \"gamma\"") {
            assertRefused(Receipt.parse(data), label, because: reason)
        }
        // subset skips a byte order mark at the start of a receipt (but not of a feed).
        XCTAssertNoThrow(try Receipt.parse(Data([0xEF, 0xBB, 0xBF] + Array(text.utf8))).get())
    }

    private func assertRefused<T>(_ result: Result<T, FeedRefusal>, _ label: String, because reason: String, line: UInt = #line) {
        switch result {
        case .success: XCTFail("\(label) is accepted", line: line)
        case .failure(let refusal):
            XCTAssertTrue(
                refusal.problems.contains { $0.contains(reason) }, "\(label): \(refusal.problems) lacks \(reason)", line: line
            )
        }
    }
}

/// `text` (a valid document, an object) changed in ways JSONSerialization still reads and `subset` refuses, each with
/// the reason it is refused. `property` is a member that would make the document invalid: added again after its valid
/// spelling, JSONSerialization would keep the first value and JSON.parse the last.
func lenientVariants(of text: String, property: String) -> [(String, Data, String)] {
    let body = text.trimmingCharacters(in: .whitespacesAndNewlines).dropLast()
    // The first character of the property name (ASCII in every caller), written as a \u escape.
    let first = property.unicodeScalars.dropFirst().first!
    let escaped = "\"" + String(format: "\\u%04x", first.value) + property.dropFirst(2)
    XCTAssertTrue(property.hasPrefix("\"") && first.isASCII, "\(property) does not start with an ASCII name")
    XCTAssertNotEqual(escaped, property, "the escaped variant must differ from the plain one")
    return [
        ("a trailing comma in an object", Data((body + ",}").utf8), "not JSON: a trailing comma"),
        ("a property given twice", Data((body + ",\(property)}").utf8), "appears twice"),
        ("a property given twice, once escaped", Data((body + ",\(escaped)}").utf8), "appears twice"),
        ("a NUL byte after it", Data((text + "\u{0}").utf8), "not JSON: unexpected byte 0x00"),
        ("a NUL byte in a string", Data(text.replacingOccurrences(of: "live", with: "li\u{0}ve").utf8), "not JSON: a control character"),
        ("UTF-16LE", text.data(using: .utf16LittleEndian)!, "not JSON"),
        ("UTF-16BE", text.data(using: .utf16BigEndian)!, "not JSON"),
        ("UTF-32LE", text.data(using: .utf32LittleEndian)!, "not JSON"),
        ("UTF-32BE", text.data(using: .utf32BigEndian)!, "not JSON")
    ]
}
