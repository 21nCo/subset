// The Timer MCP tools (SET-79): the SET-74 operations, run by the daemon through the SET-76 client.
// Input schemas reuse the SET-74 `schemas` for ids, names, labels, phases and rounds; durations are
// whole seconds. No tool schema has a top-level oneOf, anyOf, allOf or not, which some hosts refuse,
// so the rules between fields (exactly one start mode, `id` or `name`) are checked here.
import { TIMER_LIMITS, TIMER_SCHEMA_VERSION, schemas, timerLine } from '@subset/timer';
import { presetLine } from '../commands/presets.mjs';
import { CliError, call, endsAt, findPreset, formatLocalTime, resolveName } from '../commands/shared.mjs';
import { DurationError, parseUntil } from '../parse-duration.mjs';
import { BOARD_TOOLS, boardToolMetadata } from './app.mjs';

const { $schema: _dialect, ...SAVE_INPUT } = schemas.inputs['presets.save'];
const TIMER_ID = schemas.inputs.get.properties.id;
const PRESET_ID = schemas.inputs['presets.remove'].properties.id;
const NAME = SAVE_INPUT.properties.name;
const INTERVAL = SAVE_INPUT.properties.timer.oneOf.find((branch) => branch.properties.kind.const === 'interval');
const { label: LABEL, phase: PHASE } = INTERVAL.properties.segments.items.properties;

const MIN_SECONDS = TIMER_LIMITS.minDurationMs / 1_000;
const MAX_SECONDS = TIMER_LIMITS.maxDurationMs / 1_000;
const seconds = (description) => ({ type: 'integer', minimum: MIN_SECONDS, maximum: MAX_SECONDS, description });

const LOCAL = 'Timers run locally in the subset-timer daemon on this computer and keep running after the conversation ends.';
const REPORT = 'Tell the user the timer id and, while it runs, when it ends.';
const PRESET_REPORT = 'Tell the user the preset id; once timer_start starts a timer from it, tell them the timer id and when it ends.';
const BY_ID_OR_NAME = 'Give exactly one of id (from timer_list) and name (a unique timer name, ignoring case).';

/** The interval fields of timer_start's `interval` and of timer_preset_save, in seconds. */
const INTERVAL_PROPERTIES = {
  work: seconds('Seconds of work in each round.'),
  rest: seconds('Seconds of rest after the work in each round.'),
  rounds: { ...INTERVAL.properties.rounds, description: 'How many times the round repeats.' },
  prep: seconds('Seconds to get ready before the first round.'),
  cooldown: seconds('Seconds of cooldown after the last round.'),
  segments: {
    type: 'array',
    minItems: 1,
    maxItems: TIMER_LIMITS.segments,
    description: 'Instead of work and rest: the steps of one round, in order.',
    items: {
      type: 'object',
      properties: { label: { ...LABEL, description: 'Shown name of the step; defaults to its phase.' }, phase: PHASE, seconds: seconds('Length of the step in seconds.') },
      required: ['phase', 'seconds'],
      additionalProperties: false
    }
  }
};
const INTERVAL_INPUT = {
  type: 'object',
  description: 'An interval workout: work (with optional rest) or segments, repeated for rounds, with optional prep and cooldown. Durations are in seconds.',
  properties: INTERVAL_PROPERTIES,
  required: ['rounds'],
  additionalProperties: false
};

