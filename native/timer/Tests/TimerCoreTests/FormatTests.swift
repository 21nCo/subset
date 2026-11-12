import Foundation
import Testing
@testable import TimerCore

private func countdown(_ id: String, durationMs: Int, status: TimerStatus, startedAt: Int? = nil, accumulatedMs: Int = 0) -> StoredTimer {
    StoredTimer(definition: TimerDefinition(kind: .countdown, id: id, name: id, sound: true, countdownTicks: false, createdAt: 0,
                                            durationMs: durationMs, lapsEnabled: false),
                runtime: TimerRuntime(status: status, startedAt: startedAt, accumulatedMs: accumulatedMs, laps: [], skippedMs: 0))
}

@Test func timeLeftRoundsUpAndElapsedRoundsDown() {
    #expect(TimerFormat.duration(0, rounding: .up) == "0:00")
    #expect(TimerFormat.duration(1, rounding: .up) == "0:01")
    #expect(TimerFormat.duration(1_999, rounding: .down) == "0:01")
    #expect(TimerFormat.duration(59_001, rounding: .up) == "1:00")
    #expect(TimerFormat.duration(3_599_000, rounding: .up) == "59:59")
    #expect(TimerFormat.duration(3_600_000, rounding: .up) == "1:00:00")
    #expect(TimerFormat.duration(86_400_000, rounding: .down) == "24:00:00")
    #expect(TimerFormat.duration(-5_000, rounding: .up) == "0:00")
}

@Test func timeLeftFollowsTheClockFromTimestamps() {
    let timer = countdown("t_eggs0000", durationMs: 360_000, status: .running, startedAt: 1_000_000)
    #expect(TimerFormat.state(timer, now: 1_000_000) == "running · 6:00 left")
    #expect(TimerFormat.state(timer, now: 1_000_000 + 1) == "running · 6:00 left")
    #expect(TimerFormat.state(timer, now: 1_000_000 + 1_000) == "running · 5:59 left")
    #expect(TimerFormat.state(timer, now: 1_000_000 + 359_999) == "running · 0:01 left")
    // A running timer whose time is up shows as finished before the daemon records it.
    #expect(TimerFormat.state(timer, now: 1_000_000 + 360_000) == "finished · 6:00 total")
    // A clock that went backward adds nothing.
    #expect(TimerFormat.state(timer, now: 900_000) == "running · 6:00 left")
}

private func interval(_ id: String, name: String, rounds: Int, prepMs: Int? = nil, segments: [(String, Phase, Int)], status: TimerStatus,
                      startedAt: Int? = nil, accumulatedMs: Int = 0) -> StoredTimer {
    StoredTimer(definition: TimerDefinition(kind: .interval, id: id, name: name, sound: true, countdownTicks: false, createdAt: 0,
                                            segments: segments.map { Segment(label: $0.0, phase: $0.1, durationMs: $0.2) },
                                            rounds: rounds, prepMs: prepMs),
                runtime: TimerRuntime(status: status, startedAt: startedAt, accumulatedMs: accumulatedMs, laps: [], skippedMs: 0))
}

// The same lines as packages/timer/test/agent.test.mjs ("a labelled step leads with its label, then its position").
@Test func aLabelledStepLeadsWithItsLabelThenItsPosition() {
    let start = 1_000_000
    let segments: [(String, Phase, Int)] = [("Squats", .work, 40_000), ("Rest", .rest, 20_000), ("Lunges", .work, 40_000),
                                            ("Rest", .rest, 20_000), ("Plank: hold", .work, 30_000)]
    let hiit = interval("t_hiit0000", name: "HIIT", rounds: 1, prepMs: 10_000, segments: segments, status: .running, startedAt: start)
    #expect(TimerFormat.line(hiit, now: start + 4_000) == "HIIT (t_hiit0000): running · prep · 0:06 left · next Squats 0:40")
    #expect(TimerFormat.line(hiit, now: start + 38_000) == "HIIT (t_hiit0000): running · Squats · step 1/5 · 0:12 left · next rest 0:20")
    #expect(TimerFormat.line(hiit, now: start + 55_000) == "HIIT (t_hiit0000): running · rest · step 2/5 · 0:15 left · next Lunges 0:40")
    #expect(TimerFormat.line(hiit, now: start + 151_000) == "HIIT (t_hiit0000): running · Plank: hold · step 5/5 · 0:09 left")
    let paused = interval("t_hiit0000", name: "HIIT", rounds: 1, prepMs: 10_000, segments: segments, status: .paused, accumulatedMs: 38_000)
    #expect(TimerFormat.line(paused, now: start + 900_000) == "HIIT (t_hiit0000): paused · Squats · step 1/5 · 0:12 left · next rest 0:20")
    // Several rounds count rounds; a label that only repeats the phase shows the phase.
    let legs = interval("t_legs0000", name: "Legs", rounds: 2, segments: [("Squats", .work, 40_000), ("REST", .rest, 20_000)],
                        status: .running, startedAt: start)
    #expect(TimerFormat.line(legs, now: start + 70_000) == "Legs (t_legs0000): running · Squats · round 2/2 · 0:30 left · next rest 0:20")
    #expect(TimerFormat.line(legs, now: start + 45_000) == "Legs (t_legs0000): running · rest · round 1/2 · 0:15 left · next Squats 0:40")
}

