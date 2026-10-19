// Pure helpers behind the board view (`subset.timer.board@1`): its props, which controls each timer
// offers, the destructive second press, the create form's validation and action errors. Nothing here
// touches the DOM, a clock or a transport, so it runs under `node --test`.
import type { TimerBoardResult, TimerSnapshot } from '../agent.js';
import { project } from '../engine.js';
import { TIMER_LIMITS, type Phase, type Preset, type PresetTimerSpec, type TimerDefinition, type TimerSpec, type TimerStatus } from '../model.js';
import type { OperationName, TimerError } from '../operations.js';
import { validators } from '../schemas.js';
import { parseDurationText, durationText } from './format.js';

export * from './format.js';
export * from './announce.js';

/** What `actions.invoke` resolves to: the operation's result, or `{ error }` when it failed. */
export type TimerActionOutcome = Record<string, unknown> | { error: TimerError };

export interface TimerBoardActions {
  /**
   * Runs one Timer operation through the host's transport. A rejected promise counts as a failure
   * of that operation; its message is shown.
   */
  invoke(operation: OperationName, input: Record<string, unknown>): Promise<TimerActionOutcome>;
}

export interface TimerBoardCapabilities {
  /** Show the create form. */
  create: boolean;
  /** Show reset and remove. */
  destructive: boolean;
}

export type TimerBoardDensity = 'compact' | 'full';

/**
 * Props of `TimerBoard.svelte`. `result`, `capabilities` and `density` are serializable and match
 * `schemas.viewProps`; `actions` and `now` are functions the host supplies.
 */
export interface TimerBoardProps {
  /** The agent result's `structuredContent`, or the `list` result. A new value replaces the board's timers. */
  result: TimerBoardResult;
  actions: TimerBoardActions;
  /** Epoch milliseconds. Defaults to `Date.now`. */
  now?: () => number;
  capabilities: TimerBoardCapabilities;
  density: TimerBoardDensity;
}

/** How often the board re-projects every timer from its timestamps. */
export const REFRESH_MS = 250;
/** How long a pressed reset or remove waits for its confirming second press. */
export const CONFIRM_MS = 3_000;

/** The latest epoch millisecond a `Date` can hold, so the board can always show `observedAt`. */
const MAX_DATE_MS = 8_640_000_000_000_000;

const firstIssue = (error: { issues: readonly { path: readonly PropertyKey[]; message: string }[] }, root: string) => {
  const issue = error.issues[0];
  return `${issue.path.map(String).join('.') || root}: ${issue.message}`;
};

/**
 * Checks a `result` from the host against the contract before the board renders it, and that the
 * board can render it: `observedAt` is a time a `Date` can show and each timer id appears once.
 */
export function readBoardResult(value: unknown): { ok: true; result: TimerBoardResult } | { ok: false; message: string } {
  const parsed = validators.outputs.list.safeParse(value);
  if (!parsed.success) return { ok: false, message: firstIssue(parsed.error, 'result') };
  const result = parsed.data as TimerBoardResult;
  if (result.observedAt > MAX_DATE_MS) return { ok: false, message: 'observedAt: must be a time a Date can show' };
  const ids = new Set(result.timers.map((timer) => timer.definition.id));
  if (ids.size !== result.timers.length) return { ok: false, message: 'timers: each timer id must appear once' };
  return { ok: true, result };
}

export const CONTROLS = ['start', 'pause', 'resume', 'lap', 'skip', 'reset', 'remove'] as const;
export type ControlName = (typeof CONTROLS)[number];
/** `hidden` when the kind or the host's capabilities rule a control out; `disabled` when only the state does. */
export type ControlState = 'enabled' | 'disabled' | 'hidden';
export type ControlTable = Record<ControlName, ControlState>;

/**
 * Each control's state for a timer, from its status at `now` (a running timer whose time is up is
 * finished) and the same rules the operations enforce, so an enabled control does not fail on state.
 */
