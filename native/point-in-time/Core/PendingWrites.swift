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
public struct PendingWrites: Sendable {
    enum Write: Equatable, Sendable {
        case save(Segment)
        /// Deletes `[from, to)` and then checkpoints the WAL, so the removed titles and URLs do not linger in it.
        case retract(from: Date, to: Date)
        case deleteAll
    }

    private(set) var queue: [Write] = []
    /// The last write error, kept until every queued write has succeeded.
    public private(set) var failure: String?

    public init() {}

    public var isEmpty: Bool { queue.isEmpty }

    /// Saves `segment` (see `ActivityStore.save`). Returns whether the queue drained.
    @discardableResult
    public mutating func save(_ segment: Segment, to storage: CaptureStorage) -> Bool {
        if case .save(let last)? = queue.last, last.start == segment.start {
            // The store keeps one row per segment start, so the newer save of the same segment replaces the queued one.
            queue[queue.count - 1] = .save(segment)
        } else {
            queue.append(.save(segment))
        }
        return retry(storage)
    }

    /// Removes everything recorded in `[from, to)` and checkpoints the WAL. Returns whether the queue drained.
    @discardableResult
    public mutating func retract(from: Date, to: Date, in storage: CaptureStorage) -> Bool {
        if to > from {
            if case .retract(let lower, let upper)? = queue.last, from <= upper, to >= lower {
                queue[queue.count - 1] = .retract(from: min(lower, from), to: max(upper, to))
            } else {
                queue.append(.retract(from: from, to: to))
            }
        }
        return retry(storage)
    }

    /// Deletes every segment and block. Writes still queued are dropped, because the deletion would remove their result.
    @discardableResult
    public mutating func deleteAll(in storage: CaptureStorage) -> Bool {
        queue = [.deleteAll]
        return retry(storage)
    }

    /// Applies queued writes in order until one fails. Returns whether the queue drained.
    @discardableResult
    public mutating func retry(_ storage: CaptureStorage) -> Bool {
        while let write = queue.first {
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
            queue.removeFirst()
        }
        failure = nil
        return true
    }
}
