import Foundation

/// The store writes capture makes. `ActivityStore` is the real one; tests inject failures.
public protocol CaptureStorage: AnyObject {
    func save(_ segment: Segment) throws
    func deleteData(from: Date, to: Date) throws
    func checkpoint() throws
    /// Deletes every row; `compact` then removes the deleted pages from the file.
    func removeAll() throws
    func compact() throws
    /// The latest end of any stored segment, or nil when none is stored.
    func latestSegmentEnd() throws -> Date?
}

extension ActivityStore: CaptureStorage {}

/// Applies capture's writes to the store in the order they were made, and keeps every write that has not succeeded yet.
/// A failed write is retried, with everything queued behind it, on the next `retry` or write; nothing later is applied
/// out of order, so a retried save can never bring back time that a later retraction or deletion removed. A failure
/// therefore neither drops recorded time nor keeps retracted time, and stays visible until the queue drains.
///
/// Recovering leaves the store exactly as if every admitted write had been applied in request order, whatever the wall
/// clock did. Compaction only rewrites the queue into one with that result, and only when it can prove it, using the
/// latest end of every segment stored or queued: the stored maximum, read from storage, and the end of every segment
/// admitted since. While that bound is no later than a retraction's end, nothing reaches past its range, so the
/// retraction removes everything from its start onwards: it may drop the queued saves inside its range, which it
/// deletes anyway, and when the bound is also no later than the end of a queued retraction directly before it, the two
/// become one covering both ranges and the gap between them, which removes the same. After the clock moves back, rows
/// can end later than the request time, so retractions stay separate and keep every queued save; until storage has
/// reported its maximum, nothing is compacted at all. The bound is re-read after a retraction or deletion has been
/// applied, and a queued Delete All starts it afresh, so a removal lets compaction resume.
///
/// One signal governs capture: `acceptsCapture` holds only while the queue has room for the next save and for the save
/// that closes the segment it starts, and capture stops as soon as it fails (see `CaptureSession`). Saves are refused
/// once the queue holds `capacity` writes (that time is not captured), which capture that obeys the signal never
/// reaches. Retractions and deletions are always admitted, and never dropped or made to delete more to fit; each adds at
/// most one write, and Delete All replaces the whole queue. Each `retry` applies at most `writesPerRetry` writes, so
/// recovering from a long outage never blocks the caller for long; `drain` applies the whole queue, for example before
/// quitting.
public struct PendingWrites: Sendable {
    enum Write: Equatable, Sendable {
        case save(Segment)
        /// Deletes `[from, to)` and then checkpoints the WAL, so the removed titles and URLs do not linger in it.
        case retract(from: Date, to: Date)
        /// Deletes every row and then compacts the file.
        case deleteAll
    }

    public let capacity: Int
    public let writesPerRetry: Int
    /// Queued writes are `entries[head...]`; dequeuing advances `head`, and the consumed prefix is dropped in bulk.
    private var entries: [Write] = []
    private var head = 0
    /// The last write error, kept until every queued write has succeeded.
    public private(set) var failure: String?
    /// How many retractions and deletions have removed rows from storage. It changes once when the delete step of one
    /// succeeds, whether it ran at once or on a later retry, and even when the checkpoint or compaction after it failed
    /// and the write stays queued, so readers can reload as soon as stored activity is gone.
    public private(set) var appliedRemovals = 0
    /// Whether the delete step of the write at the head of the queue has succeeded, so retrying it is not counted again.
    private var headRemoved = false
    /// Saves refused because the queue was full; that time was not captured.
    private(set) var refusedSaves = 0
    /// Whether storage has reported the latest end of what it holds since the last removal was applied, and that end.
    private var knowsStoredEnd = false
    private var storedEnd: Date?
    /// The latest end of every segment admitted since storage last reported its end; refused saves are never stored.
    private var admittedEnd = Date.distantPast

    public init(capacity: Int = 256, writesPerRetry: Int = 8) {
        precondition(capacity > 0 && writesPerRetry > 0)
        self.capacity = capacity
        self.writesPerRetry = writesPerRetry
    }

    public var isEmpty: Bool { count == 0 }
    public var count: Int { entries.count - head }
    var queue: ArraySlice<Write> { entries[head...] }

    /// Whether the next save and the save that closes the segment it starts would both be admitted. Capture records only
    /// while this holds.
    public var acceptsCapture: Bool { count + 2 <= capacity }

    /// Whether a deletion or idle retraction is still queued, so activity that should be gone is still stored.
    public var hasPendingDeletion: Bool {
        queue.contains { if case .save = $0 { false } else { true } }
    }

    /// Whether recorded activity is still queued, so it is not stored yet.
    public var hasPendingSave: Bool {
        queue.contains { if case .save = $0 { true } else { false } }
    }

    /// No segment stored, or stored once the queue drains, ends after this; nil until storage has reported its latest end.
    private var latestKnownEnd: Date? {
        knowsStoredEnd ? max(storedEnd ?? .distantPast, admittedEnd) : nil
    }

