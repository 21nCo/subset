import { randomBytes } from 'node:crypto';
import { deliverToSink } from './alerts.mjs';

/** How long a registered handler has to acknowledge an alert before the daemon's sink plays it. */
export const ACK_TIMEOUT_MS = 2_000;
/** How many settled alerts are remembered, so a late or repeated acknowledgement gets its answer. */
export const SETTLED_LIMIT = 1_000;

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
 * `publish(alert)` sends the `alert` event to every subscriber; `isOpen(subscriberId)` says
 * whether that subscriber's event stream is still open. Results are `{ ok: true, ... }` or
 * `{ ok: false, status, code, message }`.
 */
export function createAlertHandlers({ clock, sink, log, publish, isOpen, newId = newAlertId, ackTimeoutMs = ACK_TIMEOUT_MS }) {
  let handler = null;
  /** alertId → { alert, timer, subscriberId, handle }, for alerts the handler has not yet acknowledged. */
  const pending = new Map();
  /** alertId → { outcome: 'acknowledged' | 'fallback', subscriberId }, oldest first. */
  const settled = new Map();
  const counts = { acknowledged: 0, fallbacks: 0 };

  function remember(alertId, outcome, subscriberId) {
    settled.set(alertId, { outcome, subscriberId });
    if (settled.size > SETTLED_LIMIT) settled.delete(settled.keys().next().value);
  }

  /** Plays a pending alert through the sink, once, and records the fallback. */
  function fallBack(alertId, reason) {
    const entry = pending.get(alertId);
    if (!entry) return;
    pending.delete(alertId);
    clock.clearTimeout(entry.handle);
    remember(alertId, 'fallback', entry.subscriberId);
    counts.fallbacks += 1;
    log(`alert ${alertId} (${entry.alert.kind} of ${entry.alert.timerId}) ${reason}; the ${sink.name} sink plays it.`);
    deliverToSink(sink, entry.alert, entry.timer, log);
  }

  function fallBackAll(subscriberId, reason) {
    for (const [alertId, entry] of [...pending]) if (subscriberId === null || entry.subscriberId === subscriberId) fallBack(alertId, reason);
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
      entry.handle = clock.setTimeout(() => fallBack(alertId, `was not acknowledged within ${ackTimeoutMs / 1000} s`), ackTimeoutMs);
      publish({ ...alert, alertId, ackRequired: true, timerName: timer.name, sound: timer.sound });
    },

    /**
     * The handler `subscriberId` takes `alertId`. Acknowledging an alert it already took is a
     * no-op, so a retried acknowledgement gets the same answer.
     */
    acknowledge(alertId, subscriberId) {
      const entry = pending.get(alertId);
      const owner = entry?.subscriberId ?? settled.get(alertId)?.subscriberId;
      if (owner === undefined) return refused(404, 'not_found', 'No alert has that id.');
      if (owner !== subscriberId) return refused(409, 'not_alert_handler', 'That alert was handed to another handler.');
      if (entry) {
        pending.delete(alertId);
        clock.clearTimeout(entry.handle);
        remember(alertId, 'acknowledged', subscriberId);
        counts.acknowledged += 1;
        return { ok: true };
      }
      if (settled.get(alertId).outcome === 'acknowledged') return { ok: true };
      return refused(410, 'alert_expired', 'The daemon already played that alert.');
    },

    /** At shutdown: every pending alert falls back and the handler is dropped. */
    stop() {
      handler = null;
      fallBackAll(null, 'was pending when the daemon stopped');
    }
  };
}
