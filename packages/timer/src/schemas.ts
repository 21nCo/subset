import { z } from 'zod';
import { totalDurationMs, type TimerProjection } from './engine.js';
import {
  PHASES, PRESET_ID_PATTERN, TIMER_ID_PATTERN, TIMER_LIMITS, TIMER_SCHEMA_VERSION, TIMER_STATUSES, TIMER_VIEW_ID,
  textLength, type Preset, type Timer, type TimerSpec, type TimerStore
} from './model.js';
import { BUILT_IN_PRESET_IDS } from './presets.js';

// The zod schemas validate untrusted input at runtime; `schemas` is their JSON Schema (draft 2020-12)
// for hosts, MCP tool definitions and the Swift client. A rule JSON Schema cannot state is added
// with `.meta()` so both forms agree, except "until is within the next 24 hours", which depends on
// `now` and is checked by the operations, and the store's position rule below.

// One line of text: no control characters, line or paragraph separators, or bidi embeddings,
// overrides or isolates (which could reorder the agent's text line), and at least one visible
// character. Both checks are a single character class, so they take linear time, and an aborting
// length check (a code point is at most two UTF-16 units) bounds the input before either runs.
const ONE_LINE = /^[^\p{Cc}\p{Zl}\p{Zp}\u202A-\u202E\u2066-\u2069]*$/u;
const VISIBLE = /[^\s\p{Z}\p{Cc}\p{Cf}\p{Cs}\p{M}\p{Default_Ignorable_Code_Point}]/u;
const line = (max: number) =>
  z.string()
    .max(max * 2, { abort: true, message: `must be at most ${max} characters` })
    .regex(ONE_LINE, 'must be one line without control or bidi formatting characters')
    .regex(VISIBLE, 'must have a visible character')
    .refine((value) => textLength(value) <= max, `must be at most ${max} characters`)
    .meta({ minLength: 1, maxLength: max });

const name = line(TIMER_LIMITS.nameLength);
const duration = z.number().int().min(TIMER_LIMITS.minDurationMs).max(TIMER_LIMITS.maxDurationMs);
const epochMs = z.number().int().nonnegative();
const nonNegativeMs = z.number().int().nonnegative();
const until = z.iso.datetime({ offset: true });
const timerId = z.string().regex(TIMER_ID_PATTERN, 'must be a timer id such as t_ab12cd34');
const presetId = z.string().regex(
  new RegExp(`^(?:${BUILT_IN_PRESET_IDS.join('|')}|${PRESET_ID_PATTERN.source.slice(1, -1)})$`),
  'must be a built-in preset id or a saved preset id such as p_ab12cd34'
);
const phase = z.enum(PHASES);

const segment = z.strictObject({ label: line(TIMER_LIMITS.labelLength), phase, durationMs: duration });
const commonSpec = { name: name.optional(), sound: z.boolean().optional(), countdownTicks: z.boolean().optional() };
const countdownSpec = z.strictObject({
  kind: z.literal('countdown'), ...commonSpec,
  durationMs: duration.optional(), until: until.optional(), lapsEnabled: z.boolean().optional()
})
  .refine((spec) => (spec.durationMs === undefined) !== (spec.until === undefined), 'needs exactly one of durationMs and until')
  .meta({ oneOf: [{ required: ['durationMs'] }, { required: ['until'] }] });
const stopwatchSpec = z.strictObject({ kind: z.literal('stopwatch'), ...commonSpec });
const intervalBody = {
  segments: z.array(segment).min(1).max(TIMER_LIMITS.segments),
  rounds: z.number().int().min(1).max(TIMER_LIMITS.rounds),
  prepMs: duration.optional(),
  cooldownMs: duration.optional()
};
const intervalSpec = z.strictObject({ kind: z.literal('interval'), ...commonSpec, ...intervalBody });
const timerSpec = z.discriminatedUnion('kind', [countdownSpec, stopwatchSpec, intervalSpec]);
// A preset names a length, never one moment in time.
const presetTimerSpec = z.discriminatedUnion('kind', [
  z.strictObject({ kind: z.literal('countdown'), ...commonSpec, durationMs: duration, lapsEnabled: z.boolean().optional() }),
  stopwatchSpec,
  intervalSpec
]);

