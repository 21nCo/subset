import Foundation

/// What capture is doing, for the menu. `CaptureSession` picks one in order of precedence, from the store down to
/// idle, so a state shown can hide a lower one (a backlog shown while the Mac is also asleep); the session's own rules
/// read the conditions, never this precedence.
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

/// System sleep and display sleep, tracked apart because macOS reports them separately and in either order: the display
/// can sleep first and stay asleep through a wake without it (a dark wake), and a lock or idle need not follow. The Mac
/// counts as asleep while either is, so one wake never clears the other. Each notification sets its own flag, so a
/// duplicate or a wake without a matching sleep changes nothing else.
public struct SleepSignals: Equatable, Sendable {
    public private(set) var systemAsleep = false
    public private(set) var displayAsleep = false

    public init() {}

    public var asleep: Bool { systemAsleep || displayAsleep }

    public mutating func systemWillSleep() { systemAsleep = true }
    public mutating func systemDidWake() { systemAsleep = false }
    public mutating func screensDidSleep() { displayAsleep = true }
    public mutating func screensDidWake() { displayAsleep = false }
}

/// Capture's state, recorder, and write queue, kept together so the rules between them hold in one place:
/// - Tracking (recording or idle) holds only while the store's latest end has been read, the user's choices allow it,
///   the queue accepts capture, and the clock is not behind recorded activity. Otherwise capture stops in a named state,
///   and a save that leaves the queue without room stops it at once, while the open segment's closing save still fits.
///   Capture therefore never makes a save the queue refuses, and the queue holds at most `capacity` writes plus one for
///   each Delete Today requested while capture is stopped. Tracking off and pause outrank the store and the clock.
/// - Idle retraction never reaches before the moment recording last became possible again: after the store was read,
///   and after tracking off, a pause, sleep, lock, or a session switch, read from the conditions whatever state is shown,
///   and after the clock was behind recorded activity, so it never reaches rows recorded in another clock frame. A
///   backlog alone does not move it, so input-free time recorded before a backlog is still removed after it.
/// - Every update that leaves the session stopped (any state but recording or idle) ends recording, with or without an
///   open segment, so no window read begun before the stop is applied after it.
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
    /// When recording last became possible again; idle retraction never reaches before it.
    private var recordingSince = Date.distantPast
    /// Whether an interruption or a clock behind recorded activity was seen since `recordingSince` was last set.
    private var resumePending = true
    private var lastFlush = Date.distantPast

    public init(storage: CaptureStorage?, maxSampleInterval: TimeInterval, writes: PendingWrites = PendingWrites()) {
        self.storage = storage
        self.writes = writes
        sequencer = CaptureSequencer(recorder: SegmentRecorder(maxSampleInterval: maxSampleInterval))
    }

    public var open: Segment? { sequencer.open }

    /// Retries queued writes and decides the state from `conditions` at `now`. Stopping ends recording and voids reads in
    /// flight; becoming idle ends the open segment when input stopped and retracts what was stored since.
    public mutating func update(_ conditions: CaptureConditions, at now: Date) {
        if let storage, !writes.isEmpty { writes.retry(storage) }
        seed()
        if interrupts(conditions) || now < sequencer.recordedThrough {
            resumePending = true
        } else if resumePending {
            resumePending = false
            recordingSince = now
        }
        let previous = state
        state = decide(conditions, at: now)
        switch state {
        case .recording: break
        case .idle:
            guard previous != .idle else { break }
            let idleStart = max(now.addingTimeInterval(-conditions.secondsSinceInput), recordingSince)
            if let segment = sequencer.gap(at: idleStart) { save(segment) }
            if let storage { writes.retract(since: idleStart, until: now, in: storage) }
            stopWithoutRoom(at: now)
        default:
            stop(at: now)
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

    /// Applies a finished read while recording and still current; otherwise drops it, without flushing or saving at the
    /// stale read's date.
    public mutating func complete(_ ticket: CaptureSequencer.Ticket, with content: Segment?) {
        guard state == .recording, sequencer.isCurrent(ticket) else {
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

    /// A user choice or system state during which input-free time is not the user being idle, read from the conditions:
    /// the state shown may rank a backlog or a clock behind recorded activity above it.
    private func interrupts(_ conditions: CaptureConditions) -> Bool {
        storage == nil || !seeded || !conditions.trackingOn || conditions.paused || conditions.asleep || conditions.locked
            || conditions.sessionInactive
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

    /// Ends recording at `date`, never before the open segment's last sample, saves the segment if one was open, and
    /// voids reads in flight.
    private mutating func stop(at date: Date) {
        if let segment = sequencer.gap(at: max(date, sequencer.open?.end ?? date)) { save(segment) }
    }

    private mutating func save(_ segment: Segment) {
        if let storage { writes.save(segment, to: storage) }
    }
}
