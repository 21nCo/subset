// The subset-minutes command. `cli.mjs` calls `main` with the real process; tests pass a fake driver.
import { spawn } from 'node:child_process';
import { lstatSync, realpathSync } from 'node:fs';
import { mkdir } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { parseArgs } from 'node:util';
import {
  DEFAULT_DISPLAY_NAME,
  MINUTES_CONTRACT_VERSION,
  createEvent,
  defaultOutputDirectory,
  defaultProfileDirectory,
  defaultStateDirectory,
  findChrome,
  parseMeetingLink,
  readStatus,
  redactUrlsInText,
  runDoctor,
  runMeetingSession,
  writeSessionRecord,
} from '@subset/minutes';
import manifest from '../package.json' with { type: 'json' };

export const usage = `Usage: subset-minutes <command> [options]

Sends a visible notetaker bot to a Google Meet or Zoom (web client) meeting in the
system Google Chrome and records the other participants' audio to a WebM file.
Tell participants you are recording, and follow the recording rules that apply to you.

Commands
  join <link>           Join and record until the meeting ends or Ctrl-C
    --link-from-stdin   Read the link from the first line of stdin instead (keeps a Zoom
                        passcode out of the process list)
    --out <dir>         Folder for the recording (default ~/Documents/Minutes Recordings)
    --name <name>       Name shown in the meeting (default "${DEFAULT_DISPLAY_NAME}")
    --max-minutes <n>   Leave after n minutes in the meeting (default 240)
    --json              Print one JSON event per line (contract v${MINUTES_CONTRACT_VERSION})
    --stop-on-stdin-close
                        Stop and finalize when stdin closes (for a parent app)
  status                Show current and recent sessions; reads only (add --json)
  doctor                Check Node.js, Chrome, the bot profile, and the output folder (add --json)
  sign-in               Open Chrome with the bot profile to sign in to Google once
  --help, --version

Shared options
  --profile <dir>       Bot Chrome profile (default from SUBSET_MINUTES_PROFILE_DIR or the data folder)

Exit status: 0 success, 1 the session or a check failed, 2 invalid command or meeting link.
`;

const commandOptions = {
  join: { out: { type: 'string' }, name: { type: 'string' }, 'max-minutes': { type: 'string' }, json: { type: 'boolean' }, profile: { type: 'string' }, 'stop-on-stdin-close': { type: 'boolean' }, 'link-from-stdin': { type: 'boolean' } },
  status: { json: { type: 'boolean' } },
  doctor: { json: { type: 'boolean' }, out: { type: 'string' }, profile: { type: 'string' } },
  'sign-in': { profile: { type: 'string' } },
};

const expandHome = (value, home) => (value === '~' ? home : value.startsWith('~/') ? path.join(home, value.slice(2)) : value);

/**
 * The absolute path with symlinks resolved in its longest existing prefix (the rest may not exist yet), or
 * null when an entry on the way exists but cannot be resolved (a dangling symlink could lead anywhere).
 */
function canonical(value) {
  const absolute = path.resolve(value);
  let existing = absolute;
  for (;;) {
    try {
      return path.join(realpathSync(existing), path.relative(existing, absolute));
    } catch {
      if (!isMissing(existing)) return null;
      const parent = path.dirname(existing);
      if (parent === existing) return absolute;
      existing = parent;
    }
  }
}

/** Whether nothing exists at `value` (not even a dangling symlink). Any other lstat error counts as present. */
function isMissing(value) {
  try {
    return lstatSync(value, { throwIfNoEntry: false }) === undefined;
  } catch {
    return false;
  }
}

/**
 * The `--profile` folder, or null when it is outside the home folder. Chrome runs with this profile and
 * `sign-in` creates it, so a caller (possibly an agent) cannot point either at an arbitrary folder.
 */
function profileInsideHome(value, home) {
  const resolved = canonical(path.resolve(expandHome(value, home)));
  const base = canonical(home);
  if (!resolved || !base || !resolved.startsWith(base + path.sep)) return null;
  // No control characters: the path becomes part of a Chrome argument.
  return /^[^\0-\x1f\x7f]+$/.test(resolved) ? resolved : null;
}

