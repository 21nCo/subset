import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import test from 'node:test';
import { createClient, pidAlive } from '../../src/daemon/index.mjs';
import { eventually, tempDataDir } from './helpers.mjs';

/** Counts the daemons a client starts, using the real spawn. */
function countingSpawn() {
  const children = [];
  const wrapped = (...args) => {
    const child = spawn(...args);
    children.push({ child, args });
    return child;
  };
  return { spawn: wrapped, children };
}

async function stopDaemon(client) {
  try {
    const { body } = await client.status();
    await client.shutdown();
    await eventually(() => !pidAlive(body.pid));
  } catch {
    // Already gone.
  }
}

test('a client starts a detached daemon on first use and later clients reuse it', async (t) => {
  const dataDir = tempDataDir(t);
  const spawner = countingSpawn();
  const client = createClient({ dataDir, spawn: spawner.spawn });
  t.after(() => stopDaemon(client));

  const created = await client.op('start', { timer: { kind: 'stopwatch', name: 'Run' } });
  assert.equal(created.status, 200);
  assert.equal(spawner.children.length, 1);
  const [{ child, args }] = spawner.children;
  assert.deepEqual(args[1].slice(1), ['daemon', 'run']);
  assert.equal(args[2].detached, true);
  assert.equal(args[2].env.SUBSET_TIMER_DATA_DIR, dataDir);
  const { body: status } = await client.status();
  assert.equal(status.pid, child.pid);
  assert.notEqual(status.pid, process.pid);

  const second = createClient({ dataDir, spawn: spawner.spawn });
  const listed = await second.timers();
  assert.deepEqual(listed.body.structuredContent.timers.map((timer) => timer.definition.name), ['Run']);
  assert.equal(spawner.children.length, 1);
  assert.equal((await second.status()).body.pid, child.pid);
  assert.match(readFileSync(join(dataDir, 'daemon.log'), 'utf8'), new RegExp(`listening on .* \\(pid ${child.pid}\\)`));
});

test('clients starting at once end up on one daemon', async (t) => {
  const dataDir = tempDataDir(t);
  const clients = Array.from({ length: 3 }, () => createClient({ dataDir }));
  t.after(() => stopDaemon(clients[0]));
  const replies = await Promise.all(clients.map((client) => client.op('create', { timer: { kind: 'stopwatch' } })));
  assert.deepEqual(replies.map((reply) => reply.status), [200, 200, 200]);
  const pids = await Promise.all(clients.map(async (client) => (await client.status()).body.pid));
  assert.equal(new Set(pids).size, 1);
  assert.equal((await clients[0].timers()).body.structuredContent.timers.length, 3);
});

test('a daemon that never comes up is reported as daemon_unavailable', async (t) => {
  const dataDir = tempDataDir(t);
  const failing = join(dataDir, '..', 'fails.mjs');
  writeFileSync(failing, 'process.exit(1);\n');
  const client = createClient({ dataDir, cliPath: failing, startTimeoutMs: 300 });
  const startedAt = Date.now();
  await assert.rejects(client.timers(), (error) => error.code === 'daemon_unavailable' && /did not start within 0\.3 s/.test(error.message));
  assert.ok(Date.now() - startedAt >= 300);
  assert.equal(existsSync(join(dataDir, 'daemon.sock')), false);
});

test('the event stream delivers state from a started daemon', async (t) => {
  const dataDir = tempDataDir(t);
  const client = createClient({ dataDir });
  t.after(() => stopDaemon(client));
  const received = [];
  const stream = await client.events((event) => received.push(event));
  await eventually(() => received.length === 1);
  assert.equal(received[0].event, 'state');
  await client.op('create', { timer: { kind: 'stopwatch', name: 'Watched' } });
  await eventually(() => received.length === 2);
  assert.equal(received[1].data.structuredContent.timers[0].definition.name, 'Watched');
  stream.close();
  await stream.done;
});

test('a request that meets a daemon shutting down is run by the daemon started after it', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const socket = join(dataDir, 'daemon.sock');
  const lock = join(dataDir, 'daemon.lock');
  // A daemon in its shutdown window: it still holds the lock and answers 503 daemon_unavailable.
  writeFileSync(lock, `${process.pid}\n`);
  const closing = createServer((request, response) => {
    response.writeHead(503, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ error: { code: 'daemon_unavailable', message: 'The daemon is shutting down.' } }));
  });
  await new Promise((resolve) => closing.listen(socket, resolve));
  const spawner = countingSpawn();
  const client = createClient({ dataDir, spawn: spawner.spawn });
  t.after(() => stopDaemon(client));

  const pending = client.op('create', { timer: { kind: 'stopwatch', name: 'After' } });
  // The daemon spawned meanwhile finds the lock held and exits; the old one then finishes closing.
  await eventually(() => spawner.children.length === 1 && spawner.children[0].child.exitCode !== null);
  assert.equal(spawner.children[0].child.exitCode, 3);
  await new Promise((resolve) => closing.close(resolve));
  rmSync(socket, { force: true });
  rmSync(lock);

  const reply = await pending;
  assert.equal(reply.status, 200);
  assert.equal(spawner.children.length, 2);
  assert.equal((await client.status()).body.pid, spawner.children[1].child.pid);
  assert.deepEqual((await client.timers()).body.structuredContent.timers.map((timer) => timer.definition.name), ['After']);
});
