import Foundation

/// An `alert` event (packages/timer-cli/src/daemon/alerts.mjs). While an alert handler is registered, the daemon adds
/// `alertId`, `ackRequired`, and the timer's `timerName` and `sound` as they were when the alert fell due
/// (alert-handlers.mjs).
public struct TimerAlert: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case segment, tick, finish, missedWhileAway
    }

    /// The interval step that began (`segment`), is ending (`tick`), or is current (`missedWhileAway`).
    public struct Step: Codable, Equatable, Sendable {
        public var index: Int
        public var round: Int?
        public var phase: Phase
        public var label: String
        public var durationMs: Int
    }

    public var timerId: String
    public var kind: Kind
    public var at: Int
    public var segment: Step?
    public var secondsLeft: Int?
    public var missed: Int?
    public var alertId: String?
    public var ackRequired: Bool?
    public var timerName: String?
    public var sound: Bool?

    public init(timerId: String, kind: Kind, at: Int, segment: Step? = nil, secondsLeft: Int? = nil, missed: Int? = nil,
                alertId: String? = nil, ackRequired: Bool? = nil, timerName: String? = nil, sound: Bool? = nil) {
        self.timerId = timerId
        self.kind = kind
        self.at = at
        self.segment = segment
        self.secondsLeft = secondsLeft
        self.missed = missed
        self.alertId = alertId
        self.ackRequired = ackRequired
        self.timerName = timerName
        self.sound = sound
    }
}

/// The daemon's answer to an acknowledgement.
public enum AlertAcknowledgement: Equatable, Sendable {
    /// The handler owns the alert and plays it.
    case acknowledged
    /// The daemon's own sink already played it (410); the handler must not.
    case expired
}

/// The daemon's alert handler routes, so tests can substitute a fake.
public protocol AlertHandlerDaemon: Sendable {
    func registerAlertHandler(subscriberId: String) async throws
    func unregisterAlertHandler(subscriberId: String) async throws
    func acknowledgeAlert(_ alertId: String, subscriberId: String) async throws -> AlertAcknowledgement
    func confirmAlert(_ alertId: String, subscriberId: String) async throws
    func releaseAlert(_ alertId: String, subscriberId: String) async throws
}

extension DaemonClient: AlertHandlerDaemon {
    private struct SubscriberBody: Encodable { var subscriberId: String }
    private struct Ignored: Decodable {}