export function controlStates(definition: TimerDefinition, status: TimerStatus, capabilities: TimerBoardCapabilities, now: number): ControlTable {
  const when = (condition: boolean): ControlState => (condition ? 'enabled' : 'disabled');
  const underWay = status === 'running' || status === 'paused';
  const lapCapable = definition.kind === 'stopwatch' || (definition.kind === 'countdown' && definition.lapsEnabled);
  // An `until` countdown that has not started can start only while its time is 1 second to 24 hours away.
  const untilMs = definition.kind === 'countdown' && definition.durationMs === undefined ? Date.parse(definition.until ?? '') - now : null;
  const startable = untilMs === null || (untilMs >= TIMER_LIMITS.minDurationMs && untilMs <= TIMER_LIMITS.maxDurationMs);
  return {
    start: when(status === 'idle' && startable),
    pause: when(status === 'running'),
    resume: when(status === 'paused'),
    lap: lapCapable ? when(status === 'running') : 'hidden',
    skip: definition.kind === 'interval' ? when(underWay) : 'hidden',
    reset: capabilities.destructive ? when(status !== 'idle') : 'hidden',
    remove: capabilities.destructive ? 'enabled' : 'hidden'
  };
}

/** The control Space runs and the card's main button shows: start, pause or resume, whichever is enabled. */
export function primaryControl(table: ControlTable): 'start' | 'pause' | 'resume' | null {
  return (['pause', 'resume', 'start'] as const).find((control) => table[control] === 'enabled') ?? null;
}

/**
 * A control keyed on a card: Space for the primary control, L for lap and S for skip. A key held
 * down repeats its keydown; only the first press acts, so holding L takes one lap.
 */
export function keyControl({ key, repeat = false }: { key: string; repeat?: boolean }, table: ControlTable): ControlName | null {
  if (repeat) return null;
  const control = key === ' ' ? primaryControl(table) : key === 'l' || key === 'L' ? 'lap' : key === 's' || key === 'S' ? 'skip' : null;
  return control && table[control] === 'enabled' ? control : null;
}

/** The destructive control waiting for its second press, and since when. */
export type Armed = { timerId: string; control: 'reset' | 'remove'; at: number } | null;

/**
 * A press on reset or remove. The first press arms it; a second press on the same control of the
 * same timer within `CONFIRM_MS` runs it. Any other press, or a late one, arms afresh.
 */
export function pressDestructive(armed: Armed, timerId: string, control: 'reset' | 'remove', now: number): { run: boolean; armed: Armed } {
  if (armed && armed.timerId === timerId && armed.control === control && now - armed.at >= 0 && now - armed.at < CONFIRM_MS) {
    return { run: true, armed: null };
  }
  return { run: false, armed: { timerId, control, at: now } };
}

/** Whether `armed` still waits for its second press at `now`. */
export const isArmed = (armed: Armed, timerId: string, control: 'reset' | 'remove', now: number) =>
  armed !== null && armed.timerId === timerId && armed.control === control && now - armed.at >= 0 && now - armed.at < CONFIRM_MS;

/** An operation that failed, named for the inline error. */
export interface ActionFailure {
  operation: OperationName;
  timerId: string | null;
  message: string;
}

const OPERATION_LABELS: Record<OperationName, string> = {
  create: 'Create', start: 'Start', pause: 'Pause', resume: 'Resume', lap: 'Lap', skip: 'Skip', reset: 'Reset', remove: 'Remove',
  list: 'List', get: 'Get', 'presets.list': 'Loading presets', 'presets.save': 'Saving the preset', 'presets.remove': 'Removing the preset'
};

/** For example `Pause failed: Timer t_ab12cd34 is paused; only a running timer can pause.` */
export function failureText(failure: Pick<ActionFailure, 'operation' | 'message'>): string {
  return `${OPERATION_LABELS[failure.operation]} failed: ${failure.message}`;
}

type Outcome = { ok: true; result: Record<string, unknown> } | { ok: false; failure: ActionFailure };

