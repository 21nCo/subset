import Foundation
import Testing
@testable import TimerApp
@testable import TimerCore

/// One log for the daemon calls, sounds and notifications, so tests see their order.
private final class Log: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    var all: [String] { lock.withLock { entries } }
    func add(_ entry: String) { lock.withLock { entries.append(entry) } }
}

private final class FakeDaemon: AlertHandlerDaemon, @unchecked Sendable {
    let log: Log
    private let lock = NSLock()
    private var expired: Set<String> = []
    private var holdAcks = false
    private var held: CheckedContinuation<Void, Never>?

    init(log: Log) { self.log = log }

    func expire(_ alertId: String) { lock.withLock { _ = expired.insert(alertId) } }
    /// Keeps the next acknowledgement's answer until `release()`.
    func holdNextAck() { lock.withLock { holdAcks = true } }
    var holding: Bool { lock.withLock { held != nil } }
    func release() { lock.withLock { held.take() }?.resume() }

    func registerAlertHandler(subscriberId: String) async throws { log.add("register \(subscriberId)") }
    func unregisterAlertHandler(subscriberId: String) async throws { log.add("unregister \(subscriberId)") }
    func acknowledgeAlert(_ alertId: String, subscriberId: String) async throws -> AlertAcknowledgement {
        log.add("ack \(alertId)")
        if lock.withLock({ holdAcks }) {
            await withCheckedContinuation { continuation in lock.withLock { holdAcks = false; held = continuation } }
        }
        return lock.withLock { expired.contains(alertId) } ? .expired : .acknowledged
    }
    func confirmAlert(_ alertId: String, subscriberId: String) async throws {}
}

@MainActor
private final class FakeNotifications: UserNotifying {
    let log: Log
    var authorized: Bool
    var posted: [TimerNotification] = []

    init(log: Log, authorized: Bool) {
        self.log = log
        self.authorized = authorized
    }

    func requestAuthorization() async -> Bool {
        log.add("ask")
        return authorized
    }

    func isAuthorized() async -> Bool { authorized }

    func post(_ notification: TimerNotification) {
        posted.append(notification)
        log.add("notify \(notification.title): \(notification.body)")
    }
}

@MainActor
private final class FakeSounds: SoundPlaying {
    let log: Log
    init(log: Log) { self.log = log }
    func play(_ sounds: [SystemSound]) {
        if !sounds.isEmpty { log.add("sound " + sounds.map(\.rawValue).joined(separator: " ")) }
    }
}

private func event(_ name: String, _ json: String) -> EventSubscription.Update {
    .event(ServerSentEvent(event: name, data: json))
}

