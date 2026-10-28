import Foundation
import Testing
@testable import TimerCore

/// Records the daemon calls and plays in one order, keeps the handler the daemon holds, and answers as told.
final class FakeAlertDaemon: AlertHandlerDaemon, @unchecked Sendable {
    /// A request that gets no answer: one the daemon never saw, or one it applied before the reply was lost.
    enum Lost { case beforeApplying, afterApplying }

    private let lock = NSLock()
    private var entries: [String] = []
    private var acks: [Result<AlertAcknowledgement, DaemonError>] = []
    private var registerError: DaemonError?
    private var lostRegistrations: [Lost] = []
    private var lostUnregistrations: [Lost] = []
    private var lostAcks: [Lost] = []
    /// The alerts the daemon handed over; acknowledging one again gets `.acknowledged`.
    private var taken: Set<String> = []
    private var holder: String?
    private var confirmations: [String] = []
    private var lostConfirmations = 0
    private var lostReleases = 0
    private var released: Set<String> = []
    private var duringAck: (@Sendable () async -> Void)?
    private var duringRelease: (@Sendable () async -> Void)?
    private var partAnswers: [Result<Void, DaemonError>] = []
    private var lostParts = 0
    private var finishAnswers: [Result<Void, DaemonError>] = []
    private var lostFinishes = 0
    private var finishesFail = false
    private var partsInLog = false
    private var duringPart: (@Sendable () async -> Void)?

    var log: [String] { lock.withLock { entries } }
    /// The subscriber the daemon holds as its handler.
    var handler: String? { lock.withLock { holder } }
    /// Each "received" the app sent, as "<alertId> <subscriberId>", kept apart from `log`.
    var confirmed: [String] { lock.withLock { confirmations } }

