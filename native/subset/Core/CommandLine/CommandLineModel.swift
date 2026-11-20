import Combine
import Foundation

/// The Command Line section's view of the `subset` command: checked when the window opens and on **Check Again**.
@MainActor
public final class CommandLineModel: ObservableObject {
    /// How long `stop()` waits by default: longer than `ToolRunner` takes to stop a shell's group (SIGTERM, then SIGKILL
    /// 5 seconds later, given up 5 seconds after that).
    public static let stopLimit: TimeInterval = 12

    @Published public private(set) var status: SubsetCommandStatus = .checking
    @Published public private(set) var isChecking = false

    private let detector: SubsetCommandDetector
    /// Shells not yet ended, including one whose check already showed `notInstalled` at the time limit.
    private var probes: [Int: SubsetCommandProbe] = [:]
    private var nextProbe = 0
    private var stopped = false

    public init(detector: SubsetCommandDetector) {
        self.detector = detector
    }

    /// Whether a shell is still running or being stopped, so quitting has to wait for it.
    public var hasRunningShell: Bool { !probes.isEmpty }

    /// Looks for `subset` again. A check while another runs, or once `stop()` was called, does nothing.
    public func check() async {
        guard !isChecking, !stopped else { return }
        isChecking = true
        status = .checking
        let probe = detector.start()
        let id = nextProbe
        nextProbe += 1
        probes[id] = probe
        Task { await end(id) }
        status = await detector.detect(probe)
        isChecking = false
    }

    /// For quitting: starts no new check, stops every shell still running (a check in progress then shows
    /// `notInstalled`) and returns once each has ended with everything it started, or after `limit` seconds.
    public func stop(within limit: TimeInterval = CommandLineModel.stopLimit) async {
        stopped = true
        let running = probes
        for probe in running.values { probe.cancel() }
        _ = await SubsetCommandDetector.within(limit) {
            await withTaskGroup(of: Void.self) { group in
                for id in running.keys { group.addTask { await self.end(id) } }
            }
        }
    }

    /// Waits for a shell to end and then forgets it. Whoever waits does the forgetting, so `stop()` returns only after
    /// every shell it waited for is gone from `hasRunningShell`; a shell given up at the limit stays tracked.
    private func end(_ id: Int) async {
        guard let probe = probes[id] else { return }
        await probe.ended()
        probes[id] = nil
    }
}
