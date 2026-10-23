import Foundation
import Security
@testable import SystemCore
import XCTest

/// Choosing OpenRouter for Explain and the send preview (SET-160), with the Keychain double and the `URLProtocol` stub
/// of `OpenRouterTests`, never the network or the real Keychain: OpenRouter chosen only while its key is stored; the
/// choice set back, with a notice, by every check that finds it cannot be used; the first request of the session sent
/// only once its preview is confirmed, with exactly the body shown; and the work in flight ended by a provider change,
/// Add Key or Remove Key, and Send folder names.
@MainActor
final class OpenRouterExplainTests: XCTestCase {
    private static let key = "sk-or-v1-" + String(repeating: "0123456789abcdef", count: 4)
    private static let answer = #"{"summary":"A sync agent.","whatItIs":"It syncs files.","removalSafety":"review","howToRemove":"Quit it.","confidence":"medium","suggestedOrigin":null}"#
    private let redactor = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: ["jdoe"], sendFolderNames: false,
                                           key: Array(repeating: 7, count: 32))

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    // MARK: Choosing OpenRouter

    func testOpenRouterCanBeChosenOnlyWhileItsKeyIsStored() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain, key: nil)
        let center = center(defaults, account)
        XCTAssertFalse(center.canChoose(.openRouter))
        XCTAssertFalse(center.choose(.openRouter), "no key stored")
        XCTAssertEqual(center.choice, .none)
        XCTAssertNil(defaults.string(forKey: ExplainCenter.choiceKey))

        await account.addKey(Self.key)
        XCTAssertTrue(center.canChoose(.openRouter))
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "openRouter")
        await center.refreshAvailability()
        XCTAssertEqual(center.availability, .availableOnOpenRouter)

        // Without the account, OpenRouter is not offered.
        let bare = ExplainCenter(defaults: self.defaults(), redactor: redactor, provider: { _ in nil })
        XCTAssertFalse(bare.choose(.openRouter))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testRemovingTheKeySetsTheChoiceBackAndSaysWhy() async throws {
        let defaults = defaults()
        let account = await account(defaults, keychain: FakeKeychain())
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        await account.removeKey()
        XCTAssertEqual(center.choice, .appleIntelligence, "never left on a provider that cannot run")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.noKey))
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence", "stored as shown")
        XCTAssertFalse(center.choose(.openRouter))

        // Choosing a provider clears the notice.
        center.choose(.none)
        XCTAssertNil(center.notice)
    }

    func testAKeychainThatDoesNotAnswerWhetherAKeyIsStoredSetsTheChoiceBack() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        keychain.failure = errSecInteractionNotAllowed
        await account.refreshKey()
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(center.notice, ExplainCenter.notice(.keyUnreadable))
        XCTAssertFalse(center.canChoose(.openRouter), "not while whether a key is stored is unknown")

        // Once it answers again, OpenRouter can be chosen again, but is not chosen for the user.
        keychain.failure = nil
        await account.refreshKey()
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertTrue(center.choose(.openRouter))
    }

    /// Settings says why OpenRouter cannot be chosen as it is, not only that a key must be stored: a key that Settings
    /// still shows as stored is being changed, or the Keychain has not said whether it is stored.
    func testSettingsSaysWhyOpenRouterCannotBeChosen() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = launching(defaults, keychain: keychain)
        let center = center(defaults, account)
        XCTAssertEqual(center.openRouterUnavailableReason, ExplainCenter.waitsForKeychain, "not read yet")
        await account.refreshKey()
        XCTAssertEqual(center.openRouterUnavailableReason, ExplainCenter.waitsForKey)

        await account.addKey(Self.key)
        XCTAssertNil(center.openRouterUnavailableReason)
        keychain.holdsOtherCalls = true
        let removing = Task { await account.removeKey() }
        try await until { keychain.heldOtherCalls == 1 }
        XCTAssertTrue(account.hasKey, "still shown as stored")
        XCTAssertEqual(center.openRouterUnavailableReason, ExplainCenter.waitsForKeyChange)
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        await removing.value
        XCTAssertEqual(center.openRouterUnavailableReason, ExplainCenter.waitsForKey)

        await account.addKey(Self.key)
        keychain.failure = errSecInteractionNotAllowed
        await account.refreshKey()
        XCTAssertTrue(account.hasKey, "still shown as stored")
        XCTAssertEqual(center.openRouterUnavailableReason, ExplainCenter.waitsForKeychain)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAStoredChoiceOfOpenRouterFollowsTheFirstReadOfWhetherAKeyIsStored() async throws {
        // A key stored: kept.
        let kept = defaults()
        kept.set("openRouter", forKey: ExplainCenter.choiceKey)
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let account = launching(kept, keychain: keychain)
        let center = center(kept, account)
        XCTAssertEqual(center.choice, .openRouter, "kept until the launch read answers")
        await account.refreshKey()
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertNil(center.notice)

        // No key stored: set back, and stored so.
        let gone = defaults()
        gone.set("openRouter", forKey: ExplainCenter.choiceKey)
        let empty = launching(gone, keychain: FakeKeychain())
        let setBack = self.center(gone, empty)
        await empty.refreshKey()
        XCTAssertEqual(setBack.choice, .appleIntelligence)
        XCTAssertEqual(setBack.notice, ExplainCenter.notice(.noKey))
        XCTAssertEqual(self.center(gone, empty).choice, .appleIntelligence, "the next launch shows what was shown")

        // The Keychain failing at launch: set back too.
        let failing = defaults()
        failing.set("openRouter", forKey: ExplainCenter.choiceKey)
        let locked = FakeKeychain()
        try OpenRouterKeyStore(items: locked).save(Self.key)
        locked.failure = errSecInteractionNotAllowed
        let unread = launching(failing, keychain: locked)
        let unreadCenter = self.center(failing, unread)
        await unread.refreshKey()
        XCTAssertEqual(unreadCenter.choice, .appleIntelligence)
        XCTAssertEqual(failing.string(forKey: ExplainCenter.choiceKey), "appleIntelligence")

        // Without the account, or with no key known to be stored when it is made, it starts set back.
        let bare = defaults()
        bare.set("openRouter", forKey: ExplainCenter.choiceKey)
        XCTAssertEqual(ExplainCenter(defaults: bare, redactor: redactor, provider: { _ in nil }).choice, .appleIntelligence)
        gone.set("openRouter", forKey: ExplainCenter.choiceKey)
        let late = self.center(gone, empty)
        XCTAssertEqual(late.choice, .appleIntelligence)
        XCTAssertEqual(late.notice, ExplainCenter.notice(.noKey))
        XCTAssertEqual(gone.string(forKey: ExplainCenter.choiceKey), "appleIntelligence")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAModelIDThatHeldTheKeyOrCouldNotBeCheckedSetsTheChoiceBack() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        account.model = "x/\(Self.key)"
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(center.notice, ExplainCenter.notice(.modelHeldKey))

        XCTAssertTrue(center.choose(.openRouter))
        keychain.failure = errSecInteractionNotAllowed
        account.model = "anthropic/claude-sonnet-4"
        await account.modelChecked()
        XCTAssertEqual(account.modelError, OpenRouterAccount.modelUncheckedMessage)
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(center.notice, ExplainCenter.notice(.modelUnchecked))

        // A model ID that is not one uses openrouter/auto: OpenRouter still runs, so the choice stays.
        keychain.failure = nil
        await account.refreshKey()
        XCTAssertTrue(center.choose(.openRouter))
        account.model = "not a model"
        await account.modelChecked()
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testOpenRouterSayingNoKeyIsStoredSetsTheChoiceBackAndSendsNothing() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        // Removed outside System, after the account last read it.
        try OpenRouterKeyStore(items: keychain).remove()
        await center.explain(ExplainKey("process:1")) { _ in self.request() }
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(center.notice, ExplainCenter.notice(.noKey))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        try await until { !account.hasKey }
    }

    /// OpenRouter answers whether it is available from the Keychain alone, so a read that does not answer in time, for
    /// Settings or as a request is about to be built, is the Keychain not answering: the choice is set back, stored so,
    /// with the reason, and nothing is previewed or sent.
    func testAnOpenRouterAvailabilityReadThatDoesNotAnswerInTimeSetsTheChoiceBack() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account,
                                   availabilityTimeout: .milliseconds(200))
        XCTAssertTrue(center.choose(.openRouter))

        // Settings: whether a key is stored is held past the timeout.
        keychain.holdsOtherCalls = true
        await center.refreshAvailability()
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence", "stored as shown")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.keyUnreadable))
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()

        // Explain: the read of the key that checks the model ID before the preview is held past the timeout.
        XCTAssertTrue(center.choose(.openRouter), "the key is still shown as stored")
        let item = ExplainKey("process:1")
        keychain.holdsDataReads = true
        await center.explain(item) { _ in self.request() }
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.keyUnreadable))
        keychain.holdsDataReads = false
        keychain.releaseDataRead()
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.state(for: item), .idle, "never previewed, and no failure kept")
        XCTAssertNil(center.sentText(for: item))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    /// Only the latest OpenRouter read, not cancelled, that does not answer in time sets the choice back; the on-device
    /// provider not answering in time keeps its choice.
    func testOnlyTheLatestOpenRouterReadNotAnsweringInTimeSetsTheChoiceBack() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let silent = FakeProvider()
        silent.availabilityGate = AnswerGate()
        let center = ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account, provider: {
            $0 == .appleIntelligence ? silent : ExplainCenter.liveProvider($0, openRouter: account)
        }, availabilityTimeout: .milliseconds(300))

        center.choose(.appleIntelligence)
        await center.refreshAvailability()
        XCTAssertEqual(center.availabilityStatus, .noAnswer(seconds: 0))
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertNil(center.notice)
        silent.availabilityGate?.open()

        // Cancelled, as when Settings closes: not set back.
        XCTAssertTrue(center.choose(.openRouter))
        keychain.holdsOtherCalls = true
        let cancelled = Task { await center.refreshAvailability() }
        try await until { keychain.heldOtherCalls == 1 }
        cancelled.cancel()
        await cancelled.value
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertNil(center.notice)

        // Overtaken by a later read that answers before it would time out: not set back.
        let overtaken = Task { await center.refreshAvailability() }
        try await until { keychain.heldOtherCalls == 2 }
        keychain.holdsOtherCalls = false
        await center.refreshAvailability()
        XCTAssertEqual(center.availability, .availableOnOpenRouter)
        await overtaken.value
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertEqual(center.availability, .availableOnOpenRouter, "the newer read is kept")
        XCTAssertNil(center.notice)
        keychain.releaseOtherCall()
        keychain.releaseOtherCall()
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    /// An OpenRouter read that a later one overtook, which then finds the key unreadable, sets nothing back: the
    /// newer read, an Explain whose preview is shown or Settings', stands, and only the overtaken request ends, unsent.
    /// The latest read finding it unreadable still sets the choice back.
    func testAnOvertakenOpenRouterReadThatFindsTheKeyUnreadableSetsNothingBack() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        let first = ExplainKey("process:1"), second = ExplainKey("process:2"), third = ExplainKey("process:3")

        /// Explains `item` with its read of the key failing, held until `overtake` has run.
        func overtaken(_ item: ExplainKey, by overtake: () async throws -> Void) async throws {
            keychain.failure = errSecInteractionNotAllowed
            keychain.holdsDataReads = true
            let held = Task { await center.explain(item) { _ in self.request() } }
            try await until { keychain.heldDataReads == 1 }
            keychain.holdsDataReads = false
            keychain.failure = nil
            try await overtake()
            keychain.releaseDataRead()
            await held.value
            XCTAssertEqual(center.choice, .openRouter)
            XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "openRouter", "stored as shown")
            XCTAssertNil(center.notice)
            XCTAssertEqual(center.state(for: item), .unavailable(.openRouterKeyUnreadable), "only its own item ends")
            XCTAssertNil(center.sentText(for: item))
            XCTAssertEqual(center.availability, .availableOnOpenRouter, "the newer read is shown")
        }

        // Overtaken by another item's Explain, which read the key and shows its preview.
        var preview: SendPreview?
        try await overtaken(first) {
            await center.explain(second) { _ in self.request("backupd") }
            preview = try XCTUnwrap(confirming(center, second))
        }
        XCTAssertEqual(confirming(center, second), preview, "the newer preview is kept")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await center.confirmSend(second)
        XCTAssertEqual(StubProtocol.requests.map(\.body), [try XCTUnwrap(preview).body])

        // Overtaken by Settings' read, which found the key stored.
        try await overtaken(third) { await center.refreshAvailability() }
        XCTAssertEqual(StubProtocol.requests.count, 1)

        // The latest read finding the key unreadable sets the choice back.
        keychain.failure = errSecInteractionNotAllowed
        await center.explain(third) { _ in self.request() }
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.keyUnreadable))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// A model ID checked against the key stored then, which holds the key that replaced it outside System: the
    /// request is refused before it is previewed, so the key is never shown as the model or sent, and that sets the
    /// choice back, says why, and clears the model ID.
    func testAModelIDThatHoldsAKeyReplacedOutsideSystemSetsTheChoiceBackAndIsCleared() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        let other = "tok-0123456789abcdef"
        account.model = "acme/\(other)"
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, "acme/\(other)", "it does not hold the key stored now")
        XCTAssertTrue(center.choose(.openRouter))
        try OpenRouterKeyStore(items: keychain).save(other)

        let item = ExplainKey("process:1")
        let reads = keychain.dataReads
        await center.explain(item) { _ in self.request() }
        XCTAssertEqual(keychain.dataReads, reads + 1, "the key was read to check the model ID with")
        XCTAssertEqual(keychain.mainThreadDataReads, 0, "off the main thread")
        // Set back as availability was read, before a preview could be built.
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(center.state(for: item), .idle, "never previewed")
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing sent with the key in the body")
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence", "stored as shown")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.modelHeldKey))
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        XCTAssertFalse(center.sendConfirmed)

        // Chosen again, it uses openrouter/auto.
        XCTAssertTrue(center.choose(.openRouter))
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await center.explain(item) { _ in self.request() }
        let preview = try XCTUnwrap(confirming(center, item))
        XCTAssertTrue(preview.text.contains(#""model" : "openrouter/auto""#), preview.text)
        await center.confirmSend(item)
        XCTAssertEqual(StubProtocol.requests.map(\.body), [preview.body])

        // Set back however the refusal comes, the model ID in use having changed since included.
        let refusing = ExplainCenter(defaults: self.defaults(), redactor: redactor, openRouter: account,
                                     provider: { $0 == .openRouter ? RefusingProvider() : nil })
        XCTAssertTrue(refusing.choose(.openRouter))
        await refusing.explain(item) { _ in self.request() }
        await refusing.confirmSend(item)
        XCTAssertEqual(refusing.choice, .appleIntelligence)
        XCTAssertEqual(refusing.notice, ExplainCenter.notice(.modelHeldKey))
    }

    /// The key replaced outside System, after the preview was built, by one the model ID holds: OpenRouter refuses the
    /// confirmed body as it is sent, which sets the choice back, says why, and clears that model ID.
    func testAModelIDThatHoldsAKeyReplacedAfterThePreviewIsRefusedAsItIsSentAndCleared() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        let center = center(defaults, account)
        let other = "tok-0123456789abcdef"
        account.model = "acme/\(other)"
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, "acme/\(other)")
        XCTAssertTrue(center.choose(.openRouter))
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        XCTAssertNotNil(confirming(center, item), "the model ID does not hold the key stored as it is built")

        try OpenRouterKeyStore(items: keychain).save(other)
        await center.confirmSend(item)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing sent with the key in the body")
        XCTAssertEqual(center.choice, .appleIntelligence)
        XCTAssertEqual(defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence", "stored as shown")
        XCTAssertEqual(center.notice, ExplainCenter.notice(.modelHeldKey))
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        XCTAssertFalse(center.sendConfirmed)
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.state(for: item), .idle)
        XCTAssertNil(center.sentText(for: item))
    }

    func testARequestRefusedBeforeItIsSentKeepsNeitherItsStateNorItsBody() async throws {
        let defaults = defaults()
        let account = await account(defaults, keychain: FakeKeychain())
        let item = ExplainKey("process:1")
        for refusal in [AIAvailability.openRouterModelHeldKey, .noOpenRouterKey, .openRouterKeyUnreadable] {
            let center = ExplainCenter(defaults: self.defaults(), redactor: redactor, openRouter: account,
                                       provider: { $0 == .openRouter ? RefusingProvider(refusal: refusal) : nil })
            XCTAssertTrue(center.choose(.openRouter))
            await center.explain(item) { _ in self.request() }
            await center.confirmSend(item)
            XCTAssertEqual(center.choice, .appleIntelligence, "\(refusal)")
            // The key is still stored, so the reason the request was refused is not shown once chosen again.
            await account.refreshKey()
            XCTAssertTrue(center.choose(.openRouter), "\(refusal)")
            XCTAssertEqual(center.state(for: item), .idle, "\(refusal)")
            XCTAssertNil(center.sentText(for: item), "\(refusal): nothing left this Mac")
        }

        // A refusal that does not set the choice back is shown, with nothing sent.
        let center = ExplainCenter(defaults: self.defaults(), redactor: redactor, openRouter: account,
                                   provider: { $0 == .openRouter ? RefusingProvider(refusal: .notInThisBuild) : nil })
        XCTAssertTrue(center.choose(.openRouter))
        await center.explain(item) { _ in self.request() }
        await center.confirmSend(item)
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertEqual(center.state(for: item), .unavailable(.notInThisBuild))
        XCTAssertNil(center.sentText(for: item), "nothing left this Mac")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: Send preview

    func testTheFirstRequestWaitsForThePreviewAndTheBodySentIsTheBodyShownByteForByte() async throws {
        let (center, _, _) = await chosen()
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let first = ExplainKey("process:1")
        await center.explain(first) { _ in self.request("syncd") }
        let preview = try XCTUnwrap(confirming(center, first))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing is sent before the user confirms")
        XCTAssertEqual(preview.provider, .openRouter)
        XCTAssertEqual(preview.request, request("syncd"))
        XCTAssertTrue(preview.text.contains(request("syncd").promptText.jsonEscaped), "the redacted request, as JSON")
        XCTAssertFalse(preview.text.contains(Self.key))

        await center.confirmSend(first)
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(StubProtocol.requests.first?.body, preview.body, "sent byte for byte as shown")
        guard case .explained = center.state(for: first) else { return XCTFail("\(center.state(for: first))") }
        XCTAssertTrue(center.sendConfirmed)
        XCTAssertEqual(center.sentText(for: first), preview.text, "What was sent shows the body")

        // Not shown again this session.
        let second = ExplainKey("process:2")
        await center.explain(second) { _ in self.request("cloudd") }
        guard case .explained = center.state(for: second) else { return XCTFail("\(center.state(for: second))") }
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testCancellingThePreviewSendsNothingAndItIsShownAgain() async throws {
        let (center, _, _) = await chosen()
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        XCTAssertNotNil(confirming(center, item))
        center.cancelSend(item)
        XCTAssertEqual(center.state(for: item), .idle)
        await center.confirmSend(item)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "a cancelled preview cannot be sent")
        XCTAssertFalse(center.sendConfirmed)

        await center.explain(item) { _ in self.request() }
        XCTAssertNotNil(confirming(center, item), "still required")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    /// Whether it reached OpenRouter is not known, so the next request is previewed too.
    func testAConfirmedRequestThatOpenRouterDidNotAnswerLeavesThePreviewRequired() async throws {
        let (center, _, _) = await chosen()
        StubProtocol.enqueue(error: URLError(.notConnectedToInternet))
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        await center.confirmSend(item)
        guard case .failed = center.state(for: item) else { return XCTFail("\(center.state(for: item))") }
        XCTAssertFalse(center.sendConfirmed)
        await center.explain(ExplainKey("process:2")) { _ in self.request("cloudd") }
        XCTAssertNotNil(confirming(center, ExplainKey("process:2")))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    /// OpenRouter answering a confirmed request with an error status, after the retry, with an error, or with a refusal
    /// shows it reached OpenRouter: no preview is shown again this session.
    func testAConfirmedRequestThatOpenRouterAnsweredWithAFailureIsNotPreviewedAgain() async throws {
        let answers: [[(Int, String)]] = [
            [(401, #"{"error":{"code":401,"message":"No auth credentials found"}}"#)],
            [(402, #"{"error":{"code":402,"message":"Insufficient credits"}}"#)],
            [(503, #"{"error":{"code":503,"message":"Busy"}}"#), (503, #"{"error":{"code":503,"message":"Busy"}}"#)],
            [(200, #"{"error":{"code":502,"message":"Upstream failed"}}"#)],
            [(200, #"{"choices":[{"message":{"content":"","refusal":"No."}}]}"#)]
        ]
        for answer in answers {
            StubProtocol.reset()
            let (center, _, _) = await chosen()
            for (status, json) in answer { StubProtocol.enqueue(status: status, json: json) }
            let item = ExplainKey("process:1")
            await center.explain(item) { _ in self.request() }
            await center.confirmSend(item)
            guard case .failed = center.state(for: item) else { return XCTFail("\(answer): \(center.state(for: item))") }
            XCTAssertTrue(center.sendConfirmed, "\(answer)")

            StubProtocol.enqueue(status: 200, json: completion(Self.answer))
            let next = ExplainKey("process:2")
            await center.explain(next) { _ in self.request("cloudd") }
            guard case .explained = center.state(for: next) else { return XCTFail("\(answer): \(center.state(for: next))") }
            XCTAssertEqual(StubProtocol.requests.count, answer.count + 1, "\(answer)")
        }
    }

    /// Every request sent before OpenRouter answered a confirmed one was itself previewed and confirmed: one asked for
    /// while the first confirmed request is on its way waits for its own preview.
    func testEveryRequestBeforeTheFirstAnswerIsPreviewedItself() async throws {
        let (center, keychain, _) = await chosen()
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let a = ExplainKey("process:a"), b = ExplainKey("process:b"), c = ExplainKey("process:c")
        await center.explain(a) { _ in self.request("alpha") }
        await center.explain(b) { _ in self.request("beta") }
        let previewA = try XCTUnwrap(confirming(center, a))
        let previewB = try XCTUnwrap(confirming(center, b))
        XCTAssertNotEqual(previewA.body, previewB.body)

        keychain.holdsDataReads = true
        let sendingA = Task { await center.confirmSend(a) }
        try await until { keychain.heldDataReads == 1 }
        // C's own read of the key, which checks the model ID before its preview, is not held.
        keychain.holdsDataReads = false
        await center.explain(c) { _ in self.request("gamma") }
        XCTAssertNotNil(confirming(center, c), "A has not been answered yet")
        keychain.releaseDataRead()
        await sendingA.value
        XCTAssertEqual(StubProtocol.requests.map(\.body), [previewA.body])
        XCTAssertTrue(center.sendConfirmed)
        XCTAssertNotNil(confirming(center, b), "a preview already shown waits for the user")

        await center.confirmSend(b)
        XCTAssertEqual(StubProtocol.requests.map(\.body), [previewA.body, previewB.body])
        let d = ExplainKey("process:d")
        await center.explain(d) { _ in self.request("delta") }
        guard case .explained = center.state(for: d) else { return XCTFail("\(center.state(for: d))") }
    }

    func testChangingTheProviderEndsAPreviewAndAConfirmedRequestBeforeItIsSent() async throws {
        let (center, keychain, _) = await chosen()
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        XCTAssertNotNil(confirming(center, item))
        center.choose(.appleIntelligence)
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.state(for: item), .idle, "the preview is withdrawn")
        await center.confirmSend(item)
        XCTAssertTrue(StubProtocol.requests.isEmpty)

        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await center.explain(item) { _ in self.request() }
        keychain.holdsDataReads = true
        let sending = Task { await center.confirmSend(item) }
        try await until { keychain.heldDataReads == 1 }
        center.choose(.none)
        keychain.holdsDataReads = false
        keychain.releaseDataRead()
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "cancelled before it went out")
        XCTAssertFalse(center.sendConfirmed)
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.state(for: item), .idle)
    }

    func testRemovingTheKeyWhileARequestReadsItSendsNothing() async throws {
        let (center, keychain, account) = await chosen()
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        keychain.holdsDataReads = true
        let sending = Task { await center.confirmSend(item) }
        try await until { keychain.heldDataReads == 1 }
        // The removal is held, so only Remove Key starting can end the request.
        keychain.holdsOtherCalls = true
        let removing = Task { await account.removeKey() }
        try await until { keychain.heldOtherCalls == 1 }
        XCTAssertEqual(center.state(for: item), .idle, "ended as Remove Key starts, before the Keychain is changed")
        keychain.holdsDataReads = false
        keychain.releaseDataRead()
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing sent with the key being removed")
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        await removing.value
        XCTAssertEqual(center.choice, .appleIntelligence)
    }

    /// No request to OpenRouter is begun, confirmed, or sent while Remove Key or Add Key waits for the Keychain, so none
    /// reads, or is sent with, the key being removed or replaced, even once the session's preview was confirmed.
    func testNothingIsSentWhileTheKeyIsBeingRemovedOrReplaced() async throws {
        for replacing in [false, true] {
            StubProtocol.reset()
            let (center, keychain, account) = await chosen()
            StubProtocol.enqueue(status: 200, json: completion(Self.answer))
            let first = ExplainKey("process:1")
            await center.explain(first) { _ in self.request() }
            await center.confirmSend(first)
            XCTAssertTrue(center.sendConfirmed)
            // Answers a request sent during the change, were one sent, then the one sent after it.
            StubProtocol.enqueue(status: 200, json: completion(Self.answer))
            StubProtocol.enqueue(status: 200, json: completion(Self.answer))

            // The key test holds the Keychain queue, so the change waits behind it; whether a key is stored, and the
            // key, still answer to the provider, which reads them on its own.
            keychain.holdsDataReads = true
            let testing = Task { await account.testKey() }
            try await until { keychain.heldDataReads == 1 }
            keychain.holdsDataReads = false
            let changing = Task {
                if replacing { await account.addKey("sk-or-v1-" + String(repeating: "f", count: 64)) } else { await account.removeKey() }
            }
            try await until { account.isChangingKey }
            let waiting = ExplainKey("process:2")
            await center.explain(waiting) { _ in self.request("cloudd") }
            XCTAssertEqual(center.state(for: waiting), .failed(ExplainCenter.keyChanging, request("cloudd")), "\(replacing)")
            await center.confirmSend(waiting)
            XCTAssertEqual(StubProtocol.requests.count, 1, "nothing sent while the key changes (\(replacing))")

            keychain.releaseDataRead()
            await changing.value
            await testing.value
            XCTAssertEqual(StubProtocol.requests.count, 1, "\(replacing)")
            XCTAssertFalse(StubProtocol.requests.dropFirst().contains { $0.headers["Authorization"] == "Bearer \(Self.key)" })
            XCTAssertEqual(center.choice, replacing ? .openRouter : .appleIntelligence)
            guard replacing else { continue }
            // Once replaced, a request is sent, with the new key.
            await center.explain(waiting) { _ in self.request("cloudd") }
            guard case .explained = center.state(for: waiting) else { return XCTFail("\(center.state(for: waiting))") }
            XCTAssertEqual(StubProtocol.requests.last?.headers["Authorization"], "Bearer sk-or-v1-" + String(repeating: "f", count: 64))
        }
    }

    /// A preview made before Remove Key starts is withdrawn then, and cannot be sent while the key is removed.
    func testAPreviewShownBeforeRemoveKeyCannotBeSentWhileItWaits() async throws {
        let (center, keychain, account) = await chosen()
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        XCTAssertNotNil(confirming(center, item))
        keychain.holdsOtherCalls = true
        let removing = Task { await account.removeKey() }
        try await until { keychain.heldOtherCalls == 1 }
        XCTAssertEqual(center.state(for: item), .idle, "withdrawn as Remove Key starts")
        await center.confirmSend(item)
        await center.explain(item) { _ in self.request() }
        XCTAssertEqual(center.state(for: item), .failed(ExplainCenter.keyChanging, request()))
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        await removing.value
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    /// Add Key ends the status Settings shows for OpenRouter as it starts; once the key is replaced and OpenRouter is
    /// still chosen, it is read again, so Settings does not fall back to a bare Check. Nothing is sent.
    func testReplacingTheKeyReadsOpenRouterAvailabilityAgain() async throws {
        let (center, keychain, account) = await chosen()
        await center.refreshAvailability()
        XCTAssertEqual(center.availabilityStatus, .read(.availableOnOpenRouter))
        keychain.holdsOtherCalls = true
        let replacing = Task { await account.addKey("sk-or-v1-" + String(repeating: "f", count: 64)) }
        try await until { keychain.heldOtherCalls == 1 }
        XCTAssertNil(center.availabilityStatus, "ended as the change starts")
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        let stored = await replacing.value
        XCTAssertTrue(stored)
        try await until { center.availabilityStatus == .read(.availableOnOpenRouter) }
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testTurningFolderNamesOffWithdrawsAPreviewAndStopsASendBuiltWithThem() async throws {
        let (center, keychain, _) = await chosen()
        center.sendFolderNames = true
        let item = ExplainKey("disk:/Users/jdoe/dev/secret-client")
        let build = { (redactor: ExplainRedactor) -> ExplainRequest? in
            var facts = ExplainFacts(kind: .folder, name: redactor.name(ofPath: "/Users/jdoe/dev/secret-client"))
            facts.path = "/Users/jdoe/dev/secret-client"
            return ExplainRequest(facts, redactor: redactor)
        }
        await center.explain(item, request: build)
        XCTAssertTrue(try XCTUnwrap(confirming(center, item)).text.contains("secret-client"))
        center.sendFolderNames = false
        XCTAssertEqual(center.state(for: item), .failed(ExplainCenter.changedBeforeSending, build(redactor.sendingFolderNames(true))!))
        await center.confirmSend(item)
        XCTAssertTrue(StubProtocol.requests.isEmpty)

        // Confirmed, then turned off while the key is read: nothing is sent.
        center.sendFolderNames = true
        await center.explain(item, request: build)
        keychain.holdsDataReads = true
        let sending = Task { await center.confirmSend(item) }
        try await until { keychain.heldDataReads == 1 }
        center.sendFolderNames = false
        keychain.holdsDataReads = false
        keychain.releaseDataRead()
        await sending.value
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        guard case let .failed(message, _) = center.state(for: item) else { return XCTFail("\(center.state(for: item))") }
        XCTAssertEqual(message, ExplainCenter.changedWhileSending)
    }

    func testTurningFolderNamesOffDuringTheBackoffSendsNoRetry() async throws {
        let backoff = WaitRecorder()
        let (center, _, _) = await chosen(sleep: { duration in
            await backoff.record(duration)
            // Long enough that a retry sent after it would be seen; a cancelled task ends it at once.
            try await Task.sleep(for: .seconds(2))
        })
        center.sendFolderNames = true
        StubProtocol.enqueue(status: 503, json: #"{"error":{"code":503,"message":"Busy"}}"#)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        let sending = Task { await center.confirmSend(item) }
        try await until { !backoff.durations.isEmpty }
        center.sendFolderNames = false
        await sending.value
        try await Task.sleep(for: .milliseconds(2_100))
        XCTAssertEqual(StubProtocol.requests.count, 1, "no retry of a body built with folder names")
        guard case let .failed(message, _) = center.state(for: item) else { return XCTFail("\(center.state(for: item))") }
        XCTAssertEqual(message, ExplainCenter.changedWhileSending)
    }

    func testTheOnDeviceProviderIsNeverPreviewed() async throws {
        let provider = FakeProvider()
        let center = ExplainCenter(defaults: defaults(), redactor: redactor, provider: { $0 == .appleIntelligence ? provider : nil })
        center.choose(.appleIntelligence)
        let item = ExplainKey("process:1")
        await center.explain(item) { _ in self.request() }
        guard case .explained = center.state(for: item) else { return XCTFail("\(center.state(for: item))") }
        XCTAssertNil(center.sentText(for: item), "nothing left this Mac")
        XCTAssertFalse(center.sendConfirmed)
    }

    // MARK: Helpers

    private func defaults() -> UserDefaults {
        let name = "OpenRouterExplainTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func completion(_ content: String) -> String {
        let message = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
        return String(decoding: message, as: UTF8.self)
    }

    /// An account as the app makes it at launch, before it reads whether a key is stored.
    private func launching(_ defaults: UserDefaults, keychain: FakeKeychain,
                           sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) -> OpenRouterAccount {
        let client = OpenRouterClient(session: StubProtocol.session(), log: RecordingLog(), sleep: sleep)
        return OpenRouterAccount(keys: OpenRouterKeyStore(items: keychain), client: client, defaults: defaults,
                                 log: RecordingLog())
    }

    /// An account that has read whether a key is stored; `key`, when given, is stored first.
    private func account(_ defaults: UserDefaults, keychain: FakeKeychain, key: String? = OpenRouterExplainTests.key,
                         sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) async -> OpenRouterAccount {
        if let key { try? OpenRouterKeyStore(items: keychain).save(key) }
        let account = launching(defaults, keychain: keychain, sleep: sleep)
        await account.refreshKey()
        return account
    }

    /// Explain with the live providers and `account`.
    private func center(_ defaults: UserDefaults, _ account: OpenRouterAccount) -> ExplainCenter {
        ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account)
    }

    /// Explain with OpenRouter chosen and a key stored.
    private func chosen(sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in }) async
        -> (ExplainCenter, FakeKeychain, OpenRouterAccount) {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain, sleep: sleep)
        let center = center(defaults, account)
        XCTAssertTrue(center.choose(.openRouter))
        return (center, keychain, account)
    }

    private func request(_ name: String = "syncd") -> ExplainRequest {
        ExplainRequest(ExplainFacts(kind: .process, name: name), redactor: redactor)
    }

    private func confirming(_ center: ExplainCenter, _ item: ExplainKey) -> SendPreview? {
        if case let .confirming(preview) = center.state(for: item) { preview } else { nil }
    }

    /// Waits until `condition` holds.
    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never")
        throw CancellationError()
    }
}

/// Available, then refuses every request before sending it, by default because the model ID holds the key, as
/// `OpenRouterProvider` does.
private struct RefusingProvider: AIProvider {
    var refusal = AIAvailability.openRouterModelHeldKey

    func availability() async -> AIAvailability { .availableOnOpenRouter }
    func explain(_: ExplainRequest) async throws -> ExplanationDraft { throw ExplainError.unavailable(refusal) }
    func sentBody(for _: ExplainRequest) throws -> Data? { Data("{}".utf8) }
}

private extension String {
    /// As a JSON string's contents, with `/` unescaped as the body writes it.
    var jsonEscaped: String {
        let data = try! JSONSerialization.data(withJSONObject: self, options: [.fragmentsAllowed, .withoutEscapingSlashes])
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }
}