const objectSchema = (properties = {}, required = []) => ({ type: 'object', properties, ...(required.length ? { required } : {}), additionalProperties: false });
const ID_INPUT = objectSchema({ id: { ...TIMER_ID, description: 'The timer id, such as t_ab12cd34, from timer_list or timer_start.' } }, ['id']);
const TIMER_REF_INPUT = objectSchema({
  id: { ...TIMER_ID, description: 'The timer id, such as t_ab12cd34.' },
  name: { ...NAME, description: 'The timer name, matched ignoring case; it must name one timer.' }
});
const PRESET_REF_INPUT = objectSchema({
  id: { ...PRESET_ID, description: 'The id of a saved preset, such as p_ab12cd34.' },
  name: { ...NAME, description: 'The preset name, matched ignoring case; it must name one preset.' }
});
const START_MODES = ['preset', 'durationSeconds', 'until', 'stopwatch', 'interval', 'id'];
const NEW_TIMER_FIELDS = ['name', 'sound', 'laps', 'ticks'];
const START_INPUT = objectSchema({
  preset: { type: 'string', minLength: 1, maxLength: TIMER_LIMITS.nameLength, description: 'A preset id or name: tabata, emom, hiit (hiit-40-20), pomodoro, amrap, or a saved preset (see timer_presets).' },
  durationSeconds: seconds('A countdown of this many seconds (1 second to 24 hours).'),
  until: { type: 'string', minLength: 1, maxLength: 40, description: 'A countdown to a local time of day, HH:MM or HH:MM:SS (the next one), or an ISO 8601 time with an offset, 1 second to 24 hours ahead.' },
  stopwatch: { type: 'boolean', const: true, description: 'true for a stopwatch that counts up with laps.' },
  interval: INTERVAL_INPUT,
  id: { ...TIMER_ID, description: 'The id of an idle timer (one that was reset) to start; it keeps its name and settings.' },
  name: { ...NAME, description: 'A name for the new timer.' },
  sound: { type: 'boolean', description: 'false to play no sounds for it; notifications still show.' },
  laps: { type: 'boolean', description: 'With durationSeconds or until: true to let the countdown record laps.' },
  ticks: { type: 'boolean', description: 'Tick in the last 3 seconds of each step or countdown; on by default only for interval timers.' }
});
const SAVE_PRESET_INPUT = objectSchema({
  name: { ...NAME, description: 'The preset name.' },
  ...INTERVAL_PROPERTIES,
  sound: { type: 'boolean', description: 'false for timers from this preset to play no sounds.' }
}, ['name', 'rounds']);

const invalid = (message, path = '') => new CliError('invalid_input', message, { issues: [{ path, message }] });

/** Exactly one of `keys` is given, else `invalid_input`. */
function exactlyOne(args, keys, tool, path = '') {
  const given = keys.filter((key) => args[key] !== undefined);
  if (given.length === 1) return given[0];
  const list = `${keys.slice(0, -1).join(', ')}${keys.length > 2 ? ',' : ''} and ${keys.at(-1)}`;
  throw invalid(`${tool} needs exactly one of ${list}${given.length ? `, not ${given.join(' and ')}` : ''}.`, path);
}

/** The SET-74 interval spec for `fields` in seconds, which hold work (and rest) or segments; `prefix` starts each issue path. */
function intervalSpec(fields, prefix, tool) {
  const mode = exactlyOne(fields, ['work', 'segments'], tool, prefix.slice(0, -1));
  if (mode === 'segments' && fields.rest !== undefined) throw invalid('rest goes with work; with segments, add a rest segment instead.', `${prefix}rest`);
  const step = (label, phase, length) => ({ label, phase, durationMs: length * 1_000 });
  const segments = mode === 'work'
    ? [step('Work', 'work', fields.work), ...(fields.rest === undefined ? [] : [step('Rest', 'rest', fields.rest)])]
    : fields.segments.map((segment) => step(segment.label ?? segment.phase[0].toUpperCase() + segment.phase.slice(1), segment.phase, segment.seconds));
  const spec = { kind: 'interval', segments, rounds: fields.rounds };
  if (fields.prep !== undefined) spec.prepMs = fields.prep * 1_000;
  if (fields.cooldown !== undefined) spec.cooldownMs = fields.cooldown * 1_000;
  return spec;
}

/** The one entry named `name` ignoring case, with the CLI's matching; none is `not_found` with `hint`. */
const byName = (entries, name, noun, hint) => resolveName(entries, name, { noun, describe: ({ id, name: entryName }) => ({ id, name: entryName }), missing: `No ${noun} named "${name}". ${hint}` });

