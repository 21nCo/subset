import Foundation

/// The store writes capture makes. `ActivityStore` is the real one; tests inject failures.
public protocol CaptureStorage: AnyObject {
    func save(_ segment: Segment) throws
    func deleteData(from: Date, to: Date) throws
    func checkpoint() throws
    func deleteAll() throws
}

extension ActivityStore: CaptureStorage {}

/// Applies capture's writes to the store in the order they were made, and keeps every write that has not succeeded yet.
/// A failed write is retried, with everything queued behind it, on the next `retry` or write; nothing later is applied
/// out of order, so a retried save can never bring back time that a later retraction or deletion removed. A failure
/// therefore neither drops recorded time nor keeps retracted time, and stays visible until the queue drains.
///
/// The queue is bounded so a store that keeps failing cannot grow it without limit: once it holds `capacity` writes,
/// new saves are refused (that time is not captured), while retractions and deletions are always admitted. Each call
/// applies at most `writesPerRetry` writes, so recovering from a long outage never blocks the caller for long.
public struct PendingWrites: Sendable {
    enum Write: Equatable, Sendable {
        case save(Segment)
        /// Deletes `[from, to)` and then checkpoints the WAL, so the removed titles and URLs do not linger in it.
        case retract(from: Date, to: Date)
        case deleteAll
    }

    public let capacity: Int
    public let writesPerRetry: Int
    /// Queued writes are `entries[head...]`; dequeuing advances `head`, and the consumed prefix is dropped in bulk.
    private var entries: [Write] = []
    private var head = 0
    /// The last write error, kept until every queued write has succeeded.
    public private(set) var failure: String?

    public init(capacity: Int = 256, writesPerRetry: Int = 8) {
        precondition(capacity > 0 && writesPerRetry > 0)
        self.capacity = capacity
        self.writesPerRetry = writesPerRetry
    }

    public var isEmpty: Bool { count == 0 }
    public var count: Int { entries.count - head }
    var queue: ArraySlice<Write> { entries[head...] }

    /// Whether a deletion or idle retraction is still queued, so activity that should be gone is still stored.
    public var hasPendingDeletion: Bool {
        queue.contains { if case .save = $0 { false } else { true } }
    }

    /// Saves `segment` (see `ActivityStore.save`). Returns whether the queue drained.
    @discardableResult
    public mutating func save(_ segment: Segment, to storage: CaptureStorage) -> Bool {
        if case .save(let last)? = queue.last, last.start == segment.start {
            // The store keeps one row per segment start, so the newer save of the same segment replaces the queued one.
            entries[entries.count - 1] = .save(segment)
        } else if count < capacity {
            entries.append(.save(segment))
        }
        // Otherwise the queue is full and this segment is not captured. A shorter save that idle would have made is
        // covered by the retraction that follows it, which is always admitted.
        return retry(storage)
    }

    /// Removes everything recorded in `[from, to)` and checkpoints the WAL. Returns whether the queue drained.
    @discardableResult
    public mutating func retract(from: Date, to: Date, in storage: CaptureStorage) -> Bool {
        if to > from {
            var lower = from, upper = to
            if case .retract(let queuedLower, let queuedUpper)? = queue.last, from <= queuedUpper, to >= queuedLower {
                entries.removeLast()
                lower = min(lower, queuedLower)
                upper = max(upper, queuedUpper)
            } else if count >= capacity, let index = queue.lastIndex(where: { if case .retract = $0 { true } else { false } }),
                      case .retract(let queuedLower, let queuedUpper) = entries[index] {
                // At capacity the newest retraction absorbs the previous one and moves it last, so the queue stays bounded.
                // This also deletes what was recorded between the two ranges: a full queue errs toward deleting.
                entries.remove(at: index)
                lower = min(lower, queuedLower)
                upper = max(upper, queuedUpper)
            }
            dropSaves(within: lower, upper)
            entries.append(.retract(from: lower, to: upper))
        }
        return retry(storage)
    }

    /// Deletes every segment and block. Writes still queued are dropped, because the deletion would remove their result.
    @discardableResult
    public mutating func deleteAll(in storage: CaptureStorage) -> Bool {
        entries = [.deleteAll]
        head = 0
        return retry(storage)
    }

    /// Applies up to `writesPerRetry` queued writes in order, stopping at the first failure. Returns whether the queue
    /// drained; `failure` stays set until it has.
    @discardableResult
    public mutating func retry(_ storage: CaptureStorage) -> Bool {
        for _ in 0..<writesPerRetry {
            guard let write = queue.first else { break }
            do {
                switch write {
                case .save(let segment): try storage.save(segment)
                case .retract(let from, let to):
                    try storage.deleteData(from: from, to: to)
                    try storage.checkpoint()
                case .deleteAll: try storage.deleteAll()
                }
            } catch {
                failure = String(describing: error)
                return false
            }
            dequeue()
        }
        guard isEmpty else { return false }
        failure = nil
        return true
    }

    private mutating func dequeue() {
        head += 1
        if head == entries.count {
            entries.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= entries.count {
            entries.removeFirst(head)
            head = 0
        }
    }

    /// Drops queued saves that lie inside `[lower, upper)`: the retraction queued after them would delete their rows.
    private mutating func dropSaves(within lower: Date, _ upper: Date) {
        let kept = queue.filter { write in
            guard case .save(let segment) = write else { return true }
            return segment.start < lower || segment.end > upper
        }
        entries = Array(kept)
        head = 0
    }
}