/**
 * @param {object} io
 * @param {string[]} io.argv  Arguments after the executable and script.
 * @param {Record<string, string | undefined>} io.env
 * @param {string} io.home
 * @param {(text: string) => void} io.stdout
 * @param {(text: string) => void} io.stderr
 * @param {AbortSignal} [io.signal]  Aborts a running join (SIGINT/SIGTERM in the real CLI).
 * @param {NodeJS.ReadableStream} [io.stdin]
 * @param {() => Promise<object>} [io.createDriver]  Returns a MeetingDriver (tests pass a fake).
 * @returns {Promise<number>} exit status
 */
export async function main(io) {
  const { argv, stdout, stderr } = io;
  if (argv.length === 0 || argv.includes('--help') || argv.includes('-h')) {
    (argv.length === 0 ? stderr : stdout)(usage);
    return argv.length === 0 ? 2 : 0;
  }
  if (argv[0] === '--version' || argv[0] === '-v') {
    stdout(`${manifest.version}\n`);
    return 0;
  }

  const [command, ...rest] = argv;
  const json = rest.includes('--json');
  // Own properties only, so names such as "constructor" are unknown commands.
  const options = Object.hasOwn(commandOptions, command) ? commandOptions[command] : undefined;
  if (!options) return usageError(io, json, `Unknown command "${command}". Run subset-minutes --help.`);

  let parsed;
  try {
    parsed = parseArgs({ args: rest, options, allowPositionals: command === 'join', strict: true });
  } catch (error) {
    return usageError(io, json, error.message);
  }
  const values = parsed.values;
  const environment = { platform: process.platform, home: io.home, env: io.env };
  let profileDirectory = defaultProfileDirectory(environment);
  if (values.profile) {
    profileDirectory = profileInsideHome(values.profile, io.home);
    if (!profileDirectory) return usageError(io, json, '--profile must be a folder inside your home folder.');
  }
  const outputDirectory = values.out ? path.resolve(expandHome(values.out, io.home)) : defaultOutputDirectory(environment);

  switch (command) {
    case 'status': return status(io, environment, values.json);
    case 'doctor': return doctor(io, { profileDirectory, outputDirectory }, values.json);
    case 'sign-in': return signIn(io, profileDirectory);
    case 'join': return join(io, parsed.positionals, values, { environment, profileDirectory, outputDirectory });
  }
  return 2;
}

function usageError(io, json, message) {
  if (json) {
    io.stdout(`${JSON.stringify(createEvent(null, { type: 'error', code: 'usage', message }))}\n`);
    io.stdout(`${JSON.stringify(createEvent(null, { type: 'ended', reason: 'failed', path: null, bytes: null }))}\n`);
  } else {
    io.stderr(`${message}\n`);
  }
  return 2;
}

async function status(io, environment, json) {
  const result = await readStatus(defaultStateDirectory(environment));
  if (json) {
    io.stdout(`${JSON.stringify(result)}\n`);
    return 0;
  }
  if (!result.sessions.length) {
    io.stdout(`No Minutes sessions recorded in ${result.stateDirectory}.\n`);
    return 0;
  }
  for (const session of result.sessions) {
    const label = session.stale ? `${session.state} (process gone)` : session.alive ? `${session.state} (running, pid ${session.pid})` : session.state;
    io.stdout(`${session.startedAt}  ${session.platform.padEnd(11)}  ${label}\n`);
    io.stdout(`  ${session.meeting}\n`);
    if (session.outputPath) io.stdout(`  ${session.outputPath}\n`);
    if (session.error) io.stdout(`  error: ${session.error.message}\n`);
  }
  if (result.unreadable) io.stdout(`${result.unreadable} session record(s) could not be read.\n`);
  return 0;
}

async function doctor(io, directories, json) {
  const result = await runDoctor(directories);
  if (json) {
    io.stdout(`${JSON.stringify(result)}\n`);
  } else {
    for (const check of result.checks) {
      const mark = check.ok ? 'ok  ' : check.required ? 'FAIL' : 'warn';
      io.stdout(`${mark}  ${check.id.padEnd(16)} ${check.detail}\n`);
      if (check.fix) io.stdout(`      ${''.padEnd(16)} ${check.fix}\n`);
    }
    io.stdout(result.ok ? 'Ready to join.\n' : 'Fix the failed checks before joining.\n');
  }
  return result.ok ? 0 : 1;
}

