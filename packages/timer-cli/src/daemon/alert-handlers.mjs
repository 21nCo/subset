import { randomBytes } from 'node:crypto';
import { deliverToSink } from './alerts.mjs';

/** How long a registered handler has to acknowledge an alert before the daemon's sink plays it. */
export const ACK_TIMEOUT_MS = 2_000;
/**
 * How long an alert the sink played is remembered after its last acknowledgement request, on the
 * monotonic clock, so a late or repeated acknowledgement gets 410. Each request restarts it. Once it
 * is forgotten the answer is 404, which tells the handler not to play it either.
 */
export const SETTLED_RETENTION_MS = 60_000;
/**
 * How many acknowledged alerts the daemon keeps that no handler has said it received. None is ever
 * dropped: at this many, the daemon takes no more, and the sink plays the next alert acknowledged
 * (410). A running handler says so right after each 200, so only a handler that ended between a
 * 200 and saying so leaves one behind.
 */
export const MAX_UNRECEIVED = 1_000;

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
 * ends abruptly leaves them for the next one to play (`replay`). An acknowledgement is
 * answered only once `save(checkpoint)` has recorded the alert as taken, in `acknowledged`; when
 * that throws, the alert stays pending and the error is thrown to the caller. An acknowledged alert
 * stays in `acknowledged`, and so in every later save, until its handler says it received the 200
 * (`received`), however long that takes: a written reply does not mean the handler read it. The
 * next daemon takes the saved ones as `acknowledged`, so a handler whose 200 was lost gets it from
 * that daemon too. A handler that may no longer present an alert it took hands it back
 * (`release`), and the sink plays it once that is saved: the alert is saved as a handoff again, so
 * a daemon that ends before the sink has played it leaves it for the next one to play. When that
 * save throws, the alert stays taken and the error is thrown to the caller.
 *
 * Every sink path of a pending alert (the acknowledgement timeout, unregistering, disconnecting and
 * stopping) first asks `owns()` whether this daemon still holds `daemon.lock`. One that lost it
 * plays none of its pending alerts: the daemon that holds it plays those this one saved. Every
 * sink play (a fallback, an alert with no handler, a replayed handoff) is tracked, and once stopped
 * nothing more is handed to the sink, so what `stop()` waits for is all it plays.
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
  /** alertId → { subscriberId, at }, for alerts the sink played, least recently asked first. */
  const settled = new Map();
  /** alertId → { subscriberId, alert, timer }, for acknowledged alerts whose handler has not said it received the 200. */
  const taken = new Map();
  const counts = { acknowledged: 0, fallbacks: 0 };
  /** The sink's plays that have not finished, so shutdown can wait for them. */
  const playing = new Set();
  let stopped = false;
  const monotonic = () => (clock.monotonic ?? clock.now)();

  /** Forgets the fallbacks last asked about more than `SETTLED_RETENTION_MS` ago. */
  function forgetExpired() {
    const cutoff = monotonic() - SETTLED_RETENTION_MS;
    for (const [alertId, { at }] of settled) {
      if (at >= cutoff) break;
      settled.delete(alertId);
    }
  }

  function remember(alertId, subscriberId) {
    forgetExpired();
    settled.delete(alertId);
    settled.set(alertId, { subscriberId, at: monotonic() });
  }
  // A daemon that ended before these handlers said they received their 200 left them for this one.
  for (const { alertId, subscriberId, alert, timer } of acknowledged) taken.set(alertId, { subscriberId, alert, timer });

  const handoffs = (except = null) => [...pending].filter(([alertId]) => alertId !== except).map(([alertId, { alert, timer }]) => ({ alertId, alert, timer }));
  /** What `save` records: the pending alerts and the acknowledged ones not yet received, plus `next`. */
  function checkpoint(next = null) {
    const acknowledgements = [...taken].map(([alertId, { subscriberId, alert, timer }]) => ({ alertId, subscriberId, alert, timer }));
    if (next) acknowledgements.push(next);
    return { handoffs: handoffs(next?.alertId), acknowledged: acknowledgements };
  }

  /**
   * Saves the handoffs left once the sink has played some, the same way for every fallback (the
   * timeout, unregistering, disconnecting, stopping, the limit of taken alerts and a handback). A
   * failed save is logged and leaves `scheduler.json` behind, so the next save of the marks (at the
   * next scheduler run) records them. A daemon that ends before then leaves them to the next daemon,
   * which plays them again: across that double fault delivery is at least once, never zero, as the
   * sink cannot tell that it already played an alert.
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

  /** Plays `alert` through the sink unless stopped; `stop()` waits for each play this starts. */
  function play(alert, timer) {
    if (stopped) return;
    const played = deliverToSink(sink, alert, timer, log);
    if (!played) return;
    playing.add(played);
    const done = () => playing.delete(played);
    played.then(done, done);
  }

  /** Plays a pending alert through the sink, once, and records the fallback, while this daemon holds the lock. */
  function fallBack(alertId, reason) {
    if (stopped || !pending.has(alertId)) return false;
    // `owns` may itself begin the lost-lock shutdown, which leaves the pending alerts first.
    if (!owns()) {
      leaveToLockHolder();
      return false;
    }
    const entry = pending.get(alertId);
    if (!entry) return false;
    pending.delete(alertId);
    clock.clearTimeout(entry.handle);
    remember(alertId, entry.subscriberId);
    counts.fallbacks += 1;
    log(`alert ${alertId} (${entry.alert.kind} of ${entry.alert.timerId}) ${reason}; the ${sink.name} sink plays it.`);
    play(entry.alert, entry.timer);
    return true;
  }

  function fallBackAll(subscriberId, reason) {
    let played = false;
    for (const [alertId, entry] of [...pending]) if (subscriberId === null || entry.subscriberId === subscriberId) played = fallBack(alertId, reason) || played;
    if (played) saveAfterFallback();
  }

  const refused = (status, code, message) => ({ ok: false, status, code, message });
  const expired = () => refused(410, 'alert_expired', 'The daemon already played that alert.');
  const unavailable = () => refused(503, 'daemon_unavailable', 'The daemon is shutting down.');

  /** A refusal unless `subscriberId` holds `alertId`: pending, taken, or played by the sink. */
  function notOwnedBy(alertId, subscriberId) {
    forgetExpired();
    const owner = pending.get(alertId)?.subscriberId ?? taken.get(alertId)?.subscriberId ?? settled.get(alertId)?.subscriberId;
    if (owner === undefined) return refused(404, 'not_found', 'No alert has that id.');
    if (owner !== subscriberId) return refused(409, 'not_alert_handler', 'That alert was handed to another handler.');
    return null;
  }

  /** The sink plays pending `alertId` now; 503 once stopped, or when the daemon that holds `daemon.lock` will instead. */
  function fallBackNow(alertId, reason) {
    if (!fallBack(alertId, reason)) return unavailable();
    saveAfterFallback();
    return { ok: true };
  }

  return {
    /** The registered handler's subscriber id, or null. */
    get handler() {
      return handler;
    },
    get status() {
      return { registered: handler !== null, pending: pending.size, ...counts };
    },
    /** The alerts waiting for an acknowledgement, as `replay` takes them. */
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
        play(alert, timer);
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
     * acknowledgement gets the same answer until the handler says it received it. While
     * `MAX_UNRECEIVED` taken alerts are not yet received, a pending one is not taken: the sink plays
     * it and the answer is 410. A retry for a fallback keeps its 410 for another
     * `SETTLED_RETENTION_MS`.
     */
    acknowledge(alertId, subscriberId) {
      const refusal = notOwnedBy(alertId, subscriberId);
      if (refusal) return refusal;
      const entry = pending.get(alertId);
      if (entry && taken.size >= MAX_UNRECEIVED) {
        const played = fallBackNow(alertId, `was not taken, as ${MAX_UNRECEIVED} acknowledged alerts are not yet received`);
        return played.ok ? expired() : played;
      }
      if (entry) {
        const { alert, timer } = entry;
        save(checkpoint({ alertId, subscriberId, alert, timer }));
        pending.delete(alertId);
        clock.clearTimeout(entry.handle);
        taken.set(alertId, { subscriberId, alert, timer });
        counts.acknowledged += 1;
        return { ok: true };
      }
      if (taken.has(alertId)) return { ok: true };
      remember(alertId, subscriberId);
      return expired();
    },

    /**
     * The handler `subscriberId` received the 200 for `alertId`, so the daemon forgets it; the next
     * save leaves it out. Saying so again, or for an alert the daemon does not hold, changes nothing.
     */
    received(alertId, subscriberId) {
      const owner = taken.get(alertId)?.subscriberId;
      if (owner !== undefined && owner !== subscriberId) return refused(409, 'not_alert_handler', 'That alert was handed to another handler.');
      return { ok: true, forgotten: taken.delete(alertId) };
    },

    /**
     * The handler `subscriberId` hands `alertId` back unplayed, whether pending or taken, for
     * example because it may no longer post notifications: the sink plays it once, and a later
     * acknowledgement or release gets 410, as for any alert the sink played. A taken one is first
     * saved as a handoff; a failed save throws and leaves it taken. A daemon that is stopping, or
     * lost `daemon.lock`, answers 503 and changes nothing, so the handler asks the next daemon,
     * which has the alert saved.
     */
    release(alertId, subscriberId) {
      const refusal = notOwnedBy(alertId, subscriberId);
      if (refusal) return refusal;
      const held = taken.get(alertId);
      if (!held && !pending.has(alertId)) {
        remember(alertId, subscriberId);
        return expired();
      }
      if (stopped || !owns()) return unavailable();
      if (held) {
        taken.delete(alertId);
        pending.set(alertId, { ...held, handle: null });
        try {
          save(checkpoint());
        } catch (error) {
          pending.delete(alertId);
          taken.set(alertId, held);
          throw error;
        }
      }
      return fallBackNow(alertId, 'was handed back by its handler');
    },

    /**
     * Plays through the sink, at startup, the handoffs an earlier daemon saved and never settled
     * because it ended abruptly: no handler acknowledged them, and no sink played them.
     */
    replay(saved) {
      for (const { alertId, alert, timer } of saved) {
        log(`alert ${alertId} (${alert.kind} of ${alert.timerId}) was unacknowledged when the last daemon ended; the ${sink.name} sink plays it.`);
        play(alert, timer);
      }
    },

    /**
     * At shutdown: the handler is dropped and every pending alert falls back. A daemon that lost
     * `daemon.lock` plays none: the daemon that holds it plays those this one saved, and delivers
     * again those whose marks this one could not save. Returns a promise that settles once the sink
     * has finished every play it started (fallbacks, alerts with no handler and replayed
     * handoffs); nothing plays after that.
     */
    stop({ lockLost = false } = {}) {
      handler = null;
      if (lockLost) leaveToLockHolder();
      else fallBackAll(null, 'was pending when the daemon stopped');
      stopped = true;
      return Promise.allSettled([...playing]);
    }
  };
}
