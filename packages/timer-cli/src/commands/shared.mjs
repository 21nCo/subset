import { DaemonUnavailableError } from '../daemon/client.mjs';

/** 0 ok, 2 invalid input or ambiguous, 3 daemon unavailable, 4 not found or invalid state. */
export const EXIT = { ok: 0, invalid: 2, unavailable: 3, notFound: 4 };

const EXIT_BY_CODE = {
  invalid_input: EXIT.invalid,
  ambiguous: EXIT.invalid,
  not_found: EXIT.notFound,
  invalid_state: EXIT.notFound,
  limit_reached: EXIT.notFound,
  daemon_unavailable: EXIT.unavailable
};

/** A failure the CLI reports as `{ error: { code, message, ... } }` with its exit code. */
export class CliError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = 'CliError';
    this.code = code;
    this.details = details;
    // Anything else the daemon reports (storage_failed, internal, an unexpected reply) means it could not serve the request.
    this.exitCode = EXIT_BY_CODE[code] ?? EXIT.unavailable;
  }
}

export const usageError = (message) => new CliError('invalid_input', message);

/** The body of a successful daemon reply; otherwise the daemon's error as a `CliError`. */
export function expectOk(reply) {
  if (reply.status === 200) return reply.body;
  const error = reply.body?.error;
  if (error && typeof error.code === 'string') {
    const details = Array.isArray(error.issues) ? { issues: error.issues } : {};
    throw new CliError(error.code, String(error.message ?? error.code), details);
  }
  throw new CliError('daemon_unavailable', `The daemon answered HTTP ${reply.status}.`);
}

/** Runs a client call, turning an unreachable daemon into a `daemon_unavailable` `CliError`. */
export async function call(promise) {
  try {
    return expectOk(await promise);
  } catch (error) {
    if (error instanceof CliError) throw error;
    if (error instanceof DaemonUnavailableError) throw new CliError('daemon_unavailable', error.message);
    throw new CliError('daemon_unavailable', `The Timer daemon is unavailable: ${error.message}`);
  }
}

const fold = (text) => text.normalize('NFC').toLowerCase();

/**
 * The only entry whose name matches `name` ignoring case. No match is `not_found` with `missing`
 * as its message; several are `ambiguous`, listing the candidates.
 */
export function resolveName(entries, name, { noun, describe, missing = `No ${noun} named "${name}".` }) {
  const key = fold(name);
  const matches = entries.filter((entry) => fold(entry.name) === key);
  if (matches.length === 1) return matches[0];
  if (!matches.length) throw new CliError('not_found', missing);
  throw new CliError('ambiguous', `"${name}" matches ${matches.length} ${noun}s; use an id.`, { candidates: matches.map(describe) });
}

/**
 * The entry `ref` names: the one whose id is exactly `ref`, else the only one whose name matches
 * it ignoring case. No match is `not_found`; several are `ambiguous`, listing the candidates.
 */
export function resolveRef(entries, ref, { noun, describe }) {
  const exact = entries.find((entry) => entry.id === ref);
  if (exact) return exact;
  return resolveName(entries, ref, { noun, describe, missing: `No ${noun} with the id or name "${ref}".` });
}

/** Built-in preset names people use that are not a preset's id or name. */
const PRESET_ALIASES = { hiit: 'hiit-40-20' };

/**
 * The preset `ref` names among `presets`, for the CLI and the MCP server alike: an exact id, else a
 * unique name ignoring case (several are `ambiguous`), and only when neither matches an alias such
 * as `hiit`, so a saved preset named HIIT is not shadowed by the built-in one.
 */
export function findPreset(presets, ref) {
  try {
    return resolveRef(presets, ref, { noun: 'preset', describe: ({ id, name }) => ({ id, name }) });
  } catch (error) {
    const alias = Object.hasOwn(PRESET_ALIASES, fold(ref)) ? presets.find((preset) => preset.id === PRESET_ALIASES[fold(ref)]) : undefined;
    if (error.code === 'not_found' && alias) return alias;
    throw error;
  }
}

/** The timer `ref` names, as `{ id, name, status }`. */
export async function resolveTimer(client, ref) {
  const { structuredContent } = await call(client.timers());
  const timers = structuredContent.timers.map(({ definition, projection }) => ({ id: definition.id, name: definition.name, status: projection.status }));
  return resolveRef(timers, ref, { noun: 'timer', describe: (timer) => timer });
}

const pad = (value) => String(value).padStart(2, '0');

/** A local time: `HH:MM:SS` on the same day as `reference`, else `YYYY-MM-DD HH:MM:SS`. */
export function formatLocalTime(ms, reference) {
  const date = new Date(ms);
  const day = new Date(reference);
  const time = `${pad(date.getHours())}:${pad(date.getMinutes())}:${pad(date.getSeconds())}`;
  const sameDay = date.getFullYear() === day.getFullYear() && date.getMonth() === day.getMonth() && date.getDate() === day.getDate();
  return sameDay ? time : `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())} ${time}`;
}

/** When a running timer with an end will end, in epoch milliseconds, else null. */
export function endsAt({ timer, observedAt }) {
  const { status, remainingMs } = timer.projection;
  return status === 'running' && remainingMs !== null ? observedAt + remainingMs : null;
}
