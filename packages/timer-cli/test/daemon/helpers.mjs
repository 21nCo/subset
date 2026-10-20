import { spawn } from 'node:child_process';
import { mkdtempSync, rmSync } from 'node:fs';
import { request } from 'node:http';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createFakeClock, createRecordingSink, socketRequest, startDaemon } from '../../src/daemon/index.mjs';

export const DAEMON_ENTRY = fileURLToPath(new URL('../../src/daemon/main.mjs', import.meta.url));

/** A fresh data directory, removed after the test. Short, so the socket path fits every platform. */
export function tempDataDir(t) {
  const dir = mkdtempSync(join(tmpdir(), 'std-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return join(dir, 'data');
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

/** Collects server-sent events from `/v1/events` in arrival order. */
export function subscribe(socketPath) {
  const events = [];
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
          events.push({ event, data: JSON.parse(data) });
        }
        check();
      });
      resolve(response);
    });
    outgoing.on('error', reject);
    outgoing.end();
  });
  return {
    events,
    connected,
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
export async function eventually(condition, timeoutMs = 5_000) {
  const deadline = Date.now() + timeoutMs;
  while (!condition()) {
    if (Date.now() > deadline) throw new Error('Timed out waiting for a condition.');
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
}

/** Runs `main.mjs daemon run` as a separate process. */
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
  return { child, exited, stderr: () => stderr };
}
