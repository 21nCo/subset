import { spawn as nodeSpawn } from 'node:child_process';
import { closeSync, openSync, renameSync, statSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { holderAlive, readLock } from './lock.mjs';
import { daemonPaths, ensureDataDir, resolveDataDir } from './paths.mjs';

/** How long a client waits for a daemon it started to open its socket. */
export const START_TIMEOUT_MS = 3_000;
const POLL_MS = 50;
/** A daemon that exits without opening its socket is spawned again at most this often per start. */
const MAX_SPAWNS = 3;
const MAX_LOG_BYTES = 1024 * 1024;
/** Runs `daemon run` when no CLI path is given (SET-77 passes its own `cli.mjs`). */
export const DEFAULT_DAEMON_ENTRY = fileURLToPath(new URL('./main.mjs', import.meta.url));

export class DaemonUnavailableError extends Error {
  constructor(message, cause) {
    super(message, cause ? { cause } : undefined);
    this.name = 'DaemonUnavailableError';
    this.code = 'daemon_unavailable';
  }
}

/** A socket error that means no daemon is listening, so starting one may help. */
export function isNotListening(error) {
  return error?.code === 'ENOENT' || error?.code === 'ECONNREFUSED';
}

/** The reply of a daemon that is shutting down: it did not run the request, and a new daemon will. */
function isShuttingDown(reply) {
  return reply.status === 503 && reply.body?.error?.code === 'daemon_unavailable';
}

class ShuttingDownError extends Error {
  constructor() {
    super('The daemon is shutting down.');
    this.code = 'daemon_shutting_down';
  }
}

/**
 * One HTTP/1.1 request over the Unix socket. Resolves `{ status, body }` with the JSON body
 * parsed; rejects with the socket error (for example `ENOENT` or `ECONNREFUSED`).
 */
export function socketRequest(socketPath, method, path, body, { timeoutMs = 10_000 } = {}) {
  return new Promise((resolve, reject) => {
    const text = body === undefined ? undefined : JSON.stringify(body);
    const headers = text === undefined ? {} : { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) };
    const request = httpRequest({ socketPath, method, path, headers, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('error', reject);
      response.on('end', () => {
        const raw = Buffer.concat(chunks).toString('utf8');
        try {
          resolve({ status: response.statusCode, body: raw ? JSON.parse(raw) : null });
        } catch (error) {
          reject(new DaemonUnavailableError('The daemon sent a reply that is not JSON.', error));
        }
      });
    });
    request.setTimeout(timeoutMs, () => request.destroy(Object.assign(new Error('The daemon did not answer in time.'), { code: 'ETIMEDOUT' })));
    request.on('error', reject);
    request.end(text);
  });
}

/** Parses a server-sent event stream, calling `onEvent({ event, data })` with `data` parsed as JSON. */
function parseEvents(onEvent) {
  let buffer = '';
  return (chunk) => {
    buffer += chunk;
    let end;
    while ((end = buffer.indexOf('\n\n')) >= 0) {
      const block = buffer.slice(0, end);
      buffer = buffer.slice(end + 2);
      let event = 'message';
      const data = [];
      for (const line of block.split('\n')) {
        if (line.startsWith('event: ')) event = line.slice(7);
        else if (line.startsWith('data: ')) data.push(line.slice(6));
      }
      if (!data.length) continue;
      let parsed;
      try {
        parsed = JSON.parse(data.join('\n'));
      } catch {
        continue;
      }
      onEvent({ event, data: parsed });
    }
  };
}

function checked(reply) {
  if (reply && typeof reply.status === 'number' && isShuttingDown(reply)) throw new ShuttingDownError();
  return reply;
}

function unavailable(error) {
  if (error instanceof DaemonUnavailableError) return error;
  return new DaemonUnavailableError(`The Timer daemon is unavailable: ${error.message}`, error);
}

/** Resolves once the stream ends, closes or fails. */
function streamDone(response) {
  return new Promise((settle) => {
    for (const name of ['end', 'close', 'error']) response.on(name, settle);
  });
}

/** Opens `/v1/events`, resolving `{ close, done }` once the daemon accepts the stream. */
function openEventStream(socketPath, onEvent) {
  return new Promise((resolve, reject) => {
    const outgoing = httpRequest({ socketPath, method: 'GET', path: '/v1/events', agent: false }, (response) => {
      if (response.statusCode !== 200) {
        response.resume();
        reject(response.statusCode === 503 ? new ShuttingDownError() : new DaemonUnavailableError(`The daemon refused the event stream (HTTP ${response.statusCode}).`));
        return;
      }
      response.setEncoding('utf8');
      const done = streamDone(response);
      response.on('data', parseEvents(onEvent));
      resolve({ close: () => outgoing.destroy(), done });
    });
    outgoing.on('error', reject);
    outgoing.end();
  });
}

