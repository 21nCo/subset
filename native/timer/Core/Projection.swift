import Foundation

/// Computes a timer's state at any moment from its stored timestamps, as `project` in
/// packages/timer/src/engine.ts does, so the app can count down every second without asking the daemon.
public enum Projection {
    public static func project(_ timer: StoredTimer, now: Int) -> TimerProjection {
        let (definition, runtime) = (timer.definition, timer.runtime)
        let totalMs = totalDurationMs(definition, now: now)
        var elapsedMs = runtime.accumulatedMs + runtime.skippedMs
        // A clock that went backward adds nothing rather than going negative.
        if runtime.status == .running, let startedAt = runtime.startedAt { elapsedMs += max(0, now - startedAt) }
        if let totalMs { elapsedMs = min(elapsedMs, totalMs) }
        let finished = runtime.status == .finished || (runtime.status == .running && totalMs != nil && elapsedMs >= totalMs!)
        if finished, let totalMs { elapsedMs = totalMs }
        var projection = TimerProjection(status: finished ? .finished : runtime.status, elapsedMs: elapsedMs, totalMs: totalMs,
                                         remainingMs: totalMs.map { max(0, $0 - elapsedMs) }, finished: finished, step: nil, next: nil)
        if definition.kind == .interval, !finished {
            let index = stepIndex(definition, at: elapsedMs)
            var step = intervalStep(definition, index: index)
            step.elapsedMs = elapsedMs - step.startMs
            step.remainingMs = step.startMs + step.durationMs - elapsedMs
            projection.step = step
            projection.next = index + 1 < stepCount(definition) ? intervalStep(definition, index: index + 1) : nil
        }
        return projection
    }

    /// The timer's length, or nil for a stopwatch. An `until` countdown that has not started counts down to its
    /// target time from `now`.
    public static func totalDurationMs(_ definition: TimerDefinition, now: Int) -> Int? {
        switch definition.kind {
        case .stopwatch:
            return nil
        case .countdown:
            if let durationMs = definition.durationMs { return durationMs }
            guard let until = definition.until.flatMap(epochMilliseconds) else { return 0 }
            return max(0, until - now)
        case .interval:
            return (definition.prepMs ?? 0) + (definition.rounds ?? 0) * cycleMs(definition) + (definition.cooldownMs ?? 0)
        }
    }

    /// Epoch milliseconds for an ISO 8601 time with an offset, with or without fractional seconds.
    public static func epochMilliseconds(_ iso: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        for options: ISO8601DateFormatter.Options in [[.withInternetDateTime], [.withInternetDateTime, .withFractionalSeconds]] {
            formatter.formatOptions = options
            if let date = formatter.date(from: iso) { return Int((date.timeIntervalSince1970 * 1000).rounded()) }
        }
        return nil
    }

    private static func segments(_ definition: TimerDefinition) -> [Segment] { definition.segments ?? [] }

    private static func cycleMs(_ definition: TimerDefinition) -> Int { segments(definition).reduce(0) { $0 + $1.durationMs } }

    static func stepCount(_ definition: TimerDefinition) -> Int {
        (definition.prepMs ?? 0 > 0 ? 1 : 0) + (definition.rounds ?? 0) * segments(definition).count + (definition.cooldownMs ?? 0 > 0 ? 1 : 0)
    }

    static func intervalStep(_ definition: TimerDefinition, index: Int) -> IntervalStep {
        let prep = definition.prepMs ?? 0
        if prep > 0, index == 0 {
            return IntervalStep(index: 0, segmentIndex: nil, round: nil, phase: .prep, label: "Prep", startMs: 0, durationMs: prep)
        }
        let list = segments(definition)
        let rounds = definition.rounds ?? 0
        let inRounds = index - (prep > 0 ? 1 : 0)
        if inRounds < rounds * list.count {
            let round = inRounds / list.count
            let segmentIndex = inRounds % list.count
            let startMs = prep + round * cycleMs(definition) + list[..<segmentIndex].reduce(0) { $0 + $1.durationMs }
            let segment = list[segmentIndex]
            return IntervalStep(index: index, segmentIndex: segmentIndex, round: round + 1, phase: segment.phase, label: segment.label,
                                startMs: startMs, durationMs: segment.durationMs)
        }
        return IntervalStep(index: index, segmentIndex: nil, round: nil, phase: .cooldown, label: "Cooldown",
                            startMs: prep + rounds * cycleMs(definition), durationMs: definition.cooldownMs ?? 0)
    }

