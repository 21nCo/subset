import Foundation
@testable import SystemCore
import SystemDisk
import SystemProcesses
import XCTest

/// What Explain sends for a scanned folder, a leftover, and a suggestion of a fixture scan.
@MainActor
final class DiskExplainTests: XCTestCase {
    private var fixture: DiskFixture!

    override func setUp() async throws {
        fixture = try DiskFixture()
        try fixture.populate()
    }

    override func tearDown() async throws {
        fixture?.remove()
    }

    private var redactor: ExplainRedactor {
        ExplainRedactor(homes: [fixture.home], accountNames: [], sendFolderNames: false, key: Array(repeating: 2, count: 32))
    }

    private func request(_ model: DiskWindowModel, _ id: DiskRowID) throws -> ExplainRequest {
        let request = try XCTUnwrap(model.explainRequest(for: id, redactor: redactor, now: Date()))
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains(fixture.home), json)
        XCTAssertNotNil(model.explainKey(for: id))
        XCTAssertTrue(model.canExplain(id))
        return request
    }

    func testAFolderRequestCarriesItsSizesAgeAndOrigin() async throws {
        let model = try await fixture.scanned()
        let documents = try request(model, try XCTUnwrap(model.row(named: "Documents")).id)
        XCTAssertEqual(documents.kind, .folder)
        XCTAssertEqual(documents.type, "Folder")
        XCTAssertEqual(documents.path, "~/Documents")
        XCTAssertNotNil(documents.sizes)
        XCTAssertEqual(documents.age, "Last changed 0 minutes ago")
        XCTAssertNil(documents.bundleID)

        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Editor")).id)
        let cache = try request(model, try XCTUnwrap(model.row(named: "com.example.editor")).id)
        XCTAssertEqual(cache.kind, .folder)
        XCTAssertEqual(cache.type, "Folder in ~/Library/Caches")
        XCTAssertEqual(cache.path, "~/Library/Caches/com.example.editor")
        XCTAssertEqual(cache.bundleID, "com.example.editor")
        XCTAssertEqual(cache.teamID, "EXAMPLE123")
        XCTAssertEqual(cache.vendor, "Example Ltd")
        XCTAssertEqual(cache.matchedRule, "Named for an installed app's bundle ID: Editor")
        XCTAssertTrue(cache.evidence.contains { $0.hasPrefix("Matches the reclaim rule App caches") }, "\(cache.evidence)")
        XCTAssertFalse(cache.maySuggestOrigin)
    }

    func testALeftoverRequestNamesTheMissingAppsIdentifier() async throws {
        let model = try await fixture.scanned()
        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Leftovers")).id)
        let leftover = try request(model, try XCTUnwrap(model.row(named: "com.gone.app.plist")).id)
        XCTAssertEqual(leftover.kind, .leftover)
        XCTAssertEqual(leftover.bundleID, "com.gone.app")
        XCTAssertEqual(leftover.path, "~/Library/Preferences/com.gone.app.plist")
        XCTAssertEqual(leftover.matchedRule, "Named for a bundle ID no installed app has")
    }

    func testASuggestionRequestCarriesItsRuleAndItems() async throws {
        let model = try await fixture.scanned()
        model.tab = .suggestions
        let derived = try XCTUnwrap(model.row(named: "Xcode DerivedData"))
        let suggestion = try request(model, derived.id)
        XCTAssertEqual(suggestion.kind, .suggestion)
        XCTAssertEqual(suggestion.name, "Xcode DerivedData")
        XCTAssertEqual(suggestion.type, "Safe to reclaim suggestion")
        XCTAssertEqual(suggestion.matchedRule?.hasPrefix("Xcode DerivedData: "), true)
        XCTAssertEqual(suggestion.members, [redactor.placeholder("App-abc")], "a project's name is a folder name")
        XCTAssertEqual(suggestion.evidence.first, "Location: ~/Library/Developer/Xcode/DerivedData")
        XCTAssertNil(suggestion.path)
        let named = try XCTUnwrap(model.explainRequest(for: derived.id, redactor: redactor.sendingFolderNames(true)))
        XCTAssertEqual(named.members, ["App-abc"])

        model.toggle(derived.id)
        let item = try request(model, try XCTUnwrap(model.row(named: "App-abc")).id)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertTrue(item.evidence.contains { $0.hasPrefix("Matches the reclaim rule Xcode DerivedData") })
    }

    func testGroupsAndShowMoreRowsAreNotExplained() async throws {
        let model = try await fixture.scanned(rowLimit: 1)
        let more = try XCTUnwrap(model.rows.first(where: \.isMore))
        XCTAssertNil(model.explainKey(for: more.id))
        XCTAssertFalse(model.canExplain(more.id))
        XCTAssertNil(model.explainRequest(for: more.id, redactor: redactor))
        model.tab = .origins
        let group = try XCTUnwrap(model.row(named: "Editor"))
        XCTAssertNil(model.explainKey(for: group.id))
        XCTAssertFalse(model.canExplain(group.id))
        XCTAssertNil(model.explainRequest(for: group.id, redactor: redactor))
    }
}
