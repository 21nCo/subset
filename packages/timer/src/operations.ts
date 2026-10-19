import type { z } from 'zod';
import { timerBoard, timerSnapshot, type TimerBoardResult, type TimerSnapshot } from './agent.js';
import { finishedRuntime, intervalStep, intervalStepIndexAt, project, settle, totalDurationMs } from './engine.js';
import {
  ID_SPACE, TIMER_LIMITS, idleRuntime, issuedId, type Preset, type Timer, type TimerDefinition, type TimerSpec, type TimerStore
} from './model.js';
import { BUILT_IN_PRESETS } from './presets.js';
import { validators } from './schemas.js';

export type TimerErrorCode = 'not_found' | 'invalid_state' | 'limit_reached' | 'invalid_input';
export interface TimerError {
  code: TimerErrorCode;
  message: string;
  /** For `invalid_input`: which fields failed and why. */
  issues?: { path: string; message: string }[];
}
export type OperationOutcome<Result> = { ok: true; store: TimerStore; result: Result } | { ok: false; error: TimerError };

export interface TimerResult {
  timer: TimerSnapshot;
  /** The operation's `now`: when the host ran it, on the clock of `TimerBoardResult.observedAt`. */
  observedAt: number;
}
export interface RemovedResult {
  removedId: string;
}
/** `remove`'s result; `observedAt` as in `TimerResult`. */
export interface TimerRemovedResult extends RemovedResult {
  observedAt: number;
}

export type WriteClass = 'read' | 'write' | 'destructive';
/** Hosts gate each operation on its class: reads need no consent, destructive writes need the user's explicit request. */
export const OPERATION_WRITE_CLASS = {
  create: 'write',
  start: 'write',
  pause: 'write',
  resume: 'write',
  lap: 'write',
  skip: 'write',
  reset: 'destructive',
  remove: 'destructive',
  list: 'read',
  get: 'read',
  'presets.list': 'read',
  'presets.save': 'write',
  'presets.remove': 'destructive'
} as const satisfies Record<keyof typeof validators.inputs, WriteClass>;
export type OperationName = keyof typeof OPERATION_WRITE_CLASS;
export const OPERATION_NAMES = Object.keys(OPERATION_WRITE_CLASS) as OperationName[];

const failure = (code: TimerErrorCode, message: string, issues?: TimerError['issues']): { ok: false; error: TimerError } =>
  ({ ok: false, error: issues ? { code, message, issues } : { code, message } });
const success = <Result>(store: TimerStore, result: Result): OperationOutcome<Result> => ({ ok: true, store, result });

function parse<Schema extends z.ZodType>(schema: Schema, input: unknown): { ok: true; value: z.infer<Schema> } | { ok: false; error: TimerError } {
  // An omitted input means `{}`; `null` is malformed, as the JSON Schemas say.
  const parsed = schema.safeParse(input === undefined ? {} : input);
  if (parsed.success) return { ok: true, value: parsed.data };
  const issues = parsed.error.issues.map((issue) => ({ path: issue.path.map(String).join('.'), message: issue.message }));
  return failure('invalid_input', issues.map((issue) => (issue.path ? `${issue.path}: ${issue.message}` : issue.message)).join('; '), issues);
}

function withTimer(store: TimerStore, id: string, now: number): { ok: true; timer: Timer; index: number } | { ok: false; error: TimerError } {
  const index = store.timers.findIndex((timer) => timer.definition.id === id);
  if (index < 0) return failure('not_found', `No timer ${id}.`);
  return { ok: true, timer: settle(store.timers[index], now), index };
}

function replaceTimer(store: TimerStore, index: number, timer: Timer, now: number): OperationOutcome<TimerResult> {
  const timers = store.timers.slice();
  timers[index] = timer;
  return success({ ...store, timers }, { timer: timerSnapshot(timer, now), observedAt: now });
}

/**
 * The next id and the store's following `idSequence`, or null once the store has issued every id.
 * Each sequence gives a distinct id, so the live-id check only guards stores written another way.
 */
function freshId(prefix: 't' | 'p', store: TimerStore, taken: Set<string>): { id: string; idSequence: number } | null {
  for (let sequence = store.idSequence; sequence < ID_SPACE; sequence++) {
    const id = issuedId(prefix, sequence);
    if (!taken.has(id)) return { id, idSequence: sequence + 1 };
  }
  return null;
}
const idsExhausted = () => failure('limit_reached', 'This store has issued every id it can.');

