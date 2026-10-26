import Foundation
@testable import SystemCore
import XCTest
#if canImport(FoundationModels)
import FoundationModels
#endif

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

    func testResultsStayWithinTheirBudgetAndThingsLeftOutGetNoID() throws {
        let source = FakeAskSource()
        source.bulky = true
        let toolbox = AskToolbox(source: source, redactor: redactor)
        toolbox.begin(1, redactor: redactor)
        func listed(_ result: String, prefix: String, total: Int) throws -> Int {
            XCTAssertLessThanOrEqual(result.count, AskToolbox.resultLimit)
            let object = try json(result)
            let ids = (object["results"] as? [[String: Any]] ?? []).map { $0["id"] as? String }
            XCTAssertEqual(object["notListed"] as? Int, total - ids.count, "everything left out is counted")
            XCTAssertEqual(ids, (0..<ids.count).map { "\(prefix)\($0 + 1)" })
            return ids.count
        }
        // Twenty suggestions with every text at its cap, five more not listed by the source, and twenty long items.
        let suggestions = try toolbox.call("reclaimSuggestions", arguments: Data(), question: 1)
        let suggestionsListed = try listed(suggestions, prefix: "s", total: 25)
        XCTAssertTrue((1..<20).contains(suggestionsListed), suggestions)
        XCTAssertNil(toolbox.target(for: "s\(suggestionsListed + 1)"), "what is left out has no id")
        let items = try toolbox.call("largestItems", arguments: Data(#"{"limit":20}"#.utf8), question: 1)
        let itemsListed = try listed(items, prefix: "d", total: 20)
        XCTAssertTrue((1..<20).contains(itemsListed), items)
        XCTAssertNil(toolbox.target(for: "d\(itemsListed + 1)"), "what is left out has no id")

        // Results list things only within the question's budget, until it is used up.
        var used = suggestions.count + items.count
        XCTAssertLessThanOrEqual(used, AskToolbox.questionLimit)
        var later: [Int] = []
        for _ in 1...2 {
            let result = try toolbox.call("largestItems", arguments: Data(), question: 1)
            let count = try listed(result, prefix: "d", total: 20)
            used += result.count
            XCTAssertLessThanOrEqual(used, AskToolbox.questionLimit)
            later.append(count)
        }
        XCTAssertEqual(later.last, 0, "the question's budget is used up: \(later)")

        // The next question has its own budget, and the same things keep their ids.
        toolbox.begin(2, redactor: redactor)
        let again = try toolbox.call("reclaimSuggestions", arguments: Data(), question: 2)
        XCTAssertEqual(try listed(again, prefix: "s", total: 25), suggestionsListed)
        XCTAssertEqual(again, suggestions)
    }

    func testEveryStringAQuestionsCallsReturnCountsTowardsItsBudget() throws {
        let source = FakeAskSource()
        source.bulky = true
        let toolbox = AskToolbox(source: source, redactor: redactor)
        var question = 1
        toolbox.begin(question, redactor: redactor)
        var used = 0
        func call(_ name: String, _ arguments: String = "{}") throws -> [String: Any] {
            let result = try toolbox.call(name, arguments: Data(arguments.utf8), question: question)
            used += result.count
            XCTAssertLessThanOrEqual(result.count, AskToolbox.resultLimit, name)
            XCTAssertLessThanOrEqual(used, AskToolbox.questionLimit, "after \(name): \(used)")
            return try json(result)
        }
        func refused(_ object: [String: Any]) -> Bool {
            object["results"] == nil && object["error"] as? String == AskToolbox.tooLarge
        }

        // Ten groups, then one group's facts, as Explain sends them, three times: the facts alone fill the rest.
        let groups = try call("topGroups", #"{"metric":"memory","limit":10}"#)
        XCTAssertEqual((groups["results"] as? [Any])?.count, 10)
        let detail = try call("groupDetail", #"{"id":"g1"}"#)
        let factsSent = try JSONSerialization.data(withJSONObject: try XCTUnwrap(detail["group"])).count
        XCTAssertTrue((2_000...AskToolbox.resultLimit).contains(factsSent), "facts sized as a real group's: \(factsSent)")
        for _ in 1...2 {
            let again = try call("groupDetail", #"{"id":"g1"}"#)
            XCTAssertTrue(refused(again), "facts that do not fit are not sent at all: \(again)")
            XCTAssertNil(again["group"])
        }
        XCTAssertNil(toolbox.target(for: "g\(FakeAskSource.subgroups + 11)"), "a refused result gives no id")

        // Refusals count too, and room is kept for them: invalid arguments, then results that fill the rest, then
        // calls past the limit, one of them for a tool that does not exist.
        question = 2
        toolbox.begin(question, redactor: redactor)
        used = 0
        XCTAssertNotNil(try call("groupDetail", #"{"id":"g999"}"#)["error"])
        XCTAssertNotNil(try call("largestItems", #"{"limit":20}"#)["results"])
        XCTAssertNotNil(try call("topGroups", #"{"metric":"cpu","limit":10}"#)["results"])
        XCTAssertNotNil(try call("topGroups", #"{"metric":"cpu","limit":10}"#)["notListed"])
        XCTAssertNotNil(try call("deleteEverything")["error"])
        for _ in 2...AskToolbox.callLimit {
            XCTAssertNotNil(try call("reclaimSuggestions")["error"])
        }
        XCTAssertEqual(toolbox.records.map(\.ran), [false, true, true, true, false, false, false, false])
        XCTAssertFalse(source.ran.contains("reclaimSuggestions"))

        // Every refusal fits the room kept for it, even naming a tool whose name grows when escaped.
        question = 3
        toolbox.begin(question, redactor: redactor)
        used = 0
        let unknown = try toolbox.call(String(repeating: #"""#, count: 60), arguments: Data(), question: question)
        XCTAssertLessThanOrEqual(unknown.count, AskToolbox.refusalLimit)
        XCTAssertTrue(try XCTUnwrap(json(unknown)["error"] as? String).hasPrefix("There is no tool named"), unknown)
        XCTAssertLessThanOrEqual(AskToolbox.error(AskToolbox.tooLarge).count, AskToolbox.refusalLimit)
        XCTAssertEqual(try json(AskToolbox.error(AskToolbox.tooLarge))["error"] as? String, AskToolbox.tooLarge)
    }

    func testCallsPastAQuestionsBudgetReturnNothingAndEndIt() throws {
        let source = FakeAskSource()
        source.bulky = true
        let toolbox = AskToolbox(source: source, redactor: redactor)
        toolbox.begin(1, redactor: redactor)
        // Valid, invalid, unknown, and refused calls in turn, three times as many as a question takes.
        let mixed = [("topGroups", #"{"metric":"memory","limit":10}"#), ("groupDetail", #"{"id":"g1"}"#),
                     ("deleteEverything", "{}"), ("largestItems", #"{"limit":"all"}"#), ("reclaimSuggestions", ""),
                     ("groupDetail", #"{"id":"g999"}"#)]
        var used = 0
        var returned = 0
        for number in 0..<(3 * AskToolbox.budgetedCalls) {
            let (name, arguments) = mixed[number % mixed.count]
            do {
                let result = try toolbox.call(name, arguments: Data(arguments.utf8), question: 1)
                returned += 1
                used += result.count
                XCTAssertLessThanOrEqual(result.count, AskToolbox.resultLimit, "call \(number + 1), \(name)")
                XCTAssertNotNil(try JSONSerialization.jsonObject(with: Data(result.utf8)) as? [String: Any])
            } catch {
                XCTAssertEqual(error as? ExplainError, AskToolbox.exhausted, "call \(number + 1)")
            }
            XCTAssertLessThanOrEqual(used, AskToolbox.questionLimit, "after call \(number + 1), \(name)")
        }
        XCTAssertEqual(returned, AskToolbox.budgetedCalls, "nothing is returned past the question's calls")
        XCTAssertEqual(toolbox.records.count, AskToolbox.budgetedCalls)
        XCTAssertEqual(source.ran, ["topGroups memory app 10", "groupDetail \(FakeAskSource.chrome)"],
                       "only the first four calls could run, and only two of them were valid")

        // A question that has ended returns nothing either; the next has its own budget.
        toolbox.end()
        XCTAssertThrowsError(try toolbox.call("memoryState", arguments: Data(), question: 1)) { error in
            XCTAssertTrue(error is CancellationError, "\(error)")
        }
        toolbox.begin(2, redactor: redactor)
        XCTAssertNotNil(try json(try toolbox.call("memoryState", arguments: Data(), question: 2))["pressure"])
    }

    func testAModelCallingToolsPastTheBudgetEndsTheQuestionWhichIsNotCounted() async throws {
        let provider = ScriptedProvider()
        provider.calls = Array(repeating: ("memoryState", "{}"), count: 3 * AskToolbox.budgetedCalls)
        let (ask, _, source) = center(provider)
        try await answer(ask, "Why is my Mac slow?")
        let exchange = try XCTUnwrap(ask.exchanges.last)
        XCTAssertEqual(exchange.state, .failed(AskToolbox.exhausted.message))
        XCTAssertEqual(provider.results.count, AskToolbox.budgetedCalls, "the call past the budget ended the answer")
        XCTAssertLessThanOrEqual(provider.results.joined().count, AskToolbox.questionLimit)
        XCTAssertEqual(exchange.tools.count, AskToolbox.budgetedCalls, "the tools it called are kept")
        XCTAssertEqual(source.ran.count, AskToolbox.callLimit)
        XCTAssertEqual(ask.questionsLeft, AskCenter.followUpLimit + 1, "a failed question is not counted")

        provider.calls = []
        try await answer(ask, "Why is my Mac slow?")
        XCTAssertEqual(ask.exchanges.count, 1, "asked again in its place")
        guard case .answered = ask.exchanges[0].state else { return XCTFail("\(ask.exchanges[0].state)") }
    }

    func testFoundationModelsToolsEndTheAnswerOnceTheQuestionsCallsAreUsedUp() async throws {
        #if canImport(FoundationModels)
        guard #available(macOS 26, *) else { throw XCTSkip("FoundationModels needs macOS 26") }
        let toolbox = AskToolbox(source: FakeAskSource(), redactor: redactor)
        toolbox.begin(1, redactor: redactor)
        let tool = AskModelTool<NoArguments>(tool: .memoryState, tools: toolbox.tools(for: 1))
        for _ in 0..<AskToolbox.budgetedCalls {
            _ = try await tool.call(arguments: NoArguments())
        }
        do {
            let late = try await tool.call(arguments: NoArguments())
            XCTFail("returned \(late)")
        } catch {
            XCTAssertEqual(error as? ExplainError, AskToolbox.exhausted)
            // The session throws it wrapped, and the question fails with the toolbox's reason.
            let failure = AppleIntelligenceProvider.askFailure(LanguageModelSession.ToolCallError(tool: tool, underlyingError: error))
            XCTAssertEqual(failure as? ExplainError, AskToolbox.exhausted)
        }
        toolbox.end()
        let ended = AppleIntelligenceProvider.askFailure(LanguageModelSession.ToolCallError(tool: tool,
                                                                                            underlyingError: CancellationError()))
        XCTAssertTrue(ended is CancellationError, "a question that has ended stays ended: \(ended)")
        let other = AppleIntelligenceProvider.askFailure(LanguageModelSession.ToolCallError(tool: tool,
                                                                                            underlyingError: URLError(.unknown)))
        XCTAssertEqual(other as? ExplainError, .failed("Apple Intelligence could not use System's tools to answer."))
        #else
        throw XCTSkip("Built without FoundationModels")
        #endif
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

    func testAnAnswerLeftWithNothingOnceUnknownIDsAreRemovedIsEmpty() throws {
        let chrome = AskTarget.group(FakeAskSource.chrome)
        let none: (String) -> AskTarget? = { _ in nil }
        XCTAssertThrowsError(try AskAnswer(validating: "[g99]", target: none))
        XCTAssertThrowsError(try AskAnswer(validating: "[g99, x5].", target: none))
        XCTAssertEqual(try AskAnswer(validating: "[g1]", target: { $0 == "g1" ? chrome : nil }).parts,
                       [.citation(id: "g1", target: chrome)])
        XCTAssertEqual(try AskAnswer(validating: "No [g99] 2.", target: none).text, "No 2.")
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

    func testAnAnswerCitingOnlyUnknownIDsFailsAndIsNotCounted() async throws {
        let provider = ScriptedProvider()
        provider.calls = [("memoryState", "{}")]
        provider.answer = "[g99]"
        let (ask, _, _) = center(provider)
        try await answer(ask, "Why?")
        XCTAssertEqual(ask.exchanges.map(\.state), [.failed("The answer was rejected: The answer is empty.")])
        XCTAssertEqual(ask.exchanges.last?.tools.map(\.call), ["memoryState()"], "the tools it called are kept")
        XCTAssertEqual(ask.questionsLeft, 6)
        provider.answer = "Memory is fine."
        try await answer(ask, "Why, again?")
        XCTAssertEqual(ask.exchanges.map(\.question), ["Why, again?"])
        XCTAssertEqual(ask.questionsLeft, 5)
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
        provider.calls = [("memoryState", "{}")]
        let (ask, _, _) = center(provider, timeout: .milliseconds(50))
        XCTAssertTrue(ask.ask("Why?"))
        try await until { !ask.isBusy }
        XCTAssertEqual(ask.exchanges.map(\.state), [.failed("Apple Intelligence did not answer within 0 seconds. Ask again.")])
        XCTAssertEqual(ask.exchanges[0].tools.map(\.call), ["memoryState()"], "the tools it called are kept")
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
    private var storedCalls: [(String, String)] = []
    private var storedAnswer = "An answer."
    private var storedFailure: (any Error)?
    private var storedPrompts: [AskPrompt] = []
    private var storedResults: [String] = []
    /// Holds each answer, after the tool calls, until the test opens it.
    var hold: AnswerGate?

    var calls: [(String, String)] {
        get { lock.withLock { storedCalls } }
        set { lock.withLock { storedCalls = newValue } }
    }
    var answer: String {
        get { lock.withLock { storedAnswer } }
        set { lock.withLock { storedAnswer = newValue } }
    }
    var failure: (any Error)? {
        get { lock.withLock { storedFailure } }
        set { lock.withLock { storedFailure = newValue } }
    }
    var prompts: [AskPrompt] { lock.withLock { storedPrompts } }
    var results: [String] { lock.withLock { storedResults } }

    func availability() async -> AIAvailability { .available }

    func explain(_: ExplainRequest) async throws -> ExplanationDraft {
        throw ExplainError.failed("Not used.")
    }

    func ask(_ prompt: AskPrompt, tools: AskTools, gate _: AskSendGate) async throws -> String {
        lock.withLock { storedPrompts.append(prompt) }
        for (name, arguments) in calls {
            let result = try await tools.call(name, arguments: Data(arguments.utf8))
            lock.withLock { storedResults.append(result) }
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
    /// Lists twenty disk items and twenty suggestions, every text at its cap, groups with long names, and a group's
    /// full facts, as the largest results could be.
    var bulky = false
    static let subgroups = 3
    private static let long = String(repeating: "long text ", count: 40)

    func topGroups(by metric: AskMetric, layer: AttributionLayer, limit: Int, redactor: ExplainRedactor) -> AskOutput {
        ran.append("topGroups \(metric.rawValue) \(layer.rawValue) \(limit)")
        if bulky {
            return AskOutput(["layer": .words(layer.rawValue)], entries: (1...limit).map { number in
                AskEntry(.group(number == 1 ? Self.chrome : OriginGroupID(.app(bundlePath: "/Applications/App\(number).app"))),
                         ["name": .name(String(Self.long.prefix(200))), "memory": .words("1.2 GB"),
                          "launchSource": .words(String(Self.long.prefix(100)))])
            })
        }
        return AskOutput(["layer": .words(layer.rawValue)], entries: [
            AskEntry(.group(Self.chrome), ["name": .name("Google Chrome"), "memory": .words("1.2 GB")]),
            AskEntry(.group(Self.project), ["name": .name("jdoe's project"),
                                            "path": .path(redactor.path("/Users/jdoe/dev/secret-project"))])
        ].prefix(limit).map { $0 })
    }

    func groupDetail(_ group: OriginGroupID, redactor: ExplainRedactor) -> AskOutput? {
        ran.append("groupDetail \(group)")
        guard bulky else { return AskOutput(["name": .name("Google Chrome")]) }
        // A group's facts, about as large as a real group's with long names, members, and evidence, and subgroups.
        var facts = ExplainFacts(kind: .processGroup, name: String(Self.long.prefix(200)))
        facts.type = "App"
        facts.app = facts.name
        facts.bundleID = String(Self.long.prefix(120))
        facts.signingID = String(Self.long.prefix(120))
        facts.vendor = String(Self.long.prefix(120))
        facts.members = (1...10).map { "Helper \($0) " + String(Self.long.prefix(90)) }
        facts.evidence = (1...6).map { _ in ExplainFacts.Evidence(.appBundle, path: "/Applications/Google Chrome.app") }
        let subgroups = (1...Self.subgroups).map { number in
            AskEntry(.group(OriginGroupID(.app(bundlePath: "/Applications/Sub\(number).app"))), ["name": .name("Sub")])
        }
        return AskOutput(["group": .facts(ExplainRequest(facts, redactor: redactor))], entries: subgroups)
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
        if bulky {
            return AskOutput([:], entries: (1...20).map { number in
                let path = "/Volumes/Archive/" + String(repeating: "folder/", count: 30) + "file\(number).mov"
                return AskEntry(.diskItem(path: path), ["path": .path(redactor.path(path)), "name": .name(Self.long),
                                                        "size": .words(Self.long)])
            })
        }
        let path = "/Users/jdoe/Movies/trip.mov"
        return AskOutput([:], entries: [AskEntry(.diskItem(path: path), ["path": .path(redactor.path(path))])])
    }

    func reclaimSuggestions(redactor _: ExplainRedactor) -> AskOutput {
        ran.append("reclaimSuggestions")
        if bulky {
            return AskOutput(["notListed": .count(5)], entries: (1...20).map { number in
                AskEntry(.suggestion("disk-suggestion:rule\(number)::"), [
                    "rule": .words(Self.long), "whatItIs": .words(Self.long), "comesBack": .words(Self.long),
                    "cleanup": .words(Self.long), "itemNames": .names(Array(repeating: Self.long, count: 5))
                ])
            })
        }
        return AskOutput([:], entries: [AskEntry(.suggestion("disk-suggestion:xcodeDerivedData::"),
                                                 ["rule": .words("Xcode DerivedData")])])
    }

    func select(_ target: AskTarget) -> Bool {
        selected.append(target)
        return true
    }
}