    func record(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    /// The answers to the next acknowledgements, in order; once used up, each is `.acknowledged`.
    func answerAcks(_ answers: [Result<AlertAcknowledgement, DaemonError>]) {
        lock.withLock { acks = answers }
    }

    /// Records in `log` each part the app asks to start, as "playing <alertId> <part>", and each it says it finished, as
    /// "played <alertId> <part>", and answers the next ones as told: `lost` (`lostFinishes`) get no answer, then
    /// `answers` (`finishes`) in order, then 200.
    func answerParts(_ answers: [Result<Void, DaemonError>] = [], lost: Int = 0, finishes: [Result<Void, DaemonError>] = [], lostFinishes: Int = 0) {
        lock.withLock {
            partsInLog = true
            partAnswers = answers
            lostParts = lost
            finishAnswers = finishes
            self.lostFinishes = lostFinishes
        }
    }

    /// Answers every later "played" with a server error, as a daemon that can save neither file does.
    func failEveryFinish() {
        lock.withLock { finishesFail = true }
    }

    /// Runs `action` while the next request to start a part is on its way, before its answer.
    func whileNextPartIsAnswered(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock { duringPart = action }
    }

    /// Runs `action` while the next acknowledgement is on its way, before its answer.
    func whileNextAckIsAnswered(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock { duringAck = action }
    }

    /// Runs `action` while the next handback is on its way, before the daemon takes it.
    func whileNextReleaseIsAnswered(_ action: @escaping @Sendable () async -> Void) {
        lock.withLock { duringRelease = action }
    }

    func refuseRegistration(_ error: DaemonError?) {
        lock.withLock { registerError = error }
    }

    /// The next registrations, unregistrations and acknowledgements that get no answer, in order, and how many of the
    /// next confirmations and handbacks get none.
    func lose(registrations: [Lost] = [], unregistrations: [Lost] = [], acks: [Lost] = [], confirmations: Int = 0, releases: Int = 0) {
        lock.withLock {
            lostRegistrations = registrations
            lostUnregistrations = unregistrations
            lostAcks = acks
            lostConfirmations = confirmations
            lostReleases = releases
        }
    }

    func registerAlertHandler(subscriberId: String) async throws {
        record("register \(subscriberId)")
        if let error = lock.withLock({ registerError }) { throw error }
        let lost = lock.withLock { lostRegistrations.isEmpty ? nil : lostRegistrations.removeFirst() }
        if lost == .beforeApplying { throw DaemonError.timedOut }
        lock.withLock { holder = subscriberId }
        if lost == .afterApplying { throw DaemonError.timedOut }
    }

    func unregisterAlertHandler(subscriberId: String) async throws {
        record("unregister \(subscriberId)")
        let lost = lock.withLock { lostUnregistrations.isEmpty ? nil : lostUnregistrations.removeFirst() }
        if lost == .beforeApplying { throw DaemonError.connectionFailed("reset") }
        lock.withLock { if holder == subscriberId { holder = nil } }
        if lost == .afterApplying { throw DaemonError.connectionFailed("reset") }
    }

    func acknowledgeAlert(_ alertId: String, subscriberId: String) async throws -> AlertAcknowledgement {
        record("ack \(alertId) \(subscriberId)")
        if let action = lock.withLock({ duringAck.take() }) { await action() }
        let answer: Result<AlertAcknowledgement, DaemonError> = lock.withLock {
            switch lostAcks.isEmpty ? nil : lostAcks.removeFirst() {
            case .beforeApplying?:
                return .failure(.timedOut)
            case .afterApplying?:
                taken.insert(alertId)
                return .failure(.timedOut)
            case nil:
                if taken.contains(alertId) { return .success(.acknowledged) }
                let answer = acks.isEmpty ? .success(.acknowledged) : acks.removeFirst()
                if case .success(.acknowledged) = answer { taken.insert(alertId) }
                return answer
            }
        }
        return try answer.get()
    }

    func startPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws {
        let (logged, answer): (Bool, Result<Void, DaemonError>) = lock.withLock {
            if lostParts > 0 {
                lostParts -= 1
                return (partsInLog, .failure(.timedOut))
            }
            return (partsInLog, partAnswers.isEmpty ? .success(()) : partAnswers.removeFirst())
        }
        if logged { record("playing \(alertId) \(part.name)") }
        if let action = lock.withLock({ duringPart.take() }) { await action() }
        try answer.get()
    }

    func finishPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws {
        let (logged, answer): (Bool, Result<Void, DaemonError>) = lock.withLock {
            if lostFinishes > 0 {
                lostFinishes -= 1
                return (partsInLog, .failure(.timedOut))
            }
            if finishesFail { return (partsInLog, .failure(storageFailed)) }
            return (partsInLog, finishAnswers.isEmpty ? .success(()) : finishAnswers.removeFirst())
        }
        if logged { record("played \(alertId) \(part.name)") }
        try answer.get()
    }

    func confirmAlert(_ alertId: String, subscriberId: String) async throws {
        let lost = lock.withLock {
            confirmations.append("\(alertId) \(subscriberId)")
            guard lostConfirmations > 0 else { return false }
            lostConfirmations -= 1
            return true
        }
        if lost { throw DaemonError.timedOut }
    }

    /// Hands the alert back: the daemon's sink plays it ("sink <alertId>"), once, whether it was taken or still pending.
    func releaseAlert(_ alertId: String, subscriberId: String) async throws {
        record("release \(alertId) \(subscriberId)")
        if let action = lock.withLock({ duringRelease.take() }) { await action() }
        let lost = lock.withLock {
            guard lostReleases > 0 else { return false }
            lostReleases -= 1
            return true
        }
        if lost { throw DaemonError.timedOut }
        if lock.withLock({ released.insert(alertId).inserted }) { record("sink \(alertId)") }
    }
}

/// A finish with sound off, so its one part is its notification and it plays once.
private func alert(_ id: String?, kind: TimerAlert.Kind = .finish) -> TimerAlert {
    TimerAlert(timerId: "t_1", kind: kind, at: 1_000, alertId: id, ackRequired: id == nil ? nil : true, sound: false)
}

/// A finish with sound on: its notification, then Glass three times.
private func finishWithSound(_ id: String) -> TimerAlert {
    TimerAlert(timerId: "t_1", kind: .finish, at: 1_000, alertId: id, ackRequired: true)
}

private let expired = DaemonError.rejected(status: 410, TimerError(code: "alert_expired", message: "", issues: nil))

private let storageFailed = DaemonError.rejected(status: 500, TimerError(code: "storage_failed", message: "", issues: nil))

/// What a `play` throws for a part it could not present.
private struct NotPresented: Error {}

private let conflict = DaemonError.rejected(status: 409, TimerError(code: "handler_registered", message: "Another alert handler is registered.", issues: nil))

@MainActor
private final class Permission {
    var granted = true
}

/// The app's quit, started while a request is on its way.
@MainActor
private final class Quitting {
    var task: Task<Void, Never>?
}

/// The handler under test, for a `play` that acts on it.
@MainActor
private final class HandlerBox {
    var handler: AlertHandler?
}

@MainActor
struct AlertHandlerTests {
    let daemon = FakeAlertDaemon()