const DEFAULT_NAMES = { countdown: 'Countdown', stopwatch: 'Stopwatch', interval: 'Intervals' } as const;

function definitionFrom(spec: TimerSpec, id: string, name: string | undefined, now: number): TimerDefinition {
  const common = {
    id,
    name: name ?? spec.name ?? DEFAULT_NAMES[spec.kind],
    sound: spec.sound ?? true,
    countdownTicks: spec.countdownTicks ?? spec.kind === 'interval',
    createdAt: now
  };
  switch (spec.kind) {
    case 'countdown':
      return {
        kind: 'countdown', ...common,
        ...(spec.durationMs !== undefined ? { durationMs: spec.durationMs } : { until: spec.until }),
        lapsEnabled: spec.lapsEnabled ?? false
      };
    case 'stopwatch':
      return { kind: 'stopwatch', ...common };
    case 'interval':
      return {
        kind: 'interval', ...common,
        segments: spec.segments.map((segment) => ({ ...segment })),
        rounds: spec.rounds,
        ...(spec.prepMs !== undefined && { prepMs: spec.prepMs }),
        ...(spec.cooldownMs !== undefined && { cooldownMs: spec.cooldownMs })
      };
  }
}

/** Milliseconds from `now` to an `until` time when it lies 1 second to 24 hours ahead, else null. */
function untilDuration(until: string, now: number): number | null {
  const ms = Date.parse(until) - now;
  return ms >= TIMER_LIMITS.minDurationMs && ms <= TIMER_LIMITS.maxDurationMs ? ms : null;
}

function addTimer(store: TimerStore, input: { timer?: TimerSpec; preset?: string; name?: string }, now: number): { ok: true; store: TimerStore; timer: Timer } | { ok: false; error: TimerError } {
  let spec = input.timer;
  if (input.preset !== undefined) {
    const preset = allPresets(store).find((candidate) => candidate.id === input.preset);
    if (!preset) return failure('not_found', `No preset ${input.preset}.`);
    spec = { ...preset.timer, name: preset.timer.name ?? preset.name };
  }
  if (!spec) return failure('invalid_input', 'needs exactly one of timer and preset');
  if (spec.kind === 'countdown' && spec.until !== undefined && untilDuration(spec.until, now) === null) {
    return failure('invalid_input', 'timer.until: must be between 1 second and 24 hours from now', [
      { path: 'timer.until', message: 'must be between 1 second and 24 hours from now' }
    ]);
  }
  if (store.timers.length >= TIMER_LIMITS.timers) {
    return failure('limit_reached', `A store holds at most ${TIMER_LIMITS.timers} timers. Remove one first.`);
  }
  const issued = freshId('t', store, new Set(store.timers.map((timer) => timer.definition.id)));
  if (!issued) return idsExhausted();
  const { id, idSequence } = issued;
  const timer: Timer = { definition: definitionFrom(spec, id, input.name, now), runtime: idleRuntime() };
  return { ok: true, store: { ...store, idSequence, timers: [...store.timers, timer] }, timer };
}

/** Starts an idle timer. An `until` countdown fixes its duration now. */
function startIdle(timer: Timer, now: number): { ok: true; timer: Timer } | { ok: false; error: TimerError } {
  if (timer.runtime.status !== 'idle') {
    return failure('invalid_state', `Timer ${timer.definition.id} is ${timer.runtime.status}; only an idle timer can start${timer.runtime.status === 'finished' ? ' (reset it first)' : ''}.`);
  }
  let definition = timer.definition;
  if (definition.kind === 'countdown' && definition.durationMs === undefined) {
    const durationMs = untilDuration(definition.until ?? '', now);
    if (durationMs === null) return failure('invalid_state', `Timer ${definition.id} counts down to ${definition.until}, which is not 1 second to 24 hours away.`);
    definition = { ...definition, durationMs };
  }
  return { ok: true, timer: { definition, runtime: { ...idleRuntime(), status: 'running', startedAt: now } } };
}

function allPresets(store: TimerStore): Preset[] {
  return [...BUILT_IN_PRESETS, ...store.presets];
}

function create(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  const parsed = parse(validators.inputs.create, input);
  if (!parsed.ok) return parsed;
  const added = addTimer(store, parsed.value, now);
  return added.ok ? success(added.store, { timer: timerSnapshot(added.timer, now), observedAt: now }) : added;
}