    /// `POST /v1/alert-handlers`: makes the event stream `subscriberId` the one alert handler. A 409 means another is.
    public func registerAlertHandler(subscriberId: String) async throws {
        let reply = try await send("POST", "/v1/alert-handlers", body: try JSONEncoder().encode(SubscriberBody(subscriberId: subscriberId)))
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// `DELETE /v1/alert-handlers/<subscriberId>`. The daemon's sink plays any alert still waiting for an acknowledgement.
    public func unregisterAlertHandler(subscriberId: String) async throws {
        let reply = try await send("DELETE", "/v1/alert-handlers/\(Self.pathSegment(subscriberId))")
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// `POST /v1/alerts/<alertId>/ack`. Acknowledging again gets the same answer, so a retry is safe.
    public func acknowledgeAlert(_ alertId: String, subscriberId: String) async throws -> AlertAcknowledgement {
        let reply = try await send("POST", "/v1/alerts/\(Self.pathSegment(alertId))/ack",
                                   body: try JSONEncoder().encode(SubscriberBody(subscriberId: subscriberId)))
        if reply.status == 410 { return .expired }
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
        return .acknowledged
    }

    /// `POST /v1/alerts/<alertId>/received`: the app read the 200 for that alert, so the daemon stops keeping it.
    public func confirmAlert(_ alertId: String, subscriberId: String) async throws {
        let reply = try await send("POST", "/v1/alerts/\(Self.pathSegment(alertId))/received",
                                   body: try JSONEncoder().encode(SubscriberBody(subscriberId: subscriberId)))
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// `POST /v1/alerts/<alertId>/release`: the app hands back an alert it may no longer present, and the daemon's sink
    /// plays it. A 410 means the sink already played it, which is the same outcome.
    public func releaseAlert(_ alertId: String, subscriberId: String) async throws {
        let reply = try await send("POST", "/v1/alerts/\(Self.pathSegment(alertId))/release",
                                   body: try JSONEncoder().encode(SubscriberBody(subscriberId: subscriberId)))
        if reply.status == 410 { return }
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// An id as one path segment: the daemon's ids are hex, and anything else is percent-encoded.
    static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }
}

/// Makes the app the daemon's single alert handler while it may post notifications, and plays an alert only after the
/// daemon has handed it over. The app registers its current event stream only while permission is granted; the daemon
/// unregisters it when that stream closes. For each alert that asks for acknowledgement, the app acknowledges first and
/// plays only on `.acknowledged`: an alert the daemon's sink already played (410), or that the daemon handed to someone
/// else, is never played here, so every alert plays exactly once. Quitting (`quit(within:)`) hands back every alert the
/// app may have taken and not played, and waits until the daemon hears the app received each one it played. The daemon's
/// sink plays an alert the app took and never said it received 30 s after the app's stream closed
/// (`ORPHANED_ALERT_MS`), so an alert is not lost when the app ends.
@MainActor
public final class AlertHandler {
    public enum Registration: Equatable, Sendable {
        /// Not registered: no permission or no event stream, so the daemon plays alerts itself.
        case inactive
        case registered
        /// The daemon refused the registration, for example because another handler is registered (409).
        case refused(String)
    }

    public private(set) var registration = Registration.inactive
    /// Called after `registration` changes.
    public var onChange: () -> Void = {}

    private let daemon: AlertHandlerDaemon
    private let play: (TimerAlert) -> Void
    private let isPermitted: @MainActor () async -> Bool
    private let retryDelay: Duration
    private let ackRetryDelay: Duration
    private var subscriberId: String?
    private var permitted = false
    /// The stream the daemon may hold as its handler: `confirmed` once the daemon said so, unconfirmed while a request
    /// that may have registered it got no answer. Either way it is unregistered before the app counts as unregistered.
    private var claim: (id: String, confirmed: Bool)?
    private var reconciling: Task<Void, Never>?
    private var retrying: Task<Void, Never>?
    /// Set once the app is quitting: it takes no alert and registers no more.
    private var quitting = false
    /// Alerts the daemon may have handed over that the app has not handed back, or played and said it received, which
    /// quitting waits for.
    private var unsettled = 0
    private var waitingToQuit: [CheckedContinuation<Void, Never>] = []

    /// `play` presents an alert the app has taken over. A registration request the daemon did not answer is tried again
    /// after `retryDelay`, and at the next permission check; an acknowledgement, after `ackRetryDelay`. `isPermitted`
    /// reads whether the app may still post notifications, before each acknowledgement and before playing.
    public init(daemon: AlertHandlerDaemon, retryDelay: Duration = .seconds(2), ackRetryDelay: Duration = .milliseconds(250),
                isPermitted: @escaping @MainActor () async -> Bool = { true }, play: @escaping (TimerAlert) -> Void) {
        self.daemon = daemon
        self.retryDelay = retryDelay
        self.ackRetryDelay = ackRetryDelay
        self.isPermitted = isPermitted
        self.play = play
    }

    /// The id from the current event stream's `subscriber` event, or nil once it has closed. A closed stream is no
    /// longer registered: the daemon dropped it when it closed.
    public func subscribed(_ id: String?) {
        guard id != subscriberId else { return }
        subscriberId = id
        claim = nil
        reconcile()
    }

    /// Whether the app may post notifications. It registers only while it may. Each check also retries what is
    /// unsettled: a refused registration, or a request the daemon did not answer.
    public func setPermitted(_ granted: Bool) {
        permitted = granted && !quitting
        reconcile()
    }

    /// Before the app quits: it takes no more alerts and unregisters, so the daemon plays the next ones, and hands back
    /// each alert it may have taken but not played (sent again until a daemon answers), so the daemon's sink plays it.
    /// Returns once each is handed back, or played and its receipt answered, or after `bound`. The daemon's sink plays an
    /// alert whose ack or handback no daemon answered by then 30 s after the app's stream closed; one the app played whose
    /// receipt no daemon answered by then plays twice.
    public func quit(within bound: Duration = .seconds(5)) async {
        quitting = true
        setPermitted(false)
        guard unsettled > 0 else { return }
        let deadline = Task { [weak self] in
            try? await Task.sleep(for: bound)
            guard !Task.isCancelled else { return }
            self?.resumeQuitting()
        }
        await withCheckedContinuation { waitingToQuit.append($0) }
        deadline.cancel()
    }

    private func resumeQuitting() {
        let waiting = waitingToQuit
        waitingToQuit = []
        for continuation in waiting { continuation.resume() }
    }

    /// Whether the app may present an alert: it is not quitting and may still post notifications.
    private func mayPresent() async -> Bool {
        guard !quitting else { return false }
        let granted = await isPermitted()
        return granted && !quitting
    }

    /// Waits for the registration work in flight, including retries; for tests.
    public func settled() async {
        while let task = reconciling ?? retrying { await task.value }
    }

    /// Whether the daemon answered `error`, so the request is known to have changed nothing: it refused it, is shutting
    /// down (and drops its handler and plays what is pending), or is not running. Any other failure, including a server
    /// error such as a failed save, leaves the outcome unknown.
    private static func answered(_ error: Error) -> Bool {
        switch error as? DaemonError {
        case .rejected(let status, _)?: status < 500
        case .shuttingDown?, .notListening?: true
        default: false
        }
    }

    /// Brings the daemon's registration in line with `subscriberId` and `permitted`, one request at a time.
    private func reconcile() {
        retrying?.cancel()
        retrying = nil
        guard reconciling == nil else { return }
        reconciling = Task {
            var refused: (id: String, message: String)?
            var unanswered = false
            while true {
                let wanted = permitted ? subscriberId : nil
                if let held = claim, held.id != wanted {
                    // The daemon's sink plays whatever this app had not acknowledged.
                    do {
                        try await daemon.unregisterAlertHandler(subscriberId: held.id)
                    } catch where !Self.answered(error) {
                        // The daemon may still hold this stream, so it is unregistered again later.
                        unanswered = true
                        break
                    } catch {}
                    if claim?.id == held.id { claim = nil }
                    continue
                }
                if claim?.confirmed == true { break }
                // A refused stream is not asked again until the next check; a new stream is.
                guard let wanted, wanted != refused?.id else { break }
                do {
                    try await daemon.registerAlertHandler(subscriberId: wanted)
                    claim = (wanted, true)
                } catch {
                    refused = (wanted, error.localizedDescription)
                    if Self.answered(error) {
                        if claim?.id == wanted { claim = nil }
                    } else {
                        // The daemon may have registered it, so it is registered or unregistered again later.
                        claim = (wanted, false)
                        unanswered = true
                        break
                    }
                }
            }
            let wanted = permitted ? subscriberId : nil
            if let claim, claim.confirmed, claim.id == wanted {
                update(.registered)
            } else if let refused, refused.id == wanted {
                update(.refused(refused.message))
            } else {
                update(.inactive)
            }
            reconciling = nil
            if unanswered { retryLater() }
        }
    }

    private func retryLater() {
        retrying = Task { [weak self, retryDelay] in
            try? await Task.sleep(for: retryDelay)
            guard !Task.isCancelled, let self else { return }
            self.retrying = nil
            self.reconcile()
        }
    }

    private func update(_ value: Registration) {
        guard value != registration else { return }
        registration = value
        onChange()
    }

    /// Whether the daemon refused an acknowledgement (404 or 409): the alert is not this app's to play. A daemon that is
    /// shutting down or not running gives no answer, because it may have taken the alert before it went.
    private static func refused(_ error: Error) -> Bool {
        if case .rejected(let status, _)? = error as? DaemonError { return status < 500 }
        return false
    }

    /// Handles an `alert` event from the current stream: acknowledges one that asks for it, then plays it only if the
    /// daemon handed it over. Alerts that ask for no acknowledgement are the daemon's to play.
    /// An alert counts as unsettled, so quitting waits for it, until it is handed back, or played and the daemon heard
    /// that the app received it: the daemon's sink plays an alert whose handler left without saying so.
    public func receive(_ alert: TimerAlert) async {
        guard alert.ackRequired == true, let alertId = alert.alertId, permitted, let subscriberId else { return }
        unsettled += 1
        defer {
            unsettled -= 1
            if unsettled == 0 { resumeQuitting() }
        }
        guard await takeOver(alert, alertId: alertId, subscriberId: subscriberId) else { return }
        let daemon = daemon
        _ = await untilAnswered { try await daemon.confirmAlert(alertId, subscriberId: subscriberId) }
    }

    /// Acknowledges the alert, then plays it or hands it back; true once it played.
    private func takeOver(_ alert: TimerAlert, alertId: String, subscriberId: String) async -> Bool {
        // The daemon decides who owns the alert, so a registration still in flight does not matter. An acknowledgement
        // no daemon answered is sent again until one does, always for the stream the alert came on, even after the stream
        // reconnects: one it took gets `.acknowledged` again, from the next daemon too, which the event stream starts, until
        // the app says it received that answer (once that stream has been gone 30 s, its sink plays it instead and answers
        // `.expired`); one it never saw gets `.expired` once its sink has played the alert, or a 404 from a daemon that
        // played it at startup, so the alert plays once whichever was lost.
        let daemon = daemon
        var asked = false
        switch await untilAnswered(while: mayPresent, {
            asked = true
            return try await daemon.acknowledgeAlert(alertId, subscriberId: subscriberId)
        }) {
        case .answer(.acknowledged):
            // Revoked, or quitting, while the answer was on its way: the app hands the alert back rather than show what
            // it may not.
            guard await mayPresent() else {
                await handBack(alertId, subscriberId: subscriberId)
                return false
            }
            play(alert)
            return true
        case .revoked:
            // Permission revoked in System Settings since the last check, or the app is quitting: it takes no alert it
            // may not show, and gives up the handler role, so the daemon plays this alert and the next ones. An
            // acknowledgement already sent may have been taken, so that alert is handed back.
            if asked { await handBack(alertId, subscriberId: subscriberId) } else { setPermitted(false) }
        case .answer(.expired), .refused:
            break
        }
        return false
    }

    /// Gives up the handler role as soon as the revocation is seen, then hands back an alert the daemon may have handed
    /// over, until a daemon answers, so its sink plays it. A grant that arrives meanwhile is kept, so the app registers
    /// again.
    private func handBack(_ alertId: String, subscriberId: String) async {
        setPermitted(false)
        let daemon = daemon
        _ = await untilAnswered { try await daemon.releaseAlert(alertId, subscriberId: subscriberId) }
    }

    /// How a request sent until a daemon answers it ended.
    private enum Outcome<Answer> {
        case answer(Answer)
        /// The daemon refused it (404 or 409: not this app's alert, so whoever holds it plays it), or the task was
        /// cancelled.
        case refused
        /// The app may no longer post notifications, or is quitting, so the request was not sent again.
        case revoked
    }

    /// Sends `request` every `ackRetryDelay` until a daemon answers it, while `permitted` holds before each attempt.
    private func untilAnswered<Answer>(while permitted: @MainActor () async -> Bool = { true },
                                       _ request: () async throws -> Answer) async -> Outcome<Answer> {
        while !Task.isCancelled {
            guard await permitted() else { return .revoked }
            do {
                return .answer(try await request())
            } catch where Self.refused(error) {
                return .refused
            } catch {
                try? await Task.sleep(for: ackRetryDelay)
            }
        }
        return .refused
    }
}
