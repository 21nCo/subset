import Foundation
import Security
@testable import SystemCore
import XCTest

/// OpenRouter without the network or the real Keychain (SET-50): the key store against a Keychain double, the key
/// kept out of user defaults and every log call, the request and its retries against a `URLProtocol` stub, the key
/// test, and the model ID. Choosing OpenRouter for Explain and the send preview are SET-160's; a live OpenRouter run
/// is SET-56's.
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
        XCTAssertNil(keychain.item(dataProtection: false), "never the login keychain, which drops the attribute")

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

    func testWithoutTheDataProtectionKeychainNoKeyIsStoredAnywhereAndAddKeySaysWhy() async throws {
        let keychain = FakeKeychain(entitled: false)
        let store = OpenRouterKeyStore(items: keychain)
        XCTAssertThrowsError(try store.save(Self.key)) { error in
            XCTAssertEqual(error as? KeychainError, KeychainError(status: errSecMissingEntitlement))
            XCTAssertTrue((error as? KeychainError)?.message.contains("signed build") == true)
        }
        XCTAssertEqual(keychain.count, 0, "not kept in the login keychain, where this-device-only is not applied")
        XCTAssertFalse(try store.containsKey())
        XCTAssertNil(try store.readKey())
        XCTAssertNoThrow(try store.remove())

        // Add Key shows that, and no key is shown as stored.
        let account = await account(defaults(), keychain: keychain)
        let stored = await account.addKey(Self.key)
        XCTAssertFalse(stored)
        XCTAssertFalse(account.hasKey)
        XCTAssertEqual(account.keyError, KeychainError(status: errSecMissingEntitlement).message)
        XCTAssertEqual(keychain.count, 0)

        // A password of the same service in the login keychain, which does not keep the class, is not used.
        keychain.entitled = true
        keychain.set(dataProtection: false, data: Data(Self.key.utf8))
        XCTAssertFalse(try store.containsKey())
        XCTAssertNil(try store.readKey())
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
        let account = await account(defaults, keychain: keychain, log: log)
        let refused = await account.addKey("sk-or bad")
        XCTAssertFalse(refused, "refused")
        XCTAssertEqual(account.keyError, OpenRouterAccount.invalidKeyMessage)
        let stored = await account.addKey(Self.key)
        XCTAssertTrue(stored)
        XCTAssertNil(account.keyError)
        account.model = "anthropic/claude-sonnet"
        await account.modelChecked()
        let provider = account.provider()

        // A key test, an error that repeats the key, a retry, and an answer.
        StubProtocol.enqueue(status: 200, json: #"{"data":{"label":"sk-or-v1-0123…"}}"#)
        await account.testKey()
        XCTAssertEqual(account.keyTest, .passed)
        StubProtocol.enqueue(status: 503, json: #"{"error":{"code":503,"message":"Busy for key \#(Self.key)"}}"#)
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        let draft = try await provider.explain(request())
        XCTAssertEqual(draft.summary, "A sync agent.")
        StubProtocol.enqueue(status: 401, json: #"{"error":{"code":401,"message":"Invalid key \#(Self.key)"}}"#)
        do {
            _ = try await provider.explain(request())
            XCTFail("answered")
        } catch {
            let message = (error as? ExplainError)?.message ?? "\(error)"
            XCTAssertFalse(message.contains(Self.key), message)
            XCTAssertTrue(message.contains("Invalid key [key]"), message)
        }
        await account.removeKey()

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

    func testAvailabilityReadsWhetherAKeyIsStoredWithoutSendingAnything() async {
        let keychain = FakeKeychain()
        let provider = provider(keychain)
        let none = await provider.availability()
        XCTAssertEqual(none, .noOpenRouterKey)
        try? OpenRouterKeyStore(items: keychain).save(Self.key)
        let stored = await provider.availability()
        XCTAssertEqual(stored, .availableOnOpenRouter)
        XCTAssertTrue(stored.isAvailable)
        XCTAssertFalse(stored.meaning.contains("this Mac"), "it does not say explanations stay on this Mac")
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
        XCTAssertEqual(sent.body, try provider.body(for: request), "exactly the body built for the request")
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

    func testTheClientSendsExactlyTheBodyItIsGivenTheRetryIncluded() async throws {
        // Bytes no JSON encoder would produce, so a body built again or re-encoded would differ.
        let given = Data([0x7B, 0x20, 0x00, 0xFF, 0x0A]) + Data(#""model":"a/b" , "x":[1,2]}"#.utf8)
        let waits = WaitRecorder()
        StubProtocol.enqueue(status: 503, json: #"{"error":{"code":503,"message":"Busy"}}"#)
        StubProtocol.enqueue(status: 200, json: #"{"ok":true}"#)
        let answer = try await client(sleep: waits).send(.chat(given), key: Self.key)
        XCTAssertEqual(answer, Data(#"{"ok":true}"#.utf8))
        XCTAssertEqual(StubProtocol.requests.map(\.body), [given, given])
        XCTAssertEqual(StubProtocol.requests.map(\.headers["Content-Type"]), ["application/json", "application/json"])
        XCTAssertEqual(waits.durations, [.seconds(2)])

        // The provider's body is the same bytes each time it is built, so what it sends can be shown first.
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let provider = provider(keychain, model: "anthropic/claude-sonnet")
        XCTAssertEqual(try provider.body(for: request()), try provider.body(for: request()))
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

    func testAnErrorOnTheChoiceFailsWithOpenRoutersReasonWhateverContentCameWithIt() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let provider = provider(keychain)
        let error = #"{"code":502,"message":"Upstream failed for \#(Self.key)","metadata":{"provider_name":"x"}}"#
        // As OpenRouter documents a generation that fails part way: finish_reason "error", with what came before it.
        for content in ["null", #""{\"summary\":\"A sy""#, try jsonString(Self.answer)] {
            StubProtocol.enqueue(status: 200, json: #"{"choices":[{"finish_reason":"error","error":\#(error),"message":{"role":"assistant","content":\#(content)}}]}"#)
            do {
                let draft = try await provider.explain(request())
                XCTFail("a draft from \(content): \(draft)")
            } catch {
                XCTAssertEqual(error as? ExplainError, .failed("OpenRouter could not answer: Upstream failed for [key]."), content)
            }
        }
        // The error alone, or finish_reason "error" alone.
        StubProtocol.enqueue(status: 200, json: #"{"choices":[{"error":{"message":"Model overloaded"}}]}"#)
        await assertFails(provider, containing: "OpenRouter could not answer: Model overloaded.")
        StubProtocol.enqueue(status: 200, json: #"{"choices":[{"finish_reason":"error","error":null,"message":{"content":\#(try jsonString(Self.answer))}}]}"#)
        await assertFails(provider, containing: "OpenRouter could not answer: no reason given.")
        // A null error on a finished choice is no error.
        StubProtocol.enqueue(status: 200, json: #"{"choices":[{"finish_reason":"stop","error":null,"message":{"content":\#(try jsonString(Self.answer))}}]}"#)
        let draft = try await provider.explain(request())
        XCTAssertEqual(draft.summary, "A sync agent.")
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
        let keychain = FakeKeychain()
        let account = await account(defaults(), keychain: keychain)
        await account.addKey(Self.key)
        StubProtocol.enqueue(status: 200, json: #"{"data":{"label":"x"}}"#)
        await account.testKey()
        XCTAssertEqual(account.keyTest, .passed)
        XCTAssertEqual(keychain.dataReads, 1)
        XCTAssertEqual(keychain.mainThreadDataReads, 0, "the key is read off the main thread")
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
        await account.addKey("sk-or-v1-other")
        XCTAssertNil(account.keyTest)
    }

    func testAddingOrRemovingTheKeyStopsAKeyTestThatHasReadTheKeyBefore() async throws {
        let keychain = FakeKeychain()
        let account = await account(defaults(), keychain: keychain, key: Self.key)

        // Removed, then another added, after the test read the first key: neither key is sent by it.
        keychain.holdsDataReads = true
        let first = Task { await account.testKey() }
        try await until { keychain.heldDataReads == 1 }
        await account.removeKey()
        let replaced = await account.addKey("sk-or-v1-replacement")
        XCTAssertTrue(replaced)
        keychain.releaseDataRead()
        await first.value
        XCTAssertTrue(StubProtocol.requests.isEmpty, "the removed key is not sent")
        XCTAssertNil(account.keyTest)
        XCTAssertTrue(account.hasKey)

        // A test that found no key, overtaken by Add key: the key added stays usable.
        try OpenRouterKeyStore(items: keychain).remove()
        let second = Task { await account.testKey() }
        try await until { keychain.heldDataReads == 1 }
        let added = await account.addKey("sk-or-v1-third")
        XCTAssertTrue(added)
        keychain.releaseDataRead()
        await second.value
        keychain.holdsDataReads = false
        XCTAssertTrue(account.hasKey, "the stale read does not hide the key just added")
        XCTAssertNil(account.keyTest)
        XCTAssertNil(account.keyError)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testRemovingTheKeyDuringTheKeyTestsBackoffSendsNoRetry() async throws {
        let backoff = WaitRecorder()
        let account = await account(defaults(), keychain: FakeKeychain(), key: Self.key, sleep: { duration in
            await backoff.record(duration)
            // Long enough that a retry sent after it would be seen; a cancelled task ends it at once.
            try await Task.sleep(for: .seconds(2))
        })
        StubProtocol.enqueue(status: 503, json: #"{"error":{"code":503,"message":"Busy"}}"#)
        StubProtocol.enqueue(status: 200, json: #"{"data":{"label":"x"}}"#)
        let test = Task { await account.testKey() }
        try await until { !backoff.durations.isEmpty }
        await account.removeKey()
        await test.value
        try await Task.sleep(for: .milliseconds(2_100))
        XCTAssertEqual(StubProtocol.requests.count, 1, "no retry with the removed key")
        XCTAssertNil(account.keyTest)
        XCTAssertFalse(account.hasKey)
    }

    func testAKeyStoredButUnreadableAtLaunchIsFoundWhenSettingsChecksAgain() async throws {
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        keychain.failure = errSecInteractionNotAllowed
        let account = await account(defaults(), keychain: keychain)
        XCTAssertFalse(account.hasKey)
        XCTAssertEqual(account.keyError, KeychainError(status: errSecInteractionNotAllowed).message)

        // Still failing: nothing changes.
        await account.refreshKey()
        XCTAssertFalse(account.hasKey)
        XCTAssertEqual(account.keyError, KeychainError(status: errSecInteractionNotAllowed).message)

        keychain.failure = nil
        await account.refreshKey()
        XCTAssertTrue(account.hasKey)
        XCTAssertNil(account.keyError)
        XCTAssertEqual(keychain.dataReads, 0, "only whether a key is stored is read")

        // Removed outside System: the next read shows no key.
        try OpenRouterKeyStore(items: keychain).remove()
        await account.refreshKey()
        XCTAssertFalse(account.hasKey)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testNoKeychainCallIsMadeOnTheMainActorAndTheLastAddOrRemoveKeyIsWhatStays() async throws {
        // Stops at the first failure: a call made on the main actor would wait there for a held call forever.
        continueAfterFailure = false
        let keychain = FakeKeychain()
        let store = OpenRouterKeyStore(items: keychain)
        try store.save(Self.key)
        let before = keychain.mainThreadCalls

        // Launch, Add key, a failed Remove key and the read after it, and Remove key: no call on the main thread.
        let unheld = OpenRouterAccount(keys: store, client: client(), defaults: defaults())
        XCTAssertEqual(keychain.mainThreadCalls, before, "nothing is read as it is made")
        XCTAssertEqual(unheld.presence, .unknown(shown: false))
        await unheld.refreshKey()
        XCTAssertEqual(unheld.presence, .stored)
        let stored = await unheld.addKey("sk-or-v1-replacement")
        XCTAssertTrue(stored)
        keychain.failure = errSecInteractionNotAllowed
        await unheld.removeKey()
        XCTAssertEqual(unheld.presence, .unknown(shown: true))
        keychain.failure = nil
        await unheld.removeKey()
        XCTAssertEqual(unheld.presence, .absent)
        XCTAssertEqual(keychain.mainThreadCalls, before)
        try store.save(Self.key)

        // Launch: nothing is read until refreshKey, which waits for the Keychain without holding the main actor.
        keychain.holdsOtherCalls = true
        let account = OpenRouterAccount(keys: store, client: client(), defaults: defaults())
        XCTAssertEqual(account.presence, .unknown(shown: false))
        let launch = Task { await account.refreshKey() }
        try await until { keychain.heldOtherCalls == 1 }
        keychain.releaseOtherCall()
        await launch.value
        XCTAssertEqual(account.presence, .stored)

        // Add key, then Remove key while it waits: the key is removed, and none is shown.
        let add = Task { await account.addKey("sk-or-v1-replacement") }
        try await until { keychain.heldOtherCalls == 1 }
        XCTAssertEqual(account.presence, .stored, "unchanged until the Keychain answers")
        let remove = Task { await account.removeKey() }
        try await until { account.pendingKeyChanges == 2 }
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        let added = await add.value
        await remove.value
        XCTAssertTrue(added)
        XCTAssertEqual(account.presence, .absent)
        XCTAssertEqual(keychain.count, 0)

        // Remove key, then Add key while it waits: the key added is stored and shown.
        keychain.holdsOtherCalls = true
        let removeAgain = Task { await account.removeKey() }
        try await until { keychain.heldOtherCalls == 1 }
        let addAgain = Task { await account.addKey("sk-or-v1-third") }
        try await until { account.pendingKeyChanges == 2 }
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        await removeAgain.value
        _ = await addAgain.value
        XCTAssertEqual(account.presence, .stored)
        XCTAssertEqual(try store.readKey(), "sk-or-v1-third")

        // A presence read that Remove key overtakes changes nothing.
        keychain.holdsOtherCalls = true
        let refresh = Task { await account.refreshKey() }
        try await until { keychain.heldOtherCalls == 1 }
        let removeLast = Task { await account.removeKey() }
        try await until { account.pendingKeyChanges == 1 }
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        await refresh.value
        await removeLast.value
        XCTAssertEqual(account.presence, .absent)
        XCTAssertNil(account.keyError)
        XCTAssertEqual(keychain.mainThreadCalls - before, 3, "only the test's own save (an update, then an add) and read")
    }

    func testAModelIDEnteredWhileAKeyIsBeingAddedIsComparedWithThatKey() async throws {
        let key = "tok-0123456789abcdef"
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)
        XCTAssertEqual(account.presence, .absent)

        keychain.holdsOtherCalls = true
        let add = Task { await account.addKey(key) }
        try await until { keychain.heldOtherCalls == 1 }
        account.modelEntry = "x/\(key)"
        account.commitModel()
        XCTAssertEqual(account.checkedModel, "", "not used while the key may be being stored")
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        keychain.holdsOtherCalls = false
        keychain.releaseOtherCall()
        _ = await add.value
        await account.modelChecked()
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
    }

    func testAFailedReplaceKeyKeepsWhetherAKeyIsStoredInStep() async {
        let keychain = FakeKeychain()
        let account = await account(defaults(), keychain: keychain, key: Self.key)
        let replacement = "sk-or-v1-" + String(repeating: "f", count: 64)

        // Neither stored nor known whether a key is still stored: the key stays as shown.
        keychain.failure = errSecInteractionNotAllowed
        let replaced = await account.addKey(replacement)
        XCTAssertFalse(replaced)
        XCTAssertEqual(account.keyError, KeychainError(status: errSecInteractionNotAllowed).message)
        XCTAssertTrue(account.hasKey)

        // Not stored, and no key found any more: no key is shown.
        keychain.failure = nil
        keychain.entitled = false
        let replacedAgain = await account.addKey(replacement)
        XCTAssertFalse(replacedAgain)
        XCTAssertFalse(account.hasKey)
    }

    func testAModelIDIsComparedWithTheKeyWhileAFailedAddOrRemoveKeyLeavesWhetherOneIsStoredUnknown() async throws {
        let key = "tok-0123456789abcdef"
        let leaked = "x/\(key)"

        // Unreadable at launch, then Replace Key fails and so does the read after it.
        let defaults = defaults()
        let log = RecordingLog()
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(key)
        keychain.failure = errSecInteractionNotAllowed
        let account = await account(defaults, keychain: keychain, log: log)
        let replaced = await account.addKey("tok-replacement-0000")
        XCTAssertFalse(replaced)
        XCTAssertEqual(account.presence, .unknown(shown: false))
        account.model = leaked
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertEqual(account.provider().model, OpenRouterProvider.defaultModel)
        XCTAssertEqual(account.modelError, OpenRouterAccount.modelUncheckedMessage)
        keychain.failure = nil
        await account.refreshKey()
        await account.modelChecked()
        XCTAssertEqual(account.presence, .stored)
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)

        // Remove Key fails and so does the read after it: the key is still shown, and an entry still compared.
        let removeDefaults = self.defaults()
        let removeKeychain = FakeKeychain()
        let removing = await self.account(removeDefaults, keychain: removeKeychain, key: key, log: log)
        removeKeychain.failure = errSecInteractionNotAllowed
        await removing.removeKey()
        XCTAssertEqual(removing.presence, .unknown(shown: true))
        XCTAssertTrue(removing.hasKey)
        removing.model = leaked
        await removing.modelChecked()
        XCTAssertEqual(removing.checkedModel, "")
        removeKeychain.failure = nil
        await removing.refreshKey()
        await removing.modelChecked()
        XCTAssertEqual(removing.model, "")
        XCTAssertEqual(removing.checkedModel, "")

        // Only once no key is known to be stored is an entry kept without reading the key.
        await removing.removeKey()
        XCTAssertEqual(removing.presence, .absent)
        let reads = removeKeychain.dataReads
        removing.model = "anthropic/claude-sonnet"
        await removing.modelChecked()
        XCTAssertEqual(removing.checkedModel, "anthropic/claude-sonnet")
        XCTAssertEqual(removeKeychain.dataReads, reads)

        for store in [defaults, removeDefaults] {
            for (name, value) in store.dictionaryRepresentation() {
                XCTAssertFalse("\(name) \(value)".contains(key), name)
            }
        }
        for message in log.messages { XCTAssertFalse(message.contains(key), message) }
    }

    func testAKeyTestThatCannotReadTheKeyLeavesWhetherOneIsStoredUnknown() async throws {
        let keychain = FakeKeychain()
        let account = await account(defaults(), keychain: keychain, key: "tok-0123456789abcdef")
        keychain.failure = errSecInteractionNotAllowed
        await account.testKey()
        XCTAssertEqual(account.keyTest, .failed(KeychainError(status: errSecInteractionNotAllowed).message))
        XCTAssertEqual(account.presence, .unknown(shown: true))
        account.model = "x/tok-0123456789abcdef"
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    // MARK: Model ID

    func testOnlyAModelIDShapedEntryIsSentAsTheModel() {
        for model in ["openrouter/auto", "anthropic/claude-sonnet-4", "meta-llama/llama-3.1-8b-instruct:free",
                      "~anthropic/claude-sonnet-latest", " openai/gpt-4o\n"] {
            XCTAssertTrue(OpenRouterProvider.isModelID(model.trimmingCharacters(in: .whitespacesAndNewlines)), model)
            XCTAssertEqual(OpenRouterProvider.model(model), model.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        for entry in ["", "gpt-4o", "\"a/b\"", "a/b c", "a/b/c", "<a/b>", "a/b:", "a/b\nc/d", "ā/b", "x/sk-or-v1-abc",
                      "x/SK-OR-v1-abc", "sk-or-v1-abc:free", "a/" + String(repeating: "b", count: 199)] {
            XCTAssertFalse(OpenRouterProvider.isModelID(entry), entry)
            XCTAssertEqual(OpenRouterProvider.model(entry), OpenRouterProvider.defaultModel, entry)
        }
    }

    func testAKeyAnywhereInTheModelIDIsNeverKeptLoggedOrSent() async throws {
        let defaults = defaults()
        let log = RecordingLog()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain, key: Self.key, log: log)
        let wrapped = { (key: String) in ["\(key)", "\"\(key)\"", "x/\(key)", "\(key):free", "openai/gpt-\(key)-mini",
                                          "a/b\(key)c", "~X/" + key.uppercased()] }

        // An OpenRouter key, alone or inside other text, is cleared as it is entered.
        for entry in wrapped(Self.key) + [" SK-OR-v1-abc "] {
            account.model = entry
            XCTAssertEqual(account.model, "", entry)
            XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage, entry)
            XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "", entry)
            XCTAssertEqual(OpenRouterProvider.model(entry), OpenRouterProvider.defaultModel, entry)
        }
        account.model = "anthropic/claude-sonnet"
        XCTAssertNil(account.modelError)

        // A key with another prefix, inside a model ID entered before it was added, is cleared once it is added.
        let key = "tok-0123456789abcdef"
        await account.removeKey()
        account.model = "x/\(key)"
        await account.modelChecked()
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "x/\(key)", "no key to compare it with yet")
        let added = await account.addKey(key)
        XCTAssertTrue(added)
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(account.checkedModel, "")
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")

        // The same key, added first and then entered inside the model: neither kept nor used, then cleared once checked.
        for entry in wrapped(key) {
            account.model = entry
            XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "", "not kept before it is checked: \(entry)")
            XCTAssertEqual(account.provider().model, OpenRouterProvider.defaultModel, entry)
            await account.modelChecked()
            XCTAssertEqual(account.model, "", entry)
            XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage, entry)
            XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "", entry)
        }

        // A request made while the entry is being checked has the model checked before, never the entry.
        keychain.holdsDataReads = true
        account.model = "x/\(key)"
        try await until { keychain.heldDataReads == 1 }
        let pending = account.provider()
        let pendingBody = String(decoding: try pending.body(for: request()), as: UTF8.self)
        XCTAssertFalse(pendingBody.lowercased().contains(key), pendingBody)
        XCTAssertTrue(pendingBody.contains(#""model" : "openrouter/auto""#), pendingBody)
        keychain.holdsDataReads = false
        keychain.releaseDataRead()
        await account.modelChecked()
        XCTAssertEqual(account.model, "")
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        _ = try await pending.explain(request())
        XCTAssertEqual(StubProtocol.requests.map(\.body), [Data(pendingBody.utf8)])

        // A provider given such a model ID by any other way reads the key, refuses it, and sends nothing.
        for entry in wrapped(key) where OpenRouterProvider.isModelID(entry) {
            let early = OpenRouterProvider(keys: OpenRouterKeyStore(items: keychain), model: entry, client: client(log: log))
            do {
                _ = try await early.explain(request())
                XCTFail("sent \(entry)")
            } catch {
                XCTAssertEqual(error as? ExplainError, .failed(OpenRouterProvider.keyAsModelFailure), entry)
            }
        }
        XCTAssertEqual(StubProtocol.requests.count, 1)

        // A custom model ID is sent, and kept once checked, but never logged.
        account.model = "anthropic/claude-sonnet"
        await account.modelChecked()
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "anthropic/claude-sonnet")
        StubProtocol.enqueue(status: 200, json: completion(Self.answer))
        _ = try await account.provider().explain(request())
        let customBody = try XCTUnwrap(StubProtocol.requests.last?.body)
        let custom = try XCTUnwrap(JSONSerialization.jsonObject(with: customBody) as? [String: Any])
        XCTAssertEqual(custom["model"] as? String, "anthropic/claude-sonnet")

        // One kept before that holds the key now stored is not used at launch, and is cleared once checked.
        defaults.set("x/\(key)", forKey: "openRouterModel")
        let reopened = await self.account(defaults, keychain: keychain, log: log)
        XCTAssertEqual(reopened.provider().model, OpenRouterProvider.defaultModel)
        await reopened.modelChecked()
        XCTAssertEqual(reopened.model, "")
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        defaults.set("\"\(Self.key)\"", forKey: "openRouterModel")
        let refused = await self.account(defaults, keychain: FakeKeychain(), log: log)
        XCTAssertEqual(refused.model, "")
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        // One kept before that does not hold it is used once checked.
        defaults.set("anthropic/claude-sonnet", forKey: "openRouterModel")
        let kept = await self.account(defaults, keychain: keychain, log: log)
        await kept.modelChecked()
        XCTAssertEqual(kept.provider().model, "anthropic/claude-sonnet")

        XCTAssertFalse(log.messages.isEmpty)
        for message in log.messages {
            XCTAssertFalse(message.lowercased().contains(key) || message.contains("sk-or-v1") || message.contains("anthropic"),
                           message)
        }
        for (name, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(name) \(value)".lowercased().contains(key) || "\(name) \(value)".contains("sk-or-v1"), name)
        }
    }

    func testAModelIDIsNotKeptWhileTheKeyCannotBeReadToCompareItWith() async throws {
        let defaults = defaults()
        let log = RecordingLog()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain, log: log)
        let key = "tok-0123456789abcdef"
        let added = await account.addKey(key)
        XCTAssertTrue(added)
        account.model = "anthropic/claude-sonnet"
        await account.modelChecked()
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "anthropic/claude-sonnet")

        // The key inside a model ID entered while the Keychain cannot be read: not kept or used; what was kept stays.
        keychain.failure = errSecInteractionNotAllowed
        account.model = "x/\(key)"
        await account.modelChecked()
        XCTAssertEqual(account.modelError, OpenRouterAccount.modelUncheckedMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "anthropic/claude-sonnet")
        XCTAssertEqual(account.provider().model, "anthropic/claude-sonnet")
        for (name, value) in defaults.dictionaryRepresentation() {
            XCTAssertFalse("\(name) \(value)".contains(key), name)
        }

        // Checked again once the Keychain can be read: found to hold the key, it is cleared.
        keychain.failure = nil
        await account.refreshKey()
        await account.modelChecked()
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")

        // Not a model ID, with the key in quotes: openrouter/auto at once, and cleared once the key can be read.
        keychain.failure = errSecInteractionNotAllowed
        account.model = "\"\(key)\""
        await account.modelChecked()
        XCTAssertEqual(account.modelError, OpenRouterAccount.notAModelMessage)
        XCTAssertEqual(account.provider().model, OpenRouterProvider.defaultModel)
        keychain.failure = nil
        await account.refreshKey()
        await account.modelChecked()
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)

        // Whether a key is stored unknown at launch: an entry is still checked before it is kept.
        keychain.failure = errSecInteractionNotAllowed
        let unread = await self.account(defaults, keychain: keychain, log: log)
        XCTAssertFalse(unread.hasKey)
        unread.model = "x/\(key)"
        await unread.modelChecked()
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        XCTAssertEqual(unread.provider().model, OpenRouterProvider.defaultModel)
        keychain.failure = nil
        await unread.refreshKey()
        await unread.modelChecked()
        XCTAssertEqual(unread.model, "")
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
        for message in log.messages { XCTAssertFalse(message.contains(key), message) }
    }

    func testEmptyingTheModelIDClearsItsErrorButAKeyEntryStillSaysWhyItWasCleared() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain)

        // Not a model ID, then emptied: openrouter/auto, with no error left under the empty field.
        account.model = "gpt-4o"
        XCTAssertEqual(account.modelError, OpenRouterAccount.notAModelMessage)
        account.model = ""
        await account.modelChecked()
        XCTAssertNil(account.modelError)
        XCTAssertEqual(account.provider().model, OpenRouterProvider.defaultModel)

        // A model ID that cannot be checked while the key cannot be read, then emptied.
        let key = "tok-0123456789abcdef"
        let added = await account.addKey(key)
        XCTAssertTrue(added)
        keychain.failure = errSecInteractionNotAllowed
        account.model = "anthropic/claude-sonnet"
        await account.modelChecked()
        XCTAssertEqual(account.modelError, OpenRouterAccount.modelUncheckedMessage)
        account.model = ""
        await account.modelChecked()
        XCTAssertNil(account.modelError)
        XCTAssertEqual(account.provider().model, OpenRouterProvider.defaultModel)

        // An entry cleared because it holds a key still says why.
        keychain.failure = nil
        account.model = "x/sk-or-v1-abc"
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        account.model = "x/\(key)"
        await account.modelChecked()
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
    }

    func testAnUncheckedModelIDIsUsedWithNoErrorOnceWhetherAKeyIsStoredIsKnownAgain() async throws {
        let key = "tok-0123456789abcdef"
        let entry = "anthropic/claude-sonnet"

        /// An account with `key` stored and `entry` entered while the key could not be read to check it.
        func unchecked() async throws -> (OpenRouterAccount, FakeKeychain, UserDefaults) {
            let defaults = self.defaults()
            let keychain = FakeKeychain()
            let account = await self.account(defaults, keychain: keychain, key: key)
            keychain.failure = errSecInteractionNotAllowed
            account.model = entry
            await account.modelChecked()
            XCTAssertEqual(account.modelError, OpenRouterAccount.modelUncheckedMessage)
            XCTAssertEqual(account.checkedModel, "")
            keychain.failure = nil
            return (account, keychain, defaults)
        }

        func assertUsed(_ account: OpenRouterAccount, _ defaults: UserDefaults, line: UInt = #line) async {
            await account.modelChecked()
            XCTAssertEqual(account.checkedModel, entry, line: line)
            XCTAssertEqual(defaults.string(forKey: "openRouterModel"), entry, line: line)
            XCTAssertEqual(account.provider().model, entry, line: line)
            XCTAssertNil(account.modelError, line: line)
        }

        // Removed outside System, then Settings is shown again: no key is stored, so the entry is used.
        var (account, keychain, defaults) = try await unchecked()
        try OpenRouterKeyStore(items: keychain).remove()
        await account.refreshKey()
        XCTAssertEqual(account.presence, .absent)
        await assertUsed(account, defaults)

        // Remove Key.
        (account, keychain, defaults) = try await unchecked()
        await account.removeKey()
        XCTAssertEqual(account.presence, .absent)
        await assertUsed(account, defaults)

        // A key test that finds no key.
        (account, keychain, defaults) = try await unchecked()
        try OpenRouterKeyStore(items: keychain).remove()
        await account.testKey()
        XCTAssertEqual(account.presence, .absent)
        await assertUsed(account, defaults)

        // The key still stored and readable again: checked against it, then used.
        (account, keychain, defaults) = try await unchecked()
        let reads = keychain.dataReads
        await account.refreshKey()
        await assertUsed(account, defaults)
        XCTAssertEqual(keychain.dataReads, reads + 1, "compared with the key")

        // A check whose read failed, finished after Remove Key: no key is stored, so the entry is used.
        let removed = self.defaults()
        let held = FakeKeychain()
        let removing = await self.account(removed, keychain: held, key: key)
        held.holdsDataReads = true
        held.failure = errSecInteractionNotAllowed
        removing.model = entry
        try await until { held.heldDataReads == 1 }
        held.failure = nil
        // Remove Key's call waits behind the read, on the Keychain queue.
        let remove = Task { await removing.removeKey() }
        try await until { removing.pendingKeyChanges == 1 }
        held.holdsDataReads = false
        held.releaseDataRead()
        await remove.value
        await assertUsed(removing, removed)
    }

    func testTheModelIDIsCheckedAndKeptOnlyWhenCommittedButAKeyIsClearedAsItIsTyped() async throws {
        let defaults = defaults()
        let keychain = FakeKeychain()
        let account = await account(defaults, keychain: keychain, key: "tok-0123456789abcdef")
        account.modelEntry = "anthropic/claude-sonnet"
        account.commitModel()
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, "anthropic/claude-sonnet")
        let reads = keychain.dataReads

        // Typed a character at a time: what was committed stays used and kept, with no message and no key read.
        let next = "openai/gpt-4o"
        for end in next.indices.dropFirst() + [next.endIndex] {
            account.modelEntry = String(next[..<end])
            XCTAssertEqual(account.model, "anthropic/claude-sonnet")
            XCTAssertEqual(account.checkedModel, "anthropic/claude-sonnet")
            XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "anthropic/claude-sonnet")
            XCTAssertNil(account.modelError, account.modelEntry)
        }
        await account.modelChecked()
        XCTAssertEqual(keychain.dataReads, reads)

        // Return, then leaving the field: checked once against the key, then kept.
        account.commitModel()
        account.commitModel()
        await account.modelChecked()
        XCTAssertEqual(account.checkedModel, next)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), next)
        XCTAssertEqual(keychain.dataReads, reads + 1)

        // Not a model ID: said only once committed.
        account.modelEntry = "gpt-4o"
        XCTAssertNil(account.modelError)
        account.commitModel()
        XCTAssertEqual(account.modelError, OpenRouterAccount.notAModelMessage)

        // An OpenRouter key is cleared as soon as it is typed, without being committed.
        for character in "x/sk-or" {
            account.modelEntry += String(character)
            XCTAssertEqual(account.modelError, OpenRouterAccount.notAModelMessage, account.modelEntry)
        }
        account.modelEntry += "-"
        XCTAssertEqual(account.modelEntry, "", "cleared at sk-or-")
        XCTAssertEqual(account.model, "")
        XCTAssertEqual(account.modelError, OpenRouterAccount.keyAsModelMessage)
        XCTAssertEqual(defaults.string(forKey: "openRouterModel"), "")
    }

    func testAppleIntelligenceStillSaysExplanationsAreGeneratedOnThisMac() {
        XCTAssertEqual(AIAvailability.available.meaning, "Explanations are generated on this Mac.")
        XCTAssertNotEqual(AIAvailability.availableOnOpenRouter.meaning, AIAvailability.available.meaning)
    }

    // MARK: Helpers

    private static let answer = #"{"summary":"A sync agent.","whatItIs":"It syncs files.","removalSafety":"review","howToRemove":"Quit it.","confidence":"medium","suggestedOrigin":null}"#

    /// `text` as a JSON string literal.
    private func jsonString(_ text: String) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: text, options: .fragmentsAllowed), as: UTF8.self)
    }

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

    /// An account that uses `keychain` and the stub, once it has read whether a key is stored, as the app does at
    /// launch; `key`, when given, is stored first.
    private func account(_ defaults: UserDefaults, keychain: FakeKeychain, key: String? = nil,
                         log: RecordingLog = RecordingLog(),
                         sleep: (@Sendable (Duration) async throws -> Void)? = nil) async -> OpenRouterAccount {
        if let key { try? OpenRouterKeyStore(items: keychain).save(key) }
        let client = sleep.map { OpenRouterClient(session: StubProtocol.session(), log: log, sleep: $0) } ?? client(log: log)
        let account = OpenRouterAccount(keys: OpenRouterKeyStore(items: keychain), client: client, defaults: defaults,
                                        log: log)
        await account.refreshKey()
        return account
    }

    private func request(_ name: String = "syncd") -> ExplainRequest {
        ExplainRequest(ExplainFacts(kind: .process, name: name), redactor: redactor)
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
/// and the login keychain, which drops `kSecAttrAccessible` as macOS does there (a probe with a throwaway item read
/// back no accessibility attribute).
final class FakeKeychain: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Bool: [String: Any]] = [:]
    private var _entitled: Bool
    private var _failure: OSStatus?
    private var _dataReads = 0
    private var _mainThreadDataReads = 0
    private var _holdsDataReads = false
    private var _heldDataReads = 0
    private let readGate = DispatchSemaphore(value: 0)
    private var _holdsOtherCalls = false
    private var _heldOtherCalls = 0
    private var _mainThreadCalls = 0
    private let otherGate = DispatchSemaphore(value: 0)

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
    /// Each read of the key, once it has read what is stored, waits for `releaseDataRead()` while this is set.
    var holdsDataReads: Bool {
        get { lock.withLock { _holdsDataReads } }
        set { lock.withLock { _holdsDataReads = newValue } }
    }
    var heldDataReads: Int { lock.withLock { _heldDataReads } }

    func releaseDataRead() {
        readGate.signal()
    }
    var mainThreadDataReads: Int { lock.withLock { _mainThreadDataReads } }
    /// Each call that does not read the key (a search for whether one is stored, an add, an update, a delete) waits
    /// for `releaseOtherCall()` before it is made while this is set.
    var holdsOtherCalls: Bool {
        get { lock.withLock { _holdsOtherCalls } }
        set { lock.withLock { _holdsOtherCalls = newValue } }
    }
    var heldOtherCalls: Int { lock.withLock { _heldOtherCalls } }

    func releaseOtherCall() {
        otherGate.signal()
    }
    /// Calls of every kind made on the main thread.
    var mainThreadCalls: Int { lock.withLock { _mainThreadCalls } }

    /// Counts a call made on the main thread, and holds one that does not read the key while `holdsOtherCalls`.
    private func begin(readsData: Bool) {
        let hold = lock.withLock {
            if Thread.isMainThread { _mainThreadCalls += 1 }
            let hold = _holdsOtherCalls && !readsData
            if hold { _heldOtherCalls += 1 }
            return hold
        }
        guard hold else { return }
        otherGate.wait()
        lock.withLock { _heldOtherCalls -= 1 }
    }

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
        begin(readsData: false)
        return lock.withLock {
            switch keychain(attributes) {
            case let .failure(error): return error.status
            case let .success(dataProtection):
                if let item = items[dataProtection], matches(item, attributes) { return errSecDuplicateItem }
                var item = attributes
                item.removeValue(forKey: kSecUseDataProtectionKeychain as String)
                if !dataProtection { item.removeValue(forKey: kSecAttrAccessible as String) }
                items[dataProtection] = item
                return errSecSuccess
            }
        }
    }

    func copyMatching(_ query: [String: Any]) -> (OSStatus, Data?) {
        begin(readsData: query[kSecReturnData as String] as? Bool == true)
        let (result, hold) = lock.withLock {
            let result = search(query)
            let hold = _holdsDataReads && query[kSecReturnData as String] as? Bool == true
            if hold { _heldDataReads += 1 }
            return (result, hold)
        }
        if hold {
            readGate.wait()
            lock.withLock { _heldDataReads -= 1 }
        }
        return result
    }

    /// Called with the lock held.
    private func search(_ query: [String: Any]) -> (OSStatus, Data?) {
        switch keychain(query, search: true) {
        case let .failure(error): return (error.status, nil)
        case let .success(dataProtection):
            guard let item = items[dataProtection], matches(item, query) else { return (errSecItemNotFound, nil) }
            guard query[kSecReturnData as String] as? Bool == true else { return (errSecSuccess, nil) }
            _dataReads += 1
            if Thread.isMainThread { _mainThreadDataReads += 1 }
            return (errSecSuccess, item[kSecValueData as String] as? Data)
        }
    }

    func update(_ query: [String: Any], _ attributes: [String: Any]) -> OSStatus {
        begin(readsData: false)
        return lock.withLock {
            switch keychain(query) {
            case let .failure(error): return error.status
            case let .success(dataProtection):
                guard var item = items[dataProtection], matches(item, query) else { return errSecItemNotFound }
                item.merge(attributes) { $1 }
                if !dataProtection { item.removeValue(forKey: kSecAttrAccessible as String) }
                items[dataProtection] = item
                return errSecSuccess
            }
        }
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        begin(readsData: false)
        return lock.withLock {
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

    private func respond(_ status: Int, _ data: Data, _ headers: [String: String]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
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
            respond(status, data, headers)
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