async function signIn(io, profileDirectory) {
  const chrome = await findChrome();
  if (!chrome) {
    io.stderr('Google Chrome was not found. Install Chrome or set SUBSET_MINUTES_CHROME_PATH.\n');
    return 1;
  }
  await mkdir(profileDirectory, { recursive: true, mode: 0o700 });
  const child = spawn(chrome, [`--user-data-dir=${profileDirectory}`, '--no-first-run', '--no-default-browser-check', '--new-window', 'https://accounts.google.com'], { detached: true, stdio: 'ignore' });
  await new Promise((resolve, reject) => { child.once('spawn', resolve); child.once('error', reject); });
  child.unref();
  io.stdout(`Opened Chrome with the bot profile (${profileDirectory}).\nSign in with the bot's Google account, then quit that Chrome window before running join.\n`);
  return 0;
}

/**
 * Reads one line from `stream` (without its newline). Resolves null if the stream ends first with nothing,
 * or when `signal` aborts (a Stop while waiting for the link).
 */
function readFirstLine(stream, signal) {
  return new Promise((resolve) => {
    if (signal?.aborted) {
      resolve(null);
      return;
    }
    let text = '';
    const finish = (value) => {
      stream.off('data', onData);
      stream.off('end', onEnd);
      stream.off('close', onEnd);
      signal?.removeEventListener('abort', onAbort);
      stream.pause();
      resolve(value);
    };
    const onAbort = () => finish(null);
    const onData = (chunk) => {
      text += chunk;
      const newline = text.indexOf('\n');
      if (newline >= 0) finish(text.slice(0, newline));
      else if (text.length > 4_096) finish(text);
    };
    const onEnd = () => finish(text.length ? text : null);
    stream.setEncoding('utf8');
    stream.on('data', onData);
    stream.once('end', onEnd);
    stream.once('close', onEnd);
    signal?.addEventListener('abort', onAbort, { once: true });
    stream.resume();
  });
}

async function join(io, positionals, values, { environment, profileDirectory, outputDirectory }) {
  const json = Boolean(values.json);
  const fromStdin = Boolean(values['link-from-stdin']);
  if (fromStdin ? positionals.length !== 0 : positionals.length !== 1) {
    return usageError(io, json, fromStdin ? 'join --link-from-stdin takes no link argument.' : 'join needs exactly one meeting link.');
  }
  if (fromStdin && !io.stdin) return usageError(io, json, 'join --link-from-stdin needs stdin.');
  let maxDurationMs;
  if (values['max-minutes'] !== undefined) {
    const minutes = Number(values['max-minutes']);
    if (!Number.isFinite(minutes) || minutes < 1 || minutes > 24 * 60) return usageError(io, json, '--max-minutes must be between 1 and 1440.');
    maxDurationMs = minutes * 60_000;
  }
  const name = values.name ?? DEFAULT_DISPLAY_NAME;
  if (name.length > 100) return usageError(io, json, '--name must be 100 characters or fewer.');

  // Track stdin closing from the start: with --link-from-stdin the parent may write the link and close.
  let stdinClosed = false;
  if (io.stdin && (fromStdin || values['stop-on-stdin-close'])) {
    io.stdin.once('end', () => { stdinClosed = true; });
    io.stdin.once('close', () => { stdinClosed = true; });
  }
  const rawLink = fromStdin ? ((await readFirstLine(io.stdin, io.signal)) ?? '') : positionals[0];
  // A Stop that arrived before the session (for example while waiting for the stdin link) ends the command
  // without launching Chrome.
  if (io.signal?.aborted) {
    if (json) io.stdout(`${JSON.stringify(createEvent(null, { type: 'ended', reason: 'stopped', path: null, bytes: null }))}\n`);
    else io.stdout('Stopped before joining. No recording was written.\n');
    return 0;
  }
  const parsed = parseMeetingLink(rawLink);
  if (!parsed.ok) {
    if (json) {
      io.stdout(`${JSON.stringify(createEvent(null, { type: 'error', code: 'invalid_link', message: parsed.message }))}\n`);
      io.stdout(`${JSON.stringify(createEvent(null, { type: 'ended', reason: 'failed', path: null, bytes: null }))}\n`);
    } else {
      io.stderr(`${parsed.message}\n`);
    }
    return 2;
  }

  // Stop requests: the caller's signal (SIGINT/SIGTERM) and, when asked, stdin closing.
  const stop = new AbortController();
  io.signal?.addEventListener('abort', () => stop.abort(), { once: true });
  if (values['stop-on-stdin-close'] && io.stdin) {
    if (stdinClosed) stop.abort();
    io.stdin.on('end', () => stop.abort());
    io.stdin.on('close', () => stop.abort());
    io.stdin.resume();
  }

  const stateDirectory = defaultStateDirectory(environment);
  const driver = await (io.createDriver ?? defaultDriver)();
  const print = json ? (event) => io.stdout(`${JSON.stringify(event)}\n`) : humanPrinter(io);
  const result = await runMeetingSession({
    link: parsed.link,
    displayName: name,
    outputDirectory,
    profileDirectory,
    driver,
    emit: print,
    persist: (record) => writeSessionRecord(stateDirectory, record),
    signal: stop.signal,
    maxDurationMs,
  });
  if (values['stop-on-stdin-close']) io.stdin?.pause();
  return result.state === 'failed' ? 1 : 0;
}

