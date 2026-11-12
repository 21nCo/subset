// Labelled interval workouts: repeatable `--step "Label:40s"` flags and workout files (`--file <path|->`).
import { constants as fsConstants } from 'node:fs';
import { open } from 'node:fs/promises';
import { resolve } from 'node:path';
import { PHASES, TIMER_LIMITS, lineTextIssue } from '@subset.dev/timer-core';
import { parseDuration } from '../parse-duration.mjs';
import { CliError } from './shared.mjs';

/** The most a workout file may hold, in bytes. */
export const WORKOUT_FILE_LIMIT = 1024 * 1024;

const WORKOUT_FIELDS = new Set(['name', 'prep', 'cooldown', 'rest', 'rounds', 'sound', 'steps']);
const STEP_FIELDS = new Set(['label', 'duration', 'phase']);

class WorkoutIssues {
  constructor(prefix) {
    this.prefix = prefix;
    this.issues = [];
  }

  add(path, message) {
    this.issues.push({ path, message });
  }

  /** Throws `invalid_input` naming the first issue, with every issue under `issues`. */
  check() {
    if (!this.issues.length) return;
    const [first] = this.issues;
    const more = this.issues.length > 1 ? ` (and ${this.issues.length - 1} more)` : '';
    throw new CliError('invalid_input', `${this.prefix}${first.path}: ${first.message}${more}`, { issues: this.issues });
  }
}

/** Milliseconds for a duration string (`40s`, `1:30`) or a whole number of seconds; records an issue otherwise. */
function durationMs(value, path, issues) {
  if (typeof value === 'number') {
    if (Number.isInteger(value) && value >= 1 && value <= TIMER_LIMITS.maxDurationMs / 1000) return value * 1000;
    issues.add(path, 'must be a whole number of seconds from 1 to 86400, or a duration such as "40s"');
    return undefined;
  }
  if (typeof value !== 'string') {
    issues.add(path, 'must be a duration such as "40s" or "1:30", or a number of seconds');
    return undefined;
  }
  try {
    return parseDuration(value);
  } catch (error) {
    issues.add(path, error.message);
    return undefined;
  }
}

/** Checks one line of text (a label or a name) by the core's rules, after trimming it as the CLI sends it. */
function checkLine(value, max, path, issues, empty) {
  if (typeof value !== 'string' || !value.trim()) {
    issues.add(path, empty);
    return;
  }
  const issue = lineTextIssue(value.trim(), max);
  if (issue) issues.add(path, issue);
}

function checkLabel(label, path, issues) {
  checkLine(label, TIMER_LIMITS.labelLength, path, issues, 'must be a non-empty label');
}

function checkRounds(value, path, issues) {
  if (Number.isInteger(value) && value >= 1 && value <= TIMER_LIMITS.rounds) return value;
  issues.add(path, `must be a whole number from 1 to ${TIMER_LIMITS.rounds}`);
  return undefined;
}

/**
 * The segments for `steps`, with a rest of `restMs` labelled "Rest" after every step but the last.
 * A workout of more segments than the model allows is an issue at `stepsPath`.
 */
function withRests(steps, restMs, stepsPath, issues) {
  const segments = [];
  steps.forEach((step, index) => {
    segments.push(step);
    if (restMs !== undefined && index < steps.length - 1) segments.push({ label: 'Rest', phase: 'rest', durationMs: restMs });
  });
  if (segments.length > TIMER_LIMITS.segments) {
    issues.add(stepsPath, `makes ${segments.length} steps with its rests; a workout has at most ${TIMER_LIMITS.segments}`);
  }
  return segments;
}

/**
 * One `--step` value: a label, a colon and a duration (`Squats:40s`, `Plank:1:30`). The duration
 * starts after the first colon whose remainder is a valid duration, so a label may hold colons.
 */
export function parseStep(text, index, issues) {
  const path = `--step ${index + 1}`;
  for (let at = text.indexOf(':'); at !== -1; at = text.indexOf(':', at + 1)) {
    const label = text.slice(0, at).trim();
    let ms;
    try {
      ms = parseDuration(text.slice(at + 1));
    } catch {
      continue;
    }
    checkLabel(label, path, issues);
    return { label, phase: 'work', durationMs: ms };
  }
  issues.add(path, `"${text}" needs a label and a duration, for example "Squats:40s"`);
  return undefined;
}

/** The interval spec for `start interval --step ... [--rest] [--rounds] [--prep] [--cooldown]`. */
export function stepsSpec(values) {
  const issues = new WorkoutIssues('');
  for (const flag of ['work', 'file']) {
    if (values[flag] !== undefined) throw new CliError('invalid_input', `--step cannot be combined with --${flag}.`);
  }
  const steps = values.step.map((text, index) => parseStep(text, index, issues));
  const flagMs = (flag) => (values[flag] === undefined ? undefined : durationMs(values[flag], `--${flag}`, issues));
  const restMs = flagMs('rest');
  let rounds = 1;
  if (values.rounds !== undefined) {
    rounds = /^\d{1,3}$/.test(values.rounds) ? checkRounds(Number(values.rounds), '--rounds', issues) : undefined;
    if (rounds === undefined && !/^\d{1,3}$/.test(values.rounds)) issues.add('--rounds', `"${values.rounds}" is not a whole number of rounds`);
  }
  const prepMs = flagMs('prep');
  const cooldownMs = flagMs('cooldown');
  issues.check();
  const segments = withRests(steps, restMs, '--step', issues);
  issues.check();
  return { kind: 'interval', segments, rounds, ...(prepMs === undefined ? {} : { prepMs }), ...(cooldownMs === undefined ? {} : { cooldownMs }) };
}

