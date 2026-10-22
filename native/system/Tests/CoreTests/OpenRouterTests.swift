import Foundation
import Security
@testable import SystemCore
import XCTest

/// OpenRouter without the network or the real Keychain (SET-50): the key store against a Keychain double, the key
/// kept out of user defaults and every log call, the request and its retries against a `URLProtocol` stub, the key
/// test, and the send preview. A live OpenRouter run is SET-56's.
@MainActor
final class OpenRouterTests: XCTestCase {
    private static let key = "sk-or-v1-" + String(repeating: "0123456789abcdef", count: 4)
    private let redactor = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: ["jdoe"], sendFolderNames: false,
                                           key: Array(repeating: 7, count: 32))

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    // MARK: Key storage

    func testTheKeyIsAddedReadReplacedAndRemovedAsAThisDeviceOnlyGenericPassword() throws {
        let keychain = FakeKeychain()
        let store = OpenRouterKeyStore(items: keychain)
        XCTAssertFalse(try store.containsKey())
        XCTAssertNil(try store.readKey())

        try store.save(Self.key)
        XCTAssertTrue(try store.containsKey())
        XCTAssertEqual(try store.readKey(), Self.key)
        let item = try XCTUnwrap(keychain.item(dataProtection: true))
        XCTAssertEqual(item[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(item[kSecAttrService as String] as? String, "dev.subset.system.openrouter")
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertNil(item[kSecAttrSynchronizable as String])

        try store.save("sk-or-v1-replacement")
        XCTAssertEqual(try store.readKey(), "sk-or-v1-replacement")
        XCTAssertEqual(keychain.count, 1, "replaced, not added beside the old key")
        XCTAssertEqual(keychain.item(dataProtection: true)?[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)

        try store.remove()
        XCTAssertEqual(keychain.count, 0)
        XCTAssertFalse(try store.containsKey())
        XCTAssertNil(try store.readKey())
        XCTAssertNoThrow(try store.remove(), "removing no key is not an error")
    }

    func testWithoutTheDataProtectionEntitlementTheKeyIsKeptInTheLoginKeychainWithTheSameAttributes() throws {
        let keychain = FakeKeychain(entitled: false)
        let store = OpenRouterKeyStore(items: keychain)
        try store.save(Self.key)
        XCTAssertNil(keychain.item(dataProtection: true))
        let item = try XCTUnwrap(keychain.item(dataProtection: false))
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String,
                       kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(try store.readKey(), Self.key)
        try store.save("sk-or-v1-replacement")
        XCTAssertEqual(keychain.count, 1)
        XCTAssertEqual(try store.readKey(), "sk-or-v1-replacement")
        try store.remove()
        XCTAssertEqual(keychain.count, 0)

        // A key left in the login keychain moves to the data protection keychain once the build can use it.
        let moving = FakeKeychain(entitled: false)
        try OpenRouterKeyStore(items: moving).save(Self.key)
        moving.entitled = true
        try OpenRouterKeyStore(items: moving).save("sk-or-v1-replacement")
        XCTAssertNil(moving.item(dataProtection: false))
        XCTAssertNotNil(moving.item(dataProtection: true))
    }

    func testAKeychainFailureIsReportedAndAnUnusableStoredValueIsNotSent() throws {
        let keychain = FakeKeychain()
        keychain.failure = errSecInteractionNotAllowed
        let store = OpenRouterKeyStore(items: keychain)
        XCTAssertThrowsError(try store.containsKey()) { XCTAssertEqual($0 as? KeychainError, KeychainError(status: errSecInteractionNotAllowed)) }
        XCTAssertThrowsError(try store.save(Self.key))
        keychain.failure = nil
        keychain.set(dataProtection: true, data: Data("sk-or\nX-Injected: 1".utf8))
        XCTAssertThrowsError(try store.readKey(), "a value that is not one line of visible ASCII is not used as a key")
    }

    func testOnlyOneLineOfVisibleASCIIIsAcceptedAsAKey() {
        XCTAssertEqual(OpenRouterKeyStore.normalized("  \(Self.key)\n"), Self.key)
        for bad in ["", "   ", "sk-or v1", "sk-or\r\nX-Other: 1", "sk-or-\u{2028}x", "sk-or-ключ", String(repeating: "k", count: 513)] {
            XCTAssertNil(OpenRouterKeyStore.normalized(bad), bad)
        }
    }

    func testTheKeyIsNeverInUserDefaultsOrALogCall() async throws {
        let defaults = defaults()
        let log = RecordingLog()
        let keychain = FakeKeychain()
        let (center, account) = center(defaults, keychain: keychain, log: log)
        XCTAssertFalse(account.addKey("sk-or bad"), "refused")
        XCTAssertEqual(account.keyError, OpenRouterAccount.invalidKeyMessage)
        XCTAssertTrue(account.addKey(Self.key))
        XCTAssertNil(account.keyError)
        account.model = "anthropic/claude-sonnet"
        XCTAssertTrue(center.choose(.openRouter))
        center.sendFolderNames = true

        // A key test, an error that repeats the key, a retry, and an answer.
        StubProtocol.enqueue(status: 200, json: #"{"data":{"label":"sk-or-v1-0123…"}}"#)
        await account.testKey()
        XCTAssertEqual(account.keyTest, .passed)
        StubProtocol.enqueue(status: 503, json: #"{"error":{"code":503,"message":"Busy for key \#(Self.key)"}}"#)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await explainConfirmed(center, ExplainKey("a"))
        guard case .explained = center.state(for: ExplainKey("a")) else { return XCTFail("\(center.state(for: ExplainKey("a")))") }
        StubProtocol.enqueue(status: 401, json: #"{"error":{"code":401,"message":"Invalid key \#(Self.key)"}}"#)
        await center.explain(ExplainKey("b")) { _ in self.request() }
        guard case let .failed(message, _) = center.state(for: ExplainKey("b")) else {
            return XCTFail("\(center.state(for: ExplainKey("b")))")
        }
        XCTAssertFalse(message.contains(Self.key), message)
        XCTAssertTrue(message.contains("Invalid key [key]"), message)
        account.removeKey()

        XCTAssertFalse(log.messages.isEmpty)
        for message in log.messages {
            XCTAssertFalse(message.contains(Self.key) || message.contains("sk-or-v1"), message)
        }
        let domain = try XCTUnwrap(defaults.persistentDomain(forName: suiteName))
        XCTAssertEqual(domain["openRouterModel"] as? String, "anthropic/claude-sonnet")
        for (name, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(name) \(value)".contains(Self.key), name)
        }
    }

    // MARK: Provider setting

    func testOpenRouterCanBeChosenOnlyWhileAKeyIsStoredAndRemovingTheKeyTurnsItOff() {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let (center, account) = center(defaults, keychain: keychain)
        XCTAssertFalse(center.canChoose(.openRouter))
        XCTAssertFalse(center.choose(.openRouter))
        XCTAssertEqual(center.choice, .none)
        XCTAssertTrue(center.choose(.appleIntelligence))

        account.addKey(Self.key)
        XCTAssertTrue(center.choose(.openRouter))
        XCTAssertEqual(center.choice, .openRouter)
        XCTAssertEqual(self.center(defaults, keychain: keychain).0.choice, .openRouter, "kept while the key is")

        account.removeKey()
        XCTAssertFalse(account.hasKey)
        XCTAssertEqual(center.choice, .none)
        XCTAssertFalse(center.canChoose(.openRouter))

        // Chosen before the key went missing outside System: it starts as None.
        account.addKey(Self.key)
        center.choose(.openRouter)
        try? OpenRouterKeyStore(items: keychain).remove()
        XCTAssertEqual(self.center(defaults, keychain: keychain).0.choice, .none)
    }

    func testAvailabilityReadsWhetherAKeyIsStoredWithoutSendingAnything() async {
        let keychain = FakeKeychain()
        let provider = provider(keychain)
        let none = await provider.availability()
        XCTAssertEqual(none, .noOpenRouterKey)
        try? OpenRouterKeyStore(items: keychain).save(Self.key)
        let stored = await provider.availability()
        XCTAssertEqual(stored, .available)
        keychain.failure = errSecInteractionNotAllowed
        let failed = await provider.availability()
        XCTAssertEqual(failed, .openRouterKeyUnreadable)
        XCTAssertEqual(keychain.dataReads, 0, "the key itself is not read")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: Requests

    func testTheRequestIsTheSchemaBoundChatCompletionWithTheKeyOnlyInItsAuthorizationHeader() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let provider = provider(keychain, model: "  ")
        XCTAssertEqual(provider.model, "openrouter/auto", "empty sends the default")
        let request = request()
        let draft = try await provider.explain(request)
        XCTAssertEqual(try Explanation(validating: draft, for: request).summary, "A sync agent.")

        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(sent.url, URL(string: "https://openrouter.ai/api/v1/chat/completions"))
        XCTAssertEqual(sent.method, "POST")
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(Self.key)")
        XCTAssertEqual(sent.headers["X-Title"], "Subset System")
        XCTAssertNil(sent.headers["HTTP-Referer"])
        XCTAssertNil(sent.headers["Referer"])
        XCTAssertEqual(sent.timeout, 30)
        XCTAssertEqual(sent.body, try provider.body(for: request), "exactly the previewed body")
        let bodyText = String(decoding: sent.body ?? Data(), as: UTF8.self)
        XCTAssertFalse(bodyText.contains(Self.key))

        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: sent.body ?? Data()) as? [String: Any])
        XCTAssertEqual(body["model"] as? String, "openrouter/auto")
        let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
        XCTAssertEqual(messages, [["role": "system", "content": ExplainPrompt.instructions],
                                  ["role": "user", "content": request.promptText]])
        let format = try XCTUnwrap(body["response_format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["json_schema"] as? [String: Any])
        XCTAssertEqual(schema["strict"] as? Bool, true)
        XCTAssertEqual(Set(body.keys), ["model", "messages", "response_format", "provider"])
    }

    func testTheSchemaIsExactlyExplanationsFields() throws {
        let schema = OpenRouterProvider.schema
        let fields = ExplanationDraft.Key.allCases.map(\.rawValue)
        let properties = try XCTUnwrap(schema["properties"] as? [String: [String: Any]])
        XCTAssertEqual(Set(properties.keys), Set(fields))
        XCTAssertEqual(schema["required"] as? [String], fields)
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(properties["removalSafety"]?["enum"] as? [String], RemovalSafety.allCases.map(\.rawValue))
        XCTAssertEqual(properties["confidence"]?["enum"] as? [String], ExplanationConfidence.allCases.map(\.rawValue))
        XCTAssertEqual(properties["suggestedOrigin"]?["type"] as? [String], ["string", "null"])
    }

    func testAnAnswerOutsideTheSchemaOrWithoutContentIsRejected() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let provider = provider(keychain)
        for body in [
            completion(#"{"summary":"s","whatItIs":"w","removalSafety":"unsafe","howToRemove":"h","confidence":"low","suggestedOrigin":null,"run":"rm -rf ~"}"#),
            completion("```json\n{}\n```"),
            #"{"choices":[{"message":{"content":null}}]}"#,
            #"{"choices":[]}"#,
            "not json"
        ] {
            StubProtocol.enqueue(status: 200, json: body)
            do {
                _ = try await provider.explain(request())
                XCTFail(body)
            } catch let error as ExplainError {
                guard case .invalidResponse = error else { return XCTFail("\(body): \(error)") }
            }
        }
        StubProtocol.enqueue(status: 200, json: #"{"choices":[{"message":{"content":"","refusal":"No."}}]}"#)
        await assertFails(provider, containing: "declined")
    }

    func testA429IsTriedOnceMoreAfterABackoff() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let waits = WaitRecorder()
        let provider = provider(keychain, sleep: waits)
        StubProtocol.enqueue(status: 429, json: #"{"error":{"code":429,"message":"Rate limited"}}"#, headers: ["Retry-After": "3"])
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let draft = try await provider.explain(request())
        XCTAssertEqual(draft.summary, "A sync agent.")
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(StubProtocol.requests[0].body, StubProtocol.requests[1].body)
        XCTAssertEqual(waits.durations, [.seconds(3)])

        // Without a usable Retry-After, the backoff is 2 seconds; a second 429 is reported, not tried a third time.
        StubProtocol.reset()
        StubProtocol.enqueue(status: 429, json: #"{"error":{"code":429,"message":"Rate limited"}}"#, headers: ["Retry-After": "600"])
        StubProtocol.enqueue(status: 429, json: #"{"error":{"code":429,"message":"Still rate limited"}}"#)
        await assertFails(provider, containing: "OpenRouter answered 429 (client error): Still rate limited.")
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(waits.durations, [.seconds(3), .seconds(2)])
    }

    func testA5xxIsTriedOnceMoreThenReportedWithItsStatusAndMessage() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let waits = WaitRecorder()
        let provider = provider(keychain, sleep: waits)
        StubProtocol.enqueue(status: 502, json: #"{"error":{"code":502,"message":"Provider returned error"}}"#)
        StubProtocol.enqueue(status: 500, json: #"{"error":{"code":500,"message":"Internal\nerror"}}"#)
        await assertFails(provider, containing: "OpenRouter answered 500 (internal server error): Internal error.")
        XCTAssertEqual(StubProtocol.requests.count, 2)
        XCTAssertEqual(waits.durations, [.seconds(2)])

        StubProtocol.reset()
        StubProtocol.enqueue(status: 502, json: "<html>Bad gateway</html>")
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        _ = try await provider.explain(request())
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testA401AndOther4xxAreReportedWithoutARetry() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let waits = WaitRecorder()
        let provider = provider(keychain, sleep: waits)
        StubProtocol.enqueue(status: 401, json: #"{"error":{"code":401,"message":"No auth credentials found"}}"#)
        await assertFails(provider, containing: "OpenRouter answered 401 (unauthorized): No auth credentials found.")
        StubProtocol.enqueue(status: 400, json: #"{"error":{"code":400,"message":"acme/none is not a valid model ID"}}"#)
        await assertFails(provider, containing: "OpenRouter answered 400 (bad request): acme/none is not a valid model ID.")
        StubProtocol.enqueue(status: 404, json: "")
        await assertFails(provider, containing: "OpenRouter answered 404 (not found).")
        XCTAssertEqual(StubProtocol.requests.count, 3)
        XCTAssertTrue(waits.durations.isEmpty)
    }

    func testATimeoutIsReportedAndNotRetried() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let waits = WaitRecorder()
        let provider = provider(keychain, sleep: waits)
        StubProtocol.enqueue(error: URLError(.timedOut))
        await assertFails(provider, containing: "OpenRouter did not answer within 30 seconds.")
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertTrue(waits.durations.isEmpty)
        StubProtocol.enqueue(error: URLError(.notConnectedToInternet))
        await assertFails(provider, containing: "Could not reach OpenRouter")

        let configuration = OpenRouterClient.configuration(.ephemeral)
        XCTAssertEqual(configuration.timeoutIntervalForRequest, 30)
        XCTAssertEqual(configuration.timeoutIntervalForResource, 30)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.httpCookieStorage)
    }

    func testARedirectIsNotFollowedSoTheKeyGoesOnlyToOpenRouter() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        StubProtocol.enqueue(redirectTo: URL(string: "https://example.com/collect")!)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await assertFails(provider(keychain), containing: "OpenRouter answered 307")
        XCTAssertEqual(StubProtocol.requests.map(\.url?.host), ["openrouter.ai"])
    }

    func testWithNoKeyStoredNothingIsSent() async {
        let provider = provider(FakeKeychain())
        do {
            _ = try await provider.explain(request())
            XCTFail("sent without a key")
        } catch {
            XCTAssertEqual(error as? ExplainError, .unavailable(.noOpenRouterKey))
        }
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: Test key

    func testTheKeyTestSendsNoUserDataAndReportsSuccessOrTheError() async throws {
        let (_, account) = center(defaults(), keychain: FakeKeychain())
        account.addKey(Self.key)
        StubProtocol.enqueue(status: 200, json: #"{"data":{"label":"x"}}"#)
        await account.testKey()
        XCTAssertEqual(account.keyTest, .passed)
        let sent = try XCTUnwrap(StubProtocol.requests.first)
        XCTAssertEqual(sent.url, URL(string: "https://openrouter.ai/api/v1/key"))
        XCTAssertEqual(sent.method, "GET")
        XCTAssertNil(sent.body)
        XCTAssertEqual(sent.headers["Authorization"], "Bearer \(Self.key)")
        XCTAssertEqual(sent.headers["X-Title"], "Subset System")
        XCTAssertNil(sent.headers["HTTP-Referer"])

        StubProtocol.enqueue(status: 401, json: #"{"error":{"code":401,"message":"User not found."}}"#)
        await account.testKey()
        XCTAssertEqual(account.keyTest, .failed("OpenRouter answered 401 (unauthorized): User not found."))

        // Adding another key clears the result, which was the old key's.
        account.addKey("sk-or-v1-other")
        XCTAssertNil(account.keyTest)
    }

    // MARK: Send preview

    func testTheFirstRequestOfASessionWaitsForTheUserToConfirmExactlyWhatIsSentAndLaterOnesDoNot() async throws {
        let (center, account) = center(defaults(), keychain: FakeKeychain())
        account.addKey(Self.key)
        center.choose(.openRouter)
        let first = ExplainKey("process:1")
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let task = Task { await center.explain(first) { _ in self.request() } }
        let preview = try await confirming(center, first)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing is sent before the user confirms")
        XCTAssertEqual(preview.provider, .openRouter)
        XCTAssertFalse(preview.text.contains(Self.key))
        center.confirmSend(first)
        await task.value
        guard case .explained = center.state(for: first) else { return XCTFail("\(center.state(for: first))") }
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(StubProtocol.requests[0].body, Data(preview.text.utf8), "the body sent is the body shown")
        XCTAssertEqual(center.sentText(for: first), preview.text)
        XCTAssertTrue(center.sendConfirmed)

        // Not shown again this session, for another item or after switching providers.
        center.choose(.appleIntelligence)
        center.choose(.openRouter)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        await center.explain(ExplainKey("process:2")) { _ in self.request() }
        guard case .explained = center.state(for: ExplainKey("process:2")) else {
            return XCTFail("\(center.state(for: ExplainKey("process:2")))")
        }
        XCTAssertEqual(StubProtocol.requests.count, 2)

        // A new session (a new center) shows it again.
        let (next, _) = self.center(defaults(), keychain: FakeKeychain(), key: Self.key)
        next.choose(.openRouter)
        let again = Task { await next.explain(first) { _ in self.request() } }
        _ = try await confirming(next, first)
        next.cancelSend(first)
        await again.value
    }

    func testCancellingThePreviewSendsNothingAndTheItemCanBeAskedAgain() async throws {
        let (center, _) = center(defaults(), keychain: FakeKeychain(), key: Self.key)
        center.choose(.openRouter)
        let item = ExplainKey("disk:/x")
        let task = Task { await center.explain(item) { _ in self.request() } }
        _ = try await confirming(center, item)
        center.cancelSend(item)
        await task.value
        XCTAssertEqual(center.state(for: item), .idle)
        XCTAssertFalse(center.sendConfirmed)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertNil(center.sentText(for: item))

        // Asked again, it is previewed again, since nothing was confirmed.
        let again = Task { await center.explain(item) { _ in self.request() } }
        _ = try await confirming(center, item)
        again.cancel()
        await again.value
        XCTAssertEqual(center.state(for: item), .idle)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testChangingTheProviderWhileThePreviewIsShownSendsNothing() async throws {
        let (center, _) = center(defaults(), keychain: FakeKeychain(), key: Self.key)
        center.choose(.openRouter)
        let item = ExplainKey("disk:/x")
        let task = Task { await center.explain(item) { _ in self.request() } }
        _ = try await confirming(center, item)
        center.choose(.none)
        await task.value
        center.choose(.openRouter)
        XCTAssertEqual(center.state(for: item), .idle)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertFalse(center.sendConfirmed)
    }

    func testTurningFolderNamesOffWhileThePreviewIsShownShowsTheRebuiltBodyBeforeAnythingIsSent() async throws {
        let (center, _) = center(defaults(), keychain: FakeKeychain(), key: Self.key)
        center.choose(.openRouter)
        center.sendFolderNames = true
        let item = ExplainKey("disk:/Users/jdoe/dev/acme-merger")
        let build: (ExplainRedactor) -> ExplainRequest? = { redactor in
            var facts = ExplainFacts(kind: .folder, name: redactor.name("acme-merger", ofPath: "/Users/jdoe/dev/acme-merger"))
            facts.path = "/Users/jdoe/dev/acme-merger"
            return ExplainRequest(facts, redactor: redactor)
        }
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let task = Task { await center.explain(item, request: build) }
        let shown = try await confirming(center, item)
        XCTAssertTrue(shown.text.contains("acme-merger"))
        center.sendFolderNames = false
        center.confirmSend(item)
        let rebuilt = try await confirming(center, item) { $0.text != shown.text }
        XCTAssertFalse(rebuilt.text.contains("acme-merger"))
        XCTAssertTrue(StubProtocol.requests.isEmpty, "the body the user confirmed is no longer what would be sent")
        center.confirmSend(item)
        await task.value
        XCTAssertEqual(StubProtocol.requests.map(\.body), [Data(rebuilt.text.utf8)])
    }

    func testConfirmingOnePreviewSendsTheOtherItemsWaitingForOne() async throws {
        let (center, _) = center(defaults(), keychain: FakeKeychain(), key: Self.key)
        center.choose(.openRouter)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let first = Task { await center.explain(ExplainKey("a")) { _ in self.request() } }
        let second = Task { await center.explain(ExplainKey("b")) { _ in self.request() } }
        _ = try await confirming(center, ExplainKey("a"))
        _ = try await confirming(center, ExplainKey("b"))
        center.confirmSend(ExplainKey("b"))
        await first.value
        await second.value
        XCTAssertEqual(StubProtocol.requests.count, 2)
        for item in ["a", "b"] {
            guard case .explained = center.state(for: ExplainKey(item)) else { return XCTFail("\(center.state(for: ExplainKey(item)))") }
        }
    }

    func testAppleIntelligenceNeedsNoPreview() {
        XCTAssertFalse(AppleIntelligenceProvider().needsSendPreview)
        XCTAssertTrue(provider(FakeKeychain()).needsSendPreview)
    }

    // MARK: Helpers

    private static let answer = #"{"summary":"A sync agent.","whatItIs":"It syncs files.","removalSafety":"review","howToRemove":"Quit it.","confidence":"medium","suggestedOrigin":null}"#

    private func completion(_ content: String) -> String {
        let message = try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["role": "assistant", "content": content]]]])
        return String(decoding: message, as: UTF8.self)
    }

    private var suiteName = ""

    private func defaults() -> UserDefaults {
        suiteName = "OpenRouterTests-\(UUID().uuidString)"
        let name = suiteName
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        return UserDefaults(suiteName: name)!
    }

    private func client(log: RecordingLog = RecordingLog(), sleep: WaitRecorder = WaitRecorder()) -> OpenRouterClient {
        OpenRouterClient(session: StubProtocol.session(), log: log, sleep: { await sleep.record($0) })
    }

    private func provider(_ keychain: FakeKeychain, model: String = "", sleep: WaitRecorder = WaitRecorder()) -> OpenRouterProvider {
        OpenRouterProvider(keys: OpenRouterKeyStore(items: keychain), model: model, client: client(sleep: sleep))
    }

    /// A center whose OpenRouter account uses `keychain` and the stub; `key`, when given, is stored first.
    private func center(_ defaults: UserDefaults, keychain: FakeKeychain, key: String? = nil,
                        log: RecordingLog = RecordingLog()) -> (ExplainCenter, OpenRouterAccount) {
        if let key { try? OpenRouterKeyStore(items: keychain).save(key) }
        let account = OpenRouterAccount(keys: OpenRouterKeyStore(items: keychain), client: client(log: log),
                                        defaults: defaults, log: log)
        let center = ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account)
        return (center, account)
    }

    private func request() -> ExplainRequest {
        ExplainRequest(ExplainFacts(kind: .process, name: "syncd"), redactor: redactor)
    }

    /// The preview `item` waits for, once it waits for one that satisfies `condition`.
    private func confirming(_ center: ExplainCenter, _ item: ExplainKey,
                            where condition: (SendPreview) -> Bool = { _ in true }) async throws -> SendPreview {
        for _ in 0..<2_000 {
            if case let .confirming(preview) = center.state(for: item), condition(preview) { return preview }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("\(item) never waited for a preview: \(center.state(for: item))")
        throw CancellationError()
    }

    /// Explains `item`, confirming the preview when one is shown.
    private func explainConfirmed(_ center: ExplainCenter, _ item: ExplainKey) async {
        let task = Task { await center.explain(item) { _ in self.request() } }
        if !center.sendConfirmed, (try? await confirming(center, item)) != nil { center.confirmSend(item) }
        await task.value
    }

    private func assertFails(_ provider: OpenRouterProvider, containing text: String, line: UInt = #line) async {
        do {
            _ = try await provider.explain(request())
            XCTFail("answered", line: line)
        } catch let error as ExplainError {
            guard case let .failed(message) = error else { return XCTFail("\(error)", line: line) }
            XCTAssertTrue(message.contains(text), message, line: line)
        } catch {
            XCTFail("\(error)", line: line)
        }
    }
}

/// The Keychain as `SecItem` sees one generic password per keychain: the data protection keychain, which refuses
/// every call but a search with `errSecMissingEntitlement` until `entitled`, as macOS does for an unentitled build,
/// and the login keychain.
final class FakeKeychain: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool: [String: Any]] = [:]
    private var _entitled: Bool
    private var _failure: OSStatus?
    private var _dataReads = 0

    init(entitled: Bool = true) {
        _entitled = entitled
    }

    var entitled: Bool {
        get { lock.withLock { _entitled } }
        set { lock.withLock { _entitled = newValue } }
    }
    /// Every call fails with this status.
    var failure: OSStatus? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var count: Int { lock.withLock { items.count } }
    var dataReads: Int { lock.withLock { _dataReads } }

    func item(dataProtection: Bool) -> [String: Any]? {
        lock.withLock { items[dataProtection] }
    }

    func set(dataProtection: Bool, data: Data) {
        lock.withLock {
            items[dataProtection] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: OpenRouterKeyStore.service,
                                     kSecAttrAccount as String: OpenRouterKeyStore.account, kSecValueData as String: data]
        }
    }

    /// The keychain a query names, or the status it fails with first.
    private func keychain(_ query: [String: Any], search: Bool = false) -> Result<Bool, OSStatusError> {
        if let failure = _failure { return .failure(OSStatusError(status: failure)) }
        let dataProtection = query[kSecUseDataProtectionKeychain as String] as? Bool ?? false
        if dataProtection, !_entitled { return .failure(OSStatusError(status: search ? errSecItemNotFound : errSecMissingEntitlement)) }
        return .success(dataProtection)
    }

    private func matches(_ item: [String: Any], _ query: [String: Any]) -> Bool {
        [kSecClass, kSecAttrService, kSecAttrAccount].allSatisfy { attribute in
            (item[attribute as String] as? String) == (query[attribute as String] as? String)
        }
    }

    func add(_ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            switch keychain(attributes) {
            case let .failure(error): return error.status
            case let .success(dataProtection):
                if let item = items[dataProtection], matches(item, attributes) { return errSecDuplicateItem }
                var item = attributes
                item.removeValue(forKey: kSecUseDataProtectionKeychain as String)
                items[dataProtection] = item
                return errSecSuccess
            }
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        lock.withLock {
            switch keychain(query, search: true) {
            case let .failure(error): return (error.status, nil)
            case let .success(dataProtection):
                guard let item = items[dataProtection], matches(item, query) else { return (errSecItemNotFound, nil) }
                guard query[kSecReturnData as String] as? Bool == true else { return (errSecSuccess, nil) }
                _dataReads += 1
                return (errSecSuccess, item[kSecValueData as String] as? Data)
            }
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        lock.withLock {
            switch keychain(query) {
            case let .failure(error): return error.status
            case let .success(dataProtection):
                guard var item = items[dataProtection], matches(item, query) else { return errSecItemNotFound }
                item.merge(attributes) { $1 }
                items[dataProtection] = item
                return errSecSuccess
            }
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        lock.withLock {
            switch keychain(query) {
            case let .failure(error): return error.status
            case let .success(dataProtection):
                guard let item = items[dataProtection], matches(item, query) else { return errSecItemNotFound }
                items[dataProtection] = nil
                return errSecSuccess
            }
        }
    }
}

struct OSStatusError: Error {
    let status: OSStatus
}

/// Every message logged.
final class RecordingLog: ExplainLog, @unchecked Sendable {
    private let lock = NSLock()
    private var _messages: [String] = []

    var messages: [String] { lock.withLock { _messages } }

    func record(_ message: String) {
        lock.withLock { _messages.append(message) }
    }
}

/// Every backoff waited for, without waiting.
final class WaitRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var _durations: [Duration] = []

    var durations: [Duration] { lock.withLock { _durations } }

    func record(_ duration: Duration) async {
        lock.withLock { _durations.append(duration) }
    }
}

/// Answers each request with the next queued response, recording what was sent. One test runs at a time.
final class StubProtocol: URLProtocol, @unchecked Sendable {
    struct Sent {
        let url: URL?
        let method: String?
        let headers: [String: String]
        let body: Data?
        let timeout: TimeInterval
    }

    private enum Answer {
        case response(Int, Data, [String: String])
        case error(URLError)
        case redirect(URL)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var answers: [Answer] = []
    nonisolated(unsafe) private static var sent: [Sent] = []

    static var requests: [Sent] { lock.withLock { sent } }

    static func reset() {
        lock.withLock {
            answers = []
            sent = []
        }
    }

    static func enqueue(status: Int, json: String, headers: [String: String] = [:]) {
        lock.withLock { answers.append(.response(status, Data(json.utf8), headers)) }
    }

    static func enqueue(redirectTo url: URL) {
        lock.withLock { answers.append(.redirect(url)) }
    }

    static func enqueue(error: URLError) {
        lock.withLock { answers.append(.error(error)) }
    }

    static func session() -> URLSession {
        let configuration = OpenRouterClient.configuration(.ephemeral)
        configuration.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let answer: Answer? = Self.lock.withLock {
            Self.sent.append(Sent(url: request.url, method: request.httpMethod, headers: request.allHTTPHeaderFields ?? [:],
                                  body: body, timeout: request.timeoutInterval))
            return Self.answers.isEmpty ? nil : Self.answers.removeFirst()
        }
        switch answer {
        case let .response(status, data, headers)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case let .error(error)?:
            client?.urlProtocol(self, didFailWithError: error)
        case let .redirect(url)?:
            let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: "HTTP/1.1",
                                           headerFields: ["Location": url.absoluteString])!
            var next = request
            next.url = url
            client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            // A refused redirect delivers the 3xx response itself.
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
        case nil:
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