async function defaultDriver() {
  // Loaded only for join, so status and doctor work without starting Playwright.
  const { createChromeDriver } = await import('@subset/minutes/chrome');
  return createChromeDriver();
}

function humanPrinter(io) {
  const labels = { launching: 'Starting Chrome…', joining: 'Joining…', in_meeting: 'In the meeting. Recording. Press Ctrl-C to leave.', stopping: 'Leaving and finishing the recording…' };
  return (event) => {
    switch (event.type) {
      case 'started': io.stdout(`Sending "${event.displayName}" to ${event.meeting}\n`); break;
      case 'state': if (labels[event.state]) io.stdout(`${labels[event.state]}\n`); break;
      case 'status': io.stdout(`  ${event.message}\n`); break;
      case 'recording': io.stdout(`Recording to ${event.path}\n`); break;
      case 'error': io.stderr(`Error (${event.code}): ${event.message}\n`); break;
      case 'ended': io.stdout(event.path ? `Done (${event.reason}). ${event.bytes} bytes in ${event.path}\n` : `Done (${event.reason}). No recording was written.\n`); break;
    }
  };
}

/**
 * Runs the command against the real process: wires SIGINT/SIGTERM to a clean stop and exits when done.
 * The first SIGINT or SIGTERM asks a running join to leave and finalize the recording; a second one
 * exits immediately (the recording may then be cut short). Tests pass a fake `createDriver`.
 */
export async function runCli({ createDriver } = {}) {
  const stop = new AbortController();
  let signals = 0;
  // SIGHUP (the terminal closed) too: Playwright's handlers are off, so without it Chrome is left running
  // and the recording is not finalized.
  for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
    process.on(name, () => {
      signals += 1;
      if (signals > 1) process.exit(130);
      stop.abort();
    });
  }
  // A closed stdout (for example `| head`) must not crash a running session.
  process.stdout.on('error', () => {});

  const argv = process.argv.slice(2);
  const stdout = (text) => process.stdout.write(text);
  const stderr = (text) => process.stderr.write(text);
  let code;
  try {
    code = await main({ argv, env: process.env, home: os.homedir(), stdout, stderr, stdin: process.stdin, signal: stop.signal, createDriver });
  } catch (error) {
    // Keep the documented output even for an unexpected failure (a broken install, an unreadable folder).
    const message = redactUrlsInText(error instanceof Error ? error.message : String(error)).slice(0, 2_000);
    if (argv[0] === 'join' && argv.includes('--json')) {
      stdout(`${JSON.stringify(createEvent(null, { type: 'error', code: 'internal', message }))}\n`);
      stdout(`${JSON.stringify(createEvent(null, { type: 'ended', reason: 'failed', path: null, bytes: null }))}\n`);
    } else {
      stderr(`subset-minutes: ${message}\n`);
    }
    code = 1;
  }
  // Playwright can leave handles open after the browser closes, so exit explicitly once
  // buffered output is flushed (pipe writes are asynchronous on macOS).
  process.exitCode = code;
  process.stdout.write('', () => process.stderr.write('', () => process.exit(code)));
}
