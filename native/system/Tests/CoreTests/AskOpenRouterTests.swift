import Foundation
import Security
@testable import SystemCore
import XCTest

/// Ask (SET-51) through OpenRouter, with the Keychain double and the `URLProtocol` stub of `OpenRouterTests`, never the
/// network: tool calls answered with redacted results in the next request, the send preview before the session's first
/// confirmed request, `tool_choice` `none` after four calls, nothing sent with a key replaced since the question
/// began, and each key read one of the checks Explain's are (SET-165).
@MainActor
final class AskOpenRouterTests: XCTestCase {
    private static let key = "sk-or-v1-" + String(repeating: "0123456789abcdef", count: 4)
    private let redactor = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: ["jdoe"], sendFolderNames: false,
                                           key: Array(repeating: 7, count: 32))

    override func setUp() {
        super.setUp()
        StubProtocol.reset()
    }

    func testToolResultsGoBackInTheNextRequestAfterTheFirstIsPreviewed() async throws {
        let (ask, explain, source, _) = try await chosen()
        StubProtocol.enqueue(status: 200, json: try toolCalls([("call-1", "topGroups", #"{"metric":"memory","layer":"project"}"#)]))
        StubProtocol.enqueue(status: 200, json: try completion("Your project [g2] uses the most."))
        XCTAssertTrue(ask.ask("What is using the most memory?"))
        let preview = try await previewShown(ask)
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing is sent before Send")
        XCTAssertEqual(preview.provider, .openRouter)

        let first = try json(preview.body)
        XCTAssertEqual(first["tool_choice"] as? String, "auto")
        XCTAssertEqual((first["tools"] as? [[String: Any]])?.compactMap { ($0["function"] as? [String: Any])?["name"] as? String },
                       AskTool.allCases.map(\.rawValue))
        let messages = try XCTUnwrap(first["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["system", "user"])
        XCTAssertEqual(messages.last?["content"] as? String, "What is using the most memory?")

        ask.confirmSend(preview)
        await ask.settled()
        let sent = StubProtocol.requests.compactMap(\.body)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(sent[0], preview.body, "exactly the body shown")
        XCTAssertTrue(explain.sendConfirmed, "OpenRouter answered a confirmed request, so no preview follows")
        let second = try XCTUnwrap(try json(sent[1])["messages"] as? [[String: Any]])
        XCTAssertEqual(second.map { $0["role"] as? String }, ["system", "user", "assistant", "tool"])
        XCTAssertEqual(second[3]["tool_call_id"] as? String, "call-1")
        let result = try XCTUnwrap(second[3]["content"] as? String)
        XCTAssertTrue(result.contains(#""path":"~/dev/\#(redactor.placeholder("secret-project"))""#), result)
        XCTAssertFalse(String(decoding: sent[1], as: UTF8.self).contains("/Users/jdoe"))
        XCTAssertEqual(source.ran, ["topGroups memory project 5"])

        let exchange = try XCTUnwrap(ask.exchanges.first)
        guard case let .answered(answer) = exchange.state else { return XCTFail("\(exchange.state)") }
        XCTAssertEqual(answer.parts, [.text("Your project "), .citation(id: "g2", target: .group(FakeAskSource.project)),
                                      .text(" uses the most.")])
        XCTAssertEqual(exchange.sent, sent, "What was sent shows both bodies")

        // A follow-up is sent without a preview, with the thread's question and answer.
        StubProtocol.enqueue(status: 200, json: try completion("Yes."))
        XCTAssertTrue(ask.ask("Is that normal?"))
        await ask.settled()
        let followUp = try XCTUnwrap(try json(StubProtocol.requests[2].body ?? Data())["messages"] as? [[String: Any]])
        XCTAssertEqual(followUp.map { $0["content"] as? String }.suffix(3),
                       ["What is using the most memory?", "Your project [g2] uses the most.", "Is that normal?"])
    }

    func testCancellingThePreviewSendsNothing() async throws {
        let (ask, explain, source, _) = try await chosen()
        XCTAssertTrue(ask.ask("Why is my Mac slow?"))
        _ = try await previewShown(ask)
        ask.cancelSend()
        await ask.settled()
        XCTAssertTrue(ask.exchanges.isEmpty)
        XCTAssertTrue(StubProtocol.requests.isEmpty)
        XCTAssertFalse(explain.sendConfirmed)
        XCTAssertTrue(source.ran.isEmpty)
    }

    func testAfterFourToolCallsOpenRouterIsAskedToAnswer() async throws {
        let (ask, explain, source, _) = try await chosen()
        explain.sendConfirmed = true
        StubProtocol.enqueue(status: 200, json: try toolCalls((1...3).map { ("a\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: try toolCalls([("b1", "diskSummary", "{}"), ("b2", "reclaimSuggestions", "{}")]))
        StubProtocol.enqueue(status: 200, json: try completion("Memory is under pressure."))
        try await answer(ask, "Why is my Mac slow?")
        XCTAssertEqual(source.ran, ["memoryState", "memoryState", "memoryState", "diskSummary"])
        let bodies = try StubProtocol.requests.map { try json($0.body ?? Data()) }
        XCTAssertEqual(bodies.map { $0["tool_choice"] as? String }, ["auto", "auto", "none"])
        let last = try XCTUnwrap(bodies[2]["messages"] as? [[String: Any]])
        XCTAssertTrue((last.last?["content"] as? String)?.contains("No more tool calls") == true)
        XCTAssertEqual(ask.exchanges.last?.state, .answered(try AskAnswer(validating: "Memory is under pressure.",
                                                                          target: { _ in nil })))

        // Tools asked for after the limit are outside the format.
        StubProtocol.reset()
        StubProtocol.enqueue(status: 200, json: try toolCalls((1...4).map { ("c\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: try toolCalls([("d1", "memoryState", "{}")]))
        try await answer(ask, "And now?")
        XCTAssertEqual(ask.exchanges.last?.state,
                       .failed("The answer was rejected: The model asked for more tools after its 4."))
        XCTAssertEqual(StubProtocol.requests.count, 2)
    }

    func testABatchOfToolCallsPastTheQuestionsBudgetEndsItAndNothingMoreIsSent() async throws {
        let (ask, explain, source, _) = try await chosen()
        explain.sendConfirmed = true
        // A hundred calls in one answer: none runs, and no second request is sent.
        StubProtocol.enqueue(status: 200, json: try toolCalls((1...100).map { ("a\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: try completion("Not asked for."))
        try await answer(ask, "Why is my Mac slow?")
        var exchange = try XCTUnwrap(ask.exchanges.last)
        XCTAssertEqual(exchange.state, .failed(AskToolbox.exhausted.message))
        XCTAssertEqual(StubProtocol.requests.count, 1)
        XCTAssertEqual(exchange.sent, StubProtocol.requests.compactMap(\.body), "what was sent is kept")
        XCTAssertTrue(source.ran.isEmpty)
        XCTAssertTrue(exchange.tools.isEmpty)
        XCTAssertEqual(ask.questionsLeft, AskCenter.followUpLimit + 1, "a failed question is not counted")

        // A later batch larger than what is left: the calls before it are kept, and nothing more is sent.
        StubProtocol.reset()
        StubProtocol.enqueue(status: 200, json: try toolCalls((1...3).map { ("b\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: try toolCalls((1...(AskToolbox.budgetedCalls - 2)).map {
            ("c\($0)", "diskSummary", "{}")
        }))
        StubProtocol.enqueue(status: 200, json: try completion("Not asked for."))
        try await answer(ask, "Why is my Mac slow?")
        exchange = try XCTUnwrap(ask.exchanges.last)
        XCTAssertEqual(ask.exchanges.count, 1, "asked again in the failed question's place")
        XCTAssertEqual(exchange.state, .failed(AskToolbox.exhausted.message))
        let sent = StubProtocol.requests.compactMap(\.body)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(exchange.sent, sent)
        XCTAssertEqual(source.ran, ["memoryState", "memoryState", "memoryState"])
        XCTAssertEqual(exchange.tools.map(\.ran), [true, true, true])
        let results = try XCTUnwrap(try json(sent[1])["messages"] as? [[String: Any]]).compactMap { message in
            message["role"] as? String == "tool" ? message["content"] as? String : nil
        }
        XCTAssertEqual(results.count, 3)
        XCTAssertLessThanOrEqual(results.joined().count, AskToolbox.questionLimit)

        // Asked again, it is answered and counted.
        StubProtocol.reset()
        StubProtocol.enqueue(status: 200, json: try completion("Memory is under pressure."))
        try await answer(ask, "Why is my Mac slow?")
        XCTAssertEqual(ask.questionsLeft, AskCenter.followUpLimit)
    }

    func testAKeyReplacedSinceTheQuestionBeganIsNeverUsed() async throws {
        let (ask, _, _, keychain) = try await chosen()
        XCTAssertTrue(ask.ask("Why is my Mac slow?"))
        let preview = try await previewShown(ask)
        // Replaced outside System.
        try OpenRouterKeyStore(items: keychain).save("sk-or-v1-" + String(repeating: "f", count: 64))
        ask.confirmSend(preview)
        await ask.settled()
        XCTAssertEqual(ask.exchanges.last?.state, .failed(OpenRouterProvider.keyChanged))
        XCTAssertTrue(StubProtocol.requests.isEmpty)
    }

    func testAQuestionFailingAfterAToolRoundTripKeepsWhatWasSentAndTheTools() async throws {
        let (ask, explain, _, _) = try await chosen()
        explain.sendConfirmed = true
        StubProtocol.enqueue(status: 200, json: try toolCalls([("call-1", "memoryState", "{}")]))
        StubProtocol.enqueue(status: 400, json: #"{"error":{"code":400,"message":"No endpoints support tools."}}"#)
        try await answer(ask, "Why?")
        let exchange = try XCTUnwrap(ask.exchanges.last)
        XCTAssertEqual(exchange.state, .failed("OpenRouter answered 400 (bad request): No endpoints support tools."))
        let sent = StubProtocol.requests.compactMap(\.body)
        XCTAssertEqual(sent.count, 2)
        XCTAssertEqual(exchange.sent, sent, "both bodies left this Mac, the second with the tool's result")
        XCTAssertEqual(exchange.tools, [AskToolRecord(call: "memoryState()", ran: true)])
    }

    func testAnOpenRouterErrorIsShownAndNothingMoreIsSent() async throws {
        let (ask, explain, _, _) = try await chosen()
        explain.sendConfirmed = true
        StubProtocol.enqueue(status: 400, json: #"{"error":{"code":400,"message":"No endpoints support tools."}}"#)
        try await answer(ask, "Why?")
        XCTAssertEqual(ask.exchanges.last?.state,
                       .failed("OpenRouter answered 400 (bad request): No endpoints support tools."))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    // MARK: Checks shared with Explain (SET-165)

    /// The key removed outside System, found as the question begins or as its previewed body is sent: the latest check
    /// sets the choice back as Explain's does, saying why, and nothing is sent.
    func testAKeyRemovedOutsideSystemSetsTheChoiceBackAndSendsNothing() async throws {
        for afterPreview in [false, true] {
            StubProtocol.reset()
            let setup = try await openRouterChosen()
            let ask = setup.ask
            let explain = setup.explain
            if afterPreview {
                XCTAssertTrue(ask.ask("Why is my Mac slow?"))
                let preview = try await previewShown(ask)
                try OpenRouterKeyStore(items: setup.keychain).remove()
                ask.confirmSend(preview)
            } else {
                try OpenRouterKeyStore(items: setup.keychain).remove()
                XCTAssertTrue(ask.ask("Why is my Mac slow?"))
            }
            await ask.settled()
            XCTAssertTrue(StubProtocol.requests.isEmpty, "after preview: \(afterPreview)")
            XCTAssertEqual(explain.choice, .appleIntelligence, "after preview: \(afterPreview)")
            XCTAssertEqual(setup.defaults.string(forKey: ExplainCenter.choiceKey), "appleIntelligence", "stored as shown")
            XCTAssertEqual(explain.notice, ExplainCenter.notice(.noKey))
            XCTAssertEqual(ask.notice, ExplainCenter.notice(.noKey), "Ask says why its thread ended")
            XCTAssertTrue(ask.exchanges.isEmpty)
            XCTAssertFalse(explain.sendConfirmed)
            XCTAssertEqual(setup.keychain.mainThreadDataReads, 0, "off the main thread")
        }
    }

    /// A model ID checked against the key stored then, which holds the key that replaced it outside System: the
    /// question's first key read refuses it before anything is previewed, sets the choice back and clears the model ID,
    /// as Explain's refusal does, so the key is never sent or left stored as the model ID.
    func testAModelIDHoldingAKeyReplacedOutsideSystemIsClearedAndNothingIsSent() async throws {
        let other = "tok-0123456789abcdef"
        let setup = try await openRouterChosen(model: "acme/\(other)")
        XCTAssertEqual(setup.account.checkedModel, "acme/\(other)", "it does not hold the key stored now")
        try OpenRouterKeyStore(items: setup.keychain).save(other)

        XCTAssertTrue(setup.ask.ask("Why is my Mac slow?"))
        await setup.ask.settled()
        XCTAssertTrue(StubProtocol.requests.isEmpty, "nothing sent with the key in the body")
        XCTAssertEqual(setup.explain.choice, .appleIntelligence)
        XCTAssertEqual(setup.explain.notice, ExplainCenter.notice(.modelHeldKey))
        XCTAssertEqual(setup.ask.notice, ExplainCenter.notice(.modelHeldKey))
        XCTAssertEqual(setup.account.checkedModel, "")
        XCTAssertEqual(setup.account.model, "")
        XCTAssertEqual(setup.defaults.string(forKey: "openRouterModel"), "")
        XCTAssertTrue(setup.ask.exchanges.isEmpty)
    }

    /// An older check, the account's read of whether a key is stored, held with a failure until a question reached its
    /// preview: the question's key read overtook it, so it sets nothing back and the preview and thread stand, and
    /// exactly the body shown is sent.
    func testAnOlderFailingCheckOvertakenByAQuestionSetsNothingBack() async throws {
        let setup = try await openRouterChosen()
        let ask = setup.ask
        let keychain = setup.keychain
        StubProtocol.enqueue(status: 200, json: try completion("Earlier."))
        setup.explain.sendConfirmed = true
        try await answer(ask, "What is using the most memory?")
        setup.explain.sendConfirmed = false

        keychain.failure = errSecInteractionNotAllowed
        keychain.holdsSearches = true
        let read = Task { await setup.account.refreshKey() }
        try await until { keychain.heldSearches == 1 }
        keychain.holdsSearches = false
        keychain.failure = nil
        XCTAssertTrue(ask.ask("Why is my Mac slow?"))
        let preview = try await previewShown(ask)
        keychain.releaseSearch()
        await read.value
        XCTAssertEqual(setup.explain.choice, .openRouter)
        XCTAssertNil(setup.explain.notice)
        XCTAssertNil(ask.notice)
        XCTAssertEqual(ask.exchanges.count, 2, "the thread is kept")
        XCTAssertEqual(ask.exchanges.last?.state, .confirming(preview), "the newer preview is kept")

        StubProtocol.enqueue(status: 200, json: try completion("Memory is under pressure."))
        ask.confirmSend(preview)
        await ask.settled()
        XCTAssertEqual(StubProtocol.requests.last?.body, preview.body)
        guard case .answered? = ask.exchanges.last?.state else { return XCTFail("\(String(describing: ask.exchanges.last))") }
    }

    /// The question's key read, as its previewed body is sent, held after finding no key until a later check found it
    /// stored again: it fails only its own question, saying what it found, and changes no provider and no thread.
    func testAQuestionsRefusalOvertakenByALaterCheckEndsOnlyThatQuestion() async throws {
        let setup = try await openRouterChosen()
        let ask = setup.ask
        let keychain = setup.keychain
        StubProtocol.enqueue(status: 200, json: try completion("Earlier."))
        setup.explain.sendConfirmed = true
        try await answer(ask, "What is using the most memory?")
        setup.explain.sendConfirmed = false

        XCTAssertTrue(ask.ask("Why is my Mac slow?"))
        let preview = try await previewShown(ask)
        try OpenRouterKeyStore(items: keychain).remove()
        keychain.holdsDataReads = true
        let reads = keychain.heldDataReads
        ask.confirmSend(preview)
        try await until { keychain.heldDataReads == reads + 1 }
        keychain.holdsDataReads = false
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        // Settings' read, a later check, finds the key stored again.
        await setup.explain.refreshAvailability()
        XCTAssertEqual(setup.explain.availability, .availableOnOpenRouter)
        keychain.releaseDataRead()
        await ask.settled()

        XCTAssertEqual(StubProtocol.requests.count, 1, "only the earlier question was sent")
        XCTAssertEqual(setup.explain.choice, .openRouter)
        XCTAssertNil(setup.explain.notice)
        XCTAssertNil(ask.notice)
        XCTAssertEqual(ask.exchanges.count, 2, "the thread is kept")
        XCTAssertEqual(ask.exchanges.last?.state, .failed(try XCTUnwrap(ExplainCenter.overtaken(.noOpenRouterKey))))
    }

    /// Add Key or Remove Key starting while the question reads the key ends the question: nothing is sent with the key
    /// being replaced or removed.
    func testChangingTheKeyMidQuestionSendsNothing() async throws {
        for replacing in [false, true] {
            StubProtocol.reset()
            let setup = try await openRouterChosen()
            let ask = setup.ask
            let keychain = setup.keychain
            setup.explain.sendConfirmed = true
            StubProtocol.enqueue(status: 200, json: try completion("Answered."))
            keychain.holdsDataReads = true
            XCTAssertTrue(ask.ask("Why is my Mac slow?"))
            try await until { keychain.heldDataReads == 1 }
            // The change is held, so only its start can end the question.
            keychain.holdsOtherCalls = true
            let changing = Task {
                if replacing { await setup.account.addKey("sk-or-v1-" + String(repeating: "f", count: 64)) } else {
                    await setup.account.removeKey()
                }
            }
            try await until { keychain.heldOtherCalls == 1 }
            XCTAssertEqual(ask.exchanges.last?.state, .failed(AskCenter.keyChanged), "replacing: \(replacing)")
            keychain.holdsDataReads = false
            keychain.releaseDataRead()
            await ask.settled()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(StubProtocol.requests.isEmpty, "replacing: \(replacing)")
            keychain.holdsOtherCalls = false
            keychain.releaseOtherCall()
            await changing.value
            XCTAssertEqual(setup.explain.choice, replacing ? .openRouter : .appleIntelligence)
            XCTAssertTrue(StubProtocol.requests.isEmpty)
        }
    }

    // MARK: Helpers

    private struct Setup {
        let ask: AskCenter
        let explain: ExplainCenter
        let source: FakeAskSource
        let keychain: FakeKeychain
        let account: OpenRouterAccount
        let defaults: UserDefaults
    }

    /// OpenRouter chosen, with a key stored and, with `model`, that model ID checked.
    private func openRouterChosen(model: String? = nil) async throws -> Setup {
        let name = "AskOpenRouterTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let client = OpenRouterClient(session: StubProtocol.session(), log: RecordingLog(),
                                      sleep: { _ in /* Retries are not waited for in tests. */ })
        let account = OpenRouterAccount(keys: OpenRouterKeyStore(items: keychain), client: client, defaults: defaults,
                                        log: RecordingLog())
        await account.refreshKey()
        if let model {
            account.model = model
            await account.modelChecked()
        }
        let explain = ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account)
        XCTAssertTrue(explain.choose(.openRouter))
        let source = FakeAskSource()
        return Setup(ask: AskCenter(explain: explain, source: source), explain: explain, source: source,
                     keychain: keychain, account: account, defaults: defaults)
    }

    private func chosen() async throws -> (AskCenter, ExplainCenter, FakeAskSource, FakeKeychain) {
        let setup = try await openRouterChosen()
        return (setup.ask, setup.explain, setup.source, setup.keychain)
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never")
        throw CancellationError()
    }

    private func answer(_ ask: AskCenter, _ question: String) async throws {
        XCTAssertTrue(ask.ask(question))
        await ask.settled()
        XCTAssertFalse(ask.isBusy)
    }

    private func previewShown(_ ask: AskCenter) async throws -> AskSendPreview {
        for _ in 0..<2_000 {
            if case let .confirming(preview)? = ask.exchanges.last?.state { return preview }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("no preview")
        throw CancellationError()
    }

    private func completion(_ content: String) throws -> String {
        try text(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func toolCalls(_ calls: [(id: String, name: String, arguments: String)]) throws -> String {
        try text(["choices": [["finish_reason": "tool_calls", "message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        ] as [String: Any]]]])
    }

    private func text(_ object: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
}