/**
 * Reads what `invoke` gave back: the result, or the failure to show. A thrown or rejected call is a
 * failure, and so is a reply that does not match the operation's result schema or names another
 * timer than the one acted on, so a broken host reply never reaches the board.
 */
export function readOutcome(operation: OperationName, timerId: string | null, outcome: unknown): Outcome {
  const fail = (message: string) => ({ ok: false as const, failure: { operation, timerId, message } });
  if (outcome instanceof Error) return fail(outcome.message || 'The host could not run it.');
  if (!outcome || typeof outcome !== 'object') return fail('The host returned no result.');
  if ('error' in outcome) {
    const error = (outcome as { error: unknown }).error;
    const message = error && typeof error === 'object' && typeof (error as TimerError).message === 'string' ? (error as TimerError).message : '';
    return fail(message || 'The host reported an error.');
  }
  const parsed = validators.outputs[operation].safeParse(outcome);
  if (!parsed.success) return fail(`The host's reply does not match the Timer contract (${firstIssue(parsed.error, 'reply')}).`);
  const result = parsed.data as Record<string, unknown>;
  if (timerId !== null) {
    const replyId = (result as { timer?: TimerSnapshot }).timer?.definition.id ?? (result as { removedId?: string }).removedId;
    if (replyId !== undefined && replyId !== timerId) return fail(`The host replied for timer ${replyId} instead of ${timerId}.`);
  }
  return { ok: true, result };
}

/**
 * The board's timers after a successful action, until the host passes a new `result`: a returned
 * snapshot replaces (or adds) its timer and a removal drops it. `result` has passed `readOutcome`.
 */
export function applyResult(timers: readonly TimerSnapshot[], result: Record<string, unknown>): TimerSnapshot[] {
  const snapshot = (result as { timer?: TimerSnapshot }).timer;
  if (snapshot) {
    const index = timers.findIndex((timer) => timer.definition.id === snapshot.definition.id);
    return index < 0 ? [...timers, snapshot] : timers.map((timer, at) => (at === index ? snapshot : timer));
  }
  const removedId = (result as { removedId?: unknown }).removedId;
  if (typeof removedId === 'string') return timers.filter((timer) => timer.definition.id !== removedId);
  return timers.slice();
}

/**
 * Settles one action's reply against the board. `basis` is the host `result` the action started
 * under and `board.basis` the current one. A reply to an action that started before the host passed
 * a newer `result` is not applied: the newer result already holds or supersedes it, and applying it
 * could bring back a timer the host removed or undo a newer change. Its failure is still shown.
 * `timers` is null when the board's timers stay as they are.
 */
export function settleAction(
  board: { timers: readonly TimerSnapshot[]; basis: unknown },
  action: { operation: OperationName; timerId: string | null; basis: unknown },
  outcome: unknown
): (Outcome & { ok: false }) | { ok: true; result: Record<string, unknown>; timers: TimerSnapshot[] | null } {
  const read = readOutcome(action.operation, action.timerId, outcome);
  if (!read.ok) return read;
  return { ok: true, result: read.result, timers: action.basis === board.basis ? applyResult(board.timers, read.result) : null };
}

/** The presets in a `presets.list` result, or null when it does not match the contract. */
export function readPresets(result: unknown): Preset[] | null {
  const parsed = validators.outputs['presets.list'].safeParse(result);
  return parsed.success ? (parsed.data.presets as Preset[]) : null;
}

/** A timer re-projected at `now` from its definition and runtime. */
export const reproject = (snapshot: TimerSnapshot, now: number): TimerSnapshot =>
  ({ ...snapshot, projection: project({ definition: snapshot.definition, runtime: snapshot.runtime }, now) });

// The create form. Fields hold the text the user typed; durations accept seconds, `m:ss` or `h:mm:ss`.

export interface SegmentDraft {
  label: string;
  /** One of the phases; a string so that a value from elsewhere is reported rather than trusted. */
  phase: Phase | string;
  duration: string;
}

