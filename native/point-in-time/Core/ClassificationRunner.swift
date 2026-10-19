import Foundation

/// Exponential backoff after a failed provider request (network, rate limit, process, or an unusable answer).
public struct ClassificationBackoff: Equatable, Sendable {
    public static let base: TimeInterval = 30
    public static let maximum: TimeInterval = 30 * 60

    public private(set) var failures = 0
    public private(set) var notBefore: Date?

    public init() {}

    /// Waits 30 s after the first failure, doubling up to 30 minutes, or longer when the provider asked for it.
    public mutating func failed(at date: Date, retryAfter: TimeInterval? = nil) {
        failures += 1
        let delay = min(Self.maximum, Self.base * pow(2, Double(min(failures - 1, 16))))
        notBefore = date.addingTimeInterval(max(delay, min(retryAfter ?? 0, Self.maximum)))
    }

    public mutating func succeeded() {
        failures = 0
        notBefore = nil
    }

    /// After a wake, the network returning, or a settings change: the next request may go now. The failure count is
    /// kept, so another failure still waits longer than the last.
    public mutating func resume() {
        notBefore = nil
    }

    public func allows(_ date: Date) -> Bool {
        notBefore.map { date >= $0 } ?? true
    }
}

/// What the settings window shows about classification.
public struct ClassificationStatus: Equatable, Sendable {
    public var lastSuccess: Date?
    public var lastError: String?
    public var lastErrorAt: Date?
    public var pending = 0
    public var failed = 0
    public var inFlight = false

    public init() {}
}

/// The classification queue: sends batches of up to 10 completed pending blocks to the configured provider, one
/// request at a time, and stores the validated labels. Pending blocks live in the store, so a relaunch resumes where
/// the last run stopped; the backoff lives in memory and starts fresh.
@MainActor
public final class ClassificationRunner {
    /// A block is sent once this long has passed after its end, so the idle retraction (120 s after the last input) and
    /// the open segment's flush (every 60 s) can no longer change it.
    public static let settleDelay: TimeInterval = 300

    public private(set) var status = ClassificationStatus()
    public private(set) var backoff = ClassificationBackoff()
    public var onChange: (() -> Void)?

    private let store: ActivityStore
    private let memory: () -> String
    private let clock: () -> Date

    public init(store: ActivityStore, memory: @escaping () -> String, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.memory = memory
        self.clock = clock
    }

    /// Lets the next request go now (wake, network back, settings changed).
    public func resume() {
        backoff.resume()
    }

    /// Sends at most one batch unless a request is in flight or the backoff has not elapsed. Returns true when labels
    /// were stored, so the caller can send the next batch at once.
    @discardableResult
    public func runOnce(provider: (any ClassificationProvider)?, options: ClassificationOptions) async -> Bool {
        guard !status.inFlight else { return false }
        let now = clock()
        refreshCounts(options, now: now)
        guard let provider, backoff.allows(now) else { return false }
        let request: ClassificationRequest
        let deletions = store.deletions
        do {
            let blocks = try store.pendingBlocks(completedBy: now.addingTimeInterval(-Self.settleDelay), options: options,
                                                 limit: ClassificationRequest.maxBlocks)
            guard let built = ClassificationRequest(blocks: blocks, memory: memory(), corrections: try store.recentCorrections(),
                                                    options: options) else { return false }
            request = built
        } catch {
            record(String(describing: error), at: now)
            return false
        }
        status.inFlight = true
        onChange?()
        let answer: Result<String, Error>
        do {
            answer = .success(try await provider.complete(prompt: request.prompt, schema: ClassificationRequest.responseSchema))
        } catch {
            answer = .failure(error)
        }
        status.inFlight = false
        let finished = clock()
        defer {
            refreshCounts(options, now: finished)
            onChange?()
        }
        switch answer {
        case .failure(let error):
            if case .rateLimited(let retryAfter) = error as? ProviderError {
                backoff.failed(at: finished, retryAfter: retryAfter)
            } else {
                backoff.failed(at: finished)
            }
            record(String(describing: error), at: finished)
            return false
        case .success(let text):
            do {
                let (accepted, rejected) = try request.validate(text)
                try store.applyClassifications(accepted, rejected: rejected, provider: provider.name, model: provider.model, at: finished,
                                               deletionsSeen: deletions)
                if !rejected.isEmpty {
                    record("\(rejected.count) block(s) got an invalid answer and stay pending", at: finished)
                }
                guard !accepted.isEmpty else {
                    backoff.failed(at: finished)
                    return false
                }
                backoff.succeeded()
                status.lastSuccess = finished
                return true
            } catch let error as ProviderError {
                // The whole answer was unusable: every block counts one failed attempt.
                try? store.applyClassifications([], rejected: request.blocks.map(\.start), provider: provider.name,
                                                model: provider.model, at: finished, deletionsSeen: deletions)
                backoff.failed(at: finished)
                record(String(describing: error), at: finished)
                return false
            } catch {
                record(String(describing: error), at: finished)
                return false
            }
        }
    }

    private func record(_ error: String, at date: Date) {
        status.lastError = error
        status.lastErrorAt = date
    }

    private func refreshCounts(_ options: ClassificationOptions, now: Date) {
        guard let summary = try? store.classificationSummary(completedBy: now.addingTimeInterval(-Self.settleDelay), options: options) else { return }
        status.pending = summary.pending
        status.failed = summary.failed
        status.lastSuccess = max(status.lastSuccess ?? .distantPast, summary.lastClassified ?? .distantPast)
        if status.lastSuccess == .distantPast { status.lastSuccess = nil }
    }
}