/** Opens the daemon log for a spawned daemon's output, keeping one previous log of up to 1 MiB. */
function openDaemonLog(logPath) {
  try {
    if (statSync(logPath).size > MAX_LOG_BYTES) renameSync(logPath, `${logPath}.1`);
  } catch (error) {
    if (error.code !== 'ENOENT') throw error;
  }
  return openSync(logPath, 'a', 0o600);
}

/**
 * A client of the per-user daemon. Each call connects to `daemon.sock`; when the socket is missing
 * or refuses, the client spawns `node <cliPath> daemon run` detached and unreferenced, waits up to
 * `START_TIMEOUT_MS` for the socket, and otherwise rejects with `DaemonUnavailableError`
 * (`code: 'daemon_unavailable'`).
 */
export function createClient({
  dataDir = resolveDataDir(),
  cliPath = DEFAULT_DAEMON_ENTRY,
  execPath = process.execPath,
  env = process.env,
  spawn = nodeSpawn,
  startTimeoutMs = START_TIMEOUT_MS
} = {}) {
  const paths = daemonPaths(dataDir);
  let starting = null;

  /** Spawns `daemon run`. Resolves the child's state: `exited` turns true when it ends. */
  function spawnDaemon() {
    ensureDataDir(dataDir);
    const logFd = openDaemonLog(paths.log);
    const state = { exited: false };
    try {
      const child = spawn(execPath, [cliPath, 'daemon', 'run'], {
        detached: true,
        stdio: ['ignore', logFd, logFd],
        env: { ...env, SUBSET_TIMER_DATA_DIR: dataDir }
      });
      // A failed spawn surfaces as the socket never appearing.
      child.on('error', () => {
        state.exited = true;
      });
      child.on('exit', () => {
        state.exited = true;
      });
      child.unref();
    } finally {
      closeSync(logFd);
    }
    return state;
  }

  /**
   * True while a live process holds `daemon.lock`, such as a daemon that is still shutting down. A
   * lock is never seen before its pid is in it, so one without a valid pid is stale, as is one whose
   * pid now belongs to a process born otherwise.
   */
  function lockHeld() {
    try {
      return holderAlive(readLock(paths.lock));
    } catch {
      return false;
    }
  }

  /**
   * Spawns a daemon and waits for its socket. A daemon that was shutting down when this began makes
   * the new one exit with "already running"; once the old one has released the lock, it spawns again.
   */
  async function startDaemon() {
    const spawnOrFail = () => {
      try {
        return spawnDaemon();
      } catch (error) {
        throw new DaemonUnavailableError(`Could not start the Timer daemon: ${error.message}`, error);
      }
    };
    let child = spawnOrFail();
    let spawns = 1;
    const deadline = Date.now() + startTimeoutMs;
    let lastError;
    while (Date.now() < deadline) {
      await sleep(POLL_MS);
      try {
        const reply = await socketRequest(paths.socket, 'GET', '/v1/daemon', undefined, { timeoutMs: Math.max(1, deadline - Date.now()) });
        if (!isShuttingDown(reply)) return;
        lastError = new ShuttingDownError();
      } catch (error) {
        lastError = error;
        if (!isNotListening(error)) break;
      }
      if (child.exited && spawns < MAX_SPAWNS && !lockHeld()) {
        child = spawnOrFail();
        spawns++;
      }
    }
    throw new DaemonUnavailableError(`The Timer daemon did not start within ${startTimeoutMs / 1000} s.`, lastError);
  }

  /** Makes sure a daemon is listening, starting one at most once for concurrent calls. */
  async function ensureDaemon() {
    starting ??= startDaemon().finally(() => {
      starting = null;
    });
    return starting;
  }

  /** Runs `attempt`, starting a daemon first when none is listening or the one there is shutting down. */
  async function withDaemon(attempt) {
    try {
      return checked(await attempt());
    } catch (error) {
      if (!isNotListening(error) && !(error instanceof ShuttingDownError)) throw unavailable(error);
    }
    await ensureDaemon();
    try {
      return checked(await attempt());
    } catch (error) {
      throw unavailable(error);
    }
  }

  /** `{ status, body }` for one request, starting the daemon if needed. */
  const request = (method, path, body) => withDaemon(() => socketRequest(paths.socket, method, path, body));

  /**
   * Subscribes to `/v1/events`. Resolves once connected with `{ close, done }`; `done` settles
   * when the stream ends.
   */
  function events(onEvent) {
    return withDaemon(() => openEventStream(paths.socket, onEvent));
  }

  return {
    paths,
    request,
    events,
    ensureDaemon: () => withDaemon(() => socketRequest(paths.socket, 'GET', '/v1/daemon')),
    timers: () => request('GET', '/v1/timers'),
    presets: () => request('GET', '/v1/presets'),
    op: (name, input) => request('POST', `/v1/ops/${encodeURIComponent(name)}`, input ?? {}),
    status: () => socketRequest(paths.socket, 'GET', '/v1/daemon'),
    shutdown: () => socketRequest(paths.socket, 'POST', '/v1/shutdown')
  };
}