/** Local ISO 8601 with the offset, for example 2026-10-21T17:25:00+02:00. */
function localIso(ms) {
  const date = new Date(ms);
  const pad = (value) => String(value).padStart(2, '0');
  const offset = -date.getTimezoneOffset();
  const zone = `${offset < 0 ? '-' : '+'}${pad(Math.floor(Math.abs(offset) / 60))}:${pad(Math.abs(offset) % 60)}`;
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}${zone}`;
}

/** ` Ends at 17:25:00 (2026-10-21T17:25:00+02:00).` for a running timer with an end, else ''. */
function endText(result) {
  const end = endsAt(result);
  return end === null ? '' : ` Ends at ${formatLocalTime(end, result.observedAt)} (${localIso(end)}).`;
}

const success = (structuredContent, text) => ({ content: [{ type: 'text', text }], structuredContent });

/**
 * `isError` with the code and message in the text and in `structuredContent.error`. A daemon the
 * client could not reach gets a fixed message: the client's own names the data directory or socket,
 * which the model never receives; `log` keeps the detail on stderr.
 */
export function toolError(error, log, applied = '') {
  let failure = error instanceof CliError ? error : new CliError('internal', 'The Timer MCP server failed to handle the call.');
  if (!(error instanceof CliError)) log(`tool call failed: ${error?.stack ?? error}`);
  if (failure.code === 'daemon_unavailable') {
    log(`daemon unavailable: ${failure.message}`);
    failure = new CliError('daemon_unavailable', 'The Timer daemon could not be reached or started. Run subset-timer daemon status in a terminal for details.', failure.details);
  }
  // A change the daemon made before a later read failed is reported, so the model does not repeat it.
  const message = applied ? `${applied} Reading the timers afterwards failed: ${failure.message}` : failure.message;
  const body = { code: failure.code, message, ...failure.details };
  return { content: [{ type: 'text', text: `${failure.code}: ${message}` }], structuredContent: { error: body }, isError: true };
}

/** A failure after the daemon applied a change: `headline` says what changed. */
class AppliedError extends Error {
  constructor(cause, headline, details) {
    super(headline, { cause });
    this.headline = headline;
    this.details = details;
  }
}

/** Maps mcpfn's JSON Schema issues to SET-74 `invalid_input` issues (`interval.work`, not `/interval/work`). */
function schemaIssues(issues) {
  return issues.map((issue) => {
    const path = issue.instancePath.replace(/^\//, '').split('/').filter(Boolean);
    if (issue.missingProperty) path.push(issue.missingProperty);
    if (issue.rejectedProperty) path.push(issue.rejectedProperty);
    const message = issue.rejectedProperty ? 'is not a known field' : issue.missingProperty ? 'is required' : issue.message;
    return { path: path.join('.'), message };
  });
}

/**
 * The 12 tool definitions for `@mcpfn/core`.
 * @param {object} options
 * @param {object} options.client A daemon client from `createClient`.
 * @param {() => number} [options.now] Epoch milliseconds, for `until` as a time of day.
 * @param {(message: string) => void} [options.log] Diagnostics, written to stderr by the server.
 */
export function timerTools({ client, now = Date.now, log = () => {} }) {
  const board = () => call(client.timers());

  /** The agent result after a write, with the timer it changed, and its text after a first line about the change. */
  async function afterWrite(affectedTimerId, headline) {
    const { structuredContent, text } = await readAfter(board, headline, { affectedTimerId });
    return success({ ...structuredContent, affectedTimerId }, `${headline}\n\n${text}`);
  }

  async function presetsAfter(affectedPresetId, headline) {
    const { presets } = await readAfter(() => call(client.presets()), headline, { affectedPresetId });
    return success({ presets, affectedPresetId }, `${headline}\n\n${presets.map(presetLine).join('\n')}`);
  }

  async function readAfter(read, headline, details) {
    try {
      return await read();
    } catch (error) {
      throw new AppliedError(error, headline, details);
    }
  }

  /** The preset `ref` names, resolved as the CLI does. */
  async function resolvePreset(ref) {
    const { presets } = await call(client.presets());
    try {
      return findPreset(presets, ref);
    } catch (error) {
      if (error.code === 'not_found') throw new CliError('not_found', `No preset with the id or name "${ref}". Call timer_presets to list presets.`);
      throw error;
    }
  }

  async function timerRef(args, tool) {
    if (exactlyOne(args, ['id', 'name'], tool) === 'id') return args.id;
    const { structuredContent } = await board();
    const timers = structuredContent.timers.map(({ definition }) => ({ id: definition.id, name: definition.name }));
    return byName(timers, args.name, 'timer', 'Call timer_list to list timers.').id;
  }

  async function startInput(args) {
    const mode = exactlyOne(args, START_MODES, 'timer_start');
    if (mode === 'id') {
      const extra = NEW_TIMER_FIELDS.find((key) => args[key] !== undefined);
      if (extra) throw invalid(`${extra} applies only to a new timer; id starts an existing one as it is.`, extra);
      return { id: args.id };
    }
    if (args.laps !== undefined && mode !== 'durationSeconds' && mode !== 'until') throw invalid('laps applies only to a countdown (durationSeconds or until).', 'laps');
    const name = args.name === undefined ? {} : { name: args.name };
    const settings = { ...(args.sound === undefined ? {} : { sound: args.sound }), ...(args.ticks === undefined ? {} : { countdownTicks: args.ticks }) };
    const countdown = { kind: 'countdown', ...(args.laps === undefined ? {} : { lapsEnabled: args.laps }), ...settings };
    if (mode === 'durationSeconds') return { timer: { ...countdown, durationMs: args.durationSeconds * 1_000 }, ...name };
    if (mode === 'stopwatch') return { timer: { kind: 'stopwatch', ...settings }, ...name };
    if (mode === 'interval') return { timer: { ...intervalSpec(args.interval, 'interval.', 'interval'), ...settings }, ...name };
    if (mode === 'until') {
      try {
        return { timer: { ...countdown, until: parseUntil(args.until, now()) }, ...name };
      } catch (error) {
        if (error instanceof DurationError) throw invalid(`until: ${error.message}`, 'until');
        throw error;
      }
    }
    const preset = await resolvePreset(args.preset);
    // The start input names a preset only by id; to set its sound or ticks, send the preset's timer.
    if (!Object.keys(settings).length) return { preset: preset.id, ...name };
    return { timer: { ...preset.timer, name: preset.timer.name ?? preset.name, ...settings }, ...name };
  }

  /** A write on one timer by id: the operation, then the board. */
  const timerWrite = (operation, verb) => async ({ id }) => {
    const result = await call(client.op(operation, { id }));
    const { definition } = result.timer;
    return afterWrite(definition.id, `${verb} ${definition.name} (${definition.id}).${endText(result)}`);
  };

  const definitions = [
    {
      name: 'timer_list',
      title: 'List timers',
      description: `List every timer with its status, time left and interval step. ${LOCAL} ${REPORT}`,
      inputSchema: objectSchema(),
      annotations: { readOnlyHint: true, openWorldHint: false },
      async handler() {
        const { structuredContent, text } = await board();
        return success(structuredContent, text);
      }
    },
    {
      name: 'timer_get',
      title: 'Show a timer',
      description: `Show one timer by id. ${LOCAL} ${REPORT}`,
      inputSchema: ID_INPUT,
      annotations: { readOnlyHint: true, openWorldHint: false },
      async handler({ id }) {
        const result = await call(client.op('get', { id }));
        const structuredContent = { schemaVersion: TIMER_SCHEMA_VERSION, observedAt: result.observedAt, timers: [result.timer] };
        return success(structuredContent, `${timerLine(result.timer)}${endText(result)}`);
      }
    },
    {
      name: 'timer_presets',
      title: 'List presets',
      description: `List the built-in presets (tabata, emom, hiit-40-20, pomodoro, amrap) and saved ones, for timer_start. ${LOCAL} ${PRESET_REPORT}`,
      inputSchema: objectSchema(),
      annotations: { readOnlyHint: true, openWorldHint: false },
      async handler() {
        const { presets } = await call(client.presets());
        return success({ presets }, presets.map(presetLine).join('\n'));
      }
    },
    {
      name: 'timer_start',
      title: 'Start a timer',
      description: `Create and start a timer from exactly one of: preset, durationSeconds (a countdown), until (a countdown to a time), stopwatch: true, or interval (work and rest rounds), with optional name, sound, laps and ticks; or start an idle timer by id. ${LOCAL} ${REPORT}`,
      inputSchema: START_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      async handler(args) {
        const result = await call(client.op('start', await startInput(args)));
        const { definition } = result.timer;
        return afterWrite(definition.id, `Started ${definition.name} (${definition.id}).${endText(result)}`);
      }
    },
    ...[
      ['timer_pause', 'pause', 'Pause a timer', 'Pause a running timer; it keeps its place.', 'Paused'],
      ['timer_resume', 'resume', 'Resume a timer', 'Resume a paused timer from where it stopped.', 'Resumed'],
      ['timer_lap', 'lap', 'Record a lap', 'Record a lap on a running stopwatch or a countdown with laps (amrap).', 'Recorded a lap on'],
      ['timer_skip', 'skip', 'Skip a step', 'Jump a running or paused interval timer to the start of its next step.', 'Skipped a step of']
    ].map(([name, operation, title, what, verb]) => ({
      name,
      title,
      description: `${what} ${LOCAL} ${REPORT}`,
      inputSchema: ID_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      handler: timerWrite(operation, verb)
    })),
    {
      name: 'timer_reset',
      title: 'Reset a timer',
      description: `Return a timer to idle, clearing its progress and laps. Only at the user's explicit request. ${BY_ID_OR_NAME} ${LOCAL} ${REPORT}`,
      inputSchema: TIMER_REF_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false },
      async handler(args) {
        return timerWrite('reset', 'Reset')({ id: await timerRef(args, 'timer_reset') });
      }
    },
    {
      name: 'timer_remove',
      title: 'Remove a timer',
      description: `Remove a timer for good. Only at the user's explicit request. ${BY_ID_OR_NAME} ${LOCAL} ${REPORT}`,
      inputSchema: TIMER_REF_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
      async handler(args) {
        const { timer } = await call(client.op('get', { id: await timerRef(args, 'timer_remove') }));
        const { removedId } = await call(client.op('remove', { id: timer.definition.id }));
        return afterWrite(removedId, `Removed ${timer.definition.name} (${removedId}).`);
      }
    },
    {
      name: 'timer_preset_save',
      title: 'Save a preset',
      description: `Save an interval workout as a named preset for timer_start: work (with optional rest) or segments, rounds, optional prep and cooldown, in seconds. ${LOCAL} ${PRESET_REPORT}`,
      inputSchema: SAVE_PRESET_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false },
      async handler(args) {
        const timer = { ...intervalSpec(args, '', 'timer_preset_save'), ...(args.sound === undefined ? {} : { sound: args.sound }) };
        const { preset } = await call(client.op('presets.save', { name: args.name, timer }));
        return presetsAfter(preset.id, `Saved preset ${preset.name} (${preset.id}).`);
      }
    },
    {
      name: 'timer_preset_remove',
      title: 'Remove a preset',
      description: `Remove a saved preset; built-in presets cannot be removed. Only at the user's explicit request. Give exactly one of id and name (ignoring case). ${LOCAL} Tell the user the id of the removed preset; timers already started from it keep running, so report their timer ids and end times from timer_list if asked.`,
      inputSchema: PRESET_REF_INPUT,
      annotations: { readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false },
      async handler(args) {
        let { id } = args;
        if (exactlyOne(args, ['id', 'name'], 'timer_preset_remove') === 'name') {
          const { presets } = await call(client.presets());
          ({ id } = byName(presets, args.name, 'preset', 'Call timer_presets to list presets.'));
        }
        // The daemon refuses a built-in preset with invalid_state.
        const { removedId } = await call(client.op('presets.remove', { id }));
        return presetsAfter(removedId, `Removed preset ${removedId}.`);
      }
    }
  ];

  return definitions.map((definition) => ({
    ...definition,
    // In hosts with MCP Apps, these results open the board view (SET-80); the others return no view.
    ...(BOARD_TOOLS.includes(definition.name) ? { metadata: boardToolMetadata() } : {}),
    async handler(args) {
      try {
        return await definition.handler(args);
      } catch (error) {
        if (!(error instanceof AppliedError)) return toolError(error, log);
        const { cause } = error;
        if (!(cause instanceof CliError)) log(`tool call failed: ${cause?.stack ?? cause}`);
        const failure = cause instanceof CliError ? cause : new CliError('internal', 'The Timer MCP server failed to handle the call.');
        return toolError(new CliError(failure.code, failure.message, { ...failure.details, ...error.details }), log, error.headline);
      }
    },
    handleInvalidArguments(_args, issues) {
      const mapped = schemaIssues(issues);
      const message = mapped.map((issue) => (issue.path ? `${issue.path}: ${issue.message}` : issue.message)).join('; ');
      return toolError(new CliError('invalid_input', message || 'The arguments do not match the tool schema.', { issues: mapped }), log);
    }
  }));
}
