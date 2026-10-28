import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { ALERT_PROCESS_TIMEOUT_MS } from '../alerts/process.mjs';
import { holderAlive, processBirth } from './lock.mjs';

/** The key of one SET-74 transition of a timer, as the scheduler and the play journal name it. */
export const transitionKey = (timerId, transition) => `${timerId}:${transition.type}:${transition.at}`;

/** How long a daemon waits for a sound or notification process an earlier daemon left running before it stops it. */
export const LEFT_PROCESS_WAIT_MS = ALERT_PROCESS_TIMEOUT_MS;
const POLL_MS = 100;
const BOOT_ID = /^[0-9A-Fa-f-]{1,64}$/;

let ownBoot;
/**
 * An id of the current boot of the system, read once: Linux's `boot_id`, macOS's
 * `kern.bootsessionuuid`; null when it cannot be told.
 */
export function bootId({ platform = process.platform, readFile = readFileSync, sysctl = (name) => execFileSync('/usr/sbin/sysctl', ['-n', name], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 2_000 }) } = {}) {
  try {
    const id = (platform === 'linux' ? readFile('/proc/sys/kernel/random/boot_id', 'utf8') : platform === 'darwin' ? sysctl('kern.bootsessionuuid') : '').trim();
    return BOOT_ID.test(id) ? id : null;
  } catch {
    return null;
  }
}

/** How the journal tells the fate of a sink process: the real system's processes. */
export const systemProcesses = {
  boot: () => (ownBoot ??= { value: bootId() }).value,
  birth: (pid) => processBirth(pid),
  /** True while the process `{ pid, birth }` is alive, and not another process later given its pid. */
  alive: (child) => holderAlive(child),
  kill(pid) {
    try {
      process.kill(pid, 'SIGKILL');
    } catch {
      // Gone already.
    }
  },
  sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms))
};

const serialize = ([alertId, { alert, timer, subscriberId, keys, played, running, finished }]) => ({
  alertId,
  alert,
  timer,
  ...(subscriberId === null ? {} : { subscriberId }),
  keys,
  played: [...played],
  ...(running.size ? { running: Object.fromEntries(running) } : {}),
  finished
});

/**
 * The play journal (`plays.json`): each alert the daemon's sink started playing, written before the
 * sink is called, with the parts of it that have finished (`played`: `notification`,
 * `sound:<index>`), the process playing each part still running (`running`: its pid, its birth and
 * the boot it ran in, written once it was spawned), and whether the whole play has finished. So the
 * next daemon tells an alert the sink never started (no entry: `scheduler.json` still holds it, and
 * it plays in full) from one it started (it plays only the parts not finished) and from one it
 * finished (it plays nothing, though `scheduler.json` may still hold it as a handoff or
 * acknowledgement, or hold marks behind the transitions it stands for, `keys`).
 *
 * A part left running is decided by its process, which outlives the daemon that spawned it
 * (`settle`): one still running is waited for, up to `LEFT_PROCESS_WAIT_MS`, and one that exited in
 * this boot counts as finished, as nothing else stops it; one from an earlier boot, or whose boot
 * cannot be told, died with that boot, so its part plays again. So does a part whose process was
 * spawned by a daemon that ended before writing it.
 *
 * An entry is kept until its play has finished and `scheduler.json` has been saved since without an
 * unfinished copy of it, and a write of the journal then drops it. A write that fails is logged,
 * the journal is `behind` and `onBehind()` is called: until a write succeeds again (which calls it
 * once more), every save of `scheduler.json` carries the entries (`carried`), so whichever file can
 * be written records the play, and a daemon that ends meanwhile leaves the next one each part's
 * state. `persist` writes the entries; `entries` are those earlier daemons left, from either file:
 * copies of one play are merged, as each only ever gains parts.
 */
