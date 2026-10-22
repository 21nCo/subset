import Foundation
@testable import SystemCore
@testable import SystemDisk
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
        XCTAssertEqual(documents.path?.value, "~/Documents")
        XCTAssertNotNil(documents.sizes)
        XCTAssertEqual(documents.age, "Last changed 0 minutes ago")
        XCTAssertNil(documents.bundleID)

        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Editor")).id)
        let cache = try request(model, try XCTUnwrap(model.row(named: "com.example.editor")).id)
        XCTAssertEqual(cache.kind, .folder)
        XCTAssertEqual(cache.type, "Folder in ~/Library/Caches")
        XCTAssertEqual(cache.path?.value, "~/Library/Caches/\(redactor.placeholder("com.example.editor"))")
        XCTAssertEqual(cache.name, redactor.placeholder("com.example.editor"), "named as its path is sent")
        XCTAssertEqual(cache.bundleID, "com.example.editor")
        XCTAssertEqual(cache.teamID, "EXAMPLE123")
        XCTAssertEqual(cache.vendor, "Example Ltd")
        XCTAssertEqual(cache.matchedRule, "Named for an installed app's bundle ID")
        XCTAssertEqual(cache.app, "Editor")
        XCTAssertTrue(cache.evidence.contains { $0.kind == .reclaimRule && $0.name == "App caches" }, "\(cache.evidence)")
        XCTAssertFalse(cache.maySuggestOrigin)
    }

    func testALeftoverRequestNamesTheMissingAppsIdentifier() async throws {
        let model = try await fixture.scanned()
        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Leftovers")).id)
        let leftover = try request(model, try XCTUnwrap(model.row(named: "com.gone.app.plist")).id)
        XCTAssertEqual(leftover.kind, .leftover)
        XCTAssertEqual(leftover.bundleID, "com.gone.app")
        XCTAssertEqual(leftover.path?.value, "~/Library/Preferences/\(redactor.placeholder("com.gone.app.plist"))")
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
        XCTAssertEqual(suggestion.matchedRule?.contains("Location: ~/Library/Developer/Xcode/DerivedData."), true,
                       "a rule's fixed location is System's own text, sent as it is")
        XCTAssertNil(suggestion.path)
        let named = try XCTUnwrap(model.explainRequest(for: derived.id, redactor: redactor.sendingFolderNames(true)))
        XCTAssertEqual(named.members, ["App-abc"])

        model.toggle(derived.id)
        let item = try request(model, try XCTUnwrap(model.row(named: "App-abc")).id)
        XCTAssertEqual(item.kind, .folder)
        XCTAssertTrue(item.evidence.contains { $0.kind == .reclaimRule && $0.name == "Xcode DerivedData" })
    }

    /// An account name that is also a word of System's ("in", "to") leaves a folder's and a suggestion's type, sizes,
    /// age, and rule as System words them, and is still removed from their names, identifiers, and paths.
    func testAnAccountNameThatIsAlsoAWordLeavesSystemsOwnWordsAsTheyAre() async throws {
        let model = try await fixture.scanned()
        let words = ExplainRedactor(homes: [fixture.home], accountNames: ["in", "to", "the", "of", "a", "changed", "editor"],
                                    sendFolderNames: true, key: Array(repeating: 2, count: 32))
        let plain = redactor.sendingFolderNames(true)
        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Editor")).id)
        let cacheID = try XCTUnwrap(model.row(named: "com.example.editor")).id
        let cache = try XCTUnwrap(model.explainRequest(for: cacheID, redactor: words, now: Date()))
        let cachePlain = try XCTUnwrap(model.explainRequest(for: cacheID, redactor: plain, now: Date()))
        XCTAssertEqual(cache.type, "Folder in ~/Library/Caches")
        XCTAssertEqual(cache.sizes, cachePlain.sizes)
        XCTAssertEqual(cache.age, cachePlain.age)
        XCTAssertEqual(cache.matchedRule, "Named for an installed app's bundle ID")
        XCTAssertEqual(cache.app, "[user]")
        XCTAssertEqual(cache.bundleID, "com.example.[user]")
        XCTAssertEqual(cache.path?.value, "~/Library/Caches/com.example.[user]")

        model.tab = .suggestions
        let derived = try XCTUnwrap(model.row(named: "Xcode DerivedData")).id
        let suggestion = try XCTUnwrap(model.explainRequest(for: derived, redactor: words))
        let suggestionPlain = try XCTUnwrap(model.explainRequest(for: derived, redactor: plain))
        XCTAssertEqual(suggestion.type, "Safe to reclaim suggestion")
        XCTAssertEqual(suggestion.sizes, suggestionPlain.sizes)
        XCTAssertEqual(suggestion.matchedRule, suggestionPlain.matchedRule, "a rule's words are System's own")
        XCTAssertFalse(suggestion.matchedRule?.contains(ExplainRedactor.accountPlaceholder) ?? true)
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
            XCTAssertEqual(request.path?.value.split(separator: "/").last.map(String.init), redactor.placeholder(name))
            let text = try sent(request)
            XCTAssertFalse(text.contains(name), text)
            let named = try XCTUnwrap(model.explainRequest(for: id, redactor: redactor.sendingFolderNames(true)))
            XCTAssertEqual(named.name, name)
        }

        // A suggestion not measured because a folder in a project could not be read says so as a category; the reason's
        // text, which names that folder, is not sent, even with folder names on.
        model.tab = .suggestions
        let suggestion = try request(model, stale)
        XCTAssertEqual(suggestion.notMeasured, .notRead)
        XCTAssertNil(suggestion.sizes)
        let named = try XCTUnwrap(model.explainRequest(for: stale, redactor: redactor.sendingFolderNames(true)))
        for text in [try sent(suggestion), try sent(named)] {
            for name in ["Acme", "Merger", "webclient"] { XCTAssertFalse(text.contains(name), text) }
        }
    }

    /// A suggestion's size is bounded as its row is: a sum that may count shared clone blocks twice is at most what is
    /// used, and one with an unread item at least it.
    func testASuggestionsSizeIsSentWithTheBoundsItsRowShows() {
        let format = fixture.format
        func sizes(complete: Bool, upperBound: Bool, private privateBytes: UInt64 = 8_192) -> String? {
            DiskWindowModel.sizes(of: .scanned(private: privateBytes, allocated: 8_192, complete: complete,
                                               allocatedUpperBound: upperBound), format: format)
        }
        XCTAssertEqual(sizes(complete: true, upperBound: false), "8 kB")
        XCTAssertEqual(sizes(complete: true, upperBound: true), "at most 8 kB")
        XCTAssertEqual(sizes(complete: false, upperBound: false), "at least 8 kB")
        XCTAssertEqual(sizes(complete: false, upperBound: true), "about 8 kB")
        XCTAssertEqual(sizes(complete: true, upperBound: true, private: 4_096), "at most 8 kB, 4 kB private")
        XCTAssertEqual(DiskWindowModel.sizes(of: .dockerReclaimable(upTo: 4_096, total: nil), format: format),
                       "up to 4 kB reclaimable, as Docker reports")
        XCTAssertNil(DiskWindowModel.sizes(of: .unavailable("Not read"), format: format))
    }

    func testAnUnreadableAppOutsideTheScannedFolderIsWithheldInASuggestionsReason() async throws {
        // Scanned: ~/Library only. Not readable: ~/Applications/Acme Notes.app, so a cache and a preferences file named
        // for bundle IDs no app has may be that app's, and App caches and App leftovers are not measured.
        try FileManager.default.removeItem(atPath: fixture.path("Library/Caches/com.example.editor"))
        try fixture.write("Library/Caches/com.removed.player/data", bytes: 4_000)
        try fixture.write("Applications/Acme Notes.app/Contents/Info.plist", bytes: 10)
        try fixture.lock("Applications/Acme Notes.app/Contents")
        let read = InstalledApps.read(folders: [fixture.path("Applications")]) { _ in AppSigning(signature: nil, appGroups: nil) }
        XCTAssertFalse(read.isComplete)
        let apps = InstalledApps([DiskFixture.editor], unread: read.unread)
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            DiskAnalysis(tree: result.tree, context: ReclaimContext(home: home, installedApps: apps,
                                                                    simulatorRuntimes: .installed([])))
        }))
        model.scope = .folder(path: fixture.path("Library"))
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        model.tab = .suggestions

        var checked = 0
        for rule in ["App caches", "App leftovers"] {
            guard let id = model.row(named: rule)?.id else { continue }
            let request = try request(model, id)
            XCTAssertEqual(request.notMeasured, .notRead)
            let text = try sent(request)
            for word in ["Acme", "Notes", "removed.player", "gone.app"] { XCTAssertFalse(text.contains(word), "\(rule): \(text)") }

            let named = try XCTUnwrap(model.explainRequest(for: id, redactor: redactor.sendingFolderNames(true)))
            XCTAssertFalse(try sent(named).contains("Acme Notes"), "the reason's text is not sent")
            checked += 1
        }
        XCTAssertGreaterThan(checked, 0, "\(model.rows.map(\.name))")
    }

    func testAnInstalledAppInTheHomeFolderIsNamedAsProcessesNamesItsGroup() async throws {
        // ~/Applications/Acme Notes.app is deeper than the first level under ~, so its name is its bundle's placeholder
        // unless folder names are sent, in its cache's rule and its App caches suggestion alike, as in Processes
        // (ProcessExplainTests.testAProjectOrAppGroupInTheHomeFolderIsNamedAsItsPathIsSent).
        try fixture.write("Library/Caches/com.acme.notes/cache.db", bytes: 200_000)
        let notes = InstalledApp(path: fixture.path("Applications/Acme Notes.app"), bundleID: "com.acme.notes",
                                 name: "Acme Notes", signature: nil)
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            DiskAnalysis(tree: result.tree, context: ReclaimContext(home: home, installedApps: InstalledApps([DiskFixture.editor, notes]),
                                                                    simulatorRuntimes: .installed([])))
        }))
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Acme Notes")).id)
        let cache = try XCTUnwrap(model.row(named: "com.acme.notes")).id
        model.tab = .suggestions
        let suggestion = try XCTUnwrap(model.row(named: "App caches: Acme Notes")).id
        let placeholder = redactor.placeholder("Acme Notes.app")

        let item = try request(model, cache)
        XCTAssertEqual(item.matchedRule, "Named for an installed app's bundle ID")
        XCTAssertEqual(item.app, placeholder)
        XCTAssertEqual(item.bundleID, "com.acme.notes")
        let match = try request(model, suggestion)
        XCTAssertEqual(match.name, "App caches")
        XCTAssertEqual(match.app, placeholder)
        for request in [item, match] {
            let text = try sent(request)
            for word in ["Acme", "Notes"] { XCTAssertFalse(text.contains(word), text) }
        }

        let named = redactor.sendingFolderNames(true)
        XCTAssertEqual(model.explainRequest(for: cache, redactor: named)?.app, "Acme Notes")
        XCTAssertEqual(model.explainRequest(for: suggestion, redactor: named)?.app, "Acme Notes")
    }

    func testAGroupContainerKnownOnlyByItsTeamIDIsNotSentByItsFolderName() async throws {
        // NOSUCHTEAM is no installed app's Team ID, so its container is a leftover; EXAMPLE123 is two apps', so its
        // container is that vendor's. Neither name after the Team ID is an identity an app has: it is the folder's own.
        try fixture.write("Library/Group Containers/NOSUCHTEAM.Private Client/data", bytes: 4_000)
        try fixture.write("Library/Group Containers/EXAMPLE123.Private Client/data", bytes: 4_000)
        let viewer = InstalledApp(path: "/Applications/Viewer.app", bundleID: "com.example.viewer", name: "Viewer",
                                  signature: DiskFixture.editor.signature)
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            DiskAnalysis(tree: result.tree, context: ReclaimContext(home: home, installedApps: InstalledApps([DiskFixture.editor, viewer]),
                                                                    simulatorRuntimes: .installed([])))
        }))
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        let analysis = try XCTUnwrap(model.analysis)
        func item(_ name: String) throws -> DiskRowID {
            .item(try XCTUnwrap(analysis.origins.entries.first { $0.path.hasSuffix("/Group Containers/" + name) }).index)
        }
        func leftovers(_ identifier: String) throws -> DiskRowID {
            .match(try XCTUnwrap(analysis.matches.firstIndex { $0.rule.id == .appLeftovers && $0.identifier == identifier }))
        }
        let unknownTeam = try item("NOSUCHTEAM.Private Client")
        let sharedTeam = try item("EXAMPLE123.Private Client")
        let suggestion = try leftovers("Private Client")
        let named = redactor.sendingFolderNames(true)

        for (id, team) in [(unknownTeam, "NOSUCHTEAM"), (sharedTeam, "EXAMPLE123"), (suggestion, "NOSUCHTEAM")] {
            let request = try request(model, id)
            XCTAssertNil(request.bundleID)
            XCTAssertEqual(request.teamID, team)
            let text = try sent(request)
            for word in ["Private", "Client"] { XCTAssertFalse(text.contains(word), text) }
            XCTAssertEqual(model.explainRequest(for: id, redactor: named)?.bundleID, "Private Client")
        }
        XCTAssertEqual(try request(model, unknownTeam).kind, .leftover)
        XCTAssertEqual(try request(model, suggestion).name, "App leftovers")
        XCTAssertEqual(model.explainRequest(for: suggestion, redactor: named)?.name, "App leftovers")

        // A leftover named for a bundle ID is still sent as that bundle ID.
        let gone = try request(model, try leftovers("com.gone.app"))
        XCTAssertEqual(gone.bundleID, "com.gone.app")
        XCTAssertEqual(gone.name, "App leftovers")
    }

    func testALeftoverAndAFolderAtOnePathAreExplainedSeparately() async throws {
        let model = try await fixture.scanned()
        model.tab = .origins
        model.toggle(try XCTUnwrap(model.row(named: "Leftovers")).id)
        let leftover = try XCTUnwrap(model.row(named: "com.gone.app.plist")).id
        guard case let .originItem(_, _, index) = leftover else { return XCTFail("\(leftover)") }
        let folder = DiskRowID.item(index)
        XCTAssertEqual(try request(model, leftover).kind, .leftover)
        XCTAssertEqual(try request(model, folder).kind, .leftover, "a rule found it is a leftover in the Folders tab too")
        XCTAssertEqual(model.explainKey(for: leftover), model.explainKey(for: folder))

        model.toggle(try XCTUnwrap(model.row(named: "Editor")).id)
        let cache = try XCTUnwrap(model.row(named: "com.example.editor")).id
        guard case let .originItem(section, _, cacheIndex) = cache else { return XCTFail("\(cache)") }
        let asLeftover = DiskRowID.originItem(section, .leftovers, item: cacheIndex)
        XCTAssertEqual(try request(model, cache).kind, .folder)
        XCTAssertEqual(try request(model, asLeftover).kind, .leftover)
        XCTAssertNotEqual(model.explainKey(for: cache), model.explainKey(for: asLeftover),
                          "facts that differ by context are not answered from one cached explanation")
    }

    /// Docker's image space not measured is sent as a category from the reason Docker gave; the CLI's message and the
    /// paths in it are never sent, with folder names off or on.
    func testDockerImagesNotMeasuredAreExplainedWithACategoryNotTheCLIsMessage() async throws {
        let home = fixture.home
        let cases: [(ContainerUnavailable?, ExplainNotMeasured)] = [
            (.daemonNotRunning(message: "No socket at \(home)/Clients/Acme Inc. Holdings."), .dockerNotRunning),
            (.failed(command: "docker system df", status: 1,
                     message: "No such file: \(home)/Clients/Acme ~/Private Client/docker.sock\nSecret Client"), .dockerFailed),
            (.contextUnreadable(path: "\(home)/Clients/Acme Inc. Holdings/config.json", message: "Private"),
             .dockerContextNotOnThisMac),
            (.cliNotFound, .dockerNotFound), (.cancelled, .dockerStopped), (nil, .dockerNotReported)
        ]
        for (reason, category) in cases {
            let usage: DockerImageUsage = reason.map { .unavailable($0) }
                ?? .reported(DockerImageSpace(count: nil, active: nil, size: nil, reclaimable: nil), observedAt: Date())
            let model = fixture.model(service: fixture.service(analyze: { result, _ in
                DiskAnalysis(tree: result.tree, context: ReclaimContext(
                    home: home, installedApps: InstalledApps([DiskFixture.editor]), simulatorRuntimes: .installed([]),
                    dockerImages: usage))
            }))
            model.scan()
            try await DiskFixture.wait { !model.isScanning }
            let analysis = try XCTUnwrap(model.analysis)
            let docker = DiskRowID.match(try XCTUnwrap(analysis.matches.firstIndex { $0.rule.id == .dockerImages }))
            let request = try request(model, docker)
            XCTAssertEqual(request.notMeasured, category, "\(String(describing: reason))")
            XCTAssertNil(request.sizes)
            let named = try XCTUnwrap(model.explainRequest(for: docker, redactor: redactor.sendingFolderNames(true)))
            for text in [try sent(request), try sent(named)] {
                for word in ["Acme", "Holdings", "Private", "Secret", "docker.sock", "config.json"] {
                    XCTAssertFalse(text.contains(word), "\(word): \(text)")
                }
            }
        }
    }

    func testAScanOfTheHomeFolderThroughTheDataVolumeIsRedactedAsTheHomeFolder() async throws {
        let model = fixture.model()
        model.scope = .folder(path: "/System/Volumes/Data" + fixture.home)
        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        XCTAssertEqual(model.result?.tree.rootPath, "/System/Volumes/Data" + fixture.home)
        model.open(try XCTUnwrap(model.row(named: "Documents")).id)
        let sub = try XCTUnwrap(model.row(named: "Sub")).id
        let request = try request(model, sub)
        XCTAssertEqual(request.path?.value, "~/Documents/\(redactor.placeholder("Sub"))")
        XCTAssertEqual(request.name, redactor.placeholder("Sub"))
        XCTAssertFalse(try sent(request).contains("/System/Volumes"))
        XCTAssertEqual(model.explainRequest(for: sub, redactor: redactor.sendingFolderNames(true))?.path?.value, "~/Documents/Sub")
    }

    func testAScanNotYetAnalyzedIsNotExplainedAndACancelledOneIsNotAnsweredAsAnAnalyzedOne() async throws {
        let gate = AsyncGate()
        let home = fixture.home
        let model = fixture.model(service: fixture.service(analyze: { result, _ in
            await gate.pass()
            return DiskFixture.analysis(result, home: home)
        }))
        model.scan()
        await fulfillment(of: [gate.reached], timeout: 30)
        XCTAssertEqual(model.phase, .analyzing)
        let analyzing = try XCTUnwrap(model.row(named: "Documents")).id
        XCTAssertFalse(model.canExplain(analyzing), "its origin and suggestions are still being worked out")
        XCTAssertNil(model.explainKey(for: analyzing))
        XCTAssertNil(model.explainRequest(for: analyzing, redactor: redactor))

        model.cancel()
        gate.open()
        XCTAssertEqual(model.phase, .cancelled)
        let cancelled = try XCTUnwrap(model.row(named: "Documents")).id
        let unanalyzed = try XCTUnwrap(model.explainKey(for: cancelled))
        XCTAssertNotNil(model.explainRequest(for: cancelled, key: unanalyzed, redactor: redactor))

        model.scan()
        try await DiskFixture.wait { !model.isScanning }
        XCTAssertEqual(model.phase, .completed)
        let documents = try XCTUnwrap(model.row(named: "Documents")).id
        let analyzed = try XCTUnwrap(model.explainKey(for: documents))
        XCTAssertNotEqual(analyzed, unanalyzed, "an answer about fewer facts is not kept for the analyzed item")
        XCTAssertNil(model.explainRequest(for: cancelled, key: unanalyzed, redactor: redactor),
                     "a sheet opened on the cancelled scan finds its item gone")
        XCTAssertNotNil(model.explainRequest(for: documents, key: analyzed, redactor: redactor))
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
