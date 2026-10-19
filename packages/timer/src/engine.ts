import type { IntervalDefinition, Phase, Timer, TimerDefinition, TimerRuntime, TimerStatus } from './model.js';

/** One step of an interval timer's flattened sequence: the optional prep, each segment of each round, the optional cooldown. */
export interface IntervalStep {
  index: number;
  /** Index into `segments`; null for the prep and cooldown steps. */
  segmentIndex: number | null;
  /** 1-based; null for the prep and cooldown steps. */
  round: number | null;
  phase: Phase;
  label: string;
  /** Position on the timer where the step begins. */
  startMs: number;
  durationMs: number;
}

export interface StepProjection extends IntervalStep {
  elapsedMs: number;
  remainingMs: number;
}

export interface TimerProjection {
  /** The status at `now`: a running timer whose time is up is `finished`. */
  status: TimerStatus;
  /** Position on the timer, including time jumped over by `skip`. */
  elapsedMs: number;
  /** Null for a stopwatch. */
  totalMs: number | null;
  remainingMs: number | null;
  finished: boolean;
  /** The current interval step; null for other kinds and once finished. */
  step: StepProjection | null;
  /** The interval step after the current one, if any. */
  next: IntervalStep | null;
}

export type TimerTransition =
  | { type: 'segment'; timerId: string; at: number; step: IntervalStep }
  | { type: 'tick'; timerId: string; at: number; secondsLeft: 1 | 2 | 3; stepIndex: number | null }
  | { type: 'finish'; timerId: string; at: number };

const PREP_LABEL = 'Prep';
const COOLDOWN_LABEL = 'Cooldown';

export function intervalStepCount(definition: IntervalDefinition): number {
  return (definition.prepMs ? 1 : 0) + definition.rounds * definition.segments.length + (definition.cooldownMs ? 1 : 0);
}

function cycleMs(definition: IntervalDefinition): number {
  return definition.segments.reduce((sum, segment) => sum + segment.durationMs, 0);
}

/** The step at `index` of the flattened sequence, computed without materializing every round. */
export function intervalStep(definition: IntervalDefinition, index: number): IntervalStep {
  const prep = definition.prepMs ?? 0;
  if (prep && index === 0) return { index, segmentIndex: null, round: null, phase: 'prep', label: PREP_LABEL, startMs: 0, durationMs: prep };
  const segments = definition.segments;
  const inRounds = index - (prep ? 1 : 0);
  if (inRounds < definition.rounds * segments.length) {
    const round = Math.floor(inRounds / segments.length);
    const segmentIndex = inRounds % segments.length;
    let startMs = prep + round * cycleMs(definition);
    for (let earlier = 0; earlier < segmentIndex; earlier++) startMs += segments[earlier].durationMs;
    const segment = segments[segmentIndex];
    return { index, segmentIndex, round: round + 1, phase: segment.phase, label: segment.label, startMs, durationMs: segment.durationMs };
  }
  const startMs = prep + definition.rounds * cycleMs(definition);
  return { index, segmentIndex: null, round: null, phase: 'cooldown', label: COOLDOWN_LABEL, startMs, durationMs: definition.cooldownMs ?? 0 };
}

/** Index of the step containing `position`; the step count when the position is at or past the end. */
export function intervalStepIndexAt(definition: IntervalDefinition, position: number): number {
  const prep = definition.prepMs ?? 0;
  const prepSteps = prep ? 1 : 0;
  if (position < prep) return 0;
  const cycle = cycleMs(definition);
  const inRounds = position - prep;
  const round = Math.floor(inRounds / cycle);
  if (round >= definition.rounds) {
    const end = prep + definition.rounds * cycle + (definition.cooldownMs ?? 0);
    const afterRounds = prepSteps + definition.rounds * definition.segments.length;
    return position < end ? afterRounds : intervalStepCount(definition);
  }
  let offset = inRounds - round * cycle;
  let segmentIndex = 0;
  while (offset >= definition.segments[segmentIndex].durationMs) offset -= definition.segments[segmentIndex++].durationMs;
  return prepSteps + round * definition.segments.length + segmentIndex;
}

/**
 * The timer's length, or null for a stopwatch. An `until` countdown that has not started yet counts
 * down to its target time from `now`.
 */
export function totalDurationMs(definition: TimerDefinition, now: number): number | null {
  switch (definition.kind) {
    case 'stopwatch':
      return null;
    case 'countdown':
      if (definition.durationMs !== undefined) return definition.durationMs;
      return Math.max(0, Date.parse(definition.until ?? '') - now) || 0;
    case 'interval':
      return (definition.prepMs ?? 0) + definition.rounds * cycleMs(definition) + (definition.cooldownMs ?? 0);
  }
}

