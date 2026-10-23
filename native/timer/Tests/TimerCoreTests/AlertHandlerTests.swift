import Foundation
import Testing
@testable import TimerCore

/// Records the daemon calls and plays in one order, and answers acknowledgements as told.
final class FakeAlertDaemon: AlertHandlerDaemon, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    private var acks: [Result<AlertAcknowledgement, DaemonError>] = []
    private var registerError: DaemonError?

    var log: [String] { lock.withLock { entries } }

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

    func registerAlertHandler(subscriberId: String) async throws {
        record("register \(subscriberId)")
        if let error = lock.withLock({ registerError }) { throw error }
    }

    func unregisterAlertHandler(subscriberId: String) async throws {
        record("unregister \(subscriberId)")
    }

    func acknowledgeAlert(_ alertId: String, subscriberId: String) async throws -> AlertAcknowledgement {
        record("ack \(alertId) \(subscriberId)")
        let answer = lock.withLock { acks.isEmpty ? .success(.acknowledged) : acks.removeFirst() }
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

    func handler(permitted: Bool = true, subscriber: String? = "s1") async -> AlertHandler {
        let handler = AlertHandler(daemon: daemon) { [daemon] in daemon.record("play \($0.alertId ?? "-")") }
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

    @Test func aFailedAcknowledgementIsTriedOnceMoreAndPlaysOnlyOnTheDaemonsYes() async {
        let handler = await handler()
        daemon.answerAcks([.failure(.timedOut), .success(.acknowledged), .failure(.timedOut), .success(.expired),
                           .failure(.timedOut), .failure(.connectionFailed("gone"))])
        await handler.receive(alert("a1"))
        await handler.receive(alert("a2"))
        await handler.receive(alert("a3"))
        #expect(daemon.log == ["register s1", "ack a1 s1", "ack a1 s1", "play a1", "ack a2 s1", "ack a2 s1", "ack a3 s1", "ack a3 s1"])
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

    @Test func theDaemonsAlertDecodes() throws {
        let json = #"{"timerId":"t_2","kind":"tick","secondsLeft":3,"at":5,"segment":{"index":1,"round":1,"phase":"work","label":"Work","durationMs":20000},"alertId":"ab12","ackRequired":true}"#
        let decoded = try JSONDecoder().decode(TimerAlert.self, from: Data(json.utf8))
        #expect(decoded == TimerAlert(timerId: "t_2", kind: .tick, at: 5, segment: .init(index: 1, round: 1, phase: .work, label: "Work", durationMs: 20_000),
                                      secondsLeft: 3, alertId: "ab12", ackRequired: true))
        let missed = try JSONDecoder().decode(TimerAlert.self, from: Data(#"{"timerId":"t_2","kind":"missedWhileAway","missed":4,"at":9}"#.utf8))
        #expect(missed.missed == 4 && missed.ackRequired == nil)
    }

    @Test func idsArePercentEncodedAsOnePathSegment() {
        #expect(DaemonClient.pathSegment("0f9a") == "0f9a")
        #expect(DaemonClient.pathSegment("a/b c") == "a%2Fb%20c")
    }
}
