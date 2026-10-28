import { randomBytes } from 'node:crypto';
import { deliverToSink } from './alerts.mjs';
import { createPlayJournal, executorOf, isLockLost, systemProcesses } from './play-journal.mjs';

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
 * (410). A running handler says so right after it plays each one, so only a handler that ended or
 * stalled before saying so leaves one behind, until `ORPHANED_ALERT_MS` after it left.
 */
export const MAX_UNRECEIVED = 1_000;
/**
 * How long, on the monotonic clock, an alert a handler took stays its own once that handler last
 * stopped being registered (it unregistered, its event stream closed, or it registered with an
 * earlier daemon) without its saying it received the alert. Then the sink plays it, and a later
 * acknowledgement or handback gets 410. A handler registering again cancels this, and its next
 * departure starts it over. So an alert a handler took is never lost. The sink plays only the parts
 * the handler had not said it finished (`played`), and a part it started (`playing`) is held for its
 * process: the sink plays the others, and that one only once the process has ended (quit,
 * force-quit or crashed) without the handler saying it finished it, as its sound ended with it. A
 * handler that stalled and says so later, to this daemon or the next, has it recorded as finished,
 * and one that asks again to play it is permitted it, and one that hands the alert back has the
 * sink play it at once. So each part plays once: those it finished by it, the others by the sink.
 */
export const ORPHANED_ALERT_MS = 30_000;

export const newAlertId = () => randomBytes(16).toString('hex');

