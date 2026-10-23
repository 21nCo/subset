import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createFakeClock, createRecordingSink, pidAlive, readLock, socketRequest, startDaemon } from '../../src/daemon/index.mjs';

export const DAEMON_ENTRY = fileURLToPath(new URL('../../src/daemon/main.mjs', import.meta.url));

/** What `tempDataDir` waits for before removing each directory it made. */
const stopsBeforeRemoval = new Map();

/**
 * Has the removal of `dataDir`, made by `tempDataDir`, first wait for `stop`, which ends a process
 * that may still write there. `t.after` hooks run in the order they were added, so a hook a test
 * adds after `tempDataDir` would otherwise run once the directory is already being removed.
 */
export function stopBeforeRemoval(dataDir, stop) {
  stopsBeforeRemoval.get(dataDir)?.push(stop);
}

/**
 * A fresh data directory, removed after the test. Short, so the socket path fits every platform.
 * The processes registered with `stopBeforeRemoval` and a daemon process still holding its lock
 * are stopped first, so no test leaves one behind or has one write into the directory as it goes.
 */
export function tempDataDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'std-'));
  const dataDir = join(dir, 'data');
  const stops = [];
  stopsBeforeRemoval.set(dataDir, stops);
  t.after(async () => {
    stopsBeforeRemoval.delete(dataDir);
    await Promise.all(stops.map((stop) => stop()));
    const holder = readLock(join(dataDir, 'daemon.lock'));
    if (holder?.pid && holder.pid !== process.pid && pidAlive(holder.pid)) {
      let signalled = true;
      try {
        process.kill(holder.pid, 'SIGTERM');
      } catch {
        // A lock a test wrote naming a process this user cannot signal.
        signalled = false;
      }
      if (signalled) await eventually(() => !pidAlive(holder.pid), 10_000);
    }
    rmSync(dir, { recursive: true, force: true });
  });
  return dataDir;
}

/** An in-process daemon on a fake clock with a recording sink. */
export async function startTestDaemon(t, { dataDir = tempDataDir(t), clock = createFakeClock(), ...options } = {}) {
  const sink = options.sink ?? createRecordingSink();
  const logs = [];
  const daemon = await startDaemon({ dataDir, clock, sink, log: (message) => logs.push(message), ...options });
  t.after(() => daemon.shutdown());
  const call = (method, path, body) => socketRequest(daemon.paths.socket, method, path, body);
  return { daemon, clock, sink, logs, dataDir, call, op: (name, input) => call('POST', `/v1/ops/${name}`, input) };
}

/** A request with a raw body, for malformed input. */
export function rawRequest(socketPath, method, path, body) {
  return new Promise((resolve, reject) => {
    const outgoing = request({ socketPath, method, path, agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, headers: response.headers, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
    });
    outgoing.on('error', reject);
    outgoing.end(body);
  });
}

/**
 * Collects server-sent events from `/v1/events` in arrival order. The `subscriber` event that opens
 * each stream is kept apart, as `subscriberId`, so `events` holds what follows it.
 */
export function subscribe(socketPath) {
  const events = [];
  let subscriberId = null;
  let firstEvent = null;
  const waiters = [];
  let buffer = '';
  const check = () => {
    for (const waiter of waiters.slice()) {
      if (waiter.predicate(events)) {
        waiters.splice(waiters.indexOf(waiter), 1);
        waiter.resolve(events);
      }
    }
  };
  let outgoing;
  let ended = false;
  const connected = new Promise((resolve, reject) => {
    outgoing = request({ socketPath, method: 'GET', path: '/v1/events', agent: false }, (response) => {
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const block = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          const event = /^event: (.*)$/m.exec(block)?.[1];
          const data = /^data: (.*)$/m.exec(block)?.[1];
          firstEvent ??= event;
          if (event === 'subscriber') subscriberId = JSON.parse(data).subscriberId;
          else events.push({ event, data: JSON.parse(data) });
        }
        check();
      });
      response.on('close', () => {
        ended = true;
      });
      resolve(response);
    });
    outgoing.on('error', reject);
    outgoing.end();
  });
  return {
    events,
    connected,
    get ended() {
      return ended;
    },
    get subscriberId() {
      return subscriberId;
    },
    /** The name of the stream's first event. */
    get firstEvent() {
      return firstEvent;
    },
    waitFor(predicate, timeoutMs = 5_000) {
      if (predicate(events)) return Promise.resolve(events);
      return new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`Timed out waiting for events; got ${JSON.stringify(events.map((e) => e.event))}`)), timeoutMs);
        waiters.push({ predicate, resolve: (value) => { clearTimeout(timer); resolve(value); } });
      });
    },
    close: () => outgoing.destroy()
  };
}

/** Waits for a condition that depends on socket I/O. */
export function eventually(condition, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const check = () => {
      try {
        if (condition()) return resolve();
      } catch (error) {
        return reject(error);
      }
      if (Date.now() > deadline) return reject(new Error('Timed out waiting for a condition.'));
      setTimeout(check, 10);
    };
    check();
  });
}

/** Resolves what `promise` resolves, or rejects when it has not settled within `timeoutMs`; a test never waits unbounded. */
export function within(promise, timeoutMs = 5_000, what = 'the daemon to close') {
  let timer;
  const timeout = new Promise((resolve, reject) => {
    timer = setTimeout(() => reject(new Error(`Timed out waiting for ${what}.`)), timeoutMs);
  });
  return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
}

/** Kills `child` unless it has ended, and resolves once it has exited. */
export async function stopChild(child, exited) {
  if (child.exitCode === null && child.signalCode === null) child.kill('SIGKILL');
  await within(exited, 10_000, 'a test process to exit');
}

/** Runs `main.mjs daemon run` as a separate process, stopped before its data directory is removed. */
export function spawnDaemonProcess(dataDir) {
  const child = spawn(process.execPath, [DAEMON_ENTRY, 'daemon', 'run'], {
    env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  let stderr = '';
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => {
    stderr += chunk;
  });
  const exited = new Promise((resolve) => child.on('exit', (code) => resolve(code)));
  stopBeforeRemoval(dataDir, () => stopChild(child, exited));
  return { child, exited, stderr: () => stderr };
}
