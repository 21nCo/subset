import Foundation
@testable import SystemCore
import XCTest

/// Ask (SET-51) through OpenRouter, with the Keychain double and the `URLProtocol` stub of `OpenRouterTests`, never the
/// network: tool calls answered with redacted results in the next request, the send preview before the session's first
/// confirmed request, `tool_choice` `none` after four calls, and nothing sent with a key replaced since the question
/// began.
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
        StubProtocol.enqueue(status: 200, json: toolCalls([("call-1", "topGroups", #"{"metric":"memory","layer":"project"}"#)]))
        StubProtocol.enqueue(status: 200, json: completion("Your project [g2] uses the most."))
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
        StubProtocol.enqueue(status: 200, json: completion("Yes."))
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
        StubProtocol.enqueue(status: 200, json: toolCalls((1...3).map { ("a\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: toolCalls([("b1", "diskSummary", "{}"), ("b2", "reclaimSuggestions", "{}")]))
        StubProtocol.enqueue(status: 200, json: completion("Memory is under pressure."))
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
        StubProtocol.enqueue(status: 200, json: toolCalls((1...4).map { ("c\($0)", "memoryState", "{}") }))
        StubProtocol.enqueue(status: 200, json: toolCalls([("d1", "memoryState", "{}")]))
        try await answer(ask, "And now?")
        XCTAssertEqual(ask.exchanges.last?.state,
                       .failed("The answer was rejected: The model asked for more tools after its 4."))
        XCTAssertEqual(StubProtocol.requests.count, 2)
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

    func testAnOpenRouterErrorIsShownAndNothingMoreIsSent() async throws {
        let (ask, explain, _, _) = try await chosen()
        explain.sendConfirmed = true
        StubProtocol.enqueue(status: 400, json: #"{"error":{"code":400,"message":"No endpoints support tools."}}"#)
        try await answer(ask, "Why?")
        XCTAssertEqual(ask.exchanges.last?.state,
                       .failed("OpenRouter answered 400 (bad request): No endpoints support tools."))
        XCTAssertEqual(StubProtocol.requests.count, 1)
    }

    // MARK: Helpers

    private func chosen() async throws -> (AskCenter, ExplainCenter, FakeAskSource, FakeKeychain) {
        let name = "AskOpenRouterTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = FakeKeychain()
        try OpenRouterKeyStore(items: keychain).save(Self.key)
        let client = OpenRouterClient(session: StubProtocol.session(), log: RecordingLog(), sleep: { _ in })
        let account = OpenRouterAccount(keys: OpenRouterKeyStore(items: keychain), client: client, defaults: defaults,
                                        log: RecordingLog())
        await account.refreshKey()
        let explain = ExplainCenter(defaults: defaults, redactor: redactor, openRouter: account)
        XCTAssertTrue(explain.choose(.openRouter))
        let source = FakeAskSource()
        return (AskCenter(explain: explain, source: source), explain, source, keychain)
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

    private func completion(_ content: String) -> String {
        text(["choices": [["message": ["role": "assistant", "content": content]]]])
    }

    private func toolCalls(_ calls: [(id: String, name: String, arguments: String)]) -> String {
        text(["choices": [["finish_reason": "tool_calls", "message": [
            "role": "assistant", "content": NSNull(),
            "tool_calls": calls.map { ["id": $0.id, "type": "function", "function": ["name": $0.name, "arguments": $0.arguments]] }
        ] as [String: Any]]]])
    }

    private func text(_ object: [String: Any]) -> String {
        String(decoding: try! JSONSerialization.data(withJSONObject: object), as: UTF8.self)
    }

    private func json(_ data: Data?) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(data)) as? [String: Any])
    }
}
