import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { ALERT_PROCESS_TIMEOUT_MS } from '../alerts/process.mjs';
import { holderAlive, pidAlive, processBirth } from './lock.mjs';

/** The key of one SET-74 transition of a timer, as the scheduler and the play journal name it. */
export const transitionKey = (timerId, transition) => `${timerId}:${transition.type}:${transition.at}`;

/** How long a daemon waits for a sound or notification process an earlier daemon left running before it stops it. */
export const LEFT_PROCESS_WAIT_MS = ALERT_PROCESS_TIMEOUT_MS;
const POLL_MS = 100;
/** How often a daemon checks whether an alert handler (the app) still runs while it holds a part. */
const HANDLER_POLL_MS = 1_000;
/**
 * How often a wait for a process also checks its birth, which tells a pid the system gave to another
 * process, as that takes a `ps` on macOS that blocks the daemon for a few milliseconds; each poll in
 * between only asks whether the pid exists.
 */
export const BIRTH_CHECK_MS = 30_000;
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
  /** True while a process with this pid exists, whichever it is. */
  exists: (pid) => pidAlive(pid),
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

/** `{ pid, birth, boot }` of the process `pid` now, with `app: true` for an alert handler's. */
export function executorOf(processes, pid, { app = false } = {}) {
  return { pid, birth: processes.birth(pid), boot: processes.boot(), ...(app ? { app } : {}) };
}

/** Whether `error` says this daemon no longer holds `daemon.lock` (server.mjs `LockLostError`). */
export const isLockLost = (error) => error?.name === 'LockLostError';

const body = ([alertId, { alert, timer, subscriberId, keys, played, running, finished }]) => ({
  alertId,
  alert,
  timer,
  ...(subscriberId === null ? {} : { subscriberId }),
  keys,
  played: [...played],
  ...(running.size ? { running: Object.fromEntries([...running].map(([part, child]) => [part, { ...child }])) } : {}),
  finished
});

/** Gives the journal entry `play` its next revision if it changed since it last got one. */
function stamp(play) {
  const now = JSON.stringify(body(play));
  if (now === play[1].stamped) return;
  play[1].rev += 1;
  play[1].stamped = now;
}

const serialize = (play) => {
  stamp(play);
  return { ...body(play), rev: play[1].rev };
};

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
 * A part left running is decided by its executor (`settle`). A sink process outlives the daemon
 * that spawned it: one still running is waited for, up to `LEFT_PROCESS_WAIT_MS`, then stopped, and
 * one that exited in this boot counts as finished, as nothing else stops it. Its pid and boot are
 * written as soon as it is spawned, and its birth (which tells a reused pid) in a second write, so a
 * daemon that ends between the spawn and the first write, a moment, leaves the part to play again.
 * While `plays.json` cannot be written, the birth is looked up only once the `scheduler.json` save
 * that write's failure asked for has carried the pid (`started`).
 * A part an alert handler (the app, `app: true`) started and did not say it finished is `held`: a
 * running app is no proof it finished it, so it stays undecided in the journal, across daemons, for
 * as long as the app runs (`awaitHandler`), until the app says it finished it (`done`) or ends, and
 * then it plays, as its sound ended with the app. The sink plays the other parts meanwhile. A part
 * from an earlier boot, or whose boot cannot be told, died with that boot, so it plays again. A
 * handler that asks about a part held for it decides it at once (`holder`, `giveBack`).
 *
 * `progress` are the parts an alert handler finished (`played`) or was permitted to start, with its
 * process (`started`), of alerts it holds, which `scheduler.json` has not recorded yet as it could
 * not be saved (`handled`): the next daemon adds them to its acknowledgements, and a save of
 * `scheduler.json` that records them drops them.
 *
 * An entry is kept until its play has finished and `scheduler.json` has been saved since without an
 * unfinished copy of it, and a write of the journal then drops it. A write that fails is logged,
 * the journal is `behind` and `onBehind()` is called: until a write succeeds again (which calls it
 * once more), every save of `scheduler.json` carries the entries (`carried`), so whichever file can
 * be written records the play, and a daemon that ends meanwhile leaves the next one each part's
 * state. `persist(entries, progress)` writes the journal; `entries` are those earlier daemons left,
 * from either file. Each copy of an entry has a revision (`rev`), which every change to it raises,
 * so copies of one play are merged in order: the parts finished in either count, as a play only ever
 * gains them, and the parts left running are the newer copy's, as a part can also stop being held
 * (`giveBack`) without finishing, and a file that could not be written keeps an older copy.
 * `recover()` writes them before anything else can save `scheduler.json`, which may hold the only
 * copy. A write
 * refused as this daemon lost `daemon.lock` (`isLockLost`) is not `behind`: it records nothing, and
 * the daemon that holds the lock has the journal.
 */
