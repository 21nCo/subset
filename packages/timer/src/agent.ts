import { project, type IntervalStep, type TimerProjection } from './engine.js';
import { TIMER_SCHEMA_VERSION, TIMER_VIEW_ID, type Timer, type TimerDefinition, type TimerRuntime, type TimerStore } from './model.js';

export interface TimerSnapshot {
  definition: TimerDefinition;
  runtime: TimerRuntime;
  /** Computed at `observedAt`; a view re-projects from `definition` and `runtime` as time passes. */
  projection: TimerProjection;
}

/** `structuredContent` of the agent result, and the result of the `list` operation. */
export interface TimerBoardResult {
  schemaVersion: typeof TIMER_SCHEMA_VERSION;
  observedAt: number;
  timers: TimerSnapshot[];
}

export function timerSnapshot(timer: Timer, now: number): TimerSnapshot {
  return { definition: timer.definition, runtime: timer.runtime, projection: project(timer, now) };
}

export function timerBoard(store: TimerStore, now: number): TimerBoardResult {
  return { schemaVersion: TIMER_SCHEMA_VERSION, observedAt: now, timers: store.timers.map((timer) => timerSnapshot(timer, now)) };
}

/**
 * `m:ss`, or `h:mm:ss` from an hour. Time left rounds up, so a countdown shows 0:01 until it ends;
 * time elapsed rounds down.
 */
export function formatDuration(ms: number, rounding: 'up' | 'down'): string {
  const totalSeconds = Math.max(0, rounding === 'up' ? Math.ceil(ms / 1_000) : Math.floor(ms / 1_000));
  const hours = Math.floor(totalSeconds / 3_600);
  const minutes = Math.floor((totalSeconds % 3_600) / 60);
  const seconds = String(totalSeconds % 60).padStart(2, '0');
  return hours ? `${hours}:${String(minutes).padStart(2, '0')}:${seconds}` : `${minutes}:${seconds}`;
}

function stepName(step: IntervalStep): string {
  return step.label.toLowerCase() === step.phase ? step.phase : `${step.phase} (${step.label})`;
}

const plural = (count: number, noun: string) => `${count} ${noun}${count === 1 ? '' : 's'}`;

/** One line, for example `Tabata (t_ab12cd34): running · round 3/8 · work · 0:12 left · next rest 0:10`. */
export function timerLine(snapshot: TimerSnapshot): string {
  const { definition, runtime, projection } = snapshot;
  const parts: string[] = [projection.status];
  const active = projection.status === 'running' || projection.status === 'paused';
  if (definition.kind === 'stopwatch') {
    if (projection.status !== 'idle') parts.push(`${formatDuration(projection.elapsedMs, 'down')} elapsed`);
  } else if (!active) {
    parts.push(`${formatDuration(projection.totalMs ?? 0, 'up')} total`);
  } else if (definition.kind === 'interval' && projection.step) {
    const { step, next } = projection;
    if (step.round !== null && definition.rounds > 1) parts.push(`round ${step.round}/${definition.rounds}`);
    else if (step.segmentIndex !== null && definition.segments.length > 1) parts.push(`segment ${step.segmentIndex + 1}/${definition.segments.length}`);
    parts.push(stepName(step), `${formatDuration(step.remainingMs, 'up')} left`);
    if (next) parts.push(`next ${stepName(next)} ${formatDuration(next.durationMs, 'up')}`);
  } else {
    parts.push(`${formatDuration(projection.remainingMs ?? 0, 'up')} left`);
  }
  if (runtime.laps.length) parts.push(plural(runtime.laps.length, 'lap'));
  return `${definition.name} (${definition.id}): ${parts.join(' · ')}`;
}

/**
 * The agent-facing result for every Timer host, mirroring `agentUsageResult`: structured data any
 * host can use, a plain-text fallback with one line per timer, and the registered board view ID.
 */
export function agentTimerResult(store: TimerStore, now: number) {
  const structuredContent = timerBoard(store, now);
  const text = structuredContent.timers.length ? structuredContent.timers.map(timerLine).join('\n') : 'No timers.';
  return { structuredContent, text, viewId: TIMER_VIEW_ID };
}