@Test func statusItemShowsTheRunningTimerThatEndsSoonest() {
    let now = 10_000_000
    let long = countdown("t_long0000", durationMs: 600_000, status: .running, startedAt: now - 1_000)
    let short = countdown("t_shrt0000", durationMs: 120_000, status: .running, startedAt: now - 30_000)
    let paused = countdown("t_paus0000", durationMs: 60_000, status: .paused, accumulatedMs: 50_000)
    let done = countdown("t_done0000", durationMs: 1_000, status: .running, startedAt: now - 5_000)
    let stopwatch = StoredTimer(definition: TimerDefinition(kind: .stopwatch, id: "t_stop0000", name: "Run", sound: true, countdownTicks: false, createdAt: 0),
                                runtime: TimerRuntime(status: .running, startedAt: now - 1, accumulatedMs: 0, laps: [], skippedMs: 0))
    let soonest = TimerFormat.soonest([stopwatch, long, paused, done, short], now: now)
    #expect(soonest?.timer.definition.id == "t_shrt0000")
    #expect(soonest.map { TimerFormat.duration($0.remainingMs, rounding: .up) } == "1:30")
    #expect(TimerFormat.soonest([stopwatch, paused, done], now: now) == nil)
}

@Test func countdownDurationsParseLikeTheCLI() {
    for (text, ms) in [("90s", 90_000), ("25m", 1_500_000), ("1h30m", 5_400_000), ("1H0M30S", 3_630_000), ("1:30", 90_000), (" 1:02:03 ", 3_723_000), ("24h", 86_400_000), ("1s", 1_000)] {
        #expect(DurationParser.parse(text) == .success(ms), "\(text)")
    }
    #expect(DurationParser.parse("5") == .failure(DurationError(message: "\u{201C}5\u{201D} is not a duration such as 90s, 25m, 1h30m or 1:30. Add a unit, for example 5s or 5m.")))
    #expect(DurationParser.parse("24h1s") == .failure(DurationError(message: "\u{201C}24h1s\u{201D} must be from 1 second to 24 hours.")))
    for text in ["", "0s", "1:60", "m", "1m1h", "-5m", "1.5m"] {
        guard case .failure = DurationParser.parse(text) else { Issue.record("\(text) parsed"); continue }
    }
    // The CLI reads ASCII digits only: other scripts' digits fail the same way instead of trapping or counting.
    for text in ["\u{661}:30", "1:\u{663}0", "1:3\u{660}", "\u{FF11}:02:03", "1:02:0\u{FF13}", "1h\u{663}m", "\u{665}m30s", "\u{FF15}", "1\u{17F}"] {
        #expect(DurationParser.parse(text) == .failure(DurationError(message: "\u{201C}\(text)\u{201D} is not a duration such as 90s, 25m, 1h30m or 1:30.")), "\(text)")
    }
    // Trimmed as JavaScript's trim, which takes a byte order mark and leaves U+0085 in place.
    for (text, ms) in [("\u{FEFF}90s", 90_000), ("\u{3000}25m\u{2028}", 1_500_000), ("\u{0B}1:30\u{0C}", 90_000)] {
        #expect(DurationParser.parse(text) == .success(ms), "\(text.unicodeScalars.map(\.value))")
    }
    #expect(DurationParser.parse("\u{85}90s") == .failure(DurationError(message: "\u{201C}\u{85}90s\u{201D} is not a duration such as 90s, 25m, 1h30m or 1:30.")))
}
