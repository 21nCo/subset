import Foundation

/// Reads every visible process once. `LibprocProcessSource` reads this Mac; `FixtureProcessSource` replays
/// recorded samples in tests.
public protocol ProcessSource: Sendable {
    func sample() throws -> RawProcessSample
}

public enum ProcessSourceError: Error, Equatable, Sendable {
    /// `proc_listallpids` failed with this `errno`.
    case listFailed(Int32)
    /// A fixture ran out of recorded samples.
    case exhausted
}

/// Replays recorded samples in order, then throws `exhausted`.
public final class FixtureProcessSource: ProcessSource, @unchecked Sendable {
    private let lock = NSLock()
    private var remaining: [RawProcessSample]

    public init(_ samples: [RawProcessSample]) {
        remaining = samples
    }

    public func sample() throws -> RawProcessSample {
        try lock.withLock {
            guard !remaining.isEmpty else { throw ProcessSourceError.exhausted }
            return remaining.removeFirst()
        }
    }
}