/**
 * The interval spec and name a parsed workout file describes:
 * `{ name?, prep?, cooldown?, rest?, rounds?, sound?, steps: [{ label, duration, phase? }] }`.
 */
export function workoutSpec(workout) {
  const issues = new WorkoutIssues('Workout file: ');
  if (workout === null || typeof workout !== 'object' || Array.isArray(workout)) {
    issues.add('(root)', 'must be a JSON object with "steps"');
    issues.check();
  }
  for (const key of Object.keys(workout)) if (!WORKOUT_FIELDS.has(key)) issues.add(key, 'is not a workout field');
  if (workout.name !== undefined) checkLine(workout.name, TIMER_LIMITS.nameLength, 'name', issues, 'must be a non-empty name');
  if (workout.sound !== undefined && typeof workout.sound !== 'boolean') issues.add('sound', 'must be true or false');
  const rounds = workout.rounds === undefined ? 1 : checkRounds(workout.rounds, 'rounds', issues);
  const optionalMs = (key) => (workout[key] === undefined ? undefined : durationMs(workout[key], key, issues));
  const prepMs = optionalMs('prep');
  const cooldownMs = optionalMs('cooldown');
  const restMs = optionalMs('rest');
  const steps = [];
  if (!Array.isArray(workout.steps) || !workout.steps.length) {
    issues.add('steps', 'must be a list of at least one step');
  } else {
    workout.steps.forEach((step, index) => {
      const path = `steps[${index}]`;
      if (step === null || typeof step !== 'object' || Array.isArray(step)) {
        issues.add(path, 'must be an object with "label" and "duration"');
        return;
      }
      for (const key of Object.keys(step)) if (!STEP_FIELDS.has(key)) issues.add(`${path}.${key}`, 'is not a step field');
      checkLabel(step.label, `${path}.label`, issues);
      let ms;
      if (step.duration === undefined) issues.add(`${path}.duration`, 'is required');
      else ms = durationMs(step.duration, `${path}.duration`, issues);
      // Only a missing phase means work; null or any other value is refused.
      const phase = step.phase === undefined ? 'work' : step.phase;
      if (!PHASES.includes(phase)) issues.add(`${path}.phase`, `must be one of ${PHASES.join(', ')}`);
      if (typeof step.label === 'string') steps.push({ label: step.label.trim(), phase, durationMs: ms });
    });
  }
  issues.check();
  const segments = withRests(steps, restMs, 'steps', issues);
  issues.check();
  const spec = { kind: 'interval', segments, rounds };
  if (prepMs !== undefined) spec.prepMs = prepMs;
  if (cooldownMs !== undefined) spec.cooldownMs = cooldownMs;
  if (workout.sound !== undefined) spec.sound = workout.sound;
  return { spec, name: workout.name?.trim() };
}

async function readLimited(read, label) {
  const text = await read();
  if (Buffer.byteLength(text) > WORKOUT_FILE_LIMIT) {
    throw new CliError('invalid_input', `${label} is larger than 1 MiB.`);
  }
  return text;
}

/** Reads and parses the workout `--file` names: a path (relative to `cwd`) or `-` for stdin. */
export async function readWorkout(file, { cwd = process.cwd(), readStdin } = {}) {
  let text;
  if (file === '-') {
    if (!readStdin) throw new CliError('invalid_input', '--file - needs a workout on stdin.');
    text = await readLimited(readStdin, 'The workout on stdin');
  } else {
    const path = resolve(cwd, file);
    let handle;
    try {
      // Non-blocking, so a FIFO with no writer opens at once and is refused as not a file instead of hanging.
      handle = await open(path, fsConstants.O_RDONLY | fsConstants.O_NONBLOCK);
      if (!(await handle.stat()).isFile()) throw new CliError('invalid_input', `--file: ${file} is not a file.`);
      // Read at most one byte past the limit from the open file, so a file that grows meanwhile is still refused.
      const buffer = Buffer.alloc(WORKOUT_FILE_LIMIT + 1);
      let size = 0;
      for (;;) {
        const { bytesRead } = await handle.read(buffer, size, buffer.length - size, null);
        if (!bytesRead) break;
        size += bytesRead;
        if (size > WORKOUT_FILE_LIMIT) throw new CliError('invalid_input', `--file: ${file} is larger than 1 MiB.`);
      }
      text = buffer.subarray(0, size).toString('utf8');
    } catch (error) {
      if (error instanceof CliError) throw error;
      throw new CliError('invalid_input', `--file: cannot read ${file} (${error.code ?? error.message}).`);
    } finally {
      await handle?.close();
    }
  }
  try {
    return JSON.parse(text);
  } catch (error) {
    throw new CliError('invalid_input', `Workout file: not valid JSON (${error.message}).`);
  }
}

/** Reads all of `stream` (stdin) as UTF-8, stopping once it holds more than the workout limit. */
export async function readStream(stream) {
  const chunks = [];
  let size = 0;
  for await (const chunk of stream) {
    chunks.push(chunk);
    size += chunk.length;
    if (size > WORKOUT_FILE_LIMIT) break;
  }
  return Buffer.concat(chunks).toString('utf8');
}
