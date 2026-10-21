import { TIMER_ID_PATTERN, timerLine } from '@subset/timer';
import { parseDuration, parseUntil } from '../parse-duration.mjs';
import { CliError, call, endsAt, formatLocalTime, resolveRef, resolveTimer, usageError } from './shared.mjs';

/** Built-in preset names people use that are not a preset's id or name. */
const PRESET_ALIASES = { hiit: 'hiit-40-20' };
const INTERVAL_FLAGS = ['work', 'rest', 'rounds', 'prep', 'cooldown'];

/** The human text for a timer result: its SET-74 line, and when it will end if it is running. */
export function timerResultText(result) {
  const end = endsAt(result);
  const line = timerLine(result.timer);
  return end === null ? line : `${line}\nEnds at ${formatLocalTime(end, result.observedAt)}.`;
}

function duration(flag, value) {
  try {
    return parseDuration(value);
  } catch (error) {
    throw usageError(`--${flag}: ${error.message}`);
  }
}

function rounds(value) {
  if (!/^\d{1,3}$/.test(value)) throw usageError(`--rounds: "${value}" is not a whole number of rounds.`);
  return Number(value);
}

/** An interval spec from `--work`, `--rest`, `--rounds`, `--prep` and `--cooldown`. */
export function intervalSpec(values) {
  if (values.work === undefined) throw usageError('An interval needs --work, for example --work 40s.');
  if (values.rounds === undefined) throw usageError('An interval needs --rounds, for example --rounds 10.');
  const segments = [{ label: 'Work', phase: 'work', durationMs: duration('work', values.work) }];
  if (values.rest !== undefined) segments.push({ label: 'Rest', phase: 'rest', durationMs: duration('rest', values.rest) });
  const spec = { kind: 'interval', segments, rounds: rounds(values.rounds) };
  if (values.prep !== undefined) spec.prepMs = duration('prep', values.prep);
  if (values.cooldown !== undefined) spec.cooldownMs = duration('cooldown', values.cooldown);
  return spec;
}

/** The preset `ref` names: an exact id, a unique case-insensitive name, or an alias such as `hiit`. */
async function resolvePreset(client, ref) {
  const { presets } = await call(client.presets());
  const alias = Object.hasOwn(PRESET_ALIASES, ref.toLowerCase()) ? PRESET_ALIASES[ref.toLowerCase()] : null;
  try {
    return resolveRef(presets, ref, { noun: 'preset', describe: ({ id, name }) => ({ id, name }) });
  } catch (error) {
    const aliased = error.code === 'not_found' && alias ? presets.find((preset) => preset.id === alias) : null;
    if (aliased) return aliased;
    if (error.code === 'not_found') {
      throw new CliError('not_found', `"${ref}" is not a duration, stopwatch, interval or preset. Run subset-timer presets to list presets.`);
    }
    throw error;
  }
}

/** The `start` operation input for `start <spec>` or `start --until <time>`. */
async function startInput(client, spec, values, now) {
  const intervalFlags = INTERVAL_FLAGS.filter((flag) => values[flag] !== undefined);
  const name = values.name === undefined ? {} : { name: values.name };
  const sound = values['no-sound'] ? { sound: false } : {};
  if (spec !== 'interval' && intervalFlags.length) {
    throw usageError(`--${intervalFlags[0]} applies only to start interval.`);
  }
  if (values.until !== undefined) {
    if (spec !== undefined) throw usageError('Use either a <spec> or --until, not both.');
    try {
      return { timer: { kind: 'countdown', until: parseUntil(values.until, now), ...sound }, ...name };
    } catch (error) {
      throw usageError(`--until: ${error.message}`);
    }
  }
  if (spec === undefined) throw usageError('start needs a <spec> or --until. Run subset-timer --help.');
  if (TIMER_ID_PATTERN.test(spec)) {
    if (values.name !== undefined || values['no-sound']) throw usageError('--name and --no-sound apply only to a new timer.');
    return { id: spec };
  }
  if (spec === 'stopwatch') return { timer: { kind: 'stopwatch', ...sound }, ...name };
  if (spec === 'interval') return { timer: { ...intervalSpec(values), ...sound }, ...name };
  let durationError;
  try {
    return { timer: { kind: 'countdown', durationMs: parseDuration(spec), ...sound }, ...name };
  } catch (error) {
    durationError = error;
  }
  let preset;
  try {
    preset = await resolvePreset(client, spec);
  } catch (error) {
    // Something that starts like a duration but is not one, and names no preset, is a malformed duration.
    if (error.code === 'not_found' && /^\d/.test(spec)) throw usageError(durationError.message);
    throw error;
  }
  // The start input names a preset only by id; to turn its sound off, the CLI sends the preset's timer.
  if (values['no-sound']) return { timer: { ...preset.timer, name: preset.timer.name ?? preset.name, sound: false }, ...name };
  return { preset: preset.id, ...name };
}

export const timerCommands = {
  list: {
    options: {},
    positionals: [0, 0],
    async run({ client }) {
      const result = await call(client.timers());
      return { json: result, text: result.text };
    }
  },
  status: {
    options: {},
    positionals: [1, 1],
    async run({ client, positionals: [ref] }) {
      const timer = await resolveTimer(client, ref);
      const result = await call(client.op('get', { id: timer.id }));
      return { json: result, text: timerResultText(result) };
    }
  },
  start: {
    options: {
      name: { type: 'string' },
      'no-sound': { type: 'boolean' },
      until: { type: 'string' },
      ...Object.fromEntries(INTERVAL_FLAGS.map((flag) => [flag, { type: 'string' }]))
    },
    positionals: [0, 1],
    async run({ client, positionals: [spec], values, now }) {
      const input = await startInput(client, spec, values, now());
      const result = await call(client.op('start', input));
      return { json: result, text: timerResultText(result) };
    }
  },
  rm: {
    options: {},
    positionals: [1, 1],
    async run({ client, positionals: [ref] }) {
      const timer = await resolveTimer(client, ref);
      const result = await call(client.op('remove', { id: timer.id }));
      return { json: result, text: `Removed ${timer.name} (${result.removedId}).` };
    }
  }
};

for (const operation of ['pause', 'resume', 'lap', 'skip', 'reset']) {
  timerCommands[operation] = {
    options: {},
    positionals: [1, 1],
    async run({ client, positionals: [ref] }) {
      const timer = await resolveTimer(client, ref);
      const result = await call(client.op(operation, { id: timer.id }));
      return { json: result, text: timerResultText(result) };
    }
  };
}
