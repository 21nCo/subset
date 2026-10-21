import Foundation
import Testing
@testable import TimerCore

/// packages/timer/fixtures/contract-v1, the shared fixtures every Timer host reads.
private let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("../../packages/timer/fixtures/contract-v1").standardized

private func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: fixtures.appendingPathComponent(name))
}

/// JSON text with sorted keys and without null members, which the contract and Swift's encoder write differently.
private func object(_ value: Any) throws -> Data {
    func strip(_ value: Any) -> Any {
        if let dictionary = value as? [String: Any] { return dictionary.filter { !($0.value is NSNull) }.mapValues(strip) }
        if let array = value as? [Any] { return array.map(strip) }
        return value
    }
    return try JSONSerialization.data(withJSONObject: strip(value), options: [.sortedKeys, .fragmentsAllowed])
}

/// The JSON `value` as `T`, re-encoded, equals `value`: decoding dropped and invented nothing.
private func roundTrips<T: Codable>(_ type: T.Type, _ value: Any) throws -> Bool {
    let decoded = try JSONDecoder().decode(T.self, from: try object(value))
    let encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(decoded))
    return try object(encoded) == object(value)
}

@Test func everyContractFixtureDecodes() throws {
    #expect(try FileManager.default.contentsOfDirectory(atPath: fixtures.path).sorted() ==
        ["agent-result.json", "inputs.json", "operations.json", "store.json", "view-props.json"])

    let store = try JSONDecoder().decode(TimerStore.self, from: fixture("store.json"))
    #expect(store.schemaVersion == supportedSchemaVersion)
    #expect(try roundTrips(TimerStore.self, JSONSerialization.jsonObject(with: fixture("store.json"))))

    let agent = try JSONDecoder().decode(AgentTimerResult.self, from: fixture("agent-result.json"))
    #expect(agent.viewId == "subset.timer.board@1")
    #expect(agent.structuredContent.timers.map(\.definition.id) == store.timers.map(\.definition.id))
    #expect(try roundTrips(AgentTimerResult.self, JSONSerialization.jsonObject(with: fixture("agent-result.json"))))
    #expect(try DaemonClient.board(from: fixture("agent-result.json")) == agent.structuredContent)

    let viewProps = try JSONSerialization.jsonObject(with: fixture("view-props.json")) as! [String: Any]
    #expect(try roundTrips(TimerBoard.self, viewProps["result"]!))

    // Each operation's result or error decodes as the type the client reads it as.
    let operations = try JSONSerialization.jsonObject(with: fixture("operations.json")) as! [String: Any]
    let cases = operations["cases"] as! [[String: Any]]
    var seen = Set<String>()
    for testCase in cases {
        let name = testCase["operation"] as! String
        seen.insert(name)
        if let error = testCase["error"] {
            #expect(try roundTrips(TimerError.self, error), "\(testCase["name"]!)")
            continue
        }
        let result = testCase["result"]!
        let ok: Bool = switch name {
        case "list": try roundTrips(TimerBoard.self, result)
        case "remove", "presets.remove": try roundTrips(RemovedResult.self, result)
        case "presets.list": try roundTrips(PresetList.self, result)
        case "presets.save": try roundTrips(SavedPreset.self, result)
        default: try roundTrips(TimerResult.self, result)
        }
        #expect(ok, "\(testCase["name"]!)")
        #expect(try roundTrips(OperationInput.self, testCase["input"]!), "\(testCase["name"]!) input")
    }
    #expect(seen.count == 13)

    // The valid inputs survive the app's encoding unchanged.
    let inputs = try JSONSerialization.jsonObject(with: fixture("inputs.json")) as! [String: Any]
    for entry in inputs["valid"] as! [[String: Any]] {
        #expect(try roundTrips(OperationInput.self, entry["input"]!), "\(entry)")
    }
    #expect((inputs["invalid"] as! [Any]).count > 0)
}

@Test func errorRepliesBecomeDaemonErrors() throws {
    let body = Data(#"{"error":{"code":"invalid_state","message":"Timer t_dk1facen is paused; only a running timer can pause."}}"#.utf8)
    #expect(throws: DaemonError.rejected(status: 409, TimerError(code: "invalid_state", message: "Timer t_dk1facen is paused; only a running timer can pause.", issues: nil))) {
        try DaemonClient.decode(TimerResult.self, status: 409, body: body)
    }
    let shutting = Data(#"{"error":{"code":"daemon_unavailable","message":"The daemon is shutting down."}}"#.utf8)
    #expect(throws: DaemonError.shuttingDown) { try DaemonClient.decode(TimerResult.self, status: 503, body: shutting) }
    #expect(throws: DaemonError.malformedReply("HTTP 500")) { try DaemonClient.decode(TimerResult.self, status: 500, body: Data("oops".utf8)) }
    let future = Data(#"{"structuredContent":{"schemaVersion":2,"observedAt":0,"timers":[]},"text":"","viewId":"subset.timer.board@2"}"#.utf8)
    #expect(throws: DaemonError.unsupportedSchema(2)) { try DaemonClient.board(from: future) }
}

@Test func projectionAndLinesMatchTheContract() throws {
    // Every snapshot in the fixtures was projected by the TypeScript engine at its observedAt.
    let agent = try JSONDecoder().decode(AgentTimerResult.self, from: fixture("agent-result.json"))
    let now = agent.structuredContent.observedAt
    for snapshot in agent.structuredContent.timers {
        #expect(Projection.project(snapshot.stored, now: now) == snapshot.projection, "\(snapshot.definition.name)")
    }
    #expect(agent.structuredContent.timers.map { TimerFormat.line($0.stored, now: now) }.joined(separator: "\n") == agent.text)

    let operations = try JSONDecoder().decode(OperationCases.self, from: fixture("operations.json"))
    var checked = 0
    for testCase in operations.cases {
        guard let result = testCase.result else { continue }
        for snapshot in (result.timer.map { [$0] } ?? []) + (result.timers ?? []) {
            #expect(Projection.project(snapshot.stored, now: testCase.now) == snapshot.projection, "\(testCase.name)")
            checked += 1
        }
    }
    #expect(checked >= 18)
}

private struct OperationCases: Decodable {
    struct Case: Decodable {
        struct Result: Decodable {
            var timer: TimerSnapshot?
            var timers: [TimerSnapshot]?
        }

        var name: String
        var now: Int
        var result: Result?
    }

    var cases: [Case]
}

@Test func untilCountdownCountsDownToItsTarget() {
    let definition = TimerDefinition(kind: .countdown, id: "t_00000000", name: "Train", sound: true, countdownTicks: false, createdAt: 0,
                                     until: "2026-10-19T17:30:00+02:00", lapsEnabled: false)
    let idle = StoredTimer(definition: definition, runtime: TimerRuntime(status: .idle, accumulatedMs: 0, laps: [], skippedMs: 0))
    let target = Projection.epochMilliseconds("2026-10-19T15:30:00.000Z")!
    #expect(Projection.project(idle, now: target - 90_000).remainingMs == 90_000)
    #expect(Projection.project(idle, now: target + 5).remainingMs == 0)
}
