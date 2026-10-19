import Foundation
import Observation
import SystemCore

/// Samples processes and memory on the cadence the visible UI needs and publishes the latest results. Samples
/// live only in memory.
@MainActor
@Observable
final class SystemMonitor {
    private(set) var snapshot: ProcessSnapshot?
    private(set) var memory: SystemMemory?
    private(set) var sampleError: String?
    /// Called on the main actor after each sample.
    @ObservationIgnored var onUpdate: (() -> Void)?

    @ObservationIgnored private let worker = SamplingWorker()
    @ObservationIgnored private var cadence = SamplingCadence.menuBarOnly
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var schedule = SamplingSchedule()

    var summary: StatusSummary { StatusSummary(snapshot: snapshot, memory: memory, samplingFailed: sampleError != nil) }

    func start() {
        guard loop == nil else { return }
        restart()
    }

    func setMainWindowVisible(_ visible: Bool) {
        let cadence = SamplingCadence(mainWindowVisible: visible)
        guard cadence != self.cadence else { return }
        self.cadence = cadence
        if loop != nil { restart() }
    }

    /// Restarts the loop so a cadence change applies now. A sample already running finishes; the schedule keeps the
    /// next one from starting sooner than the new interval after it started.
    private func restart() {
        loop?.cancel()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let delay = self?.nextDelay() else { return }
                if delay > .zero {
                    do { try await Task.sleep(for: delay) } catch { return }
                }
                guard let self, !Task.isCancelled else { return }
                await sampleOnce()
            }
        }
    }

    private func nextDelay() -> Duration {
        schedule.delay(for: cadence, now: .now)
    }

    private func sampleOnce() async {
        guard schedule.begin(at: .now) else { return }
        let result = await worker.sample()
        schedule.finish()
        switch result.processes {
        case let .success(snapshot):
            self.snapshot = snapshot
            sampleError = nil
        case let .failure(error):
            sampleError = "Could not list processes: \(error)"
        }
        memory = result.memory
        onUpdate?()
    }
}

/// Owns the sampler off the main actor, so reading several hundred processes never blocks the UI.
private actor SamplingWorker {
    private var sampler = Sampler(source: LibprocProcessSource(), hostCPU: LiveHostCPUSource())
    private let memorySource = LiveSystemMemorySource()

    func sample() -> (processes: Result<ProcessSnapshot, any Error>, memory: SystemMemory) {
        let processes = Result { try sampler.sample() }
        return (processes, SystemMemory(raw: memorySource.read()))
    }
}
