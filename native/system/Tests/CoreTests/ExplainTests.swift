import Foundation
@testable import SystemCore
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif

/// The AI contract shared with SET-50 without a real model: redaction, the token budget, schema validation, the
/// suggested origin, the provider setting, the session cache, and the availability mapping.
@MainActor
final class ExplainTests: XCTestCase {
    private let redactor = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: ["jdoe", "Jane Doe"],
                                           sendFolderNames: false, key: Array(repeating: 7, count: 32))

    // MARK: Redaction

    func testPathsShowHomeAsTildeAndReplaceDeeperFolderNamesUnlessFolderNamesAreSent() {
        XCTAssertEqual(redactor.path("/Users/jdoe"), "~")
        let deep = redactor.path("/Users/jdoe/dev/acme-merger/api/server")
        let client = redactor.placeholder("acme-merger")
        XCTAssertEqual(deep, "~/dev/\(client)/\(redactor.placeholder("api"))/\(redactor.placeholder("server"))")
        XCTAssertTrue(client.hasPrefix("folder-"))
        // The same folder name gets the same placeholder, the explained item's own name included.
        XCTAssertEqual(redactor.path("/Users/jdoe/dev/acme-merger"), "~/dev/\(client)")
        XCTAssertEqual(redactor.name("acme-merger", ofPath: "/Users/jdoe/dev/acme-merger"), client)
        XCTAssertEqual(redactor.name("Developer", ofPath: "/Users/jdoe/dev"), "Developer", "the first level is sent")
        XCTAssertEqual(redactor.name("Editor", ofPath: "/Applications/Editor.app"), "Editor", "outside the home folder")
        XCTAssertEqual(redactor.sendingFolderNames(true).name("acme-merger", ofPath: "/Users/jdoe/dev/acme-merger"),
                       "acme-merger")
        // macOS's own folders in ~/Library say nothing about the user; what is inside them does.
        XCTAssertEqual(redactor.path("/Users/jdoe/Library/Caches/com.example.app/data"),
                       "~/Library/Caches/\(redactor.placeholder("com.example.app"))/\(redactor.placeholder("data"))")
        XCTAssertEqual(redactor.path("/Users/jdoe/Projects/Library/Caches"),
                       "~/Projects/\(redactor.placeholder("Library"))/\(redactor.placeholder("Caches"))")
        // Another session's key gives other placeholders.
        let other = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: [], sendFolderNames: false,
                                    key: Array(repeating: 9, count: 32))
        XCTAssertNotEqual(other.placeholder("acme-merger"), client)

        let sending = redactor.sendingFolderNames(true)
        XCTAssertEqual(sending.path("/Users/jdoe/dev/acme-merger/api/server"), "~/dev/acme-merger/api/server")
    }

    func testTheAccountNameIsRemovedWhereverItAppearsButNotInsideOtherWords() {
        XCTAssertEqual(redactor.path("/Users/jdoe/jdoe-notes/file"), "~/[user]-notes/\(redactor.placeholder("file"))")
        XCTAssertEqual(redactor.text("Started by JDOE in /Users/jdoe/dev for Jane Doe; see /Users/jdoe"),
                       "Started by [user] in ~/dev for [user]; see ~")
        XCTAssertEqual(redactor.text("jdoesmith and /Users/jdoeother"), "jdoesmith and /Users/jdoeother")
        XCTAssertEqual(redactor.path("/Volumes/Backup/jdoe/archive"), "/Volumes/Backup/[user]/archive")
        XCTAssertEqual(redactor.sendingFolderNames(true).path("/Users/jdoe/dev/jdoe/x"), "~/dev/[user]/x")
    }

    func testPathsInFreeTextHaveTheirDeepFolderNamesWithheldToo() {
        let client = redactor.placeholder("secret-client")
        // A path in free text runs to the end of its clause, and a last name that is not a placeholder is withheld with
        // the words after it, since a folder name may hold spaces.
        XCTAssertEqual(redactor.text("/Users/jdoe/dev/secret-client/node_modules could not be read."),
                       "~/dev/\(client)/\(redactor.placeholder("node_modules could not be read")).")
        XCTAssertEqual(redactor.text("Runs `~/dev/secret-client/tool`, see (~/dev/secret-client); ~/dev: ok"),
                       "Runs `~/dev/\(client)/\(redactor.placeholder("tool"))`, see (~/dev/\(client)); ~/dev: ok")
        // ~/Library's own folders are read whole, spaces included, and what is inside them is withheld.
        XCTAssertEqual(redactor.text("/Users/jdoe/Library/Application Support/Acme/db is not a folder."),
                       "~/Library/Application Support/\(redactor.placeholder("Acme"))/"
                        + "\(redactor.placeholder("db is not a folder")).")
        XCTAssertEqual(redactor.text("~/Library/Application Support could not be read."),
                       "~/Library/Application Support could not be read.")
        // Text already redacted is unchanged, so a folder keeps one placeholder in every field, and its words are kept.
        let redacted = "Working directory \(redactor.path("/Users/jdoe/dev/secret-client/api")) could not be read: denied."
        XCTAssertEqual(redactor.text(redacted), redacted)
        XCTAssertEqual(redactor.text("~ and ~/dev; /tmp/secret-client"), "~ and ~/dev; /tmp/secret-client")
        XCTAssertEqual(redactor.sendingFolderNames(true).text("/Users/jdoe/dev/secret-client/node_modules could not be read."),
                       "~/dev/secret-client/node_modules could not be read.")
    }

    func testARawPathWithSpacesInFreeTextLeavesNoWordOfAWithheldName() {
        let raw = "/Users/jdoe/dev/Acme Merger/web client could not be read. 2 more places could not be searched."
        let sent = redactor.text(raw)
        for word in ["Acme", "Merger", "web", "client"] { XCTAssertFalse(sent.contains(word), sent) }
        XCTAssertTrue(sent.hasPrefix("~/dev/\(redactor.placeholder("Acme Merger"))/"), sent)
        XCTAssertTrue(sent.hasSuffix(". 2 more places could not be searched."), "the next clause is kept: \(sent)")
        // A name with a full stop, a bracket, or an apostrophe stays in the path.
        for name in ["Notes v1.2.app", "Photos (old)", "Bob's Stuff"] {
            let text = redactor.text("Runs ~/Applications/\(name)/Contents/MacOS/tool now")
            XCTAssertFalse(text.contains(name), text)
            XCTAssertFalse(text.contains("tool now"), text)
        }
        XCTAssertEqual(redactor.text(sent), sent, "redacting twice changes nothing")
        // A clause end a slash follows is inside a folder name, so the path goes on.
        for name in ["Acme Inc. Holdings", "Photos (Paris) backup", "Acme; Merger", "Draft] v2"] {
            let text = redactor.text("/Users/jdoe/Clients/\(name)/node_modules could not be read.")
            for word in name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
                XCTAssertFalse(text.contains(word), "\(word): \(text)")
            }
            XCTAssertTrue(text.hasPrefix("~/Clients/\(redactor.placeholder(name))/"), text)
        }
        // A path after it starts its own, so the clause end stays the end.
        let unread = "~/Applications/\(redactor.placeholder("Acme Notes.app")) has no readable bundle identifier."
        for next in [" /Applications/Other.app could not be read.", " Runs `/usr/bin/tool`.", " See (~/dev)."] {
            XCTAssertEqual(redactor.text(unread + next), unread + next)
        }
        // Another path in the clause starts its own.
        XCTAssertEqual(redactor.text("~/Library/Caches/com.a.b may be data of ~/Applications/Acme Notes.app: unread."),
                       "~/Library/Caches/\(redactor.placeholder("com.a.b may be data of"))"
                        + " ~/Applications/\(redactor.placeholder("Acme Notes.app: unread")).")
        XCTAssertEqual(redactor.sendingFolderNames(true).text(raw),
                       "~/dev/Acme Merger/web client could not be read. 2 more places could not be searched.")
    }

    func testKnownPathsInFreeTextAreShownWholeAndKeepTheWordsAfterThem() {
        let app = "/Users/jdoe/Applications/Acme Notes.app"
        let text = "\(app) could not be read: Permission denied. /Users/jdoe/Applications is fine."
        let shown = redactor.paths(in: text, known: [app, "/Users/jdoe/Applications/Acme", "/Applications/Other.app"])
        XCTAssertEqual(shown, "~/Applications/\(redactor.placeholder("Acme Notes.app")) could not be read: Permission "
            + "denied. /Users/jdoe/Applications is fine.")
        XCTAssertEqual(redactor.text(shown), "~/Applications/\(redactor.placeholder("Acme Notes.app")) could not be read: "
            + "Permission denied. ~/Applications is fine.")
        XCTAssertEqual(redactor.sendingFolderNames(true).paths(in: text, known: [app]),
                       "~/Applications/Acme Notes.app could not be read: Permission denied. /Users/jdoe/Applications is fine.")
    }

    func testTheProcessNameDisclosureIsInSettingsAndTheFieldGuide() throws {
        XCTAssertTrue(ExplainRedactor.folderNamesCaption.contains("A process is still named by its executable"))
        let name = try XCTUnwrap(ExplainRequest.fieldGuide.first { $0.name == "name" }).meaning
        XCTAssertTrue(name.contains("process's name as macOS reports it"), name)
        XCTAssertFalse(name.contains("process, file"), "a process's name is not said to be withheld: \(name)")
    }

    func testNoFieldOfARequestCarriesTheHomePathAccountNameOrDeepFolderNames() throws {
        var facts = ExplainFacts(kind: .process, name: "server")
        facts.path = "/Users/jdoe/dev/acme-merger/bin/server"
        facts.type = "Process in jdoe's terminal"
        facts.evidence = ["Working directory \(redactor.path("/Users/jdoe/dev/acme-merger"))",
                          "Child of zsh in /Users/jdoe", "/Users/jdoe/dev/acme-merger/.git could not be read."]
        facts.sizes = "Not measured: /Users/jdoe/dev/acme-merger could not be read."
        facts.members = ["Jane Doe helper"]
        facts.matchedRule = "Terminal session"
        let request = ExplainRequest(facts, redactor: redactor)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        for sent in [json, request.promptText] {
            XCTAssertFalse(sent.contains("/Users/"), sent)
            XCTAssertFalse(sent.localizedCaseInsensitiveContains("jdoe"), sent)
            XCTAssertFalse(sent.contains("Jane Doe"), sent)
            XCTAssertFalse(sent.contains("acme-merger"), sent)
        }
        XCTAssertEqual(request.path, "~/dev/\(redactor.placeholder("acme-merger"))/\(redactor.placeholder("bin"))/"
            + redactor.placeholder("server"))
        XCTAssertEqual(request.type, "Process in [user]'s terminal")

        let named = ExplainRequest(facts, redactor: redactor.sendingFolderNames(true))
        XCTAssertEqual(named.path, "~/dev/acme-merger/bin/server")
        XCTAssertEqual(named.sizes, "Not measured: ~/dev/acme-merger could not be read.")
    }

    func testSettingsListEveryFieldThatIsSent() throws {
        XCTAssertEqual(ExplainRequest.fieldGuide.map(\.name), ExplainRequest.CodingKeys.allCases.map(\.rawValue))
        var facts = ExplainFacts(kind: .processGroup, name: "Everything")
        facts.type = "t"; facts.path = "/p"; facts.bundleID = "b"; facts.signingID = "s"; facts.teamID = "T"
        facts.vendor = "v"; facts.launchdLabel = "l"; facts.sizes = "1"; facts.age = "a"; facts.matchedRule = "r"
        facts.evidence = ["e"]; facts.members = ["m"]
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(ExplainRequest(facts, redactor: redactor)))
        let sent = try XCTUnwrap(object as? [String: Any]).keys
        XCTAssertEqual(Set(sent), Set(ExplainRequest.fieldGuide.map(\.name)))
    }

    // MARK: Token budget

    func testARequestOverTheBudgetIsTruncatedToFitAndKeepsItsKindAndName() {
        let long = String(repeating: "x", count: 1_000)
        var facts = ExplainFacts(kind: .suggestion, name: "Xcode DerivedData")
        facts.type = long; facts.path = "/Users/jdoe/" + long; facts.bundleID = long; facts.signingID = long
        facts.teamID = long; facts.vendor = long; facts.launchdLabel = long; facts.sizes = long; facts.age = long
        facts.matchedRule = long
        facts.evidence = (0..<40).map { "evidence \($0) " + long }
        facts.members = (0..<40).map { "member \($0)" }
        let request = ExplainRequest(facts, redactor: redactor)
        XCTAssertLessThanOrEqual(request.estimatedTokens, ExplainRequest.tokenBudget)
        XCTAssertLessThanOrEqual(ExplainPrompt.instructions.count + request.promptText.count, ExplainRequest.tokenBudget * 4)
        XCTAssertTrue(request.truncated)
        XCTAssertTrue(request.promptText.contains("Some facts were shortened or left out to fit."))
        XCTAssertEqual(request.kind, .suggestion)
        XCTAssertEqual(request.name, "Xcode DerivedData")
        XCTAssertLessThan(request.evidence.count, 12)

        var small = ExplainFacts(kind: .folder, name: "Caches")
        small.evidence = ["one", "two"]
        let fits = ExplainRequest(small, redactor: redactor)
        XCTAssertFalse(fits.truncated)
        XCTAssertEqual(fits.evidence, ["one", "two"])
    }

    // MARK: Validation

    private func request(_ kind: ExplainItemKind = .process, unattributed: Bool = false) -> ExplainRequest {
        var facts = ExplainFacts(kind: kind, name: "syncd")
        facts.isUnattributedGroup = unattributed
        return ExplainRequest(facts, redactor: redactor)
    }

    private func draft(summary: String? = "A sync agent.", whatItIs: String? = "It syncs files.",
                       safety: String? = "review", howToRemove: String? = "Quit it, then move it to the Trash.",
                       confidence: String? = "medium", origin: String? = nil) -> ExplanationDraft {
        ExplanationDraft(summary: summary, whatItIs: whatItIs, removalSafety: safety, howToRemove: howToRemove,
                         confidence: confidence, suggestedOrigin: origin)
    }

    private func assertRejected(_ draft: ExplanationDraft, _ request: ExplainRequest? = nil, line: UInt = #line) {
        XCTAssertThrowsError(try Explanation(validating: draft, for: request ?? self.request()), line: line) { error in
            guard case ExplainError.invalidResponse = error else { return XCTFail("\(error)", line: line) }
        }
    }

    func testAValidAnswerIsKeptAsPlainText() throws {
        let explanation = try Explanation(validating: draft(summary: "  **Bold** <b>tag</b>\u{202E}gnp.exe\u{0007}\n"),
                                          for: request())
        XCTAssertEqual(explanation.summary, "**Bold** <b>tag</b>gnp.exe", "markup stays literal; controls are removed")
        XCTAssertEqual(explanation.removalSafety, .review)
        XCTAssertEqual(explanation.confidence, .medium)
        XCTAssertNil(explanation.suggestedOrigin)
        XCTAssertNoThrow(try Explanation(validating: draft(summary: String(repeating: "s", count: 280)), for: request()))
    }

    func testBadPartialAndOversizedAnswersAreRejected() {
        assertRejected(draft(safety: "maybe"))
        assertRejected(draft(safety: nil))
        assertRejected(draft(confidence: "certain"))
        assertRejected(draft(summary: nil))
        assertRejected(draft(whatItIs: "   "))
        assertRejected(draft(howToRemove: nil))
        assertRejected(draft(summary: String(repeating: "s", count: 281)))
        assertRejected(draft(whatItIs: String(repeating: "w", count: Explanation.textLimit + 1)))
        assertRejected(draft(howToRemove: String(repeating: "h", count: Explanation.textLimit + 1)))
    }

    func testJSONOutsideTheSchemaIsRejected() throws {
        func parse(_ json: String) throws -> ExplanationDraft { try ExplanationDraft(json: Data(json.utf8)) }
        let valid = #"{"summary":"s","whatItIs":"w","removalSafety":"unsafe","howToRemove":"h","confidence":"low","suggestedOrigin":null}"#
        XCTAssertEqual(try parse(valid), draft(summary: "s", whatItIs: "w", safety: "unsafe", howToRemove: "h", confidence: "low"))
        for bad in [
            #"{"summary":"s","whatItIs":"w","removalSafety":"unsafe","howToRemove":"h","confidence":"low","run":"rm -rf ~"}"#,
            #"{"summary":1,"whatItIs":"w","removalSafety":"unsafe","howToRemove":"h","confidence":"low"}"#,
            #"["summary"]"#,
            "not json"
        ] {
            XCTAssertThrowsError(try parse(bad), bad)
        }
        // A partial object parses, and validation rejects it.
        assertRejected(try parse(#"{"summary":"s","removalSafety":"unsafe"}"#))
    }

    func testASuggestedOriginIsKeptOnlyForAnUnattributedGroup() throws {
        let suggested = draft(origin: "Acme Sync")
        XCTAssertEqual(try Explanation(validating: suggested, for: request(.processGroup, unattributed: true)).suggestedOrigin,
                       "Acme Sync")
        XCTAssertNil(try Explanation(validating: suggested, for: request(.processGroup)).suggestedOrigin)
        XCTAssertNil(try Explanation(validating: suggested, for: request(.process, unattributed: true)).suggestedOrigin)
        XCTAssertNil(try Explanation(validating: suggested, for: request(.folder)).suggestedOrigin)
        XCTAssertFalse(request(.process, unattributed: true).maySuggestOrigin)
        assertRejected(draft(origin: "Acme\nrm -rf ~"), request(.processGroup, unattributed: true))
        assertRejected(draft(origin: String(repeating: "o", count: 81)), request(.processGroup, unattributed: true))
    }

    // MARK: Provider setting and session cache

    private func defaults() -> UserDefaults {
        let name = "ExplainTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func center(_ defaults: UserDefaults, provider: FakeProvider?, made: Counter = Counter()) -> ExplainCenter {
        ExplainCenter(defaults: defaults, redactor: redactor) { choice in
            made.count += 1
            return choice == .appleIntelligence ? provider : nil
        }
    }

    func testWithNoProviderChosenNoProviderIsMadeOrAskedAndExplainAsksToChooseOne() async {
        let made = Counter()
        let provider = FakeProvider()
        let center = center(defaults(), provider: provider, made: made)
        XCTAssertEqual(center.choice, .none, "no provider until the user picks one")
        let key = ExplainKey("process:1")
        var built = 0
        await center.explain(key) { _ in
            built += 1
            return self.request()
        }
        await center.refreshAvailability()
        XCTAssertEqual(made.count, 0)
        XCTAssertEqual(built, 0)
        XCTAssertEqual(provider.explained, 0)
        XCTAssertEqual(provider.availabilityReads, 0)
        XCTAssertEqual(center.state(for: key), .needsProvider)
        XCTAssertNil(center.availability)
    }

    func testAnExplanationIsKeptPerItemForTheSessionAndAFailureCanBeRetried() async throws {
        let provider = FakeProvider()
        provider.answer = draft(summary: String(repeating: "s", count: 300))
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("process:1")
        await center.explain(key) { _ in self.request() }
        guard case let .failed(message, _) = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
        XCTAssertTrue(message.contains("280"), message)

        provider.answer = draft()
        await center.explain(key) { _ in self.request() }
        guard case let .explained(explanation, sent) = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
        XCTAssertEqual(explanation.summary, "A sync agent.")
        XCTAssertEqual(sent, request())
        XCTAssertEqual(provider.explained, 2)

        // Kept: asking again sends nothing.
        await center.explain(key) { _ in self.request() }
        XCTAssertEqual(provider.explained, 2)
        await center.explain(ExplainKey("process:2")) { _ in self.request() }
        XCTAssertEqual(provider.explained, 3)

        center.choice = .none
        XCTAssertEqual(center.state(for: key), .needsProvider)
        center.choice = .appleIntelligence
        XCTAssertEqual(center.state(for: key), .explained(explanation, sent))
    }

    func testAnUnavailableProviderIsNotAskedToExplain() async {
        let provider = FakeProvider()
        provider.status = .appleIntelligenceNotEnabled
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("disk:/x")
        await center.explain(key) { _ in self.request() }
        XCTAssertEqual(center.state(for: key), .unavailable(.appleIntelligenceNotEnabled))
        XCTAssertEqual(center.availability, .appleIntelligenceNotEnabled)
        XCTAssertEqual(provider.explained, 0)

        provider.status = .available
        await center.explain(key) { _ in self.request() }
        XCTAssertEqual(provider.explained, 1)
    }

    func testAnItemBeingExplainedIsNotAskedTwice() async throws {
        let provider = FakeProvider()
        let gate = AnswerGate()
        provider.gate = gate
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("process:1")
        let first = Task { await center.explain(key) { _ in self.request() } }
        await gate.reached()
        guard case .working = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
        await center.explain(key) { _ in self.request() }
        gate.open()
        await first.value
        XCTAssertEqual(provider.explained, 1)
        guard case .explained = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
    }

    func testClearingTheProviderWhileItsAvailabilityIsReadSendsNothing() async throws {
        let provider = FakeProvider()
        let gate = AnswerGate()
        provider.availabilityGate = gate
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("process:1")
        let asked = Task { await center.explain(key) { _ in self.request() } }
        await gate.reached()
        center.choice = .none
        gate.open()
        await asked.value
        XCTAssertEqual(provider.explained, 0, "the request is not sent to a provider no longer chosen")
        XCTAssertNil(center.availability)
        center.choice = .appleIntelligence
        XCTAssertEqual(center.state(for: key), .idle)
    }

    func testAnAnswerThatArrivesAfterTheProviderWasClearedIsNotKept() async throws {
        let provider = FakeProvider()
        let gate = AnswerGate()
        provider.gate = gate
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("process:1")
        let asked = Task { await center.explain(key) { _ in self.request() } }
        await gate.reached()
        center.choice = .none
        gate.open()
        await asked.value
        XCTAssertEqual(provider.explained, 1)
        center.choice = .appleIntelligence
        XCTAssertEqual(center.state(for: key), .idle, "no answer is kept, and the item can be explained again")
    }

    func testTurningFolderNamesOffWhileAvailabilityIsReadSendsNoFolderName() async throws {
        let provider = FakeProvider()
        let gate = AnswerGate()
        provider.availabilityGate = gate
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        center.sendFolderNames = true
        let key = ExplainKey("disk:/Users/jdoe/dev/secret-client")
        let build = { (redactor: ExplainRedactor) -> ExplainRequest? in
            var facts = ExplainFacts(kind: .folder, name: redactor.name(ofPath: "/Users/jdoe/dev/secret-client"))
            facts.path = "/Users/jdoe/dev/secret-client"
            return ExplainRequest(facts, redactor: redactor)
        }
        let asked = Task { await center.explain(key, request: build) }
        await gate.reached()
        guard case let .working(built) = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
        XCTAssertTrue(built.promptText.contains("secret-client"), "built with folder names on")
        center.sendFolderNames = false
        gate.open()
        await asked.value
        XCTAssertEqual(provider.requests.count, 1)
        let sent = try XCTUnwrap(provider.requests.first)
        XCTAssertFalse(sent.promptText.contains("secret-client"), sent.promptText)
        XCTAssertEqual(sent, build(center.redactor))
        guard case let .explained(_, shown) = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
        XCTAssertEqual(shown, sent, "What was sent shows the request rebuilt")
    }

    func testAnItemGoneBeforeItsRequestIsBuiltSaysSoAndSendsNothing() async {
        let provider = FakeProvider()
        let center = center(defaults(), provider: provider)
        center.choice = .appleIntelligence
        let key = ExplainKey("disk:/gone")
        await center.explain(key) { _ in nil }
        XCTAssertEqual(center.state(for: key), .gone)
        XCTAssertEqual(provider.availabilityReads, 0)
        XCTAssertEqual(provider.explained, 0)
        await center.explain(key) { _ in self.request() }
        guard case .explained = center.state(for: key) else { return XCTFail("\(center.state(for: key))") }
    }

    func testTheSettingIsKeptAndSendFolderNamesChangesTheRedactor() {
        let defaults = defaults()
        let center = center(defaults, provider: nil)
        XCTAssertFalse(center.redactor.sendFolderNames)
        center.choice = .appleIntelligence
        center.sendFolderNames = true
        XCTAssertTrue(center.redactor.sendFolderNames)
        let reopened = self.center(defaults, provider: nil)
        XCTAssertEqual(reopened.choice, .appleIntelligence)
        XCTAssertTrue(reopened.sendFolderNames)
    }

    // MARK: Availability

    func testFoundationModelsAvailabilityIsShownWithItsMeaning() throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let cases: [(SystemLanguageModel.Availability, AIAvailability)] = [
            (.available, .available),
            (.unavailable(.deviceNotEligible), .deviceNotEligible),
            (.unavailable(.appleIntelligenceNotEnabled), .appleIntelligenceNotEnabled),
            (.unavailable(.modelNotReady), .modelNotReady)
        ]
        for (reported, shown) in cases {
            XCTAssertEqual(AIAvailability(reported), shown)
            XCTAssertFalse(shown.meaning.isEmpty)
        }
        XCTAssertTrue(AIAvailability.available.isAvailable)
        XCTAssertFalse(AIAvailability(.unavailable(.modelNotReady)).isAvailable)
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
    }
}