function start(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  const parsed = parse(validators.inputs.start, input);
  if (!parsed.ok) return parsed;
  if (parsed.value.id !== undefined) {
    const found = withTimer(store, parsed.value.id, now);
    if (!found.ok) return found;
    const started = startIdle(found.timer, now);
    return started.ok ? replaceTimer(store, found.index, started.timer, now) : started;
  }
  const added = addTimer(store, parsed.value, now);
  if (!added.ok) return added;
  const started = startIdle(added.timer, now);
  return started.ok ? replaceTimer(added.store, added.store.timers.length - 1, started.timer, now) : started;
}

/** Applies `change` to the timer named by `input.id` after settling it at `now`. */
function update(store: TimerStore, input: unknown, now: number, change: (timer: Timer) => { ok: true; timer: Timer } | { ok: false; error: TimerError }): OperationOutcome<TimerResult> {
  const parsed = parse(validators.inputs.pause, input);
  if (!parsed.ok) return parsed;
  const found = withTimer(store, parsed.value.id, now);
  if (!found.ok) return found;
  const changed = change(found.timer);
  return changed.ok ? replaceTimer(store, found.index, changed.timer, now) : changed;
}

const notStatus = (timer: Timer, action: string) =>
  failure('invalid_state', `Timer ${timer.definition.id} is ${timer.runtime.status}; ${action}.`);

function pause(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  return update(store, input, now, (timer) => {
    const { runtime } = timer;
    if (runtime.status !== 'running' || runtime.startedAt === null) return notStatus(timer, 'only a running timer can pause');
    return { ok: true, timer: { ...timer, runtime: {
      ...runtime, status: 'paused', accumulatedMs: runtime.accumulatedMs + Math.max(0, now - runtime.startedAt), startedAt: null, pausedAt: now
    } } };
  });
}

function resume(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  return update(store, input, now, (timer) => {
    if (timer.runtime.status !== 'paused') return notStatus(timer, 'only a paused timer can resume');
    return { ok: true, timer: { ...timer, runtime: { ...timer.runtime, status: 'running', startedAt: now, pausedAt: null } } };
  });
}

function lap(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  return update(store, input, now, (timer) => {
    const { definition, runtime } = timer;
    if (!(definition.kind === 'stopwatch' || (definition.kind === 'countdown' && definition.lapsEnabled))) {
      return failure('invalid_state', `Timer ${definition.id} does not take laps; only stopwatches and countdowns with laps enabled do.`);
    }
    if (runtime.status !== 'running') return notStatus(timer, 'only a running timer takes laps');
    if (runtime.laps.length >= TIMER_LIMITS.laps) return failure('limit_reached', `A timer records at most ${TIMER_LIMITS.laps} laps.`);
    const lapEntry = { elapsedMs: project(timer, now).elapsedMs, at: now };
    return { ok: true, timer: { ...timer, runtime: { ...runtime, laps: [...runtime.laps, lapEntry] } } };
  });
}

/**
 * Jumps to the start of the next interval step. On the last segment of the last round, or in the
 * cooldown, it finishes the timer and skips any cooldown too. A paused timer otherwise stays paused.
 */
function skip(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  return update(store, input, now, (timer) => {
    const { definition, runtime } = timer;
    if (definition.kind !== 'interval') return failure('invalid_state', `Timer ${definition.id} is a ${definition.kind}; only interval timers skip.`);
    if (runtime.status !== 'running' && runtime.status !== 'paused') return notStatus(timer, 'only a running or paused timer can skip');
    const { elapsedMs } = project(timer, now);
    const totalMs = totalDurationMs(definition, now) ?? 0;
    const step = intervalStep(definition, intervalStepIndexAt(definition, elapsedMs));
    const lastSegment = step.round === definition.rounds && step.segmentIndex === definition.segments.length - 1;
    const finishing = lastSegment || (step.phase === 'cooldown' && step.segmentIndex === null);
    const target = finishing ? totalMs : step.startMs + step.durationMs;
    const skipped = { ...runtime, skippedMs: runtime.skippedMs + (target - elapsedMs) };
    return { ok: true, timer: { ...timer, runtime: finishing ? finishedRuntime(skipped, totalMs) : skipped } };
  });
}

function reset(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  return update(store, input, now, (timer) => ({ ok: true, timer: { ...timer, runtime: idleRuntime() } }));
}