const commonDefinition = { id: timerId, name, sound: z.boolean(), countdownTicks: z.boolean(), createdAt: epochMs };
const timerDefinition = z.discriminatedUnion('kind', [
  z.strictObject({
    kind: z.literal('countdown'), ...commonDefinition,
    durationMs: duration.optional(), until: until.optional(), lapsEnabled: z.boolean()
  })
    .refine((definition) => definition.durationMs !== undefined || definition.until !== undefined, 'needs durationMs or until')
    .meta({ anyOf: [{ required: ['durationMs'] }, { required: ['until'] }] }),
  z.strictObject({ kind: z.literal('stopwatch'), ...commonDefinition }),
  z.strictObject({ kind: z.literal('interval'), ...commonDefinition, ...intervalBody })
]);

const lap = z.strictObject({ elapsedMs: nonNegativeMs, at: epochMs });
const runtimeBody = { accumulatedMs: nonNegativeMs, laps: z.array(lap).max(TIMER_LIMITS.laps), skippedMs: nonNegativeMs };
const timerRuntime = z.discriminatedUnion('status', [
  // An idle timer has not moved: no position, laps or skips.
  z.strictObject({ status: z.literal('idle'), startedAt: z.null(), pausedAt: z.null(), accumulatedMs: z.literal(0), laps: z.array(lap).max(0), skippedMs: z.literal(0) }),
  z.strictObject({ status: z.literal('running'), startedAt: epochMs, pausedAt: z.null(), ...runtimeBody }),
  z.strictObject({ status: z.literal('paused'), startedAt: z.null(), pausedAt: epochMs, ...runtimeBody }),
  z.strictObject({ status: z.literal('finished'), startedAt: z.null(), pausedAt: z.null(), ...runtimeBody })
]);

// Rules across a timer's definition and runtime, so that every timer `parseStore` accepts projects
// and schedules consistently. The JSON Schema states the ones that do not need arithmetic; the
// position rules ("running or paused before the end, finished exactly at it") are runtime only.
const objectWith = (properties: Record<string, unknown>, required: string[] = Object.keys(properties)) =>
  ({ type: 'object', properties, required });
const definitionIs = (properties: Record<string, unknown>) => objectWith({ definition: objectWith(properties) });
const runtimeMust = (properties: Record<string, unknown>) => objectWith({ runtime: objectWith(properties, []) }, ['runtime']);
const noLaps = { laps: { type: 'array', maxItems: 0 } };
const noSkips = { skippedMs: { const: 0 } };
const timerRules = [
  { if: definitionIs({ kind: { const: 'stopwatch' } }), then: runtimeMust({ status: { not: { const: 'finished' } }, ...noSkips }) },
  { if: definitionIs({ kind: { const: 'countdown' } }), then: runtimeMust(noSkips) },
  { if: definitionIs({ kind: { const: 'countdown' }, lapsEnabled: { const: false } }), then: runtimeMust(noLaps) },
  { if: definitionIs({ kind: { const: 'interval' } }), then: runtimeMust(noLaps) },
  {
    if: objectWith({ definition: objectWith({ kind: { const: 'countdown' } }), runtime: objectWith({ status: { not: { const: 'idle' } } }) }),
    then: objectWith({ definition: objectWith({}, ['durationMs']) }, ['definition'])
  }
];

