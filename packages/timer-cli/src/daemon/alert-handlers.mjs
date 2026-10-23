import { randomBytes } from 'node:crypto';
import { deliverToSink } from './alerts.mjs';

/** How long a registered handler has to acknowledge an alert before the daemon's sink plays it. */
export const ACK_TIMEOUT_MS = 2_000;
/**
 * How long a settled alert's outcome is remembered after its last acknowledgement request, on the
 * monotonic clock, so a late or repeated acknowledgement gets its answer. Each request restarts it,
 * so an outcome is kept while its handler is still asking (every 250 ms until answered), however
 * many alerts settle meanwhile; the timer limits bound how many outcomes that is.
 */
export const SETTLED_RETENTION_MS = 60_000;

export const newAlertId = () => randomBytes(16).toString('hex');

/**
 * Hands each alert to exactly one player: the registered alert handler (the Timer app) or the
 * daemon's own sink. At most one handler is registered at a time, tied to one open `/v1/events`
 * subscriber. While one is registered, each alert is published with an `alertId`,
 * `ackRequired: true` and its timer's `timerName` and `sound` as they were when it fell due, so the
 * handler plays it as the sink would even if the timer changes or is removed meanwhile. The handler
 * owns it once it acknowledges within `ACK_TIMEOUT_MS`.
 * An alert not acknowledged by then, or still pending when its handler unregisters or disconnects
 * or the daemon stops, is played by the sink at once and settled as a fallback, so a later
 * acknowledgement gets `410` and the handler never plays it too. With no handler, the sink plays
 * every alert as it is published.
 *
 * Pending alerts are `handoffs`, which the daemon saves with its scheduler marks, so a daemon that
 * ends abruptly leaves them for the next one to play (`replayHandoffs`). An acknowledgement is
 * answered only once `save(checkpoint)` has recorded the alert as taken, in `acknowledged`; when
 * that throws, the alert stays pending and the error is thrown to the caller. An acknowledged alert
 * stays in `acknowledged`, and so in every later save, until `answered(alertId)` reports that a 200
 * for it was written to its handler. The next daemon takes the saved ones as `acknowledged`, so a
 * handler whose 200 was lost when the daemon ended gets it from that daemon.
 *
 * Every sink path of a pending alert (the acknowledgement timeout, unregistering, disconnecting and
 * stopping) first asks `owns()` whether this daemon still holds `daemon.lock`. One that lost it
 * plays none of its pending alerts: the daemon that holds it plays those this one saved.
 *
 * `publish(alert)` sends the `alert` event to every subscriber; `isOpen(subscriberId)` says
 * whether that subscriber's event stream is still open. Results are `{ ok: true, ... }` or
 * `{ ok: false, status, code, message }`.
 */