private func noTimers() -> EventSubscription.Update {
    event("state", #"{"structuredContent":{"schemaVersion":1,"observedAt":0,"timers":[]},"text":"","viewId":"subset.timer.board@1"}"#)
}

private func state(timerName: String, sound: Bool) -> EventSubscription.Update {
    let timer = """
    {"definition":{"kind":"countdown","id":"t_1","name":"\(timerName)","sound":\(sound),"countdownTicks":false,"createdAt":0,"durationMs":1000},
     "runtime":{"status":"running","startedAt":0,"accumulatedMs":0,"pausedAt":null,"laps":[],"skippedMs":0},
     "projection":{"status":"running","elapsedMs":0,"totalMs":1000,"remainingMs":1000,"finished":false}}
    """
    return event("state", #"{"structuredContent":{"schemaVersion":1,"observedAt":0,"timers":[\#(timer)]},"text":"","viewId":"subset.timer.board@1"}"#)
}

/// Waits for main-actor work started by the controller.
@MainActor
private func until(_ condition: () -> Bool) async {
    for _ in 0..<500 where !condition() { try? await Task.sleep(nanoseconds: 2_000_000) }
}

@MainActor
struct AlertTests {
    fileprivate let log = Log()

    private func presenter() -> (AlertPresenter, FakeNotifications) {
        let notifications = FakeNotifications(log: log, authorized: true)
        return (AlertPresenter(notifications: notifications, sounds: FakeSounds(log: log)), notifications)
    }

    @Test func eachKindPlaysItsSoundAndTheFinishAndMissedAlertsNameTheTimer() throws {
        let (presenter, notifications) = presenter()
        let work = TimerAlert.Step(index: 1, round: 1, phase: .work, label: "Work", durationMs: 20_000)
        presenter.present(TimerAlert(timerId: "t_1", kind: .tick, at: 1, secondsLeft: 3, timerName: "Tabata", sound: true))
        presenter.present(TimerAlert(timerId: "t_1", kind: .segment, at: 2, segment: work, timerName: "Tabata", sound: true))
        presenter.present(TimerAlert(timerId: "t_1", kind: .finish, at: 3, alertId: "a3", ackRequired: true, timerName: "Tabata", sound: true))
        presenter.present(TimerAlert(timerId: "t_1", kind: .missedWhileAway, at: 4, segment: work, missed: 3, timerName: "Tabata", sound: true))
        #expect(log.all == ["sound Tink", "sound Pop", "sound Glass Glass Glass", "notify Tabata: Finished.",
                            "notify Tabata: Missed 3 alerts while away. Now: Work."])
        #expect(notifications.posted.map(\.id).first == "a3")
        #expect(notifications.posted.allSatisfy { $0.timerId == "t_1" })
    }

    @Test func aTimerWithSoundOffOnlyNotifies() throws {
        let (presenter, _) = presenter()
        presenter.present(TimerAlert(timerId: "t_1", kind: .tick, at: 1, secondsLeft: 1, timerName: "Tabata", sound: false))
        presenter.present(TimerAlert(timerId: "t_1", kind: .finish, at: 2, timerName: "Tabata", sound: false))
        presenter.present(TimerAlert(timerId: "t_9", kind: .missedWhileAway, at: 3, missed: 1))
        #expect(log.all == ["notify Tabata: Finished.", "notify Timer: Missed 1 alert while away."])
    }

    @Test func restartResetsThenStartsAndDismissRunsNothing() async {
        var operations: [String] = []
        let perform: (String, OperationInput) async -> String? = { operations.append("\($0) \($1.id ?? "")"); return nil }
        #expect(await NotificationAction.restart.run(timerId: "t_1", perform: perform) == nil)
        #expect(await NotificationAction.dismiss.run(timerId: "t_1", perform: perform) == nil)
        #expect(operations == ["reset t_1", "start t_1"])
        #expect(NotificationAction.allCases.map(\.title) == ["Restart", "Dismiss"])

        // A reset the daemon refuses does not start the timer.
        operations = []
        let failing: (String, OperationInput) async -> String? = { operation, _ in operations.append(operation); return operation == "reset" ? "No timer t_1." : nil }
        #expect(await NotificationAction.restart.run(timerId: "t_1", perform: failing) == "No timer t_1.")
        #expect(operations == ["reset"])
    }

    @Test func theAppAcknowledgesBeforePlayingAndStopsHandlingWhenPermissionIsRevoked() async {
        let daemon = FakeDaemon(log: log)
        let notifications = FakeNotifications(log: log, authorized: true)
        let controller = TimerController(paths: DaemonPaths(dataDir: "/tmp/unused"), alertDaemon: daemon, notifications: notifications, sounds: FakeSounds(log: log))
        controller.checkNotifications(ask: true)
        controller.handle(.connected)
        controller.handle(event("subscriber", #"{"subscriberId":"s1"}"#))
        controller.handle(state(timerName: "Egg", sound: true))
        await until { controller.alerts.registration == .registered }
        #expect(log.all == ["ask", "register s1"])

        controller.handle(event("alert", #"{"timerId":"t_1","kind":"finish","at":1000,"alertId":"a1","ackRequired":true}"#))
        await until { log.all.count == 5 }
        #expect(log.all.suffix(3) == ["ack a1", "sound Glass Glass Glass", "notify Egg: Finished."])

        // After the daemon's sink played an alert (410), the app plays nothing.
        daemon.expire("a2")
        controller.handle(event("alert", #"{"timerId":"t_1","kind":"segment","at":2000,"alertId":"a2","ackRequired":true}"#))
        await until { log.all.count == 6 }
        // An alert without an acknowledgement belongs to the daemon.
        controller.handle(event("alert", #"{"timerId":"t_1","kind":"tick","secondsLeft":1,"at":3000}"#))
        notifications.authorized = false
        controller.checkNotifications()
        await until { controller.alerts.registration == .inactive }
        await controller.alerts.settled()
        controller.handle(event("alert", #"{"timerId":"t_1","kind":"finish","at":4000,"alertId":"a4","ackRequired":true}"#))
        try? await Task.sleep(nanoseconds: 100_000_000)
        #expect(log.all.suffix(2) == ["ack a2", "unregister s1"])
    }

    /// A finish whose timer is removed while its acknowledgement is answered plays as that timer, quietly.
    @Test(arguments: [#","timerName":"Quiet","sound":false"#, ""])
    func anAlertKeepsItsTimersNameAndSoundWhenTheTimerIsRemovedDuringTheAcknowledgement(_ fromDaemon: String) async {
        let daemon = FakeDaemon(log: log)
        let notifications = FakeNotifications(log: log, authorized: true)
        let controller = TimerController(paths: DaemonPaths(dataDir: "/tmp/unused"), alertDaemon: daemon, notifications: notifications, sounds: FakeSounds(log: log))
        controller.checkNotifications()
        controller.handle(event("subscriber", #"{"subscriberId":"s1"}"#))
        controller.handle(state(timerName: "Quiet", sound: false))
        await until { controller.alerts.registration == .registered }
        daemon.holdNextAck()
        // The daemon sends the alert, then the `state` without the removed timer, before the app's ack is answered.
        // A daemon that names the timer is used as is; for one that does not, the app takes it on receipt.
        controller.handle(event("alert", #"{"timerId":"t_1","kind":"finish","at":1000,"alertId":"a1","ackRequired":true\#(fromDaemon)}"#))
        await until { daemon.holding }
        controller.handle(noTimers())
        #expect(controller.timers.isEmpty)
        daemon.release()
        await until { !notifications.posted.isEmpty }
        #expect(log.all == ["register s1", "ack a1", "notify Quiet: Finished."])
    }

    /// A Restart that launches the app arrives while Node.js is still being located; it runs once it is found.
    @Test func aRestartBeforeTheRuntimeIsLocatedRunsResetThenStartOnceItIs() async {
        let (located, locate) = AsyncStream.makeStream(of: Result<Runtime, RuntimeProblem>.self)
        let controller = TimerController(paths: DaemonPaths(dataDir: "/tmp/unused"), services: services(located), alertDaemon: FakeDaemon(log: log),
                                         notifications: FakeNotifications(log: log, authorized: false), sounds: FakeSounds(log: log))
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.start()
        controller.run(.restart, timerId: "t_1")
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(log.all.isEmpty && errors.isEmpty)
        locate.yield(.success(Runtime(node: "/node", nodeVersion: "22.13.0", cli: "/cli.mjs", cliSource: .bundled)))
        await until { log.all.count == 2 }
        #expect(log.all == ["reset t_1", "start t_1"])
        #expect(errors.isEmpty)
    }

    /// When locating fails, the action reports that problem, not a missing Node.js.
    @Test func aRestartBeforeTheRuntimeIsLocatedReportsTheRealSetupProblem() async {
        let (located, locate) = AsyncStream.makeStream(of: Result<Runtime, RuntimeProblem>.self)
        let controller = TimerController(paths: DaemonPaths(dataDir: "/tmp/unused"), services: services(located), alertDaemon: FakeDaemon(log: log),
                                         notifications: FakeNotifications(log: log, authorized: false), sounds: FakeSounds(log: log))
        var errors: [String] = []
        controller.onError = { errors.append($0) }
        controller.start()
        controller.run(.restart, timerId: "t_1")
        locate.yield(.failure(.bundledMissing("/Timer.app/cli")))
        await until { !errors.isEmpty }
        #expect(errors == [RuntimeProblem.bundledMissing("/Timer.app/cli").message])
        #expect(log.all.isEmpty)
    }

    /// Locates the runtime from `located`, logs operations instead of running them, and has no event stream.
    private func services(_ located: AsyncStream<Result<Runtime, RuntimeProblem>>) -> TimerController.Services {
        let log = log
        return TimerController.Services(
            locate: {
                for await result in located { return result }
                return .failure(.nodeMissing)
            },
            perform: { operation, input, _ in log.add("\(operation) \(input.id ?? "")") },
            events: { _ in AsyncStream { $0.finish() } })
    }

    @Test func aDeniedAppNeverRegisters() async {
        let notifications = FakeNotifications(log: log, authorized: false)
        let controller = TimerController(paths: DaemonPaths(dataDir: "/tmp/unused"), alertDaemon: FakeDaemon(log: log), notifications: notifications, sounds: FakeSounds(log: log))
        controller.checkNotifications(ask: true)
        controller.handle(.connected)
        controller.handle(event("subscriber", #"{"subscriberId":"s1"}"#))
        await until { log.all.count >= 1 }
        await controller.alerts.settled()
        #expect(log.all == ["ask"])
        #expect(controller.alerts.registration == .inactive)
    }
}
