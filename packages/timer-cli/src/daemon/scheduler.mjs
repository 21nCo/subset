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

/**
 * Turns running timers' transitions into alerts. It keeps `checkedThrough`, the time through which
 * every transition has been handled, and arms one timeout for the earliest upcoming transition
 * across running timers (at most `REARM_MS` ahead). Each run hands `deliver` the alerts for the
 * transitions in `(checkedThrough, now]`: those more than `LATE_MS` old collapse into one
 * `missedWhileAway` alert per timer, ahead of the ones on time.
 *
 * `checkedThrough` starts at `initialMark`, the time persisted by an earlier daemon. Null means no
 * alert was ever delivered, so every transition of a running stretch counts.
 */
export function createScheduler({ clock = systemClock, getTimers, deliver, initialMark = null }) {
  let checkedThrough = initialMark ?? 0;
  let handle = null;
  let stopped = false;

  function due(now) {
    const missed = [];
    const onTime = [];
    for (const timer of getTimers()) {
      const transitions = transitionsBetween(timer, checkedThrough, now);
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

  /** Delivers every transition due by now, then re-arms. Safe to call at any time. */
  function run() {
    if (stopped) return;
    const now = clock.now();
    if (now < checkedThrough) {
      // A small step back waits for the clock to catch up; a large one is a reset clock, so the
      // scheduler follows it rather than staying silent until the old time comes round again.
      if (checkedThrough - now > LATE_MS) checkedThrough = now;
      arm();
      return;
    }
    const alerts = due(now);
    checkedThrough = now;
    if (alerts.length) deliver(alerts, now);
    arm();
  }

  function arm() {
    if (handle !== null) clock.clearTimeout(handle);
    handle = null;
    if (stopped) return;
    const now = clock.now();
    const from = Math.max(now, checkedThrough);
    let delay = REARM_MS;
    for (const timer of getTimers()) {
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

  return { run, stop, get checkedThrough() { return checkedThrough; } };
}
