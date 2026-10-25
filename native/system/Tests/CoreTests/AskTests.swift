import Foundation
@testable import SystemCore
import XCTest

/// Ask (SET-51) with a scripted provider and a fake window: tool dispatch and argument validation, unknown tools, the
/// four-call limit, redacted tool results, cited ids kept only when a tool returned them, the follow-up limit, and Ask
/// off without a provider.
@MainActor
final class AskTests: XCTestCase {
    private let redactor = ExplainRedactor(homes: ["/Users/jdoe"], accountNames: ["jdoe"], sendFolderNames: false,
                                           key: Array(repeating: 7, count: 32))

    // MARK: Provider

    func testNoProviderTurnsAskOff() async throws {
        let made = Counter()
        let (ask, _, source) = center(ScriptedProvider(), made: made, choice: .none)
        XCTAssertTrue(ask.needsProvider)
        XCTAssertFalse(ask.canAsk)
        XCTAssertFalse(ask.ask("What is using the most memory?"))
        XCTAssertTrue(ask.exchanges.isEmpty)
        XCTAssertEqual(made.count, 0, "no provider is made")
        XCTAssertTrue(source.ran.isEmpty)
    }

    // MARK: Tools

    func testToolsRunAndOnlyIDsTheyReturnedAreLinks() async throws {
        let provider = ScriptedProvider()
        provider.calls = [("topGroups", #"{"metric":"memory","limit":2}"#)]
        provider.answer = "Chrome [g1] uses the most; [g7] and [d1] are not real."
        let (ask, _, source) = center(provider)
        XCTAssertTrue(ask.ask("  What is using the most memory?  "))
        await ask.settled()

        XCTAssertEqual(source.ran, ["topGroups memory app 2"])
        let result = try json(provider.results[0])
        XCTAssertEqual((result["results"] as? [[String: Any]])?.compactMap { $0["id"] as? String }, ["g1", "g2"])
        let exchange = try XCTUnwrap(ask.exchanges.first)
        XCTAssertEqual(exchange.question, "What is using the most memory?")
        guard case let .answered(answer) = exchange.state else { return XCTFail("\(exchange.state)") }
        XCTAssertEqual(answer.parts, [.text("Chrome "), .citation(id: "g1", target: .group(FakeAskSource.chrome)),
                                      .text(" uses the most; and are not real.")])
        XCTAssertEqual(exchange.tools, [AskToolRecord(call: "topGroups(limit: 2, metric: memory)", ran: true)])

        // A citation only selects.
        XCTAssertTrue(ask.select(.group(FakeAskSource.chrome)))
        XCTAssertEqual(source.selected, [.group(FakeAskSource.chrome)])
        XCTAssertEqual(source.ran, ["topGroups memory app 2"])
    }

    func testArgumentsAreValidatedBeforeAnythingRuns() async throws {
        let provider = ScriptedProvider()
        let (ask, _, source) = center(provider)
        provider.calls = [
            ("topGroups", #"{"metric":"disk"}"#),
            ("topGroups", #"{"metric":"cpu","limit":11}"#),
            ("topGroups", #"{"metric":"cpu","limit":"3"}"#),
            ("groupDetail", #"{"id":"g1"}"#)
        ]
        try await answer(ask, "First?")
        provider.calls = [
            ("topGroups", #"{"metric":"cpu","extra":1}"#),
            ("topGroups", "[1]"),
            ("topGroups", "{"),
            ("topGroups", #"{"layer":"app"}"#)
        ]
        try await answer(ask, "Second?")
        provider.calls = [
            ("topGroups", #"{"metric":"cpu","limit":true}"#),
            ("topGroups", #"{"metric":"cpu","limit":1.5}"#),
            ("largestItems", #"{"limit":0}"#),
            ("memoryState", #"{"verbose":true}"#)
        ]
        try await answer(ask, "Third?")
        XCTAssertTrue(source.ran.isEmpty, "\(source.ran)")
        let errors = try provider.results.map { try XCTUnwrap(try json($0)["error"] as? String) }
        XCTAssertEqual(errors, [
            "metric must be one of cpu, memory, energy.",
            "limit must be a whole number from 1 to 10.",
            "limit must be a whole number from 1 to 10.",
            "id must be a group id a tool returned in this conversation, like g1.",
            "topGroups takes no argument named extra.",
            "The arguments are not a JSON object.",
            "The arguments are not JSON.",
            "topGroups needs metric.",
            "limit must be a whole number from 1 to 10.",
            "limit must be a whole number from 1 to 10.",
            "limit must be a whole number from 1 to 20.",
            "memoryState takes no argument named verbose."
        ])
        XCTAssertTrue(ask.exchanges.allSatisfy { $0.tools.allSatisfy { !$0.ran } })

        // An id is checked against what tools returned in this thread, and its kind.
        provider.calls = [
            ("topGroups", #"{"metric":"cpu","layer":"project","limit":1}"#),
            ("groupDetail", #"{"id":"d1"}"#),
            ("groupDetail", #"{"id":"g1"}"#),
            ("largestItems", "")
        ]
        try await answer(ask, "Fourth?")
        XCTAssertEqual(source.ran, ["topGroups cpu project 1", "groupDetail \(FakeAskSource.chrome)", "largestItems 10"])
        XCTAssertNotNil(try json(provider.results[13])["error"])
    }

    func testUnknownToolsAreRejected() async throws {
        let provider = ScriptedProvider()
        provider.calls = [("deleteItem", #"{"path":"~/Movies"}"#), ("startCleanup", "{}")]
        let (ask, _, source) = center(provider)
        try await answer(ask, "Free some space?")
        XCTAssertTrue(source.ran.isEmpty)
        for result in provider.results {
            XCTAssertEqual(try json(result)["error"] as? String?, "There is no tool named "
                + (result.contains("deleteItem") ? "deleteItem" : "startCleanup")
                + ". The tools are topGroups, groupDetail, memoryState, diskSummary, largestItems, reclaimSuggestions.")
        }
        XCTAssertEqual(ask.exchanges[0].tools, [AskToolRecord(call: "deleteItem", ran: false),
                                                AskToolRecord(call: "startCleanup", ran: false)])
        // Every tool only reads.
        XCTAssertEqual(AskTool.allCases.map(\.rawValue),
                       ["topGroups", "groupDetail", "memoryState", "diskSummary", "largestItems", "reclaimSuggestions"])
    }

    func testAtMostFourToolCallsRunPerQuestion() async throws {
        let provider = ScriptedProvider()
        provider.calls = Array(repeating: ("memoryState", "{}"), count: 6)
        let (ask, _, source) = center(provider)
        try await answer(ask, "Why is my Mac slow?")
        XCTAssertEqual(source.ran, Array(repeating: "memoryState", count: 4))
        for result in provider.results.suffix(2) {
            XCTAssertEqual(try json(result)["error"] as? String, "No more tool calls are allowed for this question (at "
                + "most 4). Answer with the results you have.")
        }
        XCTAssertEqual(ask.exchanges[0].tools.map(\.ran), [true, true, true, true, false, false])

        // The next question counts from zero.
        try await answer(ask, "And now?")
        XCTAssertEqual(source.ran.count, 8)
    }

    func testToolResultsAreRedacted() async throws {
        let provider = ScriptedProvider()
        provider.calls = [("topGroups", #"{"metric":"cpu","layer":"project"}"#), ("diskSummary", "")]
        let (ask, explain, _) = center(provider)
        try await answer(ask, "Which project is busy?")
        let results = provider.results.joined()
        XCTAssertFalse(results.contains("/Users/jdoe"), results)
        XCTAssertFalse(results.contains("secret-project"), results)
        XCTAssertFalse(results.contains("jdoe"), results)
        XCTAssertTrue(results.contains(#""path":"~/dev/\#(redactor.placeholder("secret-project"))""#), results)
        XCTAssertTrue(results.contains(#""name":"[user]'s project""#), results)
        XCTAssertTrue(results.contains(#""scannedFolder":"~""#), results)

        // With Send folder names on, names are sent, in a new thread.
        explain.sendFolderNames = true
        XCTAssertTrue(ask.exchanges.isEmpty)
        XCTAssertEqual(ask.notice, AskCenter.folderNamesChanged)
        try await answer(ask, "Which project is busy?")
        XCTAssertTrue(provider.results[2].contains(#""path":"~/dev/secret-project""#), provider.results[2])
        XCTAssertNil(ask.notice)
    }

    // MARK: Answers

    func testAnswersArePlainTextWithinTheLimit() throws {
        let known: (String) -> AskTarget? = { $0 == "s1" ? .suggestion("key") : nil }
        XCTAssertThrowsError(try AskAnswer(validating: " \u{202E}\n ", target: known))
        let answer = try AskAnswer(validating: "Use **DerivedData** [s1].\u{202E} <b>x</b>", target: known)
        XCTAssertEqual(answer.parts, [.text("Use **DerivedData** "), .citation(id: "s1", target: .suggestion("key")),
                                      .text(". <b>x</b>")])
        XCTAssertEqual(answer.text, "Use **DerivedData** [s1]. <b>x</b>")
        let long = try AskAnswer(validating: String(repeating: "a", count: 3_000), target: known)
        XCTAssertEqual(long.text.count, AskAnswer.limit)
        XCTAssertTrue(long.text.hasSuffix("…"))
    }

    func testABracketCitingSeveralIDsKeepsOnlyTheKnownOnes() throws {
        let chrome = AskTarget.group(FakeAskSource.chrome)
        let known: (String) -> AskTarget? = { ["g1": chrome, "s3": .suggestion("key")][$0] }
        let answer = try AskAnswer(validating: "Chrome [g1, g99] and caches [g99, x5]. Also [G1] and [s3 g1,g01].",
                                   target: known)
        XCTAssertEqual(answer.parts, [
            .text("Chrome "), .citation(id: "g1", target: chrome), .text(" and caches. Also "),
            .citation(id: "g1", target: chrome), .text(" and "), .citation(id: "s3", target: .suggestion("key")),
            .text(" "), .citation(id: "g1", target: chrome), .text(".")
        ])
        // A follow-up gives the answer back with each kept id in its own brackets, which reads the same again.
        XCTAssertEqual(answer.text, "Chrome [g1] and caches. Also [g1] and [s3] [g1].")
        XCTAssertEqual(try AskAnswer(validating: answer.text, target: known), answer)
    }

    func testAFollowUpGetsTheThreadAndTheThreadTakesFiveFollowUps() async throws {
        let provider = ScriptedProvider()
        provider.calls = [("topGroups", #"{"metric":"memory"}"#)]
        provider.answer = "Chrome [g1] does."
        let (ask, _, _) = center(provider)
        for question in 1...6 {
            XCTAssertEqual(ask.questionsLeft, 7 - question)
            try await answer(ask, "Question \(question)?")
        }
        XCTAssertEqual(provider.prompts.count, 6)
        XCTAssertEqual(provider.prompts[0].history, [])
        XCTAssertEqual(provider.prompts[1].history, [AskPrompt.Turn(question: "Question 1?", answer: "Chrome [g1] does.")])
        XCTAssertEqual(provider.prompts[5].history.count, 5)
        XCTAssertEqual(provider.prompts[5].question, "Question 6?")

        XCTAssertEqual(ask.questionsLeft, 0)
        XCTAssertFalse(ask.canAsk)
        XCTAssertFalse(ask.ask("Question 7?"), "one question and five follow-ups")
        XCTAssertEqual(provider.prompts.count, 6)
        XCTAssertEqual(ask.exchanges.count, 6)

        // A new thread starts again, with ids from 1.
        ask.newThread()
        XCTAssertTrue(ask.exchanges.isEmpty)
        try await answer(ask, "Question 1 again?")
        XCTAssertEqual(provider.prompts[6].history, [])
        XCTAssertTrue(provider.results[6].contains(#""id":"g1""#))
    }

    func testAFailedQuestionIsNotCountedAndIsReplacedByTheNext() async throws {
        let provider = ScriptedProvider()
        provider.failure = ExplainError.failed("No connection.")
        let (ask, _, _) = center(provider)
        try await answer(ask, "Why?")
        XCTAssertEqual(ask.exchanges.map(\.state), [.failed("No connection.")])
        XCTAssertEqual(ask.questionsLeft, 6)
        provider.failure = nil
        try await answer(ask, "Why, again?")
        XCTAssertEqual(ask.exchanges.map(\.question), ["Why, again?"])
        XCTAssertEqual(provider.prompts.last?.history, [], "a failed question is not given back")

        provider.answer = "   "
        try await answer(ask, "Empty?")
        XCTAssertEqual(ask.exchanges.last?.state, .failed("The answer was rejected: The answer is empty."))
    }

    func testAskIsRefusedWhileAQuestionRunsAndForEmptyOrLongQuestions() async throws {
        let provider = ScriptedProvider()
        provider.hold = AnswerGate()
        let (ask, _, _) = center(provider)
        XCTAssertFalse(ask.ask("   "))
        XCTAssertFalse(ask.ask(String(repeating: "a", count: AskCenter.questionLimit + 1)))
        XCTAssertTrue(ask.ask("First?"))
        XCTAssertTrue(ask.isBusy)
        XCTAssertFalse(ask.ask("Second?"))
        provider.hold?.open()
        await ask.settled()
        XCTAssertEqual(ask.exchanges.count, 1)
    }

    // MARK: Ending a question

    func testStopKeepsNothingOfTheQuestion() async throws {
        let provider = ScriptedProvider()
        provider.hold = AnswerGate()
        provider.calls = [("memoryState", "{}")]
        let (ask, _, _) = center(provider)
        XCTAssertTrue(ask.ask("Why?"))
        await provider.hold?.reached()
        ask.stop()
        XCTAssertTrue(ask.exchanges.isEmpty)
        XCTAssertFalse(ask.isBusy)
        provider.hold?.open()
        await ask.settled()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(ask.exchanges.isEmpty, "the late answer is not kept")
    }

    func testChangingTheProviderEndsTheThread() async throws {
        let provider = ScriptedProvider()
        let (ask, explain, _) = center(provider)
        try await answer(ask, "First?")
        provider.hold = AnswerGate()
        XCTAssertTrue(ask.ask("Second?"))
        explain.choose(.none)
        XCTAssertTrue(ask.exchanges.isEmpty)
        XCTAssertEqual(ask.notice, AskCenter.providerChanged)
        XCTAssertTrue(ask.needsProvider)
        provider.hold?.open()
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertTrue(ask.exchanges.isEmpty)
    }

    func testAQuestionNotAnsweredInTimeFails() async throws {
        let provider = ScriptedProvider()
        provider.hold = AnswerGate()
        let (ask, _, _) = center(provider, timeout: .milliseconds(50))
        XCTAssertTrue(ask.ask("Why?"))
        try await until { !ask.isBusy }
        XCTAssertEqual(ask.exchanges.map(\.state), [.failed("Apple Intelligence did not answer within 0 seconds. Ask again.")])
        provider.hold?.open()
        XCTAssertTrue(ask.ask("Why, again?"), "asked again at once")
        await ask.settled()
    }

    // MARK: Helpers

    private func center(_ provider: ScriptedProvider, made: Counter = Counter(), choice: AIProviderChoice = .appleIntelligence,
                        timeout: Duration = .seconds(30)) -> (AskCenter, ExplainCenter, FakeAskSource) {
        let name = "AskTests-\(UUID().uuidString)"
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let explain = ExplainCenter(defaults: UserDefaults(suiteName: name)!, redactor: redactor, provider: { choice in
            guard choice != .none else { return nil }
            made.count += 1
            return provider
        })
        explain.choose(choice)
        let source = FakeAskSource()
        return (AskCenter(explain: explain, source: source, timeout: timeout), explain, source)
    }

    private func answer(_ ask: AskCenter, _ question: String) async throws {
        XCTAssertTrue(ask.ask(question))
        await ask.settled()
        XCTAssertFalse(ask.isBusy)
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func until(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("never")
        throw CancellationError()
    }
}

/// A provider that makes its scripted tool calls, keeps their results, and answers `answer`.
final class ScriptedProvider: AIProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls: [(String, String)] = []
    private var _answer = "An answer."
    private var _failure: (any Error)?
    private var _prompts: [AskPrompt] = []
    private var _results: [String] = []
    /// Holds each answer, after the tool calls, until the test opens it.
    var hold: AnswerGate?

    var calls: [(String, String)] {
        get { lock.withLock { _calls } }
        set { lock.withLock { _calls = newValue } }
    }
    var answer: String {
        get { lock.withLock { _answer } }
        set { lock.withLock { _answer = newValue } }
    }
    var failure: (any Error)? {
        get { lock.withLock { _failure } }
        set { lock.withLock { _failure = newValue } }
    }
    var prompts: [AskPrompt] { lock.withLock { _prompts } }
    var results: [String] { lock.withLock { _results } }

    func availability() async -> AIAvailability { .available }

    func explain(_: ExplainRequest) async throws -> ExplanationDraft {
        throw ExplainError.failed("Not used.")
    }

    func ask(_ prompt: AskPrompt, tools: AskTools, gate _: AskSendGate) async throws -> String {
        lock.withLock { _prompts.append(prompt) }
        for (name, arguments) in calls {
            let result = await tools.call(name, arguments: Data(arguments.utf8))
            lock.withLock { _results.append(result) }
        }
        await hold?.pass()
        if let failure { throw failure }
        return answer
    }
}

/// The window, as fixed results naming a home folder, an account name, and a withheld folder.
@MainActor
final class FakeAskSource: AskSource {
    static let chrome = OriginGroupID(.app(bundlePath: "/Applications/Google Chrome.app"))
    static let project = OriginGroupID(.project(path: "/Users/jdoe/dev/secret-project"))
    private(set) var ran: [String] = []
    private(set) var selected: [AskTarget] = []

    func topGroups(by metric: AskMetric, layer: AttributionLayer, limit: Int, redactor: ExplainRedactor) -> AskOutput {
        ran.append("topGroups \(metric.rawValue) \(layer.rawValue) \(limit)")
        return AskOutput(["layer": .words(layer.rawValue)], entries: [
            AskEntry(.group(Self.chrome), ["name": .name("Google Chrome"), "memory": .words("1.2 GB")]),
            AskEntry(.group(Self.project), ["name": .name("jdoe's project"),
                                            "path": .path(redactor.path("/Users/jdoe/dev/secret-project"))])
        ].prefix(limit).map { $0 })
    }

    func groupDetail(_ group: OriginGroupID, redactor _: ExplainRedactor) -> AskOutput? {
        ran.append("groupDetail \(group)")
        return AskOutput(["name": .name("Google Chrome")])
    }

    func memoryState() -> AskOutput {
        ran.append("memoryState")
        return AskOutput(["pressure": .words("Warning")])
    }

    func diskSummary(redactor: ExplainRedactor) -> AskOutput {
        ran.append("diskSummary")
        return AskOutput(["scannedFolder": .path(redactor.path("/Users/jdoe"))])
    }

    func largestItems(limit: Int, redactor: ExplainRedactor) -> AskOutput {
        ran.append("largestItems \(limit)")
        let path = "/Users/jdoe/Movies/trip.mov"
        return AskOutput([:], entries: [AskEntry(.diskItem(path: path), ["path": .path(redactor.path(path))])])
    }

    func reclaimSuggestions(redactor _: ExplainRedactor) -> AskOutput {
        ran.append("reclaimSuggestions")
        return AskOutput([:], entries: [AskEntry(.suggestion("disk-suggestion:xcodeDerivedData::"),
                                                 ["rule": .words("Xcode DerivedData")])])
    }

    func select(_ target: AskTarget) -> Bool {
        selected.append(target)
        return true
    }
}
