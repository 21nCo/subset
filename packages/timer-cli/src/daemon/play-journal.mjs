/** The key of one SET-74 transition of a timer, as the scheduler and the play journal name it. */
export const transitionKey = (timerId, transition) => `${timerId}:${transition.type}:${transition.at}`;

/**
 * The play journal (`plays.json`): each alert the daemon's sink started playing, written before the
 * sink is called, with the parts of it that have finished (`notification`, `sound:<index>`) and
 * whether the whole play has. So the next daemon can tell an alert the sink never started (no entry:
 * `scheduler.json` still holds it, and it plays in full) from one it started (it plays only the
 * parts not finished, so a sound cut off by a crash plays again and a finished notification does
 * not) and from one it finished (it plays nothing, though `scheduler.json` may still hold it as a
 * handoff or acknowledgement, or hold marks behind the transitions it stands for, `keys`).
 *
 * An entry is kept until its play has finished and `scheduler.json` has been saved since the entry
 * began: by then that file no longer holds the alert, nor marks behind it. A write that fails is
 * logged and the entry is kept in memory, so the next write records it; until then a daemon that
 * ends leaves the alert to the next one as `scheduler.json` holds it (at least once). `persist`
 * writes the entries; `entries` are those an earlier daemon left.
 */
export function createPlayJournal({ entries = [], persist = () => {}, log = () => {} } = {}) {
  /** alertId → { alert, timer, subscriberId, keys, played: Set, finished, saved }. */
  const plays = new Map();
  for (const { alertId, alert, timer, subscriberId = null, keys, played, finished } of entries) {
    plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), finished, saved: false });
  }

  function flush() {
    const list = [...plays].map(([alertId, { alert, timer, subscriberId, keys, played, finished }]) => ({
      alertId,
      alert,
      timer,
      ...(subscriberId === null ? {} : { subscriberId }),
      keys,
      played: [...played],
      finished
    }));
    try {
      persist(list);
    } catch (error) {
      log(`could not save plays.json: ${error.message}`);
    }
  }

  return {
    has: (alertId) => plays.has(alertId),
    /** The parts of `alertId` that have finished. */
    played: (alertId) => new Set(plays.get(alertId)?.played),
    /** Whether a journaled play stands for the transition with this `transitionKey`. */
    delivered: (key) => [...plays.values()].some((entry) => entry.keys.includes(key)),
    /** `{ alertId, alert, timer, subscriberId }` for each play that has not finished. */
    get unfinished() {
      return [...plays].filter(([, entry]) => !entry.finished).map(([alertId, { alert, timer, subscriberId }]) => ({ alertId, alert, timer, subscriberId }));
    },
    /** `{ alertId, subscriberId }` for each entry, finished or not. */
    get entries() {
      return [...plays].map(([alertId, { subscriberId }]) => ({ alertId, subscriberId }));
    },

    /** Records, before the sink is called, that it starts playing `alertId`, with the parts `played` already. */
    begin(alertId, { alert, timer, subscriberId = null, keys = [], played = [] }) {
      plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), finished: false, saved: false });
      flush();
    },

    /** Records that `part` of `alertId` finished playing. */
    done(alertId, part) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished || entry.played.has(part)) return;
      entry.played.add(part);
      flush();
    },

    /** Records that the sink finished `alertId` (played, failed or gave up). */
    finish(alertId) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished) return;
      entry.finished = true;
      if (entry.saved) plays.delete(alertId);
      flush();
    },

    /** Called once `scheduler.json` has been saved: finished entries are no longer needed. */
    saved() {
      let changed = false;
      for (const [alertId, entry] of plays) {
        if (entry.finished) {
          plays.delete(alertId);
          changed = true;
        } else entry.saved = true;
      }
      if (changed) flush();
    }
  };
}