function remove(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerRemovedResult> {
  const parsed = parse(validators.inputs.remove, input);
  if (!parsed.ok) return parsed;
  const found = withTimer(store, parsed.value.id, now);
  if (!found.ok) return found;
  return success({ ...store, timers: store.timers.filter((_, index) => index !== found.index) }, { removedId: parsed.value.id, observedAt: now });
}

function list(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerBoardResult> {
  const parsed = parse(validators.inputs.list, input);
  return parsed.ok ? success(store, timerBoard(store, now)) : parsed;
}

function get(store: TimerStore, input: unknown, now: number): OperationOutcome<TimerResult> {
  const parsed = parse(validators.inputs.get, input);
  if (!parsed.ok) return parsed;
  const found = withTimer(store, parsed.value.id, now);
  return found.ok ? success(store, { timer: timerSnapshot(store.timers[found.index], now), observedAt: now }) : found;
}

function listPresets(store: TimerStore, input: unknown): OperationOutcome<{ presets: Preset[] }> {
  const parsed = parse(validators.inputs['presets.list'], input);
  return parsed.ok ? success(store, { presets: allPresets(store) }) : parsed;
}

function savePreset(store: TimerStore, input: unknown): OperationOutcome<{ preset: Preset }> {
  const parsed = parse(validators.inputs['presets.save'], input);
  if (!parsed.ok) return parsed;
  if (store.presets.length >= TIMER_LIMITS.userPresets) {
    return failure('limit_reached', `At most ${TIMER_LIMITS.userPresets} presets can be saved. Remove one first.`);
  }
  const issued = freshId('p', store, new Set(store.presets.map((preset) => preset.id)));
  if (!issued) return idsExhausted();
  const { id, idSequence } = issued;
  const preset: Preset = { id, name: parsed.value.name, builtIn: false, timer: parsed.value.timer };
  return success({ ...store, idSequence, presets: [...store.presets, preset] }, { preset });
}

function removePreset(store: TimerStore, input: unknown): OperationOutcome<RemovedResult> {
  const parsed = parse(validators.inputs['presets.remove'], input);
  if (!parsed.ok) return parsed;
  const id = parsed.value.id;
  if (BUILT_IN_PRESETS.some((preset) => preset.id === id)) return failure('invalid_state', `Preset ${id} is built in and read-only.`);
  if (!store.presets.some((preset) => preset.id === id)) return failure('not_found', `No preset ${id}.`);
  return success({ ...store, presets: store.presets.filter((preset) => preset.id !== id) }, { removedId: id });
}

type Operation<Result> = (store: TimerStore, input: unknown, now: number) => OperationOutcome<Result>;

/** Rejects a `now` that is not whole epoch milliseconds, which would write a store `parseStore` cannot read back. */
function atValidNow<Result>(operation: Operation<Result>): Operation<Result> {
  return (store, input, now) => (Number.isSafeInteger(now) && now >= 0
    ? operation(store, input, now)
    : failure('invalid_input', 'now: must be whole epoch milliseconds', [{ path: 'now', message: 'must be whole epoch milliseconds' }]));
}

/**
 * Every operation as a pure function `(store, input, now)`. Each validates its own input and `now`,
 * so a host can pass untrusted JSON, and never mutates the store it was given.
 */
export const operations = {
  create: atValidNow(create),
  start: atValidNow(start),
  pause: atValidNow(pause),
  resume: atValidNow(resume),
  lap: atValidNow(lap),
  skip: atValidNow(skip),
  reset: atValidNow(reset),
  remove: atValidNow(remove),
  list: atValidNow(list),
  get: atValidNow(get),
  'presets.list': atValidNow(listPresets),
  'presets.save': atValidNow(savePreset),
  'presets.remove': atValidNow(removePreset)
} satisfies Record<OperationName, (store: TimerStore, input: unknown, now: number) => OperationOutcome<unknown>>;

/** Runs an operation by name, as a socket or MCP host receives it. An unknown name is `invalid_input`. */
export function runOperation(name: string, store: TimerStore, input: unknown, now: number): OperationOutcome<unknown> {
  if (!Object.hasOwn(operations, name)) return failure('invalid_input', `Unknown operation ${name}.`);
  return operations[name as OperationName](store, input, now);
}

/** Validates a persisted store, for example one read from disk. */
export function parseStore(value: unknown): { ok: true; store: TimerStore } | { ok: false; error: TimerError } {
  const parsed = parse(validators.store, value);
  return parsed.ok ? { ok: true, store: parsed.value as TimerStore } : parsed;
}