function checkTimer(value: { definition: Timer['definition']; runtime: Timer['runtime'] }, context: z.RefinementCtx) {
  const { definition, runtime } = value;
  const issue = (path: string[], message: string) => context.addIssue({ code: 'custom', path, message });
  const lapCapable = definition.kind === 'stopwatch' || (definition.kind === 'countdown' && definition.lapsEnabled);
  if (!lapCapable && runtime.laps.length > 0) issue(['runtime', 'laps'], 'only stopwatches and countdowns with laps enabled take laps');
  if (definition.kind !== 'interval' && runtime.skippedMs !== 0) issue(['runtime', 'skippedMs'], 'only interval timers skip');
  if (runtime.status === 'idle') return;
  if (definition.kind === 'countdown' && definition.durationMs === undefined) {
    issue(['definition', 'durationMs'], 'a countdown that has started has a fixed durationMs');
    return;
  }
  // Fixed once started, so `now` does not matter.
  const totalMs = totalDurationMs(definition, 0);
  const position = runtime.accumulatedMs + runtime.skippedMs;
  if (totalMs === null) {
    if (runtime.status === 'finished') issue(['runtime', 'status'], 'a stopwatch never finishes');
  } else if (runtime.status === 'finished' ? position !== totalMs : position >= totalMs) {
    issue(['runtime', 'accumulatedMs'], runtime.status === 'finished'
      ? 'a finished timer has accumulatedMs + skippedMs equal to its total'
      : `a ${runtime.status} timer has accumulatedMs + skippedMs below its total`);
  }
}

const timer = z.strictObject({ definition: timerDefinition, runtime: timerRuntime })
  .superRefine(checkTimer)
  .meta({ allOf: timerRules });
const preset = z.strictObject({ id: presetId, name, builtIn: z.boolean(), timer: presetTimerSpec });
const store = z.strictObject({
  schemaVersion: z.literal(TIMER_SCHEMA_VERSION),
  idSequence: nonNegativeMs,
  timers: z.array(timer).max(TIMER_LIMITS.timers),
  presets: z.array(preset.extend({ id: z.string().regex(PRESET_ID_PATTERN), builtIn: z.literal(false) })).max(TIMER_LIMITS.userPresets)
}).refine((value) => new Set(value.timers.map((item) => item.definition.id)).size === value.timers.length, 'timer ids must be unique')
  .refine((value) => new Set(value.presets.map((item) => item.id)).size === value.presets.length, 'preset ids must be unique');

const intervalStep = z.strictObject({
  index: nonNegativeMs,
  segmentIndex: nonNegativeMs.nullable(),
  round: z.number().int().min(1).nullable(),
  phase,
  label: z.string(),
  startMs: nonNegativeMs,
  durationMs: nonNegativeMs
});
const projection = z.strictObject({
  status: z.enum(TIMER_STATUSES),
  elapsedMs: nonNegativeMs,
  totalMs: nonNegativeMs.nullable(),
  remainingMs: nonNegativeMs.nullable(),
  finished: z.boolean(),
  step: intervalStep.extend({ elapsedMs: nonNegativeMs, remainingMs: nonNegativeMs }).nullable(),
  next: intervalStep.nullable()
});
const snapshot = z.strictObject({ definition: timerDefinition, runtime: timerRuntime, projection });
const boardResult = z.strictObject({ schemaVersion: z.literal(TIMER_SCHEMA_VERSION), observedAt: epochMs, timers: z.array(snapshot) });
const timerError = z.strictObject({
  code: z.enum(['not_found', 'invalid_state', 'limit_reached', 'invalid_input']),
  message: z.string(),
  issues: z.array(z.strictObject({ path: z.string(), message: z.string() })).optional()
});
// `actions` and `now` are functions the host passes to the view; only the serializable props have a schema.
const viewProps = z.strictObject({
  result: boardResult,
  capabilities: z.strictObject({ create: z.boolean(), destructive: z.boolean() }),
  density: z.enum(['compact', 'full'])
});