    func handler(permitted: Bool = true, subscriber: String? = "s1", retryDelay: Duration = .milliseconds(1)) async -> AlertHandler {
        let handler = AlertHandler(daemon: daemon, retryDelay: retryDelay, ackRetryDelay: .milliseconds(1)) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(permitted)
        handler.subscribed(subscriber)
        await handler.settled()
        return handler
    }

    @Test func itAcknowledgesBeforePlaying() async {
        let handler = await handler()
        #expect(handler.registration == .registered)
        await handler.receive(alert("a1"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "play a1"])
    }

    @Test func nothingPlaysAfterTheDaemonAnswers410() async {
        let handler = await handler()
        daemon.answerAcks([.success(.expired)])
        await handler.receive(alert("a1"))
        #expect(daemon.log == ["register s1", "ack a1 s1"])
    }

    @Test func anAlertHandedToAnotherHandlerOrNotAskingForAnAckIsNotPlayed() async {
        let handler = await handler()
        daemon.answerAcks([.failure(.rejected(status: 409, TimerError(code: "not_alert_handler", message: "", issues: nil)))])
        await handler.receive(alert("a1"))
        await handler.receive(alert(nil))
        #expect(daemon.log == ["register s1", "ack a1 s1"])
    }

    @Test func anAcknowledgementTheDaemonTookIsSentUntilAnsweredAndPlaysOnce() async {
        let handler = await handler()
        // The daemon took the acknowledgement, and its reply was lost three times.
        daemon.lose(acks: [.afterApplying, .afterApplying, .afterApplying])
        await handler.receive(alert("a1"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "ack a1 s1", "ack a1 s1", "ack a1 s1", "play a1"])
    }

    @Test func afterPlayingItTellsTheDaemonItReceivedTheAnswerUntilADaemonHearsIt() async {
        let handler = await handler()
        daemon.lose(confirmations: 2)
        await handler.receive(alert("a1"))
        daemon.answerAcks([.success(.expired)])
        await handler.receive(alert("a2"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "play a1", "ack a2 s1"])
        #expect(daemon.confirmed == ["a1 s1", "a1 s1", "a1 s1"])
    }

    @Test func anAcknowledgementIsSentForTheStreamTheAlertCameOnAfterTheStreamReconnects() async {
        let handler = AlertHandler(daemon: daemon, ackRetryDelay: .milliseconds(20)) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.lose(acks: Array(repeating: .afterApplying, count: 5))
        let receiving = Task { await handler.receive(alert("a1")) }
        for _ in 0..<500 where !daemon.log.contains("ack a1 s1") { try? await Task.sleep(nanoseconds: 1_000_000) }
        handler.subscribed("s2")
        await handler.settled()
        await receiving.value
        let log = daemon.log
        #expect(log.filter { $0.hasPrefix("ack") }.allSatisfy { $0 == "ack a1 s1" })
        #expect(log.lastIndex(of: "ack a1 s1")! > log.firstIndex(of: "register s2")!)
        #expect(log.filter { $0 == "play a1" }.count == 1 && daemon.confirmed == ["a1 s1"])
    }

    @Test func anAcknowledgementTheDaemonNeverSawIsSentUntilItsSinkPlayedTheAlertAndNeverPlays() async {
        let handler = await handler()
        daemon.lose(acks: [.beforeApplying, .beforeApplying])
        daemon.answerAcks([.success(.expired)])
        await handler.receive(alert("a1"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "ack a1 s1", "ack a1 s1"])
    }

