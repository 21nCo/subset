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
            if let segment = close(at: current.end) { closed.append(segment) }
        }
        guard date >= floor else { return closed }
        guard var content else {
            if let segment = close(at: date) { closed.append(segment) }
            return closed
        }
        if var current = open, current.sameContent(as: content) {
            current.end = date
            open = current
            return closed
        }
        if let segment = close(at: date) { closed.append(segment) }
        content.start = date
        content.end = date
        open = content
        return closed
    }

    /// Ends recording at `date`, for example when idle began or the Mac went to sleep. The end never precedes the
    /// segment's start and never extends more than one sample interval past its last confirmation.
    public mutating func gap(at date: Date) -> Segment? {
        close(at: date)
    }

    private mutating func close(at date: Date) -> Segment? {
        guard var segment = open else { return nil }
        open = nil
        segment.end = max(segment.start, min(date, segment.end.addingTimeInterval(maxSampleInterval)))
        floor = max(floor, segment.end)
        return segment.duration > 0 ? segment : nil
    }
}
