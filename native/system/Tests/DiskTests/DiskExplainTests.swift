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
        XCTAssertEqual(cache.path, "~/Library/Caches/\(redactor.placeholder("com.example.editor"))")
        XCTAssertEqual(cache.name, redactor.placeholder("com.example.editor"), "named as its path is sent")
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
        XCTAssertEqual(leftover.path, "~/Library/Preferences/\(redactor.placeholder("com.gone.app.plist"))")
        XCTAssertEqual(leftover.name, redactor.placeholder("com.gone.app.plist"))
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
        XCTAssertEqual(suggestion.evidence.first, "Location: ~/Library/Developer/\(redactor.placeholder("Xcode"))/"
            + redactor.placeholder("DerivedData"))
        XCTAssertNil(suggestion.path)
        let named = try XCTUnwrap(model.explainRequest(for: derived.id, redactor: redactor.sendingFolderNames(true)))
        XCTAssertEqual(named.members, ["App-abc"])

        model.toggle(derived.id)
        let item = try request(model, try XCTUnwrap(model.row(named: "App-abc")).id)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertTrue(item.evidence.contains { $0.hasPrefix("Matches the reclaim rule Xcode DerivedData") })
    }

    func testWithFolderNamesOffNoRequestCarriesAFolderNameDeeperThanTheFirstLevel() async throws {
        try fixture.write("dev/Acme Merger/package.json", bytes: 100)
        try fixture.lock("dev/Acme Merger/webclient")
        let model = try await fixture.scanned()
        model.tab = .suggestions
        let stale = try XCTUnwrap(model.row(named: "Stale node_modules")).id
        model.tab = .folders
        model.open(try XCTUnwrap(model.row(named: "dev")).id)
        let project = try XCTUnwrap(model.row(named: "Acme Merger")).id
        model.navigate(to: model.breadcrumbs[0].id)
        model.open(try XCTUnwrap(model.row(named: "Documents")).id)
        let sub = try XCTUnwrap(model.row(named: "Sub")).id

        for (id, name) in [(project, "Acme Merger"), (sub, "Sub")] {
            let request = try request(model, id)
            XCTAssertEqual(request.name, redactor.placeholder(name))
            XCTAssertEqual(request.path?.split(separator: "/").last.map(String.init), redactor.placeholder(name))
            let text = try sent(request)
            XCTAssertFalse(text.contains(name), text)
            let named = try XCTUnwrap(model.explainRequest(for: id, redactor: redactor.sendingFolderNames(true)))
            XCTAssertEqual(named.name, name)
        }

        // A suggestion not measured because a folder in a project could not be read names that folder's path.
        model.tab = .suggestions
        let suggestion = try request(model, stale)
        let reason = try XCTUnwrap(suggestion.sizes)
        XCTAssertEqual(reason, "Not measured: ~/dev/\(redactor.placeholder("Acme Merger"))/"
            + "\(redactor.placeholder("webclient")) could not be read.")
        let text = try sent(suggestion)
        for name in ["Acme", "Merger", "webclient"] {
            XCTAssertFalse(text.contains(name), text)
        }
        let named = try XCTUnwrap(model.explainRequest(for: stale, redactor: redactor.sendingFolderNames(true)))
        XCTAssertEqual(named.sizes, "Not measured: ~/dev/Acme Merger/webclient could not be read.")
    }

    private func sent(_ request: ExplainRequest) throws -> String {
        String(decoding: try JSONEncoder().encode(request), as: UTF8.self) + "\n" + request.promptText
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
