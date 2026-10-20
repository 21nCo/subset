import { spawn as nodeSpawn } from 'node:child_process';
import { closeSync, openSync, renameSync, statSync } from 'node:fs';
import { request as httpRequest } from 'node:http';
import { fileURLToPath } from 'node:url';
import { setTimeout as sleep } from 'node:timers/promises';
import { daemonPaths, ensureDataDir, resolveDataDir } from './paths.mjs';

/** How long a client waits for a daemon it started to open its socket. */
export const START_TIMEOUT_MS = 3_000;
const POLL_MS = 50;
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

  function spawnDaemon() {
    ensureDataDir(dataDir);
    const logFd = openDaemonLog(paths.log);
    try {
      const child = spawn(execPath, [cliPath, 'daemon', 'run'], {
        detached: true,
        stdio: ['ignore', logFd, logFd],
        env: { ...env, SUBSET_TIMER_DATA_DIR: dataDir }
      });
      // A failed spawn surfaces as the socket never appearing.
      child.on('error', () => {});
      child.unref();
    } finally {
      closeSync(logFd);
    }
  }

  async function startDaemon() {
    try {
      spawnDaemon();
    } catch (error) {
      throw new DaemonUnavailableError(`Could not start the Timer daemon: ${error.message}`, error);
    }
    const deadline = Date.now() + startTimeoutMs;
    let lastError;
    while (Date.now() < deadline) {
      await sleep(POLL_MS);
      try {
        await socketRequest(paths.socket, 'GET', '/v1/daemon', undefined, { timeoutMs: Math.max(1, deadline - Date.now()) });
        return;
      } catch (error) {
        lastError = error;
        if (!isNotListening(error)) break;
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

  async function withDaemon(attempt) {
    try {
      return await attempt();
    } catch (error) {
      if (!isNotListening(error)) throw unavailable(error);
    }
    await ensureDaemon();
    try {
      return await attempt();
    } catch (error) {
      throw unavailable(error);
    }
  }

  function unavailable(error) {
    if (error instanceof DaemonUnavailableError) return error;
    return new DaemonUnavailableError(`The Timer daemon is unavailable: ${error.message}`, error);
  }

  /** `{ status, body }` for one request, starting the daemon if needed. */
  const request = (method, path, body) => withDaemon(() => socketRequest(paths.socket, method, path, body));

  /**
   * Subscribes to `/v1/events`. Resolves once connected with `{ close, done }`; `done` settles
   * when the stream ends.
   */
  function events(onEvent) {
    return withDaemon(() => new Promise((resolve, reject) => {
      const outgoing = httpRequest({ socketPath: paths.socket, method: 'GET', path: '/v1/events', agent: false }, (response) => {
        if (response.statusCode !== 200) {
          response.resume();
          reject(new DaemonUnavailableError(`The daemon refused the event stream (HTTP ${response.statusCode}).`));
          return;
        }
        response.setEncoding('utf8');
        const done = new Promise((settle) => {
          response.on('end', settle);
          response.on('close', settle);
          response.on('error', settle);
        });
        response.on('data', parseEvents(onEvent));
        resolve({ close: () => outgoing.destroy(), done });
      });
      outgoing.on('error', reject);
      outgoing.end();
    }));
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