export function createPlayJournal({ entries = [], persist = () => {}, log = () => {}, onBehind = () => {}, processes = systemProcesses } = {}) {
  /** alertId → { alert, timer, subscriberId, keys, played: Set, running: Map(part → { pid, birth, boot }), finished, saved }. */
  const plays = new Map();
  let behind = false;
  for (const { alertId, alert, timer, subscriberId = null, keys, played, running = {}, finished } of entries) {
    const known = plays.get(alertId);
    if (!known) {
      plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), running: new Map(Object.entries(running)), finished, saved: false });
      continue;
    }
    for (const key of keys) if (!known.keys.includes(key)) known.keys.push(key);
    for (const part of played) known.played.add(part);
    for (const [part, child] of Object.entries(running)) if (!known.running.has(part)) known.running.set(part, child);
    known.finished ||= finished;
  }
  for (const entry of plays.values()) for (const part of entry.played) entry.running.delete(part);

  /** Writes the journal without the entries no longer needed, dropping those once written. */
  function flush({ changed = true } = {}) {
    const forget = [...plays].filter(([, entry]) => entry.finished && entry.saved).map(([alertId]) => alertId);
    try {
      persist([...plays].filter(([alertId]) => !forget.includes(alertId)).map(serialize));
    } catch (error) {
      log(`could not save plays.json: ${error.message}`);
      const was = behind;
      behind = true;
      // Only news needs carrying: a write that would only have dropped entries changed nothing.
      if (changed || !was) onBehind();
      return;
    }
    for (const alertId of forget) plays.delete(alertId);
    if (behind) {
      behind = false;
      onBehind();
    }
  }

  function markDone(entry, part) {
    entry.played.add(part);
    entry.running.delete(part);
  }

  /** Waits until the process left playing `part` has exited, stopping it after `LEFT_PROCESS_WAIT_MS`. */
  async function waitFor(entry, part, child) {
    const boot = processes.boot();
    if (child.boot === null || boot === null || child.boot !== boot) {
      entry.running.delete(part);
      return;
    }
    for (let waited = 0; processes.alive(child); waited += POLL_MS) {
      if (waited >= LEFT_PROCESS_WAIT_MS) {
        if (child.birth !== null) processes.kill(child.pid);
        break;
      }
      await processes.sleep(POLL_MS);
    }
    markDone(entry, part);
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
    /** Whether the last write of `plays.json` failed. */
    get behind() {
      return behind;
    },
    /** What a save of `scheduler.json` carries of the journal: every entry while `behind`, else none. */
    get carried() {
      return behind ? [...plays].map(serialize) : [];
    },

    /** Records, before the sink is called, that it starts playing `alertId`, with the parts `played` already. */
    begin(alertId, { alert, timer, subscriberId = null, keys = [], played = [] }) {
      plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), running: new Map(), finished: false, saved: false });
      flush();
    },

    /** Records the process `pid` the sink spawned to play `part` of `alertId`. */
    started(alertId, part, pid) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished || entry.played.has(part) || !Number.isSafeInteger(pid) || pid <= 0) return;
      entry.running.set(part, { pid, birth: processes.birth(pid), boot: processes.boot() });
      flush();
    },

    /** Records that `part` of `alertId` finished playing. */
    done(alertId, part) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished || entry.played.has(part)) return;
      markDone(entry, part);
      flush();
    },

    /** Records that the sink finished `alertId` (played, failed or gave up). */
    finish(alertId) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished) return;
      entry.finished = true;
      entry.running.clear();
      flush();
    },

    /** Whether a process an earlier daemon spawned may still be playing a part of `alertId`. */
    left: (alertId) => (plays.get(alertId)?.running.size ?? 0) > 0,

    /**
     * Decides each part of `alertId` an earlier daemon left running from its process (see above), and
     * records it; resolves once every one is decided, never rejecting.
     */
    async settle(alertId) {
      const entry = plays.get(alertId);
      if (!entry?.running.size) return;
      await Promise.all([...entry.running].map(([part, child]) => waitFor(entry, part, child).catch(() => entry.running.delete(part))));
      const done = [...entry.played];
      log(`alert ${alertId} was left playing by the last daemon; ${done.length ? `${done.join(', ')} finished` : 'no part finished'}.`);
      flush();
    },

    /**
     * Called once `scheduler.json` has been saved with `carried` (the journal entries that save
     * carried): plays that finished and that it no longer holds unfinished are dropped.
     */
    saved(carried = []) {
      const copies = new Set(carried.filter((entry) => !entry.finished).map(({ alertId }) => alertId));
      for (const [alertId, entry] of plays) entry.saved = !copies.has(alertId);
      if ([...plays.values()].some((entry) => entry.finished && entry.saved)) flush({ changed: false });
    }
  };
}