const exactlyOne = (keys: string[]) => (value: Record<string, unknown>) => keys.filter((key) => value[key] !== undefined).length === 1;
// Each branch requires its own selector and excludes every other one, so exactly one branch can
// match whatever else the input holds.
const selector = (key: string, excluded: string[]) =>
  ({ required: [key], not: { anyOf: excluded.map((other) => ({ required: [other] })) } });
const idInput = z.strictObject({ id: timerId });
const emptyInput = z.strictObject({});
const createInput = z.strictObject({ timer: timerSpec.optional(), preset: presetId.optional(), name: name.optional() })
  .refine(exactlyOne(['timer', 'preset']), 'needs exactly one of timer and preset')
  .meta({ oneOf: [selector('timer', ['preset']), selector('preset', ['timer'])] });
const startInput = z.strictObject({ id: timerId.optional(), timer: timerSpec.optional(), preset: presetId.optional(), name: name.optional() })
  .refine(exactlyOne(['id', 'timer', 'preset']), 'needs exactly one of id, timer and preset')
  .refine((value) => value.id === undefined || value.name === undefined, 'name applies only when creating a timer')
  .meta({ oneOf: [selector('id', ['timer', 'preset', 'name']), selector('timer', ['id', 'preset']), selector('preset', ['id', 'timer'])] });
const presetsSaveInput = z.strictObject({ name, timer: presetTimerSpec });
const presetIdInput = z.strictObject({ id: presetId });

const timerResult = z.strictObject({ timer: snapshot });
const removedResult = z.strictObject({ removedId: z.string() });

/** Runtime validators, used by the operations and by `parseStore`. */
export const validators = {
  store,
  timerSpec,
  inputs: {
    create: createInput,
    start: startInput,
    pause: idInput,
    resume: idInput,
    lap: idInput,
    skip: idInput,
    reset: idInput,
    remove: idInput,
    list: emptyInput,
    get: idInput,
    'presets.list': emptyInput,
    'presets.save': presetsSaveInput,
    'presets.remove': presetIdInput
  },
  outputs: {
    create: timerResult,
    start: timerResult,
    pause: timerResult,
    resume: timerResult,
    lap: timerResult,
    skip: timerResult,
    reset: timerResult,
    remove: removedResult,
    list: boardResult,
    get: timerResult,
    'presets.list': z.strictObject({ presets: z.array(preset) }),
    'presets.save': z.strictObject({ preset }),
    'presets.remove': removedResult
  }
} as const;

type JsonSchema = Record<string, unknown>;
const toJson = (schema: z.ZodType, io: 'input' | 'output'): JsonSchema => z.toJSONSchema(schema, { target: 'draft-2020-12', io }) as JsonSchema;
const mapJson = <T extends Record<string, z.ZodType>>(entries: T, io: 'input' | 'output') =>
  Object.fromEntries(Object.entries(entries).map(([key, schema]) => [key, toJson(schema, io)])) as { [K in keyof T]: JsonSchema };

/** JSON Schemas for every operation's input and result, the store, the agent result, errors and the board view's props. */
export const schemas = {
  inputs: mapJson(validators.inputs, 'input'),
  outputs: mapJson(validators.outputs, 'output'),
  store: toJson(store, 'output'),
  result: toJson(boardResult, 'output'),
  error: toJson(timerError, 'output'),
  viewProps: toJson(viewProps, 'output'),
  viewId: TIMER_VIEW_ID
};

// The hand-written types and the validators must describe the same values.
type Assert<T extends true> = T;
type _StoreMatches = Assert<z.infer<typeof store> extends TimerStore ? true : false>;
type _TimerMatches = Assert<z.infer<typeof timer> extends Timer ? true : false>;
type _SpecMatches = Assert<z.infer<typeof timerSpec> extends TimerSpec ? true : false>;
type _PresetMatches = Assert<z.infer<typeof preset> extends Preset ? true : false>;
type _ProjectionMatches = Assert<z.infer<typeof projection> extends TimerProjection ? true : false>;
