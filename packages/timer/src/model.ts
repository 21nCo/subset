// Timer's domain model, schema version 1. Every time is wall-clock epoch milliseconds, so a host that
// sleeps or restarts recomputes each timer from its timestamps instead of counting ticks.

export const TIMER_SCHEMA_VERSION = 1 as const;
export const TIMER_VIEW_ID = 'subset.timer.board@1' as const;

export const TIMER_LIMITS = {
  timers: 50,
  userPresets: 50,
  laps: 999,
  segments: 100,
  rounds: 99,
  minDurationMs: 1_000,
  maxDurationMs: 86_400_000,
  nameLength: 60,
  labelLength: 40
} as const;

export const TIMER_KINDS = ['countdown', 'stopwatch', 'interval'] as const;
export type TimerKind = (typeof TIMER_KINDS)[number];
export const PHASES = ['prep', 'work', 'rest', 'cooldown'] as const;
export type Phase = (typeof PHASES)[number];
export const TIMER_STATUSES = ['idle', 'running', 'paused', 'finished'] as const;
export type TimerStatus = (typeof TIMER_STATUSES)[number];

export interface Segment {
  /** At most 40 characters on one line. */
  label: string;
  phase: Phase;
  durationMs: number;
}

/** Settings shared by every kind. Omitted ones take the defaults in `TimerDefinition`. */
interface CommonSpec {
  name?: string;
  sound?: boolean;
  countdownTicks?: boolean;
}

/** A countdown has exactly one of `durationMs` and `until` (an ISO time within the next 24 hours). */
export interface CountdownSpec extends CommonSpec {
  kind: 'countdown';
  durationMs?: number;
  until?: string;
  lapsEnabled?: boolean;
}
export interface StopwatchSpec extends CommonSpec {
  kind: 'stopwatch';
}
export interface IntervalSpec extends CommonSpec {
  kind: 'interval';
  segments: Segment[];
  rounds: number;
  /** Before the first round. */
  prepMs?: number;
  /** After the last round. */
  cooldownMs?: number;
}
/** What a caller supplies to create a timer or save a preset. */
export type TimerSpec = CountdownSpec | StopwatchSpec | IntervalSpec;

interface CommonDefinition {
  /** `t_` plus 8 lowercase Crockford base32 characters. */
  id: string;
  name: string;
  /** Default true. */
  sound: boolean;
  /** Final-3-second ticks. Default true for interval timers, false otherwise. */
  countdownTicks: boolean;
  createdAt: number;
}
export interface CountdownDefinition extends CommonDefinition {
  kind: 'countdown';
  /** Absent only for an `until` countdown that has not started yet; the first start fixes it. */
  durationMs?: number;
  until?: string;
  lapsEnabled: boolean;
}
export interface StopwatchDefinition extends CommonDefinition {
  kind: 'stopwatch';
}
export interface IntervalDefinition extends CommonDefinition {
  kind: 'interval';
  segments: Segment[];
  rounds: number;
  prepMs?: number;
  cooldownMs?: number;
}
export type TimerDefinition = CountdownDefinition | StopwatchDefinition | IntervalDefinition;

export interface Lap {
  /** Position on the timer when the lap was taken. */
  elapsedMs: number;
  at: number;
}

/**
 * The stored state. `startedAt` is when the current running stretch began (null unless running),
 * `accumulatedMs` the running time before it, and `skippedMs` the time jumped over by `skip`. The
 * timer's position is `accumulatedMs + skippedMs + (now - startedAt)`.
 */
export interface TimerRuntime {
  status: TimerStatus;
  startedAt: number | null;
  accumulatedMs: number;
  pausedAt: number | null;
  laps: Lap[];
  skippedMs: number;
}

export interface Timer {
  definition: TimerDefinition;
  runtime: TimerRuntime;
}

export interface Preset {
  /** A built-in slug, or `p_` plus 8 lowercase Crockford base32 characters for a saved preset. */
  id: string;
  name: string;
  builtIn: boolean;
  /** Presets never hold an `until` countdown, which names one moment. */
  timer: TimerSpec;
}

/** Everything the single writer persists. Built-in presets live in code, not here. */
export interface TimerStore {
  schemaVersion: typeof TIMER_SCHEMA_VERSION;
  /** How many ids this store has issued. It seeds the next id, so removing a timer never frees its id for reuse. */
  idSequence: number;
  timers: Timer[];
  /** Saved (user) presets only. */
  presets: Preset[];
}

export function emptyStore(): TimerStore {
  return { schemaVersion: TIMER_SCHEMA_VERSION, idSequence: 0, timers: [], presets: [] };
}

export function idleRuntime(): TimerRuntime {
  return { status: 'idle', startedAt: null, accumulatedMs: 0, pausedAt: null, laps: [], skippedMs: 0 };
}

const CROCKFORD = '0123456789abcdefghjkmnpqrstvwxyz';
export const TIMER_ID_PATTERN = /^t_[0-9a-hjkmnp-tv-z]{8}$/;
export const PRESET_ID_PATTERN = /^p_[0-9a-hjkmnp-tv-z]{8}$/;

/**
 * Derives an 8-character id from a seed with two 32-bit FNV-1a passes. Ids only need to be unique
 * within one store, which the caller checks; they are not secrets.
 */
export function deriveId(prefix: 't' | 'p', seed: string): string {
  let high = 0x811c9dc5;
  let low = 0x01000193;
  for (let index = 0; index < seed.length; index++) {
    const code = seed.charCodeAt(index);
    high = Math.imul(high ^ code, 0x01000193) >>> 0;
    low = Math.imul(low ^ code, 0x5bd1e995) >>> 0;
  }
  // 40 bits: the low 8 bits of `high` and all of `low`, five bits per character.
  let value = (high & 0xff) * 2 ** 32 + low;
  let id = '';
  for (let index = 0; index < 8; index++) {
    id = CROCKFORD[value % 32] + id;
    value = Math.floor(value / 32);
  }
  return `${prefix}_${id}`;
}

/** Characters as people count them closely enough for limits: Unicode code points. */
export function textLength(value: string): number {
  return [...value].length;
}
