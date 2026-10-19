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
/** What a caller supplies to create a timer. */
export type TimerSpec = CountdownSpec | StopwatchSpec | IntervalSpec;
/** What a preset holds: a countdown always has `durationMs`, because `until` names one moment. */
export type PresetTimerSpec = (Omit<CountdownSpec, 'durationMs' | 'until'> & { durationMs: number; until?: never }) | StopwatchSpec | IntervalSpec;

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
  /** Its `name`, when set, wins over the preset's own `name` for the timers it creates. */
  timer: PresetTimerSpec;
}

/** Everything the single writer persists. Built-in presets live in code, not here. */
export interface TimerStore {
  schemaVersion: typeof TIMER_SCHEMA_VERSION;
  /**
   * The sequence of the next id to issue, at most `ID_SPACE`. It only grows and timers and presets
   * share it, so removing one never frees its id for reuse.
   */
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

/** How many ids a store can issue: one per `idSequence` value, shared by timers and presets. */
export const ID_SPACE = 2 ** 40;

const ID_MASK = (1n << 40n) - 1n;
// Odd multipliers are invertible modulo 2^40, and x ^ (x >> 20) is its own inverse on 40 bits, so
// `scramble` is a bijection on [0, 2^40). It only spreads consecutive sequences apart.
const ID_OFFSET = 0x5a3c96e1d4n;
const ID_MULTIPLIERS = [0x9e3779b97fn, 0xc2b2ae3d27n] as const;
const inverseOf = (odd: bigint) => {
  let inverse = odd;
  for (let step = 0; step < 6; step++) inverse = (inverse * (2n - odd * inverse)) & ID_MASK;
  return inverse;
};
const ID_INVERSES = [inverseOf(ID_MULTIPLIERS[0]), inverseOf(ID_MULTIPLIERS[1])] as const;
const fold = (value: bigint) => value ^ (value >> 20n);
const scramble = (value: bigint) =>
  fold((fold((fold(value ^ ID_OFFSET) * ID_MULTIPLIERS[0]) & ID_MASK) * ID_MULTIPLIERS[1]) & ID_MASK);
const unscramble = (value: bigint) =>
  fold((fold((fold(value) * ID_INVERSES[1]) & ID_MASK) * ID_INVERSES[0]) & ID_MASK) ^ ID_OFFSET;

/**
 * The id issued for `sequence`, an integer in [0, ID_SPACE). Distinct sequences give distinct ids,
 * so a store that never reuses a sequence never reissues an id. Ids are not secrets.
 */
export function issuedId(prefix: 't' | 'p', sequence: number): string {
  let value = scramble(BigInt(sequence));
  let id = '';
  for (let index = 0; index < 8; index++) {
    id = CROCKFORD[Number(value & 31n)] + id;
    value >>= 5n;
  }
  return `${prefix}_${id}`;
}

/** The sequence `issuedId` turned into `id`, or null when `id` is not a timer or preset id. */
export function idSequenceOf(id: string): number | null {
  if (!TIMER_ID_PATTERN.test(id) && !PRESET_ID_PATTERN.test(id)) return null;
  let value = 0n;
  for (const character of id.slice(2)) value = (value << 5n) | BigInt(CROCKFORD.indexOf(character));
  return Number(unscramble(value));
}

/** Characters as people count them closely enough for limits: Unicode code points. */
export function textLength(value: string): number {
  return [...value].length;
}