export function createAlertHandlers({
  clock,
  sink,
  log,
  publish,
  isOpen,
  owns = () => true,
  save = () => {},
  acknowledged = [],
  newId = newAlertId,
  ackTimeoutMs = ACK_TIMEOUT_MS
}) {
  let handler = null;
  /** alertId → { alert, timer, subscriberId, handle }, for alerts the handler has not yet acknowledged. */
  const pending = new Map();
  /** alertId → { outcome: 'acknowledged' | 'fallback', subscriberId, at, answered }, least recently asked first. */
  const settled = new Map();
  const counts = { acknowledged: 0, fallbacks: 0 };
  const monotonic = () => (clock.monotonic ?? clock.now)();

  /** Forgets the outcomes settled more than `SETTLED_RETENTION_MS` ago. */
  function forgetExpired() {
    const cutoff = monotonic() - SETTLED_RETENTION_MS;
    for (const [alertId, { at }] of settled) {
      if (at >= cutoff) break;
      settled.delete(alertId);
    }
  }

  function remember(alertId, outcome, subscriberId) {
    forgetExpired();
    settled.delete(alertId);
    settled.set(alertId, { outcome, subscriberId, at: monotonic(), answered: false });
  }
  // A daemon that ended before these acknowledgements were answered left them for this one.
  for (const { alertId, subscriberId } of acknowledged) remember(alertId, 'acknowledged', subscriberId);

  const handoffs = (except = null) => [...pending].filter(([alertId]) => alertId !== except).map(([alertId, { alert, timer }]) => ({ alertId, alert, timer }));
  /** What `save` records: the pending alerts and the acknowledged ones whose 200 was not yet written, plus `taken`. */
  function checkpoint(taken = null) {
    const unanswered = [...settled]
      .filter(([, entry]) => entry.outcome === 'acknowledged' && !entry.answered)
      .map(([alertId, { subscriberId }]) => ({ alertId, subscriberId }));
    if (taken) unanswered.push(taken);
    return { handoffs: handoffs(taken?.alertId), acknowledged: unanswered };
  }

  /**
   * Saves the handoffs left once the sink has played some. A failed save is logged; the next save
   * of the marks records them, and until then a restart may play them again rather than never.
   */
  function saveAfterFallback() {
    try {
      save(checkpoint());
    } catch (error) {
      log(`could not record played alerts: ${error.message}`);
    }
  }

  /** Drops every pending alert unplayed, for the daemon that holds `daemon.lock` to play. */
  function leaveToLockHolder() {
    for (const entry of pending.values()) clock.clearTimeout(entry.handle);
    if (pending.size) log(`${pending.size} unacknowledged alert(s) are left to the daemon that holds daemon.lock.`);
    pending.clear();
  }

  /** Plays a pending alert through the sink, once, and records the fallback, while this daemon holds the lock. */
  function fallBack(alertId, reason) {
    if (!pending.has(alertId)) return false;
    // `owns` may itself begin the lost-lock shutdown, which leaves the pending alerts first.
    if (!owns()) {
      leaveToLockHolder();
      return false;
    }
    const entry = pending.get(alertId);
    if (!entry) return false;
    pending.delete(alertId);
    clock.clearTimeout(entry.handle);
    remember(alertId, 'fallback', entry.subscriberId);
    counts.fallbacks += 1;
    log(`alert ${alertId} (${entry.alert.kind} of ${entry.alert.timerId}) ${reason}; the ${sink.name} sink plays it.`);
    deliverToSink(sink, entry.alert, entry.timer, log);
    return true;
  }

  function fallBackAll(subscriberId, reason) {
    let played = false;
    for (const [alertId, entry] of [...pending]) if (subscriberId === null || entry.subscriberId === subscriberId) played = fallBack(alertId, reason) || played;
    if (played) saveAfterFallback();
  }

  const refused = (status, code, message) => ({ ok: false, status, code, message });

  return {
    /** The registered handler's subscriber id, or null. */
    get handler() {
      return handler;
    },
    get status() {
      return { registered: handler !== null, pending: pending.size, ...counts };
    },
    /** The alerts waiting for an acknowledgement, as `replayHandoffs` takes them. */
    get handoffs() {
      return handoffs();
    },
    /** `{ handoffs, acknowledged }`, as `save` takes it. */
    get checkpoint() {
      return checkpoint();
    },

    /** Registers `subscriberId`; registering the handler again is a no-op. */
    register(subscriberId) {
      if (handler === subscriberId) return { ok: true };
      if (handler !== null) return refused(409, 'handler_registered', 'Another alert handler is registered.');
      if (!isOpen(subscriberId)) return refused(404, 'not_found', 'No open event stream has that subscriber id.');
      handler = subscriberId;
      log('an alert handler registered; it plays alerts it acknowledges.');
      return { ok: true };
    },

    /** Unregisters `subscriberId` if it is the handler; its pending alerts fall back at once. */
    unregister(subscriberId, reason = 'was left unacknowledged when its handler unregistered') {
      if (handler !== subscriberId) return false;
      handler = null;
      log('the alert handler unregistered; the sink plays alerts.');
      fallBackAll(subscriberId, reason);
      return true;
    },

    /** Called when a subscriber's event stream closes. */
    disconnected(subscriberId) {
      this.unregister(subscriberId, 'was left unacknowledged when its handler disconnected');
    },

    /** Publishes `alert` and hands it to the handler, if one is registered, else to the sink. */
    deliver(alert, timer) {
      if (handler === null) {
        publish(alert);
        deliverToSink(sink, alert, timer, log);
        return;
      }
      const alertId = newId();
      const entry = { alert, timer, subscriberId: handler, handle: null };
      pending.set(alertId, entry);
      entry.handle = clock.setTimeout(() => {
        if (fallBack(alertId, `was not acknowledged within ${ackTimeoutMs / 1000} s`)) saveAfterFallback();
      }, ackTimeoutMs);
      publish({ ...alert, alertId, ackRequired: true, timerName: timer.name, sound: timer.sound });
    },

    /**
     * The handler `subscriberId` takes `alertId`, once that is saved; a failed save throws and
     * leaves the alert pending. Acknowledging an alert it already took is a no-op, so a retried
     * acknowledgement gets the same answer, and each one keeps the outcome for another
     * `SETTLED_RETENTION_MS`.
     */
    acknowledge(alertId, subscriberId) {
      forgetExpired();
      const entry = pending.get(alertId);
      const outcome = settled.get(alertId);
      const owner = entry?.subscriberId ?? outcome?.subscriberId;
      if (owner === undefined) return refused(404, 'not_found', 'No alert has that id.');
      if (owner !== subscriberId) return refused(409, 'not_alert_handler', 'That alert was handed to another handler.');
      if (entry) {
        save(checkpoint({ alertId, subscriberId }));
        pending.delete(alertId);
        clock.clearTimeout(entry.handle);
        remember(alertId, 'acknowledged', subscriberId);
        counts.acknowledged += 1;
        return { ok: true };
      }
      settled.delete(alertId);
      settled.set(alertId, { ...outcome, at: monotonic() });
      if (outcome.outcome === 'acknowledged') return { ok: true };
      return refused(410, 'alert_expired', 'The daemon already played that alert.');
    },

    /** A 200 for `alertId` was written to its handler, so later saves leave it out. */
    answered(alertId) {
      const outcome = settled.get(alertId);
      if (outcome) outcome.answered = true;
    },

    /**
     * At shutdown: the handler is dropped and every pending alert falls back. A daemon that lost
     * `daemon.lock` plays none: the daemon that holds it plays those this one saved, and delivers
     * again those whose marks this one could not save.
     */
    stop({ lockLost = false } = {}) {
      handler = null;
      if (lockLost) return leaveToLockHolder();
      fallBackAll(null, 'was pending when the daemon stopped');
    }
  };
}

/**
 * Plays through the sink, at startup, the handoffs an earlier daemon saved and never settled
 * because it ended abruptly: no handler acknowledged them, and no sink played them.
 */
export function replayHandoffs(handoffs, sink, log) {
  for (const { alertId, alert, timer } of handoffs) {
    log(`alert ${alertId} (${alert.kind} of ${alert.timerId}) was unacknowledged when the last daemon ended; the ${sink.name} sink plays it.`);
    deliverToSink(sink, alert, timer, log);
  }
}
