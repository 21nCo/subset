import { intervalStep } from '@subset/timer';

/**
 * @typedef {'segment' | 'tick' | 'finish' | 'missedWhileAway'} AlertKind
 *
 * @typedef {object} TimerAlert An `alert` event, also passed to the sink.
 * @property {string} timerId
 * @property {AlertKind} kind
 * @property {number} at Epoch milliseconds: when the transition happened, or for `missedWhileAway` when the daemon noticed.
 * @property {{ index: number, round: number | null, phase: string, label: string, durationMs: number }} [segment]
 *   The interval step that began (`segment`) or is ending (`tick`).
 * @property {1 | 2 | 3} [secondsLeft] For `tick`.
 * @property {number} [missed] For `missedWhileAway`: how many transitions it stands for.
 *
 * @typedef {object} AlertSink Plays or shows alerts. The daemon waits for a sink only at shutdown, and a sink
 *   that throws or rejects is logged and ignored. A sink honours `timer.sound` itself.
 * @property {string} name Shown by `daemon status`.
 * @property {(alert: TimerAlert, timer: import('@subset/timer').TimerDefinition) => void | Promise<void>} alert
 */

/** The step fields an alert carries. */
function segmentOf(step) {
  return { index: step.index, round: step.round, phase: step.phase, label: step.label, durationMs: step.durationMs };
}

/** The alert for one SET-74 `transitionsBetween` entry. */
export function alertFromTransition(transition, definition) {
  const { timerId, at } = transition;
  switch (transition.type) {
    case 'segment':
      return { timerId, kind: 'segment', segment: segmentOf(transition.step), at };
    case 'tick': {
      const alert = { timerId, kind: 'tick', secondsLeft: transition.secondsLeft, at };
      if (transition.stepIndex !== null && definition.kind === 'interval') alert.segment = segmentOf(intervalStep(definition, transition.stepIndex));
      return alert;
    }
    case 'finish':
      return { timerId, kind: 'finish', at };
  }
  throw new Error(`Unknown transition ${transition.type}`);
}

/** How many alerts the recording sink keeps; a daemon that runs for weeks holds no more than this. */
export const RECORDING_LIMIT = 1_000;

/**
 * The default sink until SET-77 adds sound and notifications: it records alerts in memory, keeping
 * only the latest `limit` in `received`, oldest first.
 */
export function createRecordingSink({ limit = RECORDING_LIMIT } = {}) {
  const received = [];
  return {
    name: 'recording',
    received,
    limit,
    alert(alert, timer) {
      received.push({ alert, timer });
      if (received.length > limit) received.splice(0, received.length - limit);
    }
  };
}

/**
 * Calls the sink without waiting for it and without letting it fail the daemon. Returns, for a sink
 * that answers with a promise, one that fulfils (never rejects) when the sink is done, even when
 * `log` throws while reporting the sink's failure.
 */
export function deliverToSink(sink, alert, timer, log) {
  const report = (error) => {
    try {
      log(`alert sink ${sink.name} failed: ${error?.message ?? error}`);
    } catch {
      // A log that cannot be written must not turn a failed sound into a daemon failure.
    }
  };
  try {
    const pending = sink.alert(alert, timer);
    if (pending && typeof pending.then === 'function') return pending.then(undefined, report);
  } catch (error) {
    report(error);
  }
  return undefined;
}