export interface IntervalDraft {
  name: string;
  /** Default true. */
  sound: boolean;
  /** Final-3-second ticks. Default true for interval timers. */
  countdownTicks: boolean;
  rounds: string;
  prep: string;
  cooldown: string;
  segments: SegmentDraft[];
}

export interface CountdownDraft {
  name: string;
  /** Default true. */
  sound: boolean;
  duration: string;
  lapsEnabled: boolean;
}

/** Field errors by draft path, such as `rounds` or `segments.2.duration`. */
export type DraftErrors = Record<string, string>;
export type DraftOutcome<Spec> = { ok: true; spec: Spec } | { ok: false; errors: DraftErrors };

export const emptySegment = (phase: Phase = 'work'): SegmentDraft =>
  ({ label: phase === 'work' ? 'Work' : phase === 'rest' ? 'Rest' : phase === 'prep' ? 'Prep' : 'Cooldown', phase, duration: phase === 'rest' ? '0:10' : '0:20' });

export const emptyIntervalDraft = (): IntervalDraft =>
  ({ name: '', sound: true, countdownTicks: true, rounds: '8', prep: '', cooldown: '', segments: [emptySegment('work'), emptySegment('rest')] });

export const emptyCountdownDraft = (): CountdownDraft => ({ name: '', sound: true, duration: '5:00', lapsEnabled: false });

/** The draft that shows an interval spec, for editing a preset or checking the form against the schema fixtures. */
export function intervalDraftFrom(spec: { name?: string; sound?: boolean; countdownTicks?: boolean; rounds: number; prepMs?: number; cooldownMs?: number; segments: { label: string; phase: string; durationMs: number }[] }): IntervalDraft {
  return {
    name: spec.name ?? '',
    sound: spec.sound ?? true,
    countdownTicks: spec.countdownTicks ?? true,
    rounds: String(spec.rounds),
    prep: spec.prepMs === undefined ? '' : durationText(spec.prepMs),
    cooldown: spec.cooldownMs === undefined ? '' : durationText(spec.cooldownMs),
    segments: spec.segments.map((segment) => ({ label: segment.label, phase: segment.phase, duration: durationText(segment.durationMs) }))
  };
}

// Draft fields by the spec path the SET-74 validator reports.
const DRAFT_FIELD: Record<string, string> = { prepMs: 'prep', cooldownMs: 'cooldown', durationMs: 'duration' };
const draftPath = (path: readonly PropertyKey[]) => path.map((part) => DRAFT_FIELD[String(part)] ?? String(part)).join('.');

/** Validates a built spec with the operations' own validator, so the form accepts exactly what `create` does. */
function checkSpec<Spec extends TimerSpec>(spec: Record<string, unknown>, errors: DraftErrors): DraftOutcome<Spec> {
  const parsed = validators.timerSpec.safeParse(spec);
  if (!parsed.success) {
    for (const issue of parsed.error.issues) {
      const path = draftPath(issue.path);
      errors[path] ??= issue.message;
    }
  }
  return Object.keys(errors).length || !parsed.success ? { ok: false, errors } : { ok: true, spec: parsed.data as Spec };
}

function readDuration(text: string, field: string, errors: DraftErrors, required: boolean): number | undefined {
  const ms = parseDurationText(text);
  if (ms === null) errors[field] = 'must be seconds, m:ss or h:mm:ss';
  else if (ms === undefined && required) errors[field] = 'is required';
  return ms ?? undefined;
}

/** A blank name lets the operation pick its default. */
const optionalName = (name: string) => (name.trim() ? { name: name.trim() } : {});
/** Settings left at their defaults are omitted, as the operations fill them in. */
const unlessDefault = (key: string, value: boolean, fallback: boolean) => (value === fallback ? {} : { [key]: value });