    /// The step containing `position`; the step count at or past the end.
    static func stepIndex(_ definition: TimerDefinition, at position: Int) -> Int {
        let prep = definition.prepMs ?? 0
        let prepSteps = prep > 0 ? 1 : 0
        if position < prep { return 0 }
        let list = segments(definition)
        let rounds = definition.rounds ?? 0
        let cycle = cycleMs(definition)
        guard cycle > 0 else { return stepCount(definition) }
        let round = (position - prep) / cycle
        if round >= rounds {
            let end = prep + rounds * cycle + (definition.cooldownMs ?? 0)
            return position < end ? prepSteps + rounds * list.count : stepCount(definition)
        }
        var offset = position - prep - round * cycle
        var segmentIndex = 0
        while offset >= list[segmentIndex].durationMs {
            offset -= list[segmentIndex].durationMs
            segmentIndex += 1
        }
        return prepSteps + round * list.count + segmentIndex
    }
}

/// Text the menu shows, matching `formatDuration` and `timerLine` in packages/timer/src/agent.ts.
public enum TimerFormat {
    public enum Rounding { case up, down }

    /// `m:ss`, or `h:mm:ss` from an hour. Time left rounds up, so a countdown shows 0:01 until it ends; time
    /// elapsed rounds down.
    public static func duration(_ ms: Int, rounding: Rounding) -> String {
        let seconds = max(0, rounding == .up ? (ms + 999).floorDiv(1000) : ms.floorDiv(1000))
        let (hours, minutes) = (seconds / 3600, seconds % 3600 / 60)
        let rest = String(format: "%02d", seconds % 60)
        return hours > 0 ? "\(hours):\(String(format: "%02d", minutes)):\(rest)" : "\(minutes):\(rest)"
    }

    /// The timer's state at `now`, for example `running · round 3/8 · work · 0:12 left · next rest 0:10`.
    public static func state(_ timer: StoredTimer, now: Int) -> String {
        let (definition, runtime) = (timer.definition, timer.runtime)
        let projection = Projection.project(timer, now: now)
        var parts = [projection.status.rawValue]
        let active = projection.status == .running || projection.status == .paused
        if definition.kind == .stopwatch {
            if projection.status != .idle { parts.append("\(duration(projection.elapsedMs, rounding: .down)) elapsed") }
        } else if !active {
            parts.append("\(duration(projection.totalMs ?? 0, rounding: .up)) total")
        } else if definition.kind == .interval, let step = projection.step {
            let rounds = definition.rounds ?? 0
            let segments = definition.segments?.count ?? 0
            if let round = step.round, rounds > 1 {
                parts.append("round \(round)/\(rounds)")
            } else if let segmentIndex = step.segmentIndex, segments > 1 {
                parts.append("segment \(segmentIndex + 1)/\(segments)")
            }
            parts += [stepName(step), "\(duration(step.remainingMs ?? 0, rounding: .up)) left"]
            if let next = projection.next { parts.append("next \(stepName(next)) \(duration(next.durationMs, rounding: .up))") }
        } else {
            parts.append("\(duration(projection.remainingMs ?? 0, rounding: .up)) left")
        }
        let laps = runtime.laps.count
        if laps > 0 { parts.append("\(laps) lap\(laps == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    /// One line as the CLI and agents show it: `Name (id): state`.
    public static func line(_ timer: StoredTimer, now: Int) -> String {
        "\(timer.definition.name) (\(timer.definition.id)): \(state(timer, now: now))"
    }

    private static func stepName(_ step: IntervalStep) -> String {
        step.label.lowercased() == step.phase.rawValue ? step.phase.rawValue : "\(step.phase.rawValue) (\(step.label))"
    }

    /// The running timer that ends soonest and its time left, which the status item shows. Stopwatches never
    /// end; on a tie the earlier timer wins.
    public static func soonest(_ timers: [StoredTimer], now: Int) -> (timer: StoredTimer, remainingMs: Int)? {
        var best: (timer: StoredTimer, remainingMs: Int)?
        for timer in timers {
            let projection = Projection.project(timer, now: now)
            guard projection.status == .running, let remaining = projection.remainingMs else { continue }
            if best == nil || remaining < best!.remainingMs { best = (timer, remaining) }
        }
        return best
    }
}

private extension Int {
    func floorDiv(_ divisor: Int) -> Int {
        let quotient = self / divisor
        return self % divisor != 0 && (self < 0) != (divisor < 0) ? quotient - 1 : quotient
    }
}
