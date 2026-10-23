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

    var log: [String] { lock.withLock { entries } }
    /// The subscriber the daemon holds as its handler.
    var handler: String? { lock.withLock { holder } }

    func record(_ entry: String) {
        lock.withLock { entries.append(entry) }
    }

    /// The answers to the next acknowledgements, in order; once used up, each is `.acknowledged`.
    func answerAcks(_ answers: [Result<AlertAcknowledgement, DaemonError>]) {
        lock.withLock { acks = answers }
    }

    func refuseRegistration(_ error: DaemonError?) {
        lock.withLock { registerError = error }
    }

    /// The next registrations, unregistrations and acknowledgements that get no answer, in order.
    func lose(registrations: [Lost] = [], unregistrations: [Lost] = [], acks: [Lost] = []) {
        lock.withLock {
            lostRegistrations = registrations
            lostUnregistrations = unregistrations
            lostAcks = acks
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
}

private func alert(_ id: String?, kind: TimerAlert.Kind = .finish) -> TimerAlert {
    TimerAlert(timerId: "t_1", kind: kind, at: 1_000, alertId: id, ackRequired: id == nil ? nil : true)
}

private let conflict = DaemonError.rejected(status: 409, TimerError(code: "handler_registered", message: "Another alert handler is registered.", issues: nil))

@MainActor
struct AlertHandlerTests {
    let daemon = FakeAlertDaemon()

    func handler(permitted: Bool = true, subscriber: String? = "s1", retryDelay: Duration = .milliseconds(1)) async -> AlertHandler {
        let handler = AlertHandler(daemon: daemon, retryDelay: retryDelay, ackRetryDelay: .milliseconds(1)) { [daemon] in daemon.record("play \($0.alertId ?? "-")") }
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
        let handler = AlertHandler(daemon: daemon, retryDelay: .seconds(600)) { _ in }
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