    /// Saves `segment` (see `ActivityStore.save`). Returns whether the queue drained.
    @discardableResult
    public mutating func save(_ segment: Segment, to storage: CaptureStorage) -> Bool {
        learnStoredEnd(storage)
        if case .save(var last)? = queue.last, last.start == segment.start, last.duration > 0 {
            // The store keeps one row per start and a later save of it only moves its end, so one save with the queued
            // content and the new end stores the same row.
            last.end = segment.end
            entries[entries.count - 1] = .save(last)
        } else if count < capacity {
            entries.append(.save(segment))
        } else {
            // The queue is full and this segment is not captured. A shorter save that idle would have made is covered by
            // the retraction that follows it, which is always admitted.
            refusedSaves += 1
            return retry(storage)
        }
        admittedEnd = max(admittedEnd, segment.end)
        return retry(storage)
    }

    /// Removes everything recorded from `from` until `now`, the time of the request, and checkpoints the WAL. Returns
    /// whether the queue drained.
    @discardableResult
    public mutating func retract(since from: Date, until now: Date, in storage: CaptureStorage) -> Bool {
        learnStoredEnd(storage)
        if now > from {
            // Only when nothing stored or queued ends after `now` (see the type's documentation).
            if let known = latestKnownEnd, known <= now {
                dropSaves(within: from, now)
                if case .retract(let queuedFrom, let queuedTo)? = queue.last, known <= queuedTo {
                    entries[entries.count - 1] = .retract(from: min(from, queuedFrom), to: max(now, queuedTo))
                    // A wider head has rows its earlier delete step did not remove.
                    if count == 1 { headRemoved = false }
                    return retry(storage)
                }
            }
            entries.append(.retract(from: from, to: now))
        }
        return retry(storage)
    }

    /// Reads the latest end of what storage holds, which also bounds compaction from now on.
    public mutating func readStoredEnd(from storage: CaptureStorage) throws -> Date? {
        let end = try storage.latestSegmentEnd()
        storedEnd = end
        knowsStoredEnd = true
        return end
    }

    /// Removes everything recorded since the start of the day that contains `now`, until `now`.
    @discardableResult
    public mutating func deleteDay(containing now: Date, calendar: Calendar, in storage: CaptureStorage) -> Bool {
        retract(since: calendar.startOfDay(for: now), until: now, in: storage)
    }

    /// Deletes every segment and block. Writes still queued are dropped, because the deletion would remove their result.
    @discardableResult
    public mutating func deleteAll(in storage: CaptureStorage) -> Bool {
        entries = [.deleteAll]
        head = 0
        headRemoved = false
        // Once it is applied nothing stored before it remains, and every later write is queued after it.
        (knowsStoredEnd, storedEnd, admittedEnd) = (true, nil, .distantPast)
        return retry(storage)
    }

    /// Applies up to `writesPerRetry` queued writes in order, stopping at the first failure. Returns whether the queue
    /// drained; `failure` stays set until it has.
    @discardableResult
    public mutating func retry(_ storage: CaptureStorage) -> Bool {
        apply(upTo: writesPerRetry, storage)
    }

    /// Applies every queued write in order, stopping at the first failure, for example before quitting. The queue is
    /// bounded, so this is bounded work. Returns whether the queue drained; `failure` stays set until it has.
    @discardableResult
    public mutating func drain(_ storage: CaptureStorage) -> Bool {
        apply(upTo: count, storage)
    }

    private mutating func apply(upTo limit: Int, _ storage: CaptureStorage) -> Bool {
        for _ in 0..<limit {
            guard let write = queue.first else { break }
            do {
                switch write {
                case .save(let segment): try storage.save(segment)
                case .retract(let from, let to):
                    try storage.deleteData(from: from, to: to)
                    noteRemoval()
                    try storage.checkpoint()
                case .deleteAll:
                    try storage.removeAll()
                    noteRemoval()
                    try storage.compact()
                }
            } catch {
                failure = String(describing: error)
                return false
            }
            dequeue()
            if case .save = write {} else { forgetStoredEnd() }
        }
        guard isEmpty else { return false }
        failure = nil
        return true
    }

    private mutating func noteRemoval() {
        if !headRemoved { appliedRemovals += 1 }
        headRemoved = true
    }

    private mutating func dequeue() {
        head += 1
        headRemoved = false
        if head == entries.count {
            entries.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    /// Reads the latest stored end when it is not known; a failed read is tried again on the next write, and nothing is
    /// compacted until one succeeds. Saves admitted in between are counted in `admittedEnd` either way.
    private mutating func learnStoredEnd(_ storage: CaptureStorage) {
        if !knowsStoredEnd { _ = try? readStoredEnd(from: storage) }
    }

    /// An applied removal can lower the stored maximum, so it is read again before the next compaction; the saves still
    /// queued are not stored yet and keep counting.
    private mutating func forgetStoredEnd() {
        knowsStoredEnd = false
        storedEnd = nil
        admittedEnd = queue.reduce(.distantPast) { if case .save(let segment) = $1 { max($0, segment.end) } else { $0 } }
    }

    /// Drops queued saves that lie inside `[lower, upper)`, the range of the retraction being queued after them, which
    /// would delete their rows.
    private mutating func dropSaves(within lower: Date, _ upper: Date) {
        let kept = queue.filter { write in
            guard case .save(let segment) = write else { return true }
            return segment.start < lower || segment.end > upper
        }
        entries = Array(kept)
        head = 0
    }
}
