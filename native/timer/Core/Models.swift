import Foundation

// The app's view of the @subset/timer contract, schema version 1 (packages/timer/src/model.ts, agent.ts and
// operations.ts). Times are wall-clock epoch milliseconds. The daemon validates every input and owns every
// change; these types only carry what it sends and receives.

public let supportedSchemaVersion = 1

public enum TimerKind: String, Codable, Sendable {
    case countdown, stopwatch, interval
}

public enum Phase: String, Codable, Sendable {
    case prep, work, rest, cooldown
}

public enum TimerStatus: String, Codable, Sendable {
    case idle, running, paused, finished
}

public struct Segment: Codable, Equatable, Sendable {
    public var label: String
    public var phase: Phase
    public var durationMs: Int

    public init(label: String, phase: Phase, durationMs: Int) {
        self.label = label
        self.phase = phase
        self.durationMs = durationMs
    }
}

/// One of the three kinds, flattened: the fields of the other kinds are nil.
public struct TimerDefinition: Codable, Equatable, Sendable {
    public var kind: TimerKind
    public var id: String
    public var name: String
    public var sound: Bool
    public var countdownTicks: Bool
    public var createdAt: Int
    // Countdown. `durationMs` is nil only for an `until` countdown that has not started.
    public var durationMs: Int?
    public var until: String?
    public var lapsEnabled: Bool?
    // Interval.
    public var segments: [Segment]?
    public var rounds: Int?
    public var prepMs: Int?
    public var cooldownMs: Int?

    /// Stopwatches and countdowns with laps enabled take laps.
    public var takesLaps: Bool { kind == .stopwatch || (kind == .countdown && lapsEnabled == true) }
}

public struct Lap: Codable, Equatable, Sendable {
    public var elapsedMs: Int
    public var at: Int
}

public struct TimerRuntime: Codable, Equatable, Sendable {
    public var status: TimerStatus
    public var startedAt: Int?
    public var accumulatedMs: Int
    public var pausedAt: Int?
    public var laps: [Lap]
    public var skippedMs: Int
}

/// A timer as the daemon stores it.
public struct StoredTimer: Codable, Equatable, Sendable {
    public var definition: TimerDefinition
    public var runtime: TimerRuntime
}

/// An interval step; `elapsedMs` and `remainingMs` are set only for the current step.
public struct IntervalStep: Codable, Equatable, Sendable {
    public var index: Int
    public var segmentIndex: Int?
    public var round: Int?
    public var phase: Phase
    public var label: String
    public var startMs: Int
    public var durationMs: Int
    public var elapsedMs: Int?
    public var remainingMs: Int?
}

public struct TimerProjection: Codable, Equatable, Sendable {
    public var status: TimerStatus
    public var elapsedMs: Int
    public var totalMs: Int?
    public var remainingMs: Int?
    public var finished: Bool
    public var step: IntervalStep?
    public var next: IntervalStep?
}

public struct TimerSnapshot: Codable, Equatable, Sendable {
    public var definition: TimerDefinition
    public var runtime: TimerRuntime
    /// Computed at the board's `observedAt`; the app re-projects from `definition` and `runtime`.
    public var projection: TimerProjection

    public var stored: StoredTimer { StoredTimer(definition: definition, runtime: runtime) }
}

/// The `list` result and the agent result's `structuredContent`.
public struct TimerBoard: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var observedAt: Int
    public var timers: [TimerSnapshot]
}

/// What `GET /v1/timers` and each `state` event carry.
public struct AgentTimerResult: Codable, Equatable, Sendable {
    public var structuredContent: TimerBoard
    public var text: String
    public var viewId: String
}

/// The result of `create`, `start`, `pause`, `resume`, `lap`, `skip`, `reset` and `get`.
public struct TimerResult: Codable, Equatable, Sendable {
    public var timer: TimerSnapshot
    public var observedAt: Int
}

/// The result of `remove` (with `observedAt`) and `presets.remove`.
public struct RemovedResult: Codable, Equatable, Sendable {
    public var removedId: String
    public var observedAt: Int?
}

/// What a caller supplies to create a timer, and what a preset holds. Nil fields are left out of the JSON.
public struct TimerSpec: Codable, Equatable, Sendable {
    public var kind: TimerKind
    public var name: String?
    public var sound: Bool?
    public var countdownTicks: Bool?
    public var durationMs: Int?
    public var until: String?
    public var lapsEnabled: Bool?
    public var segments: [Segment]?
    public var rounds: Int?
    public var prepMs: Int?
    public var cooldownMs: Int?

    public init(kind: TimerKind, name: String? = nil, sound: Bool? = nil, countdownTicks: Bool? = nil, durationMs: Int? = nil,
                until: String? = nil, lapsEnabled: Bool? = nil, segments: [Segment]? = nil, rounds: Int? = nil,
                prepMs: Int? = nil, cooldownMs: Int? = nil) {
        self.kind = kind
        self.name = name
        self.sound = sound
        self.countdownTicks = countdownTicks
        self.durationMs = durationMs
        self.until = until
        self.lapsEnabled = lapsEnabled
        self.segments = segments
        self.rounds = rounds
        self.prepMs = prepMs
        self.cooldownMs = cooldownMs
    }

    public static func countdown(durationMs: Int, name: String? = nil) -> TimerSpec {
        TimerSpec(kind: .countdown, name: name, durationMs: durationMs)
    }
}

public struct Preset: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var builtIn: Bool
    public var timer: TimerSpec
}

public struct PresetList: Codable, Equatable, Sendable {
    public var presets: [Preset]
}

public struct SavedPreset: Codable, Equatable, Sendable {
    public var preset: Preset
}

/// The daemon's `state.json`.
public struct TimerStore: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var idSequence: Int
    public var timers: [StoredTimer]
    public var presets: [Preset]
}

/// An operation's input. Each operation reads only its own fields and the daemon rejects any other.
public struct OperationInput: Codable, Equatable, Sendable {
    public var id: String?
    public var timer: TimerSpec?
    public var preset: String?
    public var name: String?

    public init(id: String? = nil, timer: TimerSpec? = nil, preset: String? = nil, name: String? = nil) {
        self.id = id
        self.timer = timer
        self.preset = preset
        self.name = name
    }
}

public struct TimerError: Codable, Equatable, Sendable {
    public struct Issue: Codable, Equatable, Sendable {
        public var path: String
        public var message: String
    }

    public var code: String
    public var message: String
    public var issues: [Issue]?
}

/// The body of every error reply.
public struct ErrorReply: Codable, Equatable, Sendable {
    public var error: TimerError
}

/// `GET /v1/daemon`.
public struct DaemonInfo: Codable, Equatable, Sendable {
    public var pid: Int
    public var dataDir: String
    public var socket: String
    public var alerts: String
    public var startedAt: Int
}
