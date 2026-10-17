import Foundation

/// What capture is doing. `CaptureSession` checks these in order of precedence, from the store down to idle.
public enum CaptureState: Equatable, Sendable {
    /// The store could not be opened, or the latest end of what it holds has not been read yet.
    case storeUnavailable
    case off, paused
    /// Writes keep failing and the queue has no room for more capture.
    case writesBacklogged
    /// The clock is earlier than activity already recorded; recording resumes once it passes it, or after Delete All.
    case clockBehind
    case asleep, locked, inactiveSession
    /// Tracking, but nothing is recorded because there was no input for `CaptureSession.idleThreshold`.
    case idle
    case recording

    /// A user choice or system state during which input-free time is not the user being idle.
    var interruptsTracking: Bool {
        switch self {
        case .storeUnavailable, .off, .paused, .asleep, .locked, .inactiveSession: true
        case .writesBacklogged, .clockBehind, .idle, .recording: false
        }
    }
}

/// What the host observed when it sampled.
public struct CaptureConditions: Equatable, Sendable {
    public var trackingOn: Bool
    public var paused: Bool
    public var asleep: Bool
    public var locked: Bool
    public var sessionInactive: Bool
    /// Seconds since the last keyboard or mouse input.
    public var secondsSinceInput: TimeInterval

    public init(trackingOn: Bool = true, paused: Bool = false, asleep: Bool = false, locked: Bool = false,
                sessionInactive: Bool = false, secondsSinceInput: TimeInterval = 0) {
        self.trackingOn = trackingOn
        self.paused = paused
        self.asleep = asleep
        self.locked = locked
        self.sessionInactive = sessionInactive
        self.secondsSinceInput = secondsSinceInput
    }
}

/// Capture's state, recorder, and write queue, kept together so the rules between them hold in one place:
/// - Tracking (recording or idle) holds only while the store's latest end has been read, the user's choices allow it,
///   the queue accepts capture, and the clock is not behind recorded activity. Otherwise capture stops in a named state,
///   and a save that leaves the queue without room stops it at once, while the open segment's closing save still fits.
///   Capture therefore never makes a save the queue refuses, and the queue holds at most `capacity` writes plus one for
///   each Delete Today requested while capture is stopped. Tracking off and pause outrank the store and the clock.
/// - Idle retraction never reaches before the moment tracking last resumed after the store was read, tracking off, a
///   pause, sleep, lock, or a session switch. A backlog or a clock behind recorded activity does not move it, so
///   input-free time recorded before them is still removed.
/// - The latest stored end, read before the first sample, seeds both the recorder floor and the queue's compaction
///   bound, so nothing recorded after a relaunch with an earlier clock overlaps what is stored. Delete All resets the
///   floor to the time it was requested.
public struct CaptureSession {
    public static let idleThreshold: TimeInterval = 120
    public static let flushInterval: TimeInterval = 60

    public private(set) var state: CaptureState = .off
    public private(set) var writes: PendingWrites
    /// Why the latest stored end could not be read; nothing is recorded until it can.
    public private(set) var readError: String?
    private var sequencer: CaptureSequencer
    private let storage: CaptureStorage?
    private var seeded = false
    /// When tracking last resumed after an interruption; idle retraction never reaches before it.
    private var recordingSince = Date.distantPast
    private var lastFlush = Date.distantPast

    public init(storage: CaptureStorage?, maxSampleInterval: TimeInterval, writes: PendingWrites = PendingWrites()) {
        self.storage = storage
        self.writes = writes
        sequencer = CaptureSequencer(recorder: SegmentRecorder(maxSampleInterval: maxSampleInterval))
    }

    public var open: Segment? { sequencer.open }

    /// Retries queued writes and decides the state from `conditions` at `now`. Stopping ends the open segment; becoming
    /// idle ends it when input stopped and retracts what was stored since.
    public mutating func update(_ conditions: CaptureConditions, at now: Date) {
        if let storage, !writes.isEmpty { writes.retry(storage) }
        seed()
        let previous = state
        state = decide(conditions, at: now)
        if previous.interruptsTracking, !state.interruptsTracking { recordingSince = now }
        switch state {
        case .recording: break
        case .idle:
            guard previous != .idle else { break }
            let idleStart = max(now.addingTimeInterval(-conditions.secondsSinceInput), recordingSince)
            if let segment = sequencer.gap(at: idleStart) { save(segment) }
            if let storage { writes.retract(since: idleStart, until: now, in: storage) }
            stopWithoutRoom(at: now)
        default:
            if sequencer.open != nil { stop(at: now) }
        }
    }