/** Position before clamping to the total. A clock that went backward adds nothing rather than going negative. */
function rawPosition(runtime: TimerRuntime, now: number): number {
  const base = runtime.accumulatedMs + runtime.skippedMs;
  return runtime.status === 'running' && runtime.startedAt !== null ? base + Math.max(0, now - runtime.startedAt) : base;
}

export function project(timer: Timer, now: number): TimerProjection {
  const { definition, runtime } = timer;
  const totalMs = totalDurationMs(definition, now);
  let elapsedMs = rawPosition(runtime, now);
  if (totalMs !== null) elapsedMs = Math.min(elapsedMs, totalMs);
  const finished = runtime.status === 'finished' || (runtime.status === 'running' && totalMs !== null && elapsedMs >= totalMs);
  if (finished && totalMs !== null) elapsedMs = totalMs;
  const projection: TimerProjection = {
    status: finished ? 'finished' : runtime.status,
    elapsedMs,
    totalMs,
    remainingMs: totalMs === null ? null : Math.max(0, totalMs - elapsedMs),
    finished,
    step: null,
    next: null
  };
  if (definition.kind === 'interval' && !finished) {
    const index = intervalStepIndexAt(definition, elapsedMs);
    const step = intervalStep(definition, index);
    projection.step = { ...step, elapsedMs: elapsedMs - step.startMs, remainingMs: step.startMs + step.durationMs - elapsedMs };
    projection.next = index + 1 < intervalStepCount(definition) ? intervalStep(definition, index + 1) : null;
  }
  return projection;
}

/** Records a running timer whose time is up as finished, so later operations see the stored state the projection shows. */
export function settle(timer: Timer, now: number): Timer {
  const projection = project(timer, now);
  if (timer.runtime.status !== 'running' || !projection.finished || projection.totalMs === null) return timer;
  return { ...timer, runtime: finishedRuntime(timer.runtime, projection.totalMs) };
}

export function finishedRuntime(runtime: TimerRuntime, totalMs: number): TimerRuntime {
  return { ...runtime, status: 'finished', startedAt: null, pausedAt: null, accumulatedMs: Math.max(0, totalMs - runtime.skippedMs) };
}

/**
 * Transitions with `from < at <= to` while the timer keeps running as stored: interval step starts,
 * final-3-second ticks (when `countdownTicks` is on) and the finish, in time order. A step of 3
 * seconds or less has a tick at its own start, listed after that step's segment event. Nothing at or
 * before the position the running stretch began from is listed. A paused, idle or finished timer
 * has none, nor does a stopwatch. The scheduler calls this again after every change.
 */
export function transitionsBetween(timer: Timer, from: number, to: number): TimerTransition[] {
  const { definition, runtime } = timer;
  if (runtime.status !== 'running' || runtime.startedAt === null || Number.isNaN(from) || Number.isNaN(to) || to <= from) return [];
  const totalMs = totalDurationMs(definition, runtime.startedAt);
  if (totalMs === null) return [];
  const base = runtime.accumulatedMs + runtime.skippedMs;
  const startedAt = runtime.startedAt;
  // Positions passed during (from, to]. Anything at or before `base` happened before this running stretch.
  const low = Math.max(base, base + (from - startedAt));
  const high = Math.min(totalMs, base + (to - startedAt));
  if (Number.isNaN(low) || Number.isNaN(high) || high <= low) return [];
  const at = (position: number) => startedAt + (position - base);
  const inWindow = (position: number) => position > low && position <= high;
  const timerId = definition.id;
  const transitions: TimerTransition[] = [];
  const addTicks = (endMs: number, startMs: number, stepIndex: number | null) => {
    if (!definition.countdownTicks) return;
    for (const secondsLeft of [3, 2, 1] as const) {
      const position = endMs - secondsLeft * 1_000;
      if (position >= startMs && inWindow(position)) transitions.push({ type: 'tick', timerId, at: at(position), secondsLeft, stepIndex });
    }
  };
  if (definition.kind === 'interval') {
    const count = intervalStepCount(definition);
    for (let index = intervalStepIndexAt(definition, low); index < count; index++) {
      const step = intervalStep(definition, index);
      if (step.startMs > high) break;
      if (index > 0 && inWindow(step.startMs)) transitions.push({ type: 'segment', timerId, at: at(step.startMs), step });
      addTicks(step.startMs + step.durationMs, step.startMs, index);
    }
  } else {
    addTicks(totalMs, 0, null);
  }
  if (inWindow(totalMs)) transitions.push({ type: 'finish', timerId, at: at(totalMs) });
  return transitions;
}
