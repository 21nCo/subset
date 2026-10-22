import Foundation
import Testing
// A plain import, as an app sees TimerCore: these tests only compile against its public API.
import TimerCore

@Test func anAppBuildsACustomIntervalTimer() throws {
    let spec = TimerSpec(kind: .interval, name: "Tabata", segments: [
        Segment(label: "Work", phase: .work, durationMs: 20_000),
        Segment(label: "Rest", phase: .rest, durationMs: 10_000)
    ], rounds: 8, prepMs: 10_000)
    let input = OperationInput(timer: spec)
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(input)) as? [String: Any]
    let timer = try #require(json?["timer"] as? [String: Any])
    // Nil fields stay out of the JSON, as the daemon's schema expects.
    #expect(Set(timer.keys) == ["kind", "name", "segments", "rounds", "prepMs"])
    #expect(try JSONDecoder().decode(OperationInput.self, from: JSONEncoder().encode(input)) == input)
    #expect(TimerSpec(kind: .countdown, durationMs: 60_000) == .countdown(durationMs: 60_000))
}