    @Test func anAcknowledgementIsSentUntilADaemonAnswersItAcrossAFailedSaveAndARestart() async {
        let handler = await handler()
        let failedSave = DaemonError.rejected(status: 500, TimerError(code: "storage_failed", message: "", issues: nil))
        let notFound = DaemonError.rejected(status: 404, TimerError(code: "not_found", message: "", issues: nil))
        // a1: a failed save, then the daemon shuts down and is gone until the next one answers from its saved
        // acknowledgement. a2: the next daemon played it at startup. a3: handed to another stream.
        daemon.answerAcks([.failure(failedSave), .failure(.shuttingDown), .failure(.notListening), .success(.acknowledged),
                           .failure(.notListening), .failure(notFound), .failure(.shuttingDown), .failure(conflict)])
        await handler.receive(alert("a1"))
        await handler.receive(alert("a2"))
        await handler.receive(alert("a3"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "ack a1 s1", "ack a1 s1", "ack a1 s1", "play a1",
                               "ack a2 s1", "ack a2 s1", "ack a3 s1", "ack a3 s1"])
    }

    @Test func permissionRevokedWithoutACheckIsSeenBeforeTheAckAndHandsAlertsBackToTheDaemon() async {
        let permission = Permission()
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1),
                                   isPermitted: { permission.granted }) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        await handler.receive(alert("a1"))
        // Revoked in System Settings: no activation or menu check has run since.
        permission.granted = false
        await handler.receive(alert("a2"))
        await handler.settled()
        #expect(handler.registration == .inactive)
        #expect(daemon.log == ["register s1", "ack a1 s1", "play a1", "unregister s1"])
    }

    /// Revoked while an acknowledgement is on its way: answered after all (held), its answer lost after the daemon took
    /// it, or lost before the daemon saw it. The app plays nothing and hands the alert back, so the daemon's sink plays it.
    @Test(arguments: [nil, FakeAlertDaemon.Lost.afterApplying, .beforeApplying])
    func permissionRevokedWhileAnAckIsAnsweredHandsTheAlertBackSoItPlaysOnce(_ lost: FakeAlertDaemon.Lost?) async {
        let permission = Permission()
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1),
                                   isPermitted: { permission.granted }) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        if let lost { daemon.lose(acks: [lost]) }
        daemon.whileNextAckIsAnswered { await MainActor.run { permission.granted = false } }
        await handler.receive(alert("a1", kind: .finish))
        await handler.settled()
        #expect(handler.registration == .inactive)
        // It unregisters as soon as it sees the revocation, while the handback is on its way.
        #expect(daemon.log.prefix(2) == ["register s1", "ack a1 s1"])
        #expect(daemon.log.dropFirst(2).sorted() == ["release a1 s1", "sink a1", "unregister s1"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Permission granted again while a handback is still on its way: the handback still goes through, so the daemon's
    /// sink plays that alert, and the newer grant is kept, so the app is the handler again afterwards.
    @Test func permissionGrantedAgainWhileAnAlertIsHandedBackKeepsTheAppRegistered() async {
        let permission = Permission()
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1),
                                   isPermitted: { permission.granted }) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.whileNextAckIsAnswered { await MainActor.run { permission.granted = false } }
        daemon.whileNextReleaseIsAnswered {
            await MainActor.run {
                permission.granted = true
                handler.setPermitted(true)
            }
        }
        await handler.receive(alert("a1", kind: .finish))
        await handler.settled()
        #expect(handler.registration == .registered)
        #expect(daemon.handler == "s1")
        #expect(daemon.log.filter { $0.hasPrefix("sink") || $0.hasPrefix("play") } == ["sink a1"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Quit while an acknowledgement is on its way: answered after all (held), its answer lost after the daemon took it,
    /// or lost before the daemon saw it. The app plays nothing and hands the alert back, sent again until a daemon answers,
    /// so the daemon's sink plays it once, and quitting returns only after that.
    @Test(arguments: [nil, FakeAlertDaemon.Lost.afterApplying, .beforeApplying])
    func quittingWhileAnAckIsAnsweredHandsTheAlertBackBeforeTheAppEnds(_ lost: FakeAlertDaemon.Lost?) async {
        let handler = await handler()
        let quitting = Quitting()
        if let lost { daemon.lose(acks: [lost], releases: 2) } else { daemon.lose(releases: 2) }
        daemon.whileNextAckIsAnswered { [daemon] in
            await MainActor.run {
                quitting.task = Task {
                    await handler.quit()
                    daemon.record("quit")
                }
            }
            // Quitting has begun once the app unregisters.
            for _ in 0..<2_000 where !daemon.log.contains("unregister s1") { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        await handler.receive(alert("a1"))
        await quitting.task?.value
        await handler.settled()
        #expect(handler.registration == .inactive)
        #expect(daemon.log.prefix(2) == ["register s1", "ack a1 s1"])
        #expect(daemon.log.dropFirst(2).filter { $0 != "unregister s1" }
            == ["release a1 s1", "release a1 s1", "release a1 s1", "sink a1", "quit"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Once quitting, an alert is not acknowledged, so the daemon plays it, and a permission check that grants it does not
    /// make the app the handler again. With nothing to hand back, quitting returns at once.
    @Test func anAlertArrivingWhileQuittingIsLeftToTheDaemon() async {
        let handler = await handler()
        await handler.quit()
        await handler.receive(alert("a1"))
        handler.setPermitted(true)
        await handler.settled()
        #expect(handler.registration == .inactive)
        #expect(daemon.log == ["register s1", "unregister s1"])
    }

    /// Quitting after playing an alert waits until a daemon hears that the app received it, so the daemon never plays it
    /// too once the app's stream is gone.
    @Test func quittingWaitsUntilTheDaemonHearsTheAppReceivedAnAlertItPlayed() async {
        let handler = AlertHandler(daemon: daemon, ackRetryDelay: .milliseconds(20)) { [daemon] alert, _ in daemon.record("play \(alert.alertId ?? "-")") }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.lose(confirmations: 3)
        let receiving = Task { await handler.receive(alert("a1")) }
        for _ in 0..<2_000 where !daemon.log.contains("play a1") { try? await Task.sleep(nanoseconds: 1_000_000) }
        await handler.quit()
        daemon.record("quit after \(daemon.confirmed.count) receipts")
        await receiving.value
        #expect(daemon.log.filter { $0.hasPrefix("play") || $0.hasPrefix("quit") } == ["play a1", "quit after 4 receipts"])
    }

    /// A handback no daemon answers does not hold up quitting past its bound; the daemon's sink plays the alert once the
    /// app's stream has been gone 30 s (alert-handlers.test.mjs).
    @Test func quittingReturnsAtItsBoundWhenNoDaemonAnswersTheHandback() async {
        let handler = await handler()
        let quitting = Quitting()
        daemon.lose(releases: .max)
        daemon.whileNextAckIsAnswered { [daemon] in
            await MainActor.run { quitting.task = Task { await handler.quit(within: .milliseconds(50)) } }
            for _ in 0..<2_000 where !daemon.log.contains("unregister s1") { try? await Task.sleep(nanoseconds: 1_000_000) }
        }
        let receiving = Task { await handler.receive(alert("a1")) }
        for _ in 0..<2_000 where quitting.task == nil { try? await Task.sleep(nanoseconds: 1_000_000) }
        await quitting.task?.value
        #expect(!daemon.log.contains("sink a1") && !daemon.log.contains("play a1"))
        // The app would end here; in this test the handback is answered later.
        daemon.lose()
        await receiving.value
        #expect(daemon.log.filter { $0 == "sink a1" || $0 == "play a1" } == ["sink a1"])
    }

    @Test func itRegistersOnlyWhilePermittedAndUnregistersWhenPermissionIsRevoked() async {
        let handler = await handler(permitted: false)
        #expect(daemon.log.isEmpty)
        #expect(handler.registration == .inactive)
        // Without permission an alert is left to the daemon.
        await handler.receive(alert("a0"))
        #expect(daemon.log.isEmpty)

        handler.setPermitted(true)
        await handler.settled()
        #expect(handler.registration == .registered)
        handler.setPermitted(false)
        await handler.settled()
        #expect(handler.registration == .inactive)
        await handler.receive(alert("a1"))
        #expect(daemon.log == ["register s1", "unregister s1"])
    }

    @Test func aNewEventStreamRegistersAgainWithoutUnregisteringTheClosedOne() async {
        let handler = await handler()
        handler.subscribed(nil)
        await handler.settled()
        #expect(handler.registration == .inactive)
        await handler.receive(alert("a1"))
        handler.subscribed("s2")
        await handler.settled()
        #expect(daemon.log == ["register s1", "register s2"])
        #expect(handler.registration == .registered)
    }

    @Test func aRefusedRegistrationIsReportedAndTriedAgainAtTheNextCheck() async {
        daemon.refuseRegistration(conflict)
        let handler = await handler()
        #expect(handler.registration == .refused("Another alert handler is registered."))
        daemon.refuseRegistration(nil)
        handler.setPermitted(true)
        await handler.settled()
        #expect(handler.registration == .registered)
        #expect(daemon.log == ["register s1", "register s1"])
    }

    @Test(arguments: [FakeAlertDaemon.Lost.beforeApplying, .afterApplying])
    func anUnregistrationTheDaemonDidNotAnswerIsSentAgainUntilItIs(_ lost: FakeAlertDaemon.Lost) async {
        let handler = await handler()
        daemon.lose(unregistrations: [lost, lost])
        handler.setPermitted(false)
        await handler.settled()
        // Revoked permission means the daemon must not keep this app as its handler.
        #expect(daemon.handler == nil)
        #expect(daemon.log == ["register s1", "unregister s1", "unregister s1", "unregister s1"])
        #expect(handler.registration == .inactive)
        // Once the daemon has answered, later checks send nothing.
        handler.setPermitted(false)
        await handler.settled()
        #expect(daemon.log.count == 4)
    }

    @Test func aRegistrationWhoseAnswerWasLostIsUnregisteredWhenPermissionIsRevoked() async {
        daemon.lose(registrations: [.afterApplying])
        // No timed retry during the test, so `settled()` would wait for it: only the permission check acts.
        let handler = AlertHandler(daemon: daemon, retryDelay: .seconds(600)) { _, _ in }
        handler.setPermitted(true)
        handler.subscribed("s1")
        for _ in 0..<500 where handler.registration == .inactive { try? await Task.sleep(nanoseconds: 2_000_000) }
        #expect(daemon.handler == "s1")
        #expect(handler.registration == .refused(DaemonError.timedOut.localizedDescription))
        handler.setPermitted(false)
        await handler.settled()
        #expect(daemon.handler == nil)
        #expect(daemon.log == ["register s1", "unregister s1"])
        #expect(handler.registration == .inactive)
    }

    @Test(arguments: [FakeAlertDaemon.Lost.beforeApplying, .afterApplying])
    func aRegistrationWhoseAnswerWasLostIsSentAgainWhilePermitted(_ lost: FakeAlertDaemon.Lost) async {
        daemon.lose(registrations: [lost])
        let handler = await handler()
        #expect(daemon.handler == "s1")
        #expect(daemon.log == ["register s1", "register s1"])
        #expect(handler.registration == .registered)
    }

    private func partsHandler(permission: Permission = Permission(), reportBound: Duration = .seconds(5),
                              refusing refused: AlertPart? = nil) async -> AlertHandler {
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1), reportBound: reportBound,
                                   isPermitted: { permission.granted }) { [daemon] alert, part in
            if part == refused { throw NotPresented() }
            daemon.record("play \(alert.alertId ?? "-") \(part.name)")
            await Task.yield()
        }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.answerParts()
        return handler
    }

    @Test func anAlertsPartsAreItsNotificationThenItsSounds() {
        #expect(AlertPart.plan(for: finishWithSound("a1")).map(\.name) == ["notification", "sound:0", "sound:1", "sound:2"])
        #expect(AlertPart.plan(for: alert("a1")) == [.notification])
        #expect(AlertPart.plan(for: TimerAlert(timerId: "t_1", kind: .tick, at: 1, secondsLeft: 3)) == [.sound(0)])
        #expect(AlertPart.plan(for: TimerAlert(timerId: "t_1", kind: .segment, at: 1, sound: false)).isEmpty)
        #expect(AlertPart.plan(for: TimerAlert(timerId: "t_1", kind: .missedWhileAway, at: 1, missed: 2)) == [.notification])
    }

    /// The app asks before each part and says once each finished, so the sink of a daemon whose app ended before saying
    /// it received the alert plays only the parts the app did not finish (play-journal.test.mjs).
    @Test func eachPartIsAskedForBeforeItPlaysAndRecordedOnceItFinishedAndTheReceiptFollowsTheLast() async {
        let handler = await partsHandler()
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.dropFirst() == ["ack a1 s1",
                                           "playing a1 notification", "play a1 notification", "played a1 notification",
                                           "playing a1 sound:0", "play a1 sound:0", "played a1 sound:0",
                                           "playing a1 sound:1", "play a1 sound:1", "played a1 sound:1",
                                           "playing a1 sound:2", "play a1 sound:2", "played a1 sound:2"])
        #expect(daemon.confirmed == ["a1 s1"])
    }

    /// A part whose answer was lost is asked for again until a daemon answers, then played once; a finished part is said
    /// again until a daemon records it, before the next part.
    @Test func aPartWhoseAnswerWasLostIsSentAgainAndPlaysOnce() async {
        let handler = await partsHandler()
        daemon.answerParts(lost: 2, lostFinishes: 2)
        await handler.receive(alert("a1"))
        #expect(daemon.log.dropFirst() == ["ack a1 s1", "playing a1 notification", "playing a1 notification", "playing a1 notification",
                                           "play a1 notification", "played a1 notification", "played a1 notification", "played a1 notification"])
        #expect(daemon.confirmed == ["a1 s1"])
    }

    /// A daemon that cannot record a finished part (500 every time) does not hold back the rest of the alert: the app says
    /// so for up to its bound, then plays the next part.
    @Test func aFinishedPartNoDaemonRecordsDoesNotHoldBackTheRest() async {
        let handler = await partsHandler(reportBound: .milliseconds(20))
        daemon.failEveryFinish()
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.filter { $0.hasPrefix("play a1") } == ["play a1 notification", "play a1 sound:0", "play a1 sound:1", "play a1 sound:2"])
        #expect(daemon.log.filter { $0 == "played a1 notification" }.count > 1)
        #expect(daemon.confirmed == ["a1 s1"])
    }

    /// A part the app could not present (the notification center refused the notification) is not reported finished: the
    /// app hands the alert back, so the daemon's sink presents it and the parts after it.
    @Test func aPartTheAppCouldNotPresentIsHandedBack() async {
        let handler = await partsHandler(refusing: .notification)
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.filter { !$0.hasPrefix("register") && !$0.hasPrefix("unregister") } ==
                ["ack a1 s1", "playing a1 notification", "release a1 s1", "sink a1"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Permission revoked while the request to start a part is retried, or while its answer is on its way: the app shows
    /// nothing more and hands the alert back, so the daemon's sink plays the parts it did not finish.
    @Test(arguments: [0, 1])
    func permissionRevokedWhileAPartIsAskedForHandsTheAlertBackUnplayed(lost: Int) async {
        let permission = Permission()
        let handler = await partsHandler(permission: permission)
        daemon.answerParts(lost: lost)
        daemon.whileNextPartIsAnswered { await MainActor.run { permission.granted = false } }
        await handler.receive(alert("a1"))
        #expect(daemon.log.filter { !$0.hasPrefix("register") && !$0.hasPrefix("unregister") } ==
                ["ack a1 s1", "playing a1 notification", "release a1 s1", "sink a1"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Once the daemon's sink has played the alert, saying a part finished is refused (410): the app plays no more of it.
    @Test func aRefusedFinishStopsTheAlert() async {
        let handler = await partsHandler()
        daemon.answerParts(finishes: [.failure(expired)])
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.filter { $0.hasPrefix("play a1") } == ["play a1 notification"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Once the daemon's sink has played the alert (410, after the app stalled 30 s), the app plays no more of it and
    /// sends no receipt.
    @Test func aRefusedPartStopsTheAlert() async {
        let handler = await partsHandler()
        daemon.answerParts([.success(()), .success(()), .failure(expired)])
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.filter { $0.hasPrefix("play a1") } == ["play a1 notification", "play a1 sound:0"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Permission revoked mid-alert: the app finishes the part it is playing and says so, then hands the alert back, so the
    /// daemon's sink plays the parts it did not finish.
    @Test func permissionRevokedMidAlertHandsTheRestBack() async {
        let permission = Permission()
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1),
                                   isPermitted: { permission.granted }) { [daemon] alert, part in
            daemon.record("play \(alert.alertId ?? "-") \(part.name)")
            if part == .sound(0) { permission.granted = false }
        }
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.answerParts()
        await handler.receive(finishWithSound("a1"))
        #expect(daemon.log.filter { $0.hasPrefix("play") || $0.hasPrefix("release") || $0.hasPrefix("sink") } ==
                ["playing a1 notification", "play a1 notification", "played a1 notification", "playing a1 sound:0", "play a1 sound:0",
                 "played a1 sound:0", "release a1 s1", "sink a1"])
        #expect(daemon.confirmed.isEmpty)
    }

    /// Quitting mid-alert: the app finishes the part it is playing, says so and hands the rest back before quitting returns.
    @Test func quittingMidAlertHandsTheRestBackBeforeItReturns() async {
        let quitting = Quitting()
        let box = HandlerBox()
        let handler = AlertHandler(daemon: daemon, retryDelay: .milliseconds(1), ackRetryDelay: .milliseconds(1)) { [daemon] alert, part in
            daemon.record("play \(alert.alertId ?? "-") \(part.name)")
            guard part == .sound(0), let handler = box.handler else { return }
            // The user quits while the first Glass plays.
            quitting.task = Task {
                await handler.quit()
                daemon.record("quit")
            }
            try? await Task.sleep(for: .milliseconds(20))
        }
        box.handler = handler
        handler.setPermitted(true)
        handler.subscribed("s1")
        await handler.settled()
        daemon.answerParts()
        await handler.receive(finishWithSound("a1"))
        await quitting.task?.value
        #expect(daemon.log.filter { $0.hasPrefix("play") || $0.hasPrefix("release") || $0.hasPrefix("quit") } ==
                ["playing a1 notification", "play a1 notification", "played a1 notification", "playing a1 sound:0", "play a1 sound:0",
                 "played a1 sound:0", "release a1 s1", "quit"])
        #expect(daemon.confirmed.isEmpty)
    }

    @Test func theDaemonsAlertDecodes() throws {
        let json = #"{"timerId":"t_2","kind":"tick","secondsLeft":3,"at":5,"segment":{"index":1,"round":1,"phase":"work","label":"Work","durationMs":20000},"alertId":"ab12","ackRequired":true,"timerName":"Tabata","sound":false}"#
        let decoded = try JSONDecoder().decode(TimerAlert.self, from: Data(json.utf8))
        #expect(decoded == TimerAlert(timerId: "t_2", kind: .tick, at: 5, segment: .init(index: 1, round: 1, phase: .work, label: "Work", durationMs: 20_000),
                                      secondsLeft: 3, alertId: "ab12", ackRequired: true, timerName: "Tabata", sound: false))
        let missed = try JSONDecoder().decode(TimerAlert.self, from: Data(#"{"timerId":"t_2","kind":"missedWhileAway","missed":4,"at":9}"#.utf8))
        #expect(missed.missed == 4 && missed.ackRequired == nil)
    }

    @Test func idsArePercentEncodedAsOnePathSegment() {
        #expect(DaemonClient.pathSegment("0f9a") == "0f9a")
        #expect(DaemonClient.pathSegment("a/b c") == "a%2Fb%20c")
    }
}
