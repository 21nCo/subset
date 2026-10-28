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

/// One part of an alert as the app or the daemon's sink presents it, named as the daemon records it
/// (packages/timer-cli/src/alerts/process.mjs `playParts`): its notification, and each sound of its sequence.
public enum AlertPart: Hashable, Sendable {
    case notification
    case sound(Int)

    public var name: String {
        switch self {
        case .notification: "notification"
        case .sound(let index): "sound:\(index)"
        }
    }

    /// How many sounds an alert of `kind` plays when its timer's sound is on: Tink for a tick, Pop for a new step, Glass
    /// three times for the finish, none for alerts missed while away (`MACOS_SOUNDS` in alerts/macos.mjs).
    public static func soundCount(_ kind: TimerAlert.Kind) -> Int {
        switch kind {
        case .tick, .segment: 1
        case .finish: 3
        case .missedWhileAway: 0
        }
    }

    /// The parts of `alert`, in the order the app plays them: the notification for `finish` and `missedWhileAway`, then
    /// its sounds unless its timer's sound is off.
    public static func plan(for alert: TimerAlert) -> [AlertPart] {
        let notification: [AlertPart] = [.finish, .missedWhileAway].contains(alert.kind) ? [.notification] : []
        let sounds = alert.sound == false ? 0 : soundCount(alert.kind)
        return notification + (0..<sounds).map { .sound($0) }
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
    func startPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws
    func finishPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws
    func confirmAlert(_ alertId: String, subscriberId: String) async throws
    func releaseAlert(_ alertId: String, subscriberId: String) async throws
}

extension DaemonClient: AlertHandlerDaemon {
    private struct SubscriberBody: Encodable { var subscriberId: String }
    private struct PartBody: Encodable { var subscriberId: String; var part: String; var pid: Int32? }
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