    /// Records the content in front at `date` (nil records nothing), while recording.
    public mutating func sample(_ content: Segment?, at date: Date) {
        guard state == .recording else { return }
        apply(sequencer.sample(content, at: date), at: date)
    }

    /// Another app came to the front: the open segment ends and reads in flight are void.
    public mutating func foregroundChanged(at date: Date) {
        apply(sequencer.foregroundChanged(at: date), at: date)
    }

    /// See `CaptureSequencer.beginRead`; nil unless recording.
    public mutating func beginRead(of pid: Int32, at date: Date) -> CaptureSequencer.Ticket? {
        state == .recording ? sequencer.beginRead(of: pid, at: date) : nil
    }

    public func isCurrent(_ ticket: CaptureSequencer.Ticket) -> Bool { sequencer.isCurrent(ticket) }

    /// Applies a finished read while recording; otherwise drops it.
    public mutating func complete(_ ticket: CaptureSequencer.Ticket, with content: Segment?) {
        guard state == .recording else {
            sequencer.discard(ticket)
            return
        }
        apply(sequencer.complete(ticket, with: content), at: ticket.date)
    }

    public mutating func discard(_ ticket: CaptureSequencer.Ticket) { sequencer.discard(ticket) }

    /// Ends and saves the open segment, for example when a control changes.
    public mutating func endSegment(at date: Date) {
        stop(at: date)
        stopWithoutRoom(at: date)
    }

    /// Deletes the day containing `now`, up to `now`, or all captured activity, after ending the open segment so it
    /// cannot be written back. A deletion that fails stays queued and is retried.
    public mutating func delete(all: Bool, at now: Date, calendar: Calendar) {
        stop(at: now)
        guard let storage else { return }
        if all {
            writes.deleteAll(in: storage)
            sequencer.setFloor(now)
        } else {
            writes.deleteDay(containing: now, calendar: calendar, in: storage)
        }
        stopWithoutRoom(at: now)
    }

    /// Before quitting: ends the open segment and applies every queued write that storage accepts.
    public mutating func finish(at now: Date) {
        stop(at: now)
        if let storage, !writes.isEmpty { writes.drain(storage) }
    }

    private func decide(_ conditions: CaptureConditions, at now: Date) -> CaptureState {
        if storage == nil || !seeded { return .storeUnavailable }
        if !conditions.trackingOn { return .off }
        if conditions.paused { return .paused }
        if !writes.acceptsCapture { return .writesBacklogged }
        if now < sequencer.recordedThrough { return .clockBehind }
        if conditions.asleep { return .asleep }
        if conditions.locked { return .locked }
        if conditions.sessionInactive { return .inactiveSession }
        return conditions.secondsSinceInput >= Self.idleThreshold ? .idle : .recording
    }

    /// Reads the latest stored end until a read succeeds; it bounds both the recorder and the queue's compaction.
    private mutating func seed() {
        guard !seeded, let storage else { return }
        do {
            let end = try writes.readStoredEnd(from: storage) ?? .distantPast
            sequencer.setFloor(max(end, sequencer.recordedThrough))
            seeded = true
            readError = nil
        } catch {
            readError = String(describing: error)
        }
    }

    /// Saves segments that closed and, at most once a minute, the open one.
    private mutating func apply(_ closed: [Segment], at date: Date) {
        for segment in closed {
            save(segment)
            stopWithoutRoom(at: date)
        }
        if let open = sequencer.open, date.timeIntervalSince(lastFlush) >= Self.flushInterval {
            lastFlush = date
            save(open)
            stopWithoutRoom(at: date)
        }
    }

    /// Stops tracking once the queue lacks room for more capture; the open segment's closing save still fits.
    private mutating func stopWithoutRoom(at date: Date) {
        guard state == .recording || state == .idle, !writes.acceptsCapture else { return }
        state = .writesBacklogged
        stop(at: date)
    }

    /// Ends the open segment at `date`, never before its last sample, and saves it.
    private mutating func stop(at date: Date) {
        if let segment = sequencer.gap(at: max(date, sequencer.open?.end ?? date)) { save(segment) }
    }

    private mutating func save(_ segment: Segment) {
        if let storage { writes.save(segment, to: storage) }
    }
}