export function createPlayJournal({ entries = [], progress = [], persist = () => {}, log = () => {}, onBehind = () => {}, processes = systemProcesses } = {}) {
  /** alertId → { alert, timer, subscriberId, keys, played: Set, running: Map(part → { pid, birth, boot, app? }), finished, saved, rev, stamped }. */
  const plays = new Map();
  /** alertId → { played, started, rev }: the parts its handler finished or started that `scheduler.json` may not hold. */
  const handled = new Map(progress.map(({ alertId, played, started = {}, rev = 0 }) => [alertId, { played: [...played], started: { ...started }, rev }]));
  const progressOf = ([alertId, { played, started, rev }]) => ({ alertId, played: [...played], ...(Object.keys(started).length ? { started: { ...started } } : {}), ...(rev ? { rev } : {}) });
  let behind = false;
  let closed = false;
  /** Resolves the current poll of each `awaitHandler` (see `wake`). */
  const wakes = new Set();
  for (const { alertId, alert, timer, subscriberId = null, keys, played, running = {}, finished, rev = 0 } of entries) {
    const known = plays.get(alertId);
    if (!known) {
      plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), running: new Map(Object.entries(running)), finished, saved: false, rev });
      continue;
    }
    for (const key of keys) if (!known.keys.includes(key)) known.keys.push(key);
    for (const part of played) known.played.add(part);
    if (rev > known.rev) known.running = new Map(Object.entries(running));
    else if (rev === known.rev) for (const [part, child] of Object.entries(running)) if (!known.running.has(part)) known.running.set(part, child);
    known.rev = Math.max(known.rev, rev);
    known.finished ||= finished;
  }
  for (const entry of plays.values()) for (const part of entry.played) entry.running.delete(part);

  /** Writes the journal without the entries no longer needed, dropping those once written; returns the error of a failed write. */
  function flush({ changed = true } = {}) {
    const forget = [...plays].filter(([, entry]) => entry.finished && entry.saved).map(([alertId]) => alertId);
    try {
      persist(
        [...plays].filter(([alertId]) => !forget.includes(alertId)).map(serialize),
        [...handled].map(progressOf)
      );
    } catch (error) {
      if (isLockLost(error)) return error;
      log(`could not save plays.json: ${error.message}`);
      const was = behind;
      behind = true;
      // Only news needs carrying: a write that would only have dropped entries changed nothing.
      if (changed || !was) onBehind();
      return error;
    }
    for (const alertId of forget) plays.delete(alertId);
    if (behind) {
      behind = false;
      onBehind();
    }
    return null;
  }

  function markDone(entry, part) {
    entry.played.add(part);
    entry.running.delete(part);
    wake();
  }

  /**
   * Ends every `awaitHandler` poll now, so a part its handler finished or gave back is decided at
   * once; each checks again only once the current task ends, after a `giveBack` that is restored.
   */
  function wake() {
    for (const resolve of wakes) resolve();
    wakes.clear();
  }

  /** Whether `child` ran in an earlier boot, or one that cannot be told, so it died with it. */
  function fromEarlierBoot(child) {
    const boot = processes.boot();
    return child.boot === null || boot === null || child.boot !== boot;
  }

  /**
   * A check, polled every `pollMs`, of whether `child` is still alive: whether its pid exists, and,
   * on the first poll and every `BIRTH_CHECK_MS` after, whether it is still the same process.
   */
  function watch(child, pollMs) {
    const every = Math.max(1, Math.round(BIRTH_CHECK_MS / pollMs));
    let polls = 0;
    return () => processes.exists(child.pid) && (polls++ % every !== 0 || processes.alive(child));
  }

  /**
   * Waits until the sink process left playing `part` has ended, up to `LEFT_PROCESS_WAIT_MS`, then
   * records the part as finished, or to play again when it died with an earlier boot (see above).
   */
  async function waitFor(entry, part, child) {
    if (fromEarlierBoot(child)) {
      entry.running.delete(part);
      return;
    }
    const alive = watch(child, POLL_MS);
    for (let waited = 0; alive(); waited += POLL_MS) {
      if (entry.played.has(part)) return;
      if (waited >= LEFT_PROCESS_WAIT_MS) {
        // Never a process later given its pid.
        if (child.birth !== null && processes.alive(child)) processes.kill(child.pid);
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

    /**
     * Records, before the sink is called, that it starts playing `alertId`, with the parts `played`
     * already and those its handler's executor may still be playing (`running`, `part → executor`).
     */
    begin(alertId, { alert, timer, subscriberId = null, keys = [], played = [], running = {} }) {
      const left = Object.entries(running).filter(([part]) => !played.includes(part));
      plays.set(alertId, { alert, timer, subscriberId, keys, played: new Set(played), running: new Map(left), finished: false, saved: false, rev: 0 });
      flush();
    },

    /**
     * Records the process `pid` the sink spawned to play `part` of `alertId`: its pid and boot at
     * once, then its birth, whose lookup blocks for a few milliseconds (up to 2 s). When `plays.json`
     * cannot be written, the lookup waits for the `scheduler.json` save `onBehind()` asked for in a
     * microtask, which carries the pid, so a daemon that ends meanwhile has written it somewhere.
     */
    started(alertId, part, pid) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished || entry.played.has(part) || !Number.isSafeInteger(pid) || pid <= 0) return;
      const child = { pid, birth: null, boot: processes.boot() };
      entry.running.set(part, child);
      const lookUpBirth = () => {
        if (entry.running.get(part) !== child) return;
        child.birth = processes.birth(pid);
        if (child.birth !== null && entry.running.get(part) === child) flush();
      };
      const error = flush();
      // Queued after the save onBehind() queued, so that save runs first.
      if (error && !isLockLost(error)) queueMicrotask(lookUpBirth);
      else lookUpBirth();
    },

    /** Records that `part` of `alertId` finished playing. */
    done(alertId, part) {
      const entry = plays.get(alertId);
      if (!entry || entry.finished || entry.played.has(part)) return;
      markDone(entry, part);
      flush();
    },

    /**
     * Whether the alert handler `subscriberId`'s process may still be playing `part` of `alertId`,
     * which the sink holds for it.
     */
    awaitsHandler: (alertId, part, subscriberId) => {
      const entry = plays.get(alertId);
      return entry?.subscriberId === subscriberId && entry.running.get(part)?.app === true;
    },

    /** The parts of `alertId` its handler's process may still be playing, after `settle`: the sink plays the others. */
    held: (alertId) => [...(plays.get(alertId)?.running ?? [])].filter(([, child]) => child.app).map(([part]) => part),

    /** The process of the alert handler `subscriberId` the sink holds `part` of `alertId` for, or null. */
    holder(alertId, part, subscriberId) {
      const entry = plays.get(alertId);
      const child = entry?.subscriberId === subscriberId ? entry.running.get(part) : null;
      return child?.app ? child : null;
    },

    /**
     * Gives the parts `parts` of `alertId`, held for its handler's process, back to the sink, which
     * plays them once `awaitHandler` sees it; returns the error of a failed write (see `flush`), and
     * `restore()`, which holds them again.
     */
    giveBack(alertId, parts) {
      const entry = plays.get(alertId);
      const children = parts.map((part) => [part, entry.running.get(part)]);
      for (const part of parts) entry.running.delete(part);
      wake();
      const error = flush();
      return {
        error,
        restore: () => {
          for (const [part, child] of children) entry.running.set(part, child);
        }
      };
    },

    /**
     * Resolves once `part` of `alertId`, which the handler's process holds, is decided: the handler
     * said it finished it (`played(alertId)` holds it), or its process ended (seen within
     * `HANDLER_POLL_MS`), or the handler gave it back (`giveBack`; it does not, and the sink plays
     * it), or the journal was closed first (still held, for the next daemon). The first and the last
     * two end the wait at once (`wake`).
     */
    async awaitHandler(alertId, part) {
      const entry = plays.get(alertId);
      const child = entry?.running.get(part);
      if (!child?.app) return;
      const alive = watch(child, HANDLER_POLL_MS);
      while (!entry.played.has(part) && entry.running.get(part) === child && alive()) {
        if (closed) return;
        await new Promise((resolve) => {
          wakes.add(resolve);
          processes.sleep(HANDLER_POLL_MS).then(() => {
            wakes.delete(resolve);
            resolve();
          });
        });
      }
      if (!entry.played.has(part)) entry.running.delete(part);
    },

    /** Stops every wait for a handler: the parts stay held in the journal, for the next daemon. */
    close() {
      closed = true;
      wake();
    },

    /** Writes the entries and progress earlier daemons left, so `plays.json` holds them before `scheduler.json` is saved again. */
    recover() {
      if (plays.size || handled.size) flush();
    },

    /** The parts of alerts their handler holds that it finished or started and `scheduler.json` may not hold (see above). */
    get handled() {
      return [...handled].map(progressOf);
    },

    /**
     * Records that the handler finished the parts `played` of `alertId`, which it holds, and that its
     * process plays each part in `started`, as `scheduler.json` could not be saved; true once
     * `plays.json` holds them. Unless `keep`, a failed write forgets them again.
     */
    handle(alertId, { played = [], started = {}, rev = 0 }, { keep = true } = {}) {
      const before = handled.get(alertId);
      handled.set(alertId, { played: [...played], started: { ...started }, rev });
      const error = flush();
      if (error && !keep) {
        if (before) handled.set(alertId, before);
        else handled.delete(alertId);
      }
      if (isLockLost(error)) throw error;
      return !behind;
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
     * Decides each part of `alertId` a sink process an earlier daemon spawned was left playing, from
     * that process, and drops each its handler's process ran in an earlier boot (see above), and
     * records it; resolves once every one is decided, never rejecting. The parts the handler's
     * process holds in this boot stay `held`.
     */
    async settle(alertId) {
      const entry = plays.get(alertId);
      const left = [...(entry?.running ?? [])].filter(([, child]) => !child.app || fromEarlierBoot(child));
      if (!left.length) return;
      await Promise.all(left.map(([part, child]) => (child.app ? entry.running.delete(part) : waitFor(entry, part, child).catch(() => entry.running.delete(part)))));
      const done = [...entry.played];
      log(`alert ${alertId}: of the parts left playing, ${done.length ? `${done.join(', ')} finished` : 'none finished'}.`);
      flush();
    },

    /**
     * Called once `scheduler.json` has been saved with `carried` (the journal entries that save
     * carried) and `held` (the handoffs and acknowledgements it saved): plays that finished and that
     * it no longer holds unfinished are dropped, and so are the handled parts of each alert it does
     * not hold with fewer parts: every finished part finished, and, while acknowledged (with a
     * `subscriberId`), every started part finished or started.
     */
    saved(carried = [], held = []) {
      const copies = new Set(carried.filter((entry) => !entry.finished).map(({ alertId }) => alertId));
      for (const [alertId, entry] of plays) entry.saved = !copies.has(alertId);
      let recorded = false;
      for (const [alertId, { played, started }] of handled) {
        const behindIt = held.find((entry) => {
          if (entry.alertId !== alertId) return false;
          const finished = entry.played ?? [];
          if (played.some((part) => !finished.includes(part))) return true;
          return entry.subscriberId !== undefined && Object.keys(started).some((part) => !finished.includes(part) && !entry.started?.[part]);
        });
        if (!behindIt) recorded = handled.delete(alertId);
      }
      if (recorded || [...plays.values()].some((entry) => entry.finished && entry.saved)) flush({ changed: false });
    }
  };
}
