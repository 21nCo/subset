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
    /// The running container runtimes' VMs, from the latest sample.
    private(set) var containerVMs: [ContainerVMGroup] = []
    /// The latest container breakdown from the Docker-compatible CLI, which runs only while the main window is
    /// visible; dropped when the window is hidden.
    private(set) var containerReport: ContainerReport?
    /// Called on the main actor after each sample.
    @ObservationIgnored var onUpdate: (() -> Void)?

    @ObservationIgnored private let worker = SamplingWorker()
    @ObservationIgnored private var cadence = SamplingCadence.menuBarOnly
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var schedule = SamplingSchedule()
    @ObservationIgnored private let containerPoller = ContainerPoller()
    @ObservationIgnored private var containerRefresh: Task<Void, Never>?

    var summary: StatusSummary { StatusSummary(snapshot: snapshot, memory: memory, samplingFailed: sampleError != nil) }

    func start() {
        guard loop == nil else { return }
        restart()
    }

    func setMainWindowVisible(_ visible: Bool) {
        let cadence = SamplingCadence(mainWindowVisible: visible)
        guard cadence != self.cadence else { return }
        self.cadence = cadence
        if !visible {
            // Hiding the window stops a container poll in progress: its running command is stopped and no
            // further one starts. The last report is dropped, so reopening the window never shows it as current.
            containerRefresh?.cancel()
            containerRefresh = nil
            containerReport = nil
        }
        if loop != nil { restart() }
    }

    /// Stops a container poll in progress before the app quits: its running command gets `SIGKILL` now, since the
    /// runner's delayed one would never fire, and no further command starts.
    func stopContainerPolling() {
        containerRefresh?.cancel()
        containerRefresh = nil
        CommandRegistry.shared.shutDown()
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
            containerVMs = result.containerVMs
            sampleError = nil
        case let .failure(error):
            sampleError = "Could not list processes: \(error)"
        }
        memory = result.memory
        onUpdate?()
        refreshContainers()
    }

    /// Asks the poller for a container breakdown without holding up sampling. The poller runs the CLI only while
    /// the main window is visible and a VM runs, at most once every 10 seconds.
    private func refreshContainers() {
        guard containerRefresh == nil, cadence == .mainWindowVisible, !containerVMs.isEmpty else { return }
        let runtimes = containerVMs.map(\.runtime)
        let cadence = cadence
        containerRefresh = Task { [weak self, containerPoller] in
            let report = await containerPoller.refresh(cadence: cadence, runningRuntimes: runtimes)
            // A cancelled refresh was already cleared when the window was hidden.
            guard let self, !Task.isCancelled else { return }
            if let report { containerReport = report }
            containerRefresh = nil
        }
    }
}

/// Owns the sampler off the main actor, so reading several hundred processes never blocks the UI.
private actor SamplingWorker {
    private var sampler = Sampler(source: LibprocProcessSource(), hostCPU: LiveHostCPUSource(), origin: .live())
    private let memorySource = LiveSystemMemorySource()

    func sample() -> (processes: Result<ProcessSnapshot, any Error>, memory: SystemMemory, containerVMs: [ContainerVMGroup]) {
        let processes = Result { try sampler.sample() }
        let containerVMs = (try? processes.get()).map { ContainerVMRecognizer().groups(in: $0.processes) } ?? []
        return (processes, SystemMemory(raw: memorySource.read()), containerVMs)
    }
}