/** `started` without the parts in `parts`. */
const withoutParts = (started, parts) => Object.fromEntries(Object.entries(started).filter(([part]) => !parts.includes(part)));

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
 * stays in `acknowledged`, and so in every later save, until its handler says it received (played)
 * it (`received`), however long that takes while it is the handler: a written reply does not mean
 * the handler read it. A receipt is answered only once a save leaves the alert out; when that
 * throws, the alert stays taken and the error is thrown to the caller. The next daemon takes the
 * saved ones as `acknowledged`, so a handler whose 200 was lost gets it from that daemon too. One a
 * handler took and never said it received is played by the sink `ORPHANED_ALERT_MS` after that
 * handler last stopped being the handler (or after the next daemon started), unless it is the
 * handler again by then, so an app that ended before playing it does not lose it. Before the handler
 * plays each part of an alert it took, it asks whether it may (`playing`: while it still holds it),
 * answered once `scheduler.json` or else `plays.json` records its process (`pid`) as playing that
 * part, and once that part finished it says so
 * (`played`), answered once `scheduler.json` or else `plays.json` holds it, so the sink never plays a
 * part the handler finished. A handler that may no longer present an alert it took hands it back
 * (`release`) between parts, and the sink plays the parts it had not finished once that is saved: the
 * alert is saved as a handoff again, with those parts, so a daemon that ends before the sink has
 * played it leaves it for the next one to play from the same parts. When that save throws, the alert
 * stays taken and the error is thrown to the caller.
 *
 * Every sink play is recorded in the play journal (see `createPlayJournal`; `plays` are the entries
 * earlier daemons left, `progress` the parts handlers finished that only it holds, `savePlays` writes
 * them, and `processes` tells the fate of a sink process or a handler's)
 * before the sink is called, with the parts the handler finished, and as each part's process is
 * spawned and each part and the play finish. So a daemon that ends mid-play, or after a play whose
 * checkpoint it could not save, leaves the next one an alert it plays from the parts not finished,
 * or not at all: the next daemon takes no alert the journal holds from `acknowledged` or `replay`,
 * and answers 410 for it. While the journal cannot be written, every save carries it, and a failed
 * write is followed by a save at once, so no handoff is retired without a record of its play.
 * `delivered(key)` says whether a journaled play stands for a transition, for the scheduler.
 *
 * Every sink path of a pending alert (the acknowledgement timeout, unregistering, disconnecting,
 * stopping and an orphaned taken alert) first asks `owns()` whether this daemon still holds
 * `daemon.lock`. One that lost it plays none of its pending alerts: the daemon that holds it plays
 * those this one saved. Every
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
  plays = [],
  progress = [],
  savePlays = () => {},
  processes = systemProcesses,
  onIdle = () => {},
  newId = newAlertId,
  ackTimeoutMs = ACK_TIMEOUT_MS
}) {
  let handler = null;
  // A journal write that failed leaves scheduler.json to carry the journal, so it is saved at once.
  const journal = createPlayJournal({ entries: plays, progress, persist: savePlays, log, onBehind: requestSave, processes });
  /** alertId → { alert, timer, subscriberId, keys, played, started, handle }, for alerts the handler has not yet acknowledged. */
  const pending = new Map();
  /** alertId → { subscriberId, at }, for alerts the sink played, least recently asked first. */
  const settled = new Map();
  /**
   * alertId → { subscriberId, alert, timer, played, started, unsaved }, for acknowledged alerts whose
   * handler has not said it received them; `played` are the parts it said it finished (`unsaved` while
   * no save of `scheduler.json` holds them all), and `started` its process for each part it started
   * and has not said it finished.
   */
  const taken = new Map();
  const counts = { acknowledged: 0, fallbacks: 0 };
  /** subscriberId → timeout, for each former handler that still holds taken alerts, until `ORPHANED_ALERT_MS` ends. */
  const orphaned = new Map();
  /** The sink's plays that have not finished, so shutdown can wait for them. */
  const playing = new Set();
  let stopped = false;
  let saveRequested = false;
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
  /**
   * In `ORPHANED_ALERT_MS`, the sink plays the alerts `subscriberId` took and has not said it
   * received, unless it is the handler again by then: they fall back as pending alerts do.
   */
  function orphan(subscriberId) {
    if (orphaned.has(subscriberId) || ![...taken.values()].some((held) => held.subscriberId === subscriberId)) return;
    const handle = clock.setTimeout(() => {
      orphaned.delete(subscriberId);
      if (handler === subscriberId) return;
      for (const [alertId, held] of [...taken]) {
        if (held.subscriberId !== subscriberId) continue;
        taken.delete(alertId);
        pending.set(alertId, { ...held, handle: null });
      }
      fallBackAll(subscriberId, `was taken by a handler that left ${ORPHANED_ALERT_MS / 1000} s ago without saying it received it`);
    }, ORPHANED_ALERT_MS);
    orphaned.set(subscriberId, handle);
  }

  // The sink of an earlier daemon started these: a handler that asks about one is told it played it,
  // and `replay` plays the parts of the unfinished ones that had not finished.
  for (const { alertId, subscriberId } of journal.entries) if (subscriberId !== null) remember(alertId, subscriberId);
  let leftUnfinished = journal.unfinished;
  // A daemon that ended before these handlers said they received their 200 left them for this one,
  // and no stream of this daemon is their handler yet.
  // Parts only plays.json holds, as scheduler.json could not be saved, are added to theirs.
  const handled = new Map(journal.handled.map(({ alertId, ...parts }) => [alertId, parts]));
  for (const { alertId, subscriberId, alert, timer, played = [], started = {} } of acknowledged) {
    const progress = handled.get(alertId);
    const finished = [...new Set([...played, ...(progress?.played ?? [])])];
    const playing = withoutParts({ ...started, ...progress?.started }, finished);
    if (!journal.has(alertId)) taken.set(alertId, { subscriberId, alert, timer, played: finished, started: playing, unsaved: false });
  }
  for (const { subscriberId } of acknowledged) orphan(subscriberId);

  const progressOf = ({ played = [], started = {} }) => ({ ...(played.length ? { played } : {}), ...(Object.keys(started).length ? { started } : {}) });
  const handoffs = (except = null) =>
    [...pending].filter(([alertId]) => alertId !== except).map(([alertId, entry]) => ({ alertId, alert: entry.alert, timer: entry.timer, ...progressOf(entry) }));
  const acknowledgement = (alertId, held) => ({ alertId, subscriberId: held.subscriberId, alert: held.alert, timer: held.timer, ...progressOf(held) });
  /**
   * What `save` records: the pending alerts and the acknowledged ones not yet received, plus `next`,
   * each with the parts its handler finished, and the play journal while `plays.json` is behind.
   */
  function checkpoint(next = null) {
    const acknowledgements = [...taken].map(([alertId, held]) => acknowledgement(alertId, held));
    if (next) acknowledgements.push(acknowledgement(next.alertId, next));
    const carried = journal.carried;
    return { handoffs: handoffs(next?.alertId), acknowledged: acknowledgements, ...(carried.length ? { plays: carried } : {}) };
  }

  /**
   * Saves the handoffs left once the sink has started some, the same way for every fallback (the
   * timeout, unregistering, disconnecting, stopping, the limit of taken alerts, a handback and an
   * orphaned taken alert). A failed save is logged and leaves `scheduler.json` behind, so the next
   * save of the marks (at the next scheduler run) records them. A daemon that ends before then leaves
   * them to the next daemon, which finds each in the play journal and plays only what had not
   * finished.
   */
  function saveAfterFallback() {
    try {
      save(checkpoint());
    } catch (error) {
      log(`could not record played alerts: ${error.message}`);
    }
  }

  /**
   * Saves `scheduler.json` once the current task ends, so it carries the play journal while
   * `plays.json` cannot be written, and drops that copy once it can. A scheduler run in progress
   * saves its marks first, with the alerts it delivers.
   */
  function requestSave() {
    if (saveRequested) return;
    saveRequested = true;
    queueMicrotask(() => {
      saveRequested = false;
      saveAfterFallback();
    });
  }

  /** Drops every pending alert unplayed, for the daemon that holds `daemon.lock` to play. */
  function leaveToLockHolder() {
    for (const entry of pending.values()) clock.clearTimeout(entry.handle);
    if (pending.size) log(`${pending.size} unacknowledged alert(s) are left to the daemon that holds daemon.lock.`);
    pending.clear();
  }

  /**
   * Plays `alertId` through the sink unless stopped, journaled first, skipping the parts already
   * `played` (by a handler, or by an earlier play the journal holds). `stop()` waits for each play
   * this starts.
   */
  function play(alertId, alert, timer, { subscriberId = null, keys = [], played = [], started = {} } = {}) {
    if (stopped) return;
    if (!journal.has(alertId)) journal.begin(alertId, { alert, timer, subscriberId, keys, played, running: started });
    const running = playRest(alertId, alert, timer);
    playing.add(running);
    // Neither settle's, awaitHandler's nor deliverToSink's promise rejects.
    running.then(() => {
      playing.delete(running);
      if (!stopped && !playing.size) onIdle();
    });
  }

  /**
   * A part an earlier daemon's sink process may still be playing is first decided from that process
   * (`journal.settle`). The sink then plays the parts not finished, but those the handler's process
   * holds (`started`), each of which it plays after them once that process ended without the handler
   * saying it finished it. The play is finished once every part is decided; a daemon that stops
   * first plays no more of it, and leaves the held parts in the journal for the next daemon.
   */
  async function playRest(alertId, alert, timer) {
    if (journal.left(alertId)) await journal.settle(alertId);
    if (stopped) return;
    const held = journal.held(alertId);
    const decided = Promise.all(held.map((part) => journal.awaitHandler(alertId, part)));
    const finished = journal.played(alertId);
    await startSink(alertId, alert, timer, (part) => finished.has(part) || held.includes(part));
    await decided;
    // A part still held once this daemon stopped stays in the journal, for the next daemon.
    if (journal.held(alertId).length) return;
    const again = held.filter((part) => !journal.played(alertId).has(part));
    if (again.length) {
      if (stopped) return;
      log(`alert ${alertId}: its handler ended without saying it finished ${again.join(', ')}; the ${sink.name} sink plays ${again.length === 1 ? 'it' : 'them'}.`);
      await startSink(alertId, alert, timer, (part) => !again.includes(part));
    }
    journal.finish(alertId);
  }

  /** Calls the sink for the parts of `alertId` that `skip` does not pick, and journals each part. */
  function startSink(alertId, alert, timer, skip) {
    const progress = {
      played: { has: skip },
      started: (part, pid) => journal.started(alertId, part, pid),
      done: (part) => journal.done(alertId, part)
    };
    return deliverToSink(sink, alert, timer, log, progress);
  }

  /**
   * Gives `parts` of `alertId`, which the sink holds for its handler's process, back to the sink,
   * which plays them, once `plays.json`, or else `scheduler.json`, records that. When neither can,
   * this throws and the sink holds them still, so the handler asks again; a daemon that lost
   * `daemon.lock` throws its `LockLostError`.
   */
  function giveBack(alertId, parts) {
    const { error, restore } = journal.giveBack(alertId, parts);
    if (!error) return;
    try {
      // The failed write left the journal behind, so this save carries it.
      if (isLockLost(error)) throw error;
      save(checkpoint());
    } catch (failure) {
      restore();
      throw failure;
    }
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
    const rest = entry.played.length ? ` the parts its handler did not finish (${entry.played.join(', ')} finished)` : ' it';
    log(`alert ${alertId} (${entry.alert.kind} of ${entry.alert.timerId}) ${reason}; the ${sink.name} sink plays${rest}.`);
    play(alertId, entry.alert, entry.timer, entry);
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

  /** A refusal unless `subscriberId` took `alertId` and still holds it. */
  function heldBy(alertId, subscriberId) {
    const refusal = notOwnedBy(alertId, subscriberId);
    if (refusal) return refusal;
    if (taken.has(alertId)) return null;
    if (pending.has(alertId)) return refused(409, 'invalid_state', 'That alert is not acknowledged.');
    remember(alertId, subscriberId);
    return expired();
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
    /**
     * Whether the sink is playing or owes a part of an alert (one it holds for a handler's process
     * included), so the daemon does not exit idle; `onIdle()` is called once it no longer is.
     */
    get busy() {
      return playing.size > 0 || journal.unfinished.length > 0;
    },
    /** The alerts waiting for an acknowledgement, as `replay` takes them. */
    get handoffs() {
      return handoffs();
    },
    /** Whether a journaled play stands for the transition with this key (see `createScheduler`). */
    delivered: (key) => journal.delivered(key),
    /**
     * Called once `scheduler.json` has been saved with `saved`, so the journal forgets the plays that
     * finished before and the handled parts it now holds.
     */
    saved({ plays: carried = [], handoffs: left = [], acknowledged: kept = [] } = {}) {
      for (const { alertId, played = [] } of kept) {
        const held = taken.get(alertId);
        if (held && held.played.every((part) => played.includes(part))) held.unsaved = false;
      }
      journal.saved(carried, [...left, ...kept]);
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
      // Its alerts are its own again, so their `ORPHANED_ALERT_MS` starts over at its next departure.
      clock.clearTimeout(orphaned.get(subscriberId));
      orphaned.delete(subscriberId);
      log('an alert handler registered; it plays alerts it acknowledges.');
      return { ok: true };
    },

    /**
     * Unregisters `subscriberId` if it is the handler; its pending alerts fall back at once, and
     * those it took and has not said it received, after `ORPHANED_ALERT_MS`.
     */
    unregister(subscriberId, reason = 'was left unacknowledged when its handler unregistered') {
      if (handler !== subscriberId) return false;
      handler = null;
      log('the alert handler unregistered; the sink plays alerts.');
      fallBackAll(subscriberId, reason);
      orphan(subscriberId);
      return true;
    },

    /** Called when a subscriber's event stream closes. */
    disconnected(subscriberId) {
      this.unregister(subscriberId, 'was left unacknowledged when its handler disconnected');
    },

    /**
     * Publishes `alert` and hands it to the handler, if one is registered, else to the sink. `keys`
     * name the transitions it stands for, which a sink play journals.
     */
    deliver(alert, timer, keys = []) {
      if (handler === null) {
        publish(alert);
        play(newId(), alert, timer, { keys });
        return;
      }
      const alertId = newId();
      const entry = { alert, timer, subscriberId: handler, keys, played: [], handle: null };
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
        taken.set(alertId, { subscriberId, alert, timer, played: [], started: {}, unsaved: false });
        counts.acknowledged += 1;
        return { ok: true };
      }
      if (taken.has(alertId)) return { ok: true };
      remember(alertId, subscriberId);
      return expired();
    },

    /**
     * Whether the handler `subscriberId` may play `part` of `alertId`, which it took: yes while it
     * still holds it, so the sink has not played it, once its process `pid` is recorded as playing
     * that part in `scheduler.json`, or, when that cannot be saved, in `plays.json`, so the sink, of
     * this daemon or the next, decides that part by the process if the handler leaves without saying
     * it finished it (see `ORPHANED_ALERT_MS`). When neither can be written this throws and permits
     * nothing, forgetting the process, so the handler asks again. A pending alert gets 409
     * (`invalid_state`), and one the sink played 410, so the handler plays nothing more of it. A
     * part the sink holds for the handler's process (it was permitted that part before the sink took
     * the alert over, here or in an earlier daemon, and may not have had the answer) is permitted
     * again to that process, still held, so its `played` records it; any other process gets 410 and
     * the part is given back to the sink, which plays it (see `giveBack`). A daemon that lost
     * `daemon.lock` throws its `LockLostError` and permits nothing.
     */
    playing(alertId, subscriberId, part, pid) {
      const holder = journal.holder(alertId, part, subscriberId);
      if (holder) {
        if (holder.pid === pid && processes.alive(holder)) return { ok: true };
        giveBack(alertId, [part]);
        remember(alertId, subscriberId);
        log(`alert ${alertId}: another process of its handler asked to play ${part}; the ${sink.name} sink plays it.`);
        return expired();
      }
      const refusal = heldBy(alertId, subscriberId);
      if (refusal) return refusal;
      const held = taken.get(alertId);
      if (held.played.includes(part)) return { ok: true };
      const before = held.started;
      held.started = { ...held.started, [part]: executorOf(processes, pid, { app: true }) };
      try {
        save(checkpoint());
      } catch (error) {
        // A daemon that lost daemon.lock permits nothing: the handler asks the one that holds it.
        let recorded = false;
        try {
          recorded = !isLockLost(error) && journal.handle(alertId, held, { keep: false });
        } finally {
          if (!recorded) held.started = before;
        }
        if (!recorded) throw error;
        log(`could not save scheduler.json (${error.message}); plays.json holds that the alert handler plays ${part} of alert ${alertId}.`);
      }
      return { ok: true };
    },

    /**
     * The handler `subscriberId` finished playing `part` of `alertId`, which it took, so the sink never
     * plays that part; answered once `scheduler.json`, or, when that cannot be saved, `plays.json`
     * holds it. When neither can be written this throws, and the part is still known as finished to
     * this daemon, so its sink does not play it; saying so again tries to save it again, and once it is
     * saved, saying so again is a no-op. A part the sink holds for the handler's process, as it was
     * playing it when the sink took the alert over (here or in an earlier daemon), is recorded as
     * finished in its play, and the answer is 410 as the sink plays the rest. Refused as `playing`
     * is. A daemon that lost `daemon.lock` throws its `LockLostError`, and has recorded nothing.
     */
    played(alertId, subscriberId, part) {
      if (journal.awaitsHandler(alertId, part, subscriberId)) {
        journal.done(alertId, part);
        remember(alertId, subscriberId);
        return expired();
      }
      const refusal = heldBy(alertId, subscriberId);
      if (refusal) return refusal;
      const held = taken.get(alertId);
      if (held.played.includes(part) && !held.unsaved) return { ok: true };
      if (!held.played.includes(part)) {
        held.played = [...held.played, part];
        held.started = withoutParts(held.started, [part]);
        held.unsaved = true;
      }
      try {
        save(checkpoint());
        held.unsaved = false;
      } catch (error) {
        if (isLockLost(error) || !journal.handle(alertId, held)) throw error;
        log(`could not save scheduler.json (${error.message}); plays.json holds the parts of alert ${alertId} its handler finished.`);
      }
      return { ok: true };
    },

    /**
     * The handler `subscriberId` received `alertId` (it played it), so the daemon forgets it once
     * that is saved, and no later daemon plays it. A failed save throws and leaves it taken, so the
     * handler says so again. Saying so again, or for an alert the daemon does not hold, changes
     * nothing.
     */
    received(alertId, subscriberId) {
      const held = taken.get(alertId);
      if (held && held.subscriberId !== subscriberId) return refused(409, 'not_alert_handler', 'That alert was handed to another handler.');
      if (!held) return { ok: true, forgotten: false };
      taken.delete(alertId);
      try {
        save(checkpoint());
      } catch (error) {
        taken.set(alertId, held);
        throw error;
      }
      return { ok: true, forgotten: true };
    },

    /**
     * The handler `subscriberId` hands `alertId` back unplayed, whether pending or taken, for
     * example because it may no longer post notifications: the sink plays it once, without the parts
     * the handler finished, and a later
     * acknowledgement or release gets 410, as for any alert the sink played. A taken one is first
     * saved as a handoff; a failed save throws and leaves it taken. One the sink took over while it
     * holds a part for the handler's process (see `playing`) has those parts given back to the sink,
     * which plays them, once that is saved (see `giveBack`), and the answer is 410. A daemon that is
     * stopping, or lost `daemon.lock`, answers 503 and changes nothing, so the handler asks the next
     * daemon, which has the alert saved.
     */
    release(alertId, subscriberId) {
      const parts = journal.held(alertId).filter((part) => journal.holder(alertId, part, subscriberId));
      if (parts.length) {
        if (stopped || !owns()) return unavailable();
        giveBack(alertId, parts);
        remember(alertId, subscriberId);
        log(`alert ${alertId} was handed back by its handler; the ${sink.name} sink plays ${parts.join(', ')}.`);
        return expired();
      }
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
        // A handler hands an alert back between parts, so a part it started and did not finish plays.
        pending.set(alertId, { ...held, started: {}, handle: null });
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
     * Plays through the sink, at startup, what an earlier daemon that ended abruptly left: the
     * handoffs it saved and never settled (no handler acknowledged them) that its sink never started,
     * without the parts their handler finished, and, from the parts not finished, the plays its
     * journal holds that its sink never finished.
     */
    replay(saved) {
      // scheduler.json may hold the only copy of these, and the next save of it drops that copy.
      journal.recover();
      for (const { alertId, alert, timer, played = [], started = {} } of saved) {
        if (journal.has(alertId)) continue;
        const rest = played.length ? ` the parts its handler did not finish (${played.join(', ')} finished)` : ' it';
        log(`alert ${alertId} (${alert.kind} of ${alert.timerId}) was unacknowledged when the last daemon ended; the ${sink.name} sink plays${rest}.`);
        play(alertId, alert, timer, { played, started });
      }
      const resumed = leftUnfinished;
      leftUnfinished = [];
      for (const { alertId, alert, timer } of resumed) {
        const played = [...journal.played(alertId)];
        log(`alert ${alertId} (${alert.kind} of ${alert.timerId}) was playing when the last daemon ended${played.length ? ` (${played.join(', ')} done)` : ''}; the ${sink.name} sink plays the rest.`);
        play(alertId, alert, timer);
      }
    },

    /**
     * At shutdown: the handler is dropped and every pending alert falls back; taken alerts stay
     * saved for the next daemon, which plays any no handler claims. A daemon that lost
     * `daemon.lock` plays none: the daemon that holds it plays those this one saved, and delivers
     * again those whose marks this one could not save. Returns a promise that settles once the sink
     * has finished every play it started (fallbacks, alerts with no handler and replayed
     * handoffs); nothing plays after that.
     */
    stop({ lockLost = false } = {}) {
      handler = null;
      for (const handle of orphaned.values()) clock.clearTimeout(handle);
      orphaned.clear();
      journal.close();
      if (lockLost) leaveToLockHolder();
      else fallBackAll(null, 'was pending when the daemon stopped');
      stopped = true;
      return Promise.allSettled([...playing]);
    }
  };
}