final class Counter {
    var count = 0
}

/// A provider that answers with `answer`, counting what it is asked.
final class FakeProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _status = AIAvailability.available
    private var _answer = ExplanationDraft(summary: "A sync agent.", whatItIs: "It syncs files.", removalSafety: "review",
                                           howToRemove: "Quit it, then move it to the Trash.", confidence: "medium")
    private var _explained = 0
    private var _requests: [ExplainRequest] = []
    private var _availabilityReads = 0
    var gate: AnswerGate?
    /// Holds the availability read until the test opens it.
    var availabilityGate: AnswerGate?

    var status: AIAvailability {
        get { lock.withLock { _status } }
        set { lock.withLock { _status = newValue } }
    }
    var answer: ExplanationDraft {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var explained: Int { lock.withLock { _explained } }
    var requests: [ExplainRequest] { lock.withLock { _requests } }
    var availabilityReads: Int { lock.withLock { _availabilityReads } }

    func availability() async -> AIAvailability {
        await availabilityGate?.pass()
        return lock.withLock {
            _availabilityReads += 1
            return _status
        }
    }

    func explain(_ request: ExplainRequest) async throws -> ExplanationDraft {
        lock.withLock {
            _explained += 1
            _requests.append(request)
        }
        await gate?.pass()
        return answer
    }
}

/// Holds the first answer until the test opens it.
final class AnswerGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: CheckedContinuation<Void, Never>?
    private var watcher: CheckedContinuation<Void, Never>?
    private var isOpen = false
    private var hasArrived = false

    func pass() async {
        await withCheckedContinuation { continuation in
            let (open, watcher) = lock.withLock {
                hasArrived = true
                if !isOpen { waiting = continuation }
                defer { self.watcher = nil }
                return (isOpen, self.watcher)
            }
            watcher?.resume()
            if open { continuation.resume() }
        }
    }

    /// Returns once an answer is waiting at the gate.
    func reached() async {
        await withCheckedContinuation { continuation in
            let arrived = lock.withLock {
                if !hasArrived { watcher = continuation }
                return hasArrived
            }
            if arrived { continuation.resume() }
        }
    }

    func open() {
        let waiting = lock.withLock {
            isOpen = true
            defer { self.waiting = nil }
            return self.waiting
        }
        waiting?.resume()
    }
}
