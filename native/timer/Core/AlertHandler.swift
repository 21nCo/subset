import Foundation

/// An `alert` event (packages/timer-cli/src/daemon/alerts.mjs). While an alert handler is registered, the daemon adds
/// `alertId` and `ackRequired` (alert-handlers.mjs).
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

    public init(timerId: String, kind: Kind, at: Int, segment: Step? = nil, secondsLeft: Int? = nil, missed: Int? = nil,
                alertId: String? = nil, ackRequired: Bool? = nil) {
        self.timerId = timerId
        self.kind = kind
        self.at = at
        self.segment = segment
        self.secondsLeft = secondsLeft
        self.missed = missed
        self.alertId = alertId
        self.ackRequired = ackRequired
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

    /// An id as one path segment: the daemon's ids are hex, and anything else is percent-encoded.
    static func pathSegment(_ id: String) -> String {
        id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? id
    }
}

/// Makes the app the daemon's single alert handler while it may post notifications, and plays an alert only after the
/// daemon has handed it over. The app registers its current event stream only while permission is granted; the daemon
/// unregisters it when that stream closes. For each alert that asks for acknowledgement, the app acknowledges first and
/// plays only on `.acknowledged`: an alert the daemon's sink already played (410), or that the daemon handed to someone
/// else, is never played here, so every alert plays exactly once.
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
    private var subscriberId: String?
    private var permitted = false
    /// The subscriber the daemon accepted, as far as this app knows.
    private var registeredId: String?
    private var reconciling: Task<Void, Never>?

    /// `play` presents an alert the app has taken over.
    public init(daemon: AlertHandlerDaemon, play: @escaping (TimerAlert) -> Void) {
        self.daemon = daemon
        self.play = play
    }

    /// The id from the current event stream's `subscriber` event, or nil once it has closed. A closed stream is no
    /// longer registered: the daemon dropped it when it closed.
    public func subscribed(_ id: String?) {
        guard id != subscriberId else { return }
        subscriberId = id
        registeredId = nil
        reconcile()
    }

    /// Whether the app may post notifications. It registers only while it may.
    public func setPermitted(_ granted: Bool) {
        guard granted != permitted else {
            // A refused registration is tried again whenever permission is checked.
            if case .refused = registration { reconcile() }
            return
        }
        permitted = granted
        reconcile()
    }

    /// Waits for the registration work in flight; for tests.
    public func settled() async {
        while let task = reconciling { await task.value }
    }

    /// Brings the daemon's registration in line with `subscriberId` and `permitted`, one request at a time.
    private func reconcile() {
        guard reconciling == nil else { return }
        reconciling = Task {
            var refused: (id: String, message: String)?
            while true {
                let wanted = permitted ? subscriberId : nil
                if registeredId == wanted { break }
                if let current = registeredId {
                    registeredId = nil
                    // The daemon's sink plays whatever this app had not acknowledged.
                    try? await daemon.unregisterAlertHandler(subscriberId: current)
                    continue
                }
                // A refused stream is not asked again until the next check; a new stream is.
                guard let wanted, wanted != refused?.id else { break }
                do {
                    try await daemon.registerAlertHandler(subscriberId: wanted)
                    registeredId = wanted
                } catch {
                    refused = (wanted, error.localizedDescription)
                }
            }
            if registeredId != nil {
                update(.registered)
            } else if let refused, refused.id == (permitted ? subscriberId : nil) {
                update(.refused(refused.message))
            } else {
                update(.inactive)
            }
            reconciling = nil
        }
    }

    private func update(_ value: Registration) {
        guard value != registration else { return }
        registration = value
        onChange()
    }

    /// Handles an `alert` event from the current stream: acknowledges one that asks for it, then plays it only if the
    /// daemon handed it over. Alerts that ask for no acknowledgement are the daemon's to play.
    public func receive(_ alert: TimerAlert) async {
        guard alert.ackRequired == true, let alertId = alert.alertId, permitted, let subscriberId else { return }
        // The daemon decides who owns the alert, so a registration still in flight does not matter. A failed request is
        // tried once more: an acknowledgement the daemon took gets `.acknowledged` again, one it never saw `.expired`.
        for _ in 0..<2 {
            do {
                if try await daemon.acknowledgeAlert(alertId, subscriberId: subscriberId) == .acknowledged { play(alert) }
                return
            } catch DaemonError.rejected {
                // Not this app's alert (404 or 409), so the daemon or another handler plays it.
                return
            } catch {
                continue
            }
        }
    }
}