    /// `POST /v1/alerts/<alertId>/playing`: whether the app may play `part` of an alert it took. It may while the daemon's
    /// sink has not played the alert; a 410 means it has, so the app plays no more of it. The daemon answers 200 only once
    /// it has saved this process as playing that part, so if the app leaves before it says it finished it, the daemon's
    /// sink, or the next daemon's, holds that part while this process still runs, however long, and plays it only once the
    /// process has ended. A 500 means it could not save that, and permits nothing: the app asks again before playing it.
    public func startPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws {
        let body = PartBody(subscriberId: subscriberId, part: part.name, pid: ProcessInfo.processInfo.processIdentifier)
        let reply = try await send("POST", "/v1/alerts/\(Self.pathSegment(alertId))/playing", body: try JSONEncoder().encode(body))
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// `POST /v1/alerts/<alertId>/played`: the app finished `part` of an alert it took, so the daemon's sink never plays
    /// that part. Saying so again gets the same answer, and a 500 means the daemon could not save it, though it will not
    /// play it itself; a 410 means the sink played the rest of the alert, and recorded this part as played.
    public func finishPlaying(_ alertId: String, part: AlertPart, subscriberId: String) async throws {
        let reply = try await send("POST", "/v1/alerts/\(Self.pathSegment(alertId))/played",
                                   body: try JSONEncoder().encode(PartBody(subscriberId: subscriberId, part: part.name)))
        _ = try Self.decode(Ignored.self, status: reply.status, body: reply.body)
    }

    /// `POST /v1/alerts/<alertId>/received`: the app played every part of that alert, so the daemon stops keeping it.
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
/// else, is never played here. It then plays the alert part by part (`AlertPart.plan`), each only once a daemon said the
/// app may (`startPlaying`, which records this process as playing it), says when each part finished (`finishPlaying`,
/// for up to `reportBound`), and says it received the alert after the last. A part the app could not present (the
/// notification center refused it) hands the alert back. Quitting (`quit(within:)`) hands back every alert the app may
/// have taken and not finished, and waits until the daemon hears the app received each one it played. The daemon's sink
/// plays an alert the app took and never said it received 30 s after the app's stream last closed (`ORPHANED_ALERT_MS`),
/// without the parts the app said it finished; a part the app started and did not say it finished is held for as long
/// as the app runs (a stalled app that says so later, to that daemon or the next, has it recorded) and played once the
/// app has ended (its sound ended with it). So when the app quits past its bound, is force-quit, crashes or stalls, no
/// part is lost and none the app finished plays again. A part can play twice only if the app ends between finishing it
/// and a daemon hearing so. A daemon too old to know parts (no `playing` route) gets each alert back, for its sink.
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
    private let play: @MainActor (TimerAlert, AlertPart) async throws -> Void
    private let isPermitted: @MainActor () async -> Bool
    private let retryDelay: Duration
    private let ackRetryDelay: Duration
    private let reportBound: Duration
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

    /// `play` presents one part of an alert the app has taken over, and returns once it has finished; it throws when it
    /// could not present it. A registration request the daemon did not answer is tried again after `retryDelay`, and at
    /// the next permission check; an acknowledgement or a part, after `ackRetryDelay`. Saying a part finished is tried
    /// again for up to `reportBound`, then the app goes on with the next part and keeps saying so in the background until
    /// a daemon answers, so a daemon that cannot save does not hold back the rest of the alert. `isPermitted` reads whether the app may still post notifications, before each
    /// acknowledgement and before each part.
    public init(daemon: AlertHandlerDaemon, retryDelay: Duration = .seconds(2), ackRetryDelay: Duration = .milliseconds(250),
                reportBound: Duration = .seconds(5), isPermitted: @escaping @MainActor () async -> Bool = { true },
                play: @escaping @MainActor (TimerAlert, AlertPart) async throws -> Void) {
        self.daemon = daemon
        self.retryDelay = retryDelay
        self.ackRetryDelay = ackRetryDelay
        self.reportBound = reportBound
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
    /// each alert it may have taken but not played, after the part it is playing (sent again until a daemon answers), so
    /// the daemon's sink plays the parts it did not finish. Returns once each is handed back, or played and its receipt
    /// answered, or after `bound`. The daemon's sink plays an alert whose ack or handback no daemon answered by then 30 s
    /// after the app's stream closed, without the parts the app said it finished, so each part plays once.
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

    /// Whether the daemon has no route for the request (404 `No route ...`), as one older than this app does.
    private static func routeMissing(_ error: Error) -> Bool {
        if case .rejected(404, let reply)? = error as? DaemonError { return reply.code == "not_found" && reply.message.hasPrefix("No route") }
        return false
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

    /// Acknowledges the alert, then plays it or hands it back; true once every part played.
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
            return await playParts(alert, alertId: alertId, subscriberId: subscriberId)
        case .revoked:
            // Permission revoked in System Settings since the last check, or the app is quitting: it takes no alert it
            // may not show, and gives up the handler role, so the daemon plays this alert and the next ones. An
            // acknowledgement already sent may have been taken, so that alert is handed back.
            if asked { await handBack(alertId, subscriberId: subscriberId) } else { setPermitted(false) }
        case .answer(.expired), .refused, .unanswered, .unsupported:
            break
        }
        return false
    }

    /// Plays the alert part by part, each once a daemon said the app may, and says when each finished, so the daemon's
    /// sink never plays it too; true once every part played. One no daemon records within `reportBound` is said again in
    /// the background, until a daemon answers, while the app goes on: the daemon holds that part for this process
    /// meanwhile. Revoked, or quitting, before a part (also while the acknowledgement's or that part's answer was on its
    /// way), or a part the app could not present, or a daemon without part routes: the app hands the alert back rather
    /// than show what it may not, once a daemon heard each part it finished, and the daemon's sink plays the parts it did
    /// not finish. Refused (the sink played the alert, 410): the app plays no more.
    private func playParts(_ alert: TimerAlert, alertId: String, subscriberId: String) async -> Bool {
        let daemon = daemon
        var reports: [Task<Void, Never>] = []
        func handBackAfterReports() async {
            for report in reports { await report.value }
            await handBack(alertId, subscriberId: subscriberId)
        }
        for part in AlertPart.plan(for: alert) {
            switch await untilAnswered(while: mayPresent, { try await daemon.startPlaying(alertId, part: part, subscriberId: subscriberId) }) {
            case .answer:
                break
            case .revoked, .unsupported:
                await handBackAfterReports()
                return false
            case .refused, .unanswered:
                return false
            }
            guard await mayPresent() else {
                await handBackAfterReports()
                return false
            }
            do {
                try await play(alert, part)
            } catch {
                // Not presented, so not reported finished: the daemon's sink presents it, and the parts after it.
                await handBackAfterReports()
                return false
            }
            let report = { try await daemon.finishPlaying(alertId, part: part, subscriberId: subscriberId) }
            switch await untilAnswered(within: reportBound, report) {
            case .answer:
                break
            case .unanswered:
                // The daemon holds this part for this process meanwhile, so its sink does not play it while the app runs.
                reports.append(inBackground { _ = await self.untilAnswered(report) })
            case .refused, .revoked, .unsupported:
                return false
            }
        }
        return true
    }

    /// Runs `work` on its own, counted as unsettled, so quitting waits for it too.
    private func inBackground(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        unsettled += 1
        return Task {
            await work()
            unsettled -= 1
            if unsettled == 0 { resumeQuitting() }
        }
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
        /// No daemon answered it within the bound.
        case unanswered
        /// The daemon has no route for it (404 `No route`): it is older than this app.
        case unsupported
    }

    /// Sends `request` every `ackRetryDelay` until a daemon answers it, while `permitted` holds before each attempt, and
    /// for no longer than `bound` when given.
    private func untilAnswered<Answer>(while permitted: @MainActor () async -> Bool = { true }, within bound: Duration? = nil,
                                       _ request: () async throws -> Answer) async -> Outcome<Answer> {
        let deadline = bound.map { ContinuousClock.now + $0 }
        while !Task.isCancelled {
            guard await permitted() else { return .revoked }
            do {
                return .answer(try await request())
            } catch where Self.routeMissing(error) {
                return .unsupported
            } catch where Self.refused(error) {
                return .refused
            } catch {
                if let deadline, ContinuousClock.now >= deadline { return .unanswered }
                try? await Task.sleep(for: ackRetryDelay)
            }
        }
        return .refused
    }
}
