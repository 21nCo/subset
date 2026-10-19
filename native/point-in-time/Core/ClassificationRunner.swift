import Foundation

/// Exponential backoff after a failed provider request (network, rate limit, process, or an unusable answer).
public struct ClassificationBackoff: Equatable, Sendable {
    public static let base: TimeInterval = 30
    public static let maximum: TimeInterval = 30 * 60
    /// The longest wait a provider's Retry-After is honored for.
    public static let maximumRetryAfter: TimeInterval = 24 * 60 * 60

    public private(set) var failures = 0
    public private(set) var notBefore: Date?

    public init() {}

    /// Waits 30 s after the first failure, doubling up to 30 minutes, or as long as the provider asked (up to a day).
    public mutating func failed(at date: Date, retryAfter: TimeInterval? = nil) {
        failures += 1
        let delay = min(Self.maximum, Self.base * pow(2, Double(min(failures - 1, 16))))
        notBefore = date.addingTimeInterval(max(delay, min(retryAfter ?? 0, Self.maximumRetryAfter)))
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
    private var lastProvider: String?

    public init(store: ActivityStore, memory: @escaping () -> String, clock: @escaping () -> Date = Date.init) {
        self.store = store
        self.memory = memory
        self.clock = clock
    }

    /// Lets the next request go now (wake, network back, settings changed).
    public func resume() {
        backoff.resume()
    }

    /// Sends at most one batch unless a request is in flight, nothing is pending, or the backoff has not elapsed.
    /// `options` is read again after the provider's `prepare`, and the request is built from that reading; nil means
    /// the provider or what may be sent changed meanwhile, so nothing is sent. Returns true when the caller can run
    /// again at once: a whole batch was labeled, or the settings changed.
    @discardableResult
    public func runOnce(provider: (any ClassificationProvider)?, options: @autoclosure () -> ClassificationOptions?) async -> Bool {
        guard !status.inFlight, let initial = options() else { return false }
        if let provider, lastProvider != provider.name + "/" + provider.model {
            // Blocks that failed with another provider or model, or before a relaunch, get a fresh set of attempts.
            lastProvider = provider.name + "/" + provider.model
            try? store.requeueFailed()
        }
        let now = clock()
        refreshCounts(initial, now: now)
        guard let provider, status.pending > 0, backoff.allows(now) else { return false }
        status.inFlight = true
        onChange?()
        defer {
            status.inFlight = false
            refreshCounts(options() ?? initial, now: clock())
            onChange?()
        }
        do {
            try await provider.prepare()
            // The user may have turned the provider off, turned titles off, or excluded an app while it was prepared.
            guard let options = options() else { return true }
            let deletions = store.deletions
            let blocks = try store.pendingBlocks(completedBy: clock().addingTimeInterval(-Self.settleDelay), options: options,
                                                 limit: ClassificationRequest.maxBlocks)
            guard let request = ClassificationRequest(blocks: blocks, memory: memory(), corrections: try store.recentCorrections(),
                                                      options: options) else { return false }
            let text = try await provider.complete(prompt: request.prompt, schema: ClassificationRequest.responseSchema)
            let (accepted, rejected) = try request.validate(text)
            let finished = clock()
            let stored = try store.applyClassifications(accepted, rejected: rejected, provider: provider.name, model: provider.model,
                                                        at: finished, deletionsSeen: deletions)
            if stored > 0 {
                backoff.succeeded()
                status.lastSuccess = finished
                status.lastError = nil
            } else if accepted.isEmpty {
                backoff.failed(at: finished)
            }
            guard rejected.isEmpty else {
                // The rest of the batch waits for the next tick instead of being sent again at once.
                record("\(rejected.count) block(s) got an invalid answer and stay pending", at: finished)
                return false
            }
            return stored > 0
        } catch {
            // A failed request or an unusable answer counts against the provider, not the blocks it carried.
            if case .rateLimited(let retryAfter) = error as? ProviderError {
                backoff.failed(at: clock(), retryAfter: retryAfter)
            } else if error is ProviderError {
                backoff.failed(at: clock())
            }
            record(String(describing: error), at: clock())
            return false
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