export function intervalSpecFrom(draft: IntervalDraft): DraftOutcome<Extract<TimerSpec, { kind: 'interval' }>> {
  const errors: DraftErrors = {};
  const roundsText = draft.rounds.trim();
  const rounds = /^\d+$/.test(roundsText) ? Number(roundsText) : Number.NaN;
  if (Number.isNaN(rounds)) errors.rounds = 'must be a whole number';
  const prepMs = readDuration(draft.prep, 'prep', errors, false);
  const cooldownMs = readDuration(draft.cooldown, 'cooldown', errors, false);
  const segments = draft.segments.map((segment, index) => ({
    label: segment.label.trim(),
    phase: segment.phase,
    durationMs: readDuration(segment.duration, `segments.${index}.duration`, errors, true)
  }));
  const spec = {
    kind: 'interval', ...optionalName(draft.name), ...unlessDefault('sound', draft.sound, true),
    ...unlessDefault('countdownTicks', draft.countdownTicks, true), rounds: Number.isNaN(rounds) ? 1 : rounds, segments,
    ...(prepMs !== undefined && { prepMs }), ...(cooldownMs !== undefined && { cooldownMs })
  };
  return checkSpec(spec, errors);
}

export function countdownSpecFrom(draft: CountdownDraft): DraftOutcome<Extract<TimerSpec, { kind: 'countdown' }>> {
  const errors: DraftErrors = {};
  const durationMs = readDuration(draft.duration, 'duration', errors, true);
  return checkSpec({ kind: 'countdown', ...optionalName(draft.name), ...unlessDefault('sound', draft.sound, true), durationMs: durationMs ?? 0, ...(draft.lapsEnabled && { lapsEnabled: true }) }, errors);
}

export type CreateMode = 'preset' | 'countdown' | 'stopwatch' | 'interval';

/** The create form: a mode, the name shared by every mode, and each mode's own fields. */
export interface CreateForm {
  mode: CreateMode;
  name: string;
  presetId: string;
  countdown: CountdownDraft;
  interval: IntervalDraft;
}

export type CreateInput = { preset: string; name?: string } | { timer: TimerSpec };

/** The `create` input the form describes, checked with the operation's own validators in every mode, or each error by field. */
export function createInputFrom(form: CreateForm): DraftOutcome<CreateInput> {
  const wrap = (outcome: DraftOutcome<TimerSpec>): DraftOutcome<CreateInput> => (outcome.ok ? { ok: true, spec: { timer: outcome.spec } } : outcome);
  switch (form.mode) {
    case 'preset': {
      if (!form.presetId) return { ok: false, errors: { preset: 'Choose a preset.' } };
      const input = { preset: form.presetId, ...optionalName(form.name) };
      const parsed = validators.inputs.create.safeParse(input);
      if (parsed.success) return { ok: true, spec: input };
      const errors: DraftErrors = {};
      for (const issue of parsed.error.issues) errors[draftPath(issue.path) || 'preset'] ??= issue.message;
      return { ok: false, errors };
    }
    case 'stopwatch':
      return wrap(checkSpec({ kind: 'stopwatch', ...optionalName(form.name) }, {}));
    case 'countdown':
      return wrap(countdownSpecFrom({ ...form.countdown, name: form.name }));
    case 'interval':
      return wrap(intervalSpecFrom({ ...form.interval, name: form.name }));
  }
}

/** A preset's length and shape in a few words, for the preset picker. */
export function presetSummary(timer: PresetTimerSpec): string {
  if (timer.kind === 'stopwatch') return 'stopwatch';
  if (timer.kind === 'countdown') return `${durationText(timer.durationMs)} countdown${timer.lapsEnabled ? ' with laps' : ''}`;
  const total = (timer.prepMs ?? 0) + timer.rounds * timer.segments.reduce((sum, segment) => sum + segment.durationMs, 0) + (timer.cooldownMs ?? 0);
  return `${timer.rounds} × ${timer.segments.length} segment${timer.segments.length === 1 ? '' : 's'} · ${durationText(total)}`;
}
