import Foundation

/// Turns periodic samples and gap events into non-overlapping segments. The capture host feeds it; it never reads
/// the system itself, so every boundary is unit-testable.
public struct SegmentRecorder: Sendable {
    /// The segment currently being extended, if any. Its `end` is the last sample that confirmed it. The host
    /// persists it periodically so a crash loses little.
    public private(set) var open: Segment?
    /// A sample arriving later than this after the previous one means the process was suspended or the clock jumped;
    /// the open segment ends at its last confirmation instead of claiming the unobserved time.
    public let maxSampleInterval: TimeInterval
    /// Nothing may start before the end of what was already closed, so a clock that steps backwards cannot create
    /// overlapping segments.
    private var floor: Date = .distantPast

    public init(maxSampleInterval: TimeInterval = 30) {
        self.maxSampleInterval = maxSampleInterval
    }

    /// Records the content in front at `date` (nil when nothing should be recorded) and returns segments that closed.
    public mutating func record(_ content: Segment?, at date: Date) -> [Segment] {
        var closed: [Segment] = []
        if let current = open, date < current.end || date.timeIntervalSince(current.end) > maxSampleInterval {
            if let segment = close(at: current.end), segment.duration > 0 { closed.append(segment) }
        }
        guard date >= floor else { return closed }
        guard var content else {
            // Nothing is in front, so no sample taken before this moment may open a segment after it.
            if let segment = close(at: date), segment.duration > 0 { closed.append(segment) }
            floor = max(floor, date)
            return closed
        }
        if var current = open, current.sameContent(as: content) {
            current.end = date
            open = current
            return closed
        }
        if let segment = close(at: date), segment.duration > 0 { closed.append(segment) }
        content.start = date
        content.end = date
        open = content
        return closed
    }

    /// Ends recording at `date`, for example when idle began or the Mac went to sleep. The end never precedes the
    /// segment's start and never extends more than one sample interval past its last confirmation. Unlike `record`,
    /// this returns the segment even when it is empty (idle began at or before its start): the host may have flushed
    /// part of it already, and saving the empty segment removes that.
    public mutating func gap(at date: Date) -> Segment? {
        defer { floor = max(floor, date) }
        return close(at: date)
    }

    private mutating func close(at date: Date) -> Segment? {
        guard var segment = open else { return nil }
        open = nil
        segment.end = max(segment.start, min(date, segment.end.addingTimeInterval(maxSampleInterval)))
        floor = max(floor, segment.end)
        return segment
    }
}

/// Orders asynchronous window reads against foreground changes. The host reads a window's title and URL off the main
/// thread, so a read can finish after the user has moved on. Every foreground change, synchronous sample, and gap
/// starts a new epoch, and a read is applied only if no epoch started since it began, so a late result can never
/// extend a segment across time spent in another app, in pointInTime, on the lock screen, or in an excluded app.
public struct CaptureSequencer: Sendable {
    /// One read in flight: when it was requested and in which epoch.
    public struct Ticket: Equatable, Sendable {
        public let date: Date
        let epoch: Int
    }

    public private(set) var recorder: SegmentRecorder
    private var epoch = 0
    /// The process the current epoch's reads describe; nil after a synchronous sample or a gap.
    private var foreground: Int32?
    /// The epoch of the read in flight. Only one read is in flight at a time, across foregrounds, so a slow app cannot
    /// build a backlog of reads on the host's serial reader; a read for a newer foreground waits until it finishes.
    private var outstanding: Int?

    public init(recorder: SegmentRecorder) {
        self.recorder = recorder
    }

    public var open: Segment? { recorder.open }

    /// The system reported another app in front at `date`: the open segment ends there and reads in flight are void.
    public mutating func foregroundChanged(at date: Date) -> [Segment] {
        newEpoch(foreground: nil)
        return recorder.record(nil, at: date)
    }

    /// Records content known without a read (pointInTime itself, the lock screen, an excluded app; nil records
    /// nothing) and voids reads in flight.
    public mutating func sample(_ content: Segment?, at date: Date) -> [Segment] {
        newEpoch(foreground: nil)
        return recorder.record(content, at: date)
    }

    /// Ends recording at `date` (see `SegmentRecorder.gap`) and voids reads in flight.
    public mutating func gap(at date: Date) -> Segment? {
        newEpoch(foreground: nil)
        return recorder.gap(at: date)
    }

    /// Starts a read of process `pid`, in front at `date`. Returns nil while any read is still in flight; a read
    /// begun for an earlier foreground is already void, and the host samples again once it finishes.
    public mutating func beginRead(of pid: Int32, at date: Date) -> Ticket? {
        if foreground != pid { newEpoch(foreground: pid) }
        guard outstanding == nil else { return nil }
        outstanding = epoch
        return Ticket(date: date, epoch: epoch)
    }

    /// Whether `ticket` would still be applied: no foreground change, synchronous sample, or gap since it began.
    public func isCurrent(_ ticket: Ticket) -> Bool { ticket.epoch == epoch }

    /// Applies a finished read, unless the foreground changed since it began. Returns segments that closed.
    public mutating func complete(_ ticket: Ticket, with content: Segment?) -> [Segment] {
        discard(ticket)
        guard ticket.epoch == epoch else { return [] }
        return recorder.record(content, at: ticket.date)
    }

    /// Drops a finished read without recording it.
    public mutating func discard(_ ticket: Ticket) {
        if outstanding == ticket.epoch { outstanding = nil }
    }

    private mutating func newEpoch(foreground: Int32?) {
        epoch += 1
        self.foreground = foreground
    }
}
