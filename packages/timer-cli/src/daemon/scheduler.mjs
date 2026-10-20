import { project, transitionsBetween } from '@subset/timer';
import { alertFromTransition } from './alerts.mjs';

/** A transition handled more than this long after it happened was missed, for example during sleep. */
export const LATE_MS = 2_000;
/** The longest the scheduler waits before looking again, so a changed wall clock is noticed. */
export const REARM_MS = 60_000;

/** The production clock and timer source; tests inject a fake with the same shape. */
export const systemClock = {
  now: () => Date.now(),
  setTimeout: (callback, ms) => setTimeout(callback, ms),
  clearTimeout: (handle) => clearTimeout(handle)
};

function stepSegment(step) {
  return { index: step.index, round: step.round, phase: step.phase, label: step.label, durationMs: step.durationMs };
}

/** The running stretch a timer is in, or null: its start time and its position when it began. */
function stretchOf(timer) {
  const { runtime } = timer;
  if (runtime.status !== 'running' || runtime.startedAt === null) return null;
  return { startedAt: runtime.startedAt, base: runtime.accumulatedMs + runtime.skippedMs };
}

const sameStretch = (mark, stretch) => mark.startedAt === stretch.startedAt && mark.base === stretch.base;

/**
 * Turns running timers' transitions into alerts. For each running stretch it keeps a mark: the
 * time, on that stretch's own timeline, through which its transitions have been handled. A mark
 * only moves forward, so a wall clock set back never repeats an alert, and a stretch that begins
 * (a start, resume or skip) is marked from the moment of the operation, so a skip never fires what
 * it jumped over. It arms one timeout for the earliest upcoming transition across running timers
 * (at most `REARM_MS` ahead).
 *
 * Every run calls `onRun(alerts, now)`, with the alerts for the transitions since each mark: those
 * more than `LATE_MS` old collapse into one `missedWhileAway` alert per timer, ahead of the ones on
 * time. `initialMarks` are the marks an earlier daemon persisted; on the first run a stretch with
 * none counts from its start, so what happened while no daemon ran is reported as missed.
 */
export function createScheduler({ clock = systemClock, getTimers, onRun, initialMarks = null }) {
  let marks = new Map((initialMarks ?? []).map((mark) => [mark.timerId, mark]));
  let firstRun = true;
  let handle = null;
  let stopped = false;

  /** Marks for the stretches running now, keeping those already known. */
  function markStretches(now) {
    const next = new Map();
    for (const timer of getTimers()) {
      const stretch = stretchOf(timer);
      if (!stretch) continue;
      const timerId = timer.definition.id;
      const known = marks.get(timerId);
      if (known && sameStretch(known, stretch)) next.set(timerId, known);
      else next.set(timerId, { timerId, ...stretch, through: firstRun ? stretch.startedAt : Math.max(stretch.startedAt, now) });
    }
    marks = next;
    firstRun = false;
  }

  function due(now) {
    const missed = [];
    const onTime = [];
    for (const timer of getTimers()) {
      const mark = marks.get(timer.definition.id);
      if (!mark) continue;
      const transitions = transitionsBetween(timer, mark.through, now);
      if (now > mark.through) marks.set(mark.timerId, { ...mark, through: now });
      if (!transitions.length) continue;
      const { definition } = timer;
      const late = transitions.filter((transition) => now - transition.at > LATE_MS);
      if (late.length) {
        const alert = { timerId: definition.id, kind: 'missedWhileAway', missed: late.length, at: now };
        const { step } = project(timer, now);
        if (step) alert.segment = stepSegment(step);
        missed.push({ alert, timer: definition });
      }
      for (const transition of transitions) {
        if (now - transition.at <= LATE_MS) onTime.push({ alert: alertFromTransition(transition, definition), timer: definition });
      }
    }
    // Sorting is stable, so one timer's transitions at the same time keep the engine's order.
    onTime.sort((a, b) => a.alert.at - b.alert.at);
    return [...missed, ...onTime];
  }

  /**
   * Delivers every transition due by `now`, then re-arms. Safe to call at any time. An operation
   * passes the `now` it ran at, before and after it changes the timers.
   */
  function run(now = clock.now()) {
    if (stopped) return;
    markStretches(now);
    const alerts = due(now);
    onRun(alerts, now);
    arm();
  }

  function arm() {
    if (handle !== null) clock.clearTimeout(handle);
    handle = null;
    if (stopped) return;
    const now = clock.now();
    let delay = REARM_MS;
    for (const timer of getTimers()) {
      const mark = marks.get(timer.definition.id);
      if (!mark) continue;
      const from = Math.max(now, mark.through);
      const [next] = transitionsBetween(timer, from, from + REARM_MS);
      if (next) delay = Math.min(delay, Math.max(1, next.at - now));
    }
    handle = clock.setTimeout(() => {
      handle = null;
      run();
    }, delay);
  }

  function stop() {
    stopped = true;
    if (handle !== null) clock.clearTimeout(handle);
    handle = null;
  }

  return {
    run,
    stop,
    /** The marks of the running stretches, as `initialMarks` takes them. */
    get marks() {
      return [...marks.values()];
    }
  };
}
