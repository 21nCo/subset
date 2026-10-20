import assert from 'node:assert/strict';
import { chmodSync, existsSync, mkdirSync, readFileSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { connect } from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { TIMER_LIMITS, TIMER_VIEW_ID, emptyStore, parseStore, runOperation, transitionsBetween } from '@subset/timer';
import { DaemonRunningError, IDLE_EXIT_MS, REARM_MS, createFakeClock, socketRequest, startDaemon } from '../../src/daemon/index.mjs';
import { eventually, rawRequest, spawnDaemonProcess, startTestDaemon, subscribe, tempDataDir } from './helpers.mjs';

test('the data directory is 0700, the socket 0600, and there is no TCP listener', async (t) => {
  const { daemon } = await startTestDaemon(t);
  assert.equal(statSync(daemon.paths.dataDir).mode & 0o777, 0o700);
  const socket = statSync(daemon.paths.socket);
  assert.equal(socket.isSocket(), true);
  assert.equal(socket.mode & 0o777, 0o600);
  // A Unix socket's address is its path; a TCP listener's would be an object.
  assert.equal(typeof daemon.server.address(), 'string');
});

test('a second daemon on the same directory is refused while the first runs', async (t) => {
  const { dataDir } = await startTestDaemon(t);
  await assert.rejects(startDaemon({ dataDir, log: () => {} }), (error) => error instanceof DaemonRunningError && error.message === `already running (pid ${process.pid})`);
});

test('read routes return the agent result, presets and daemon status', async (t) => {
  const { call, daemon } = await startTestDaemon(t);
  const timers = await call('GET', '/v1/timers');
  assert.equal(timers.status, 200);
  assert.equal(timers.body.viewId, TIMER_VIEW_ID);
  assert.equal(timers.body.text, 'No timers.');
  assert.deepEqual(timers.body.structuredContent.timers, []);
  const presets = await call('GET', '/v1/presets');
  assert.equal(presets.status, 200);
  assert.deepEqual(presets.body.presets.map((preset) => preset.id), ['tabata', 'emom', 'hiit-40-20', 'pomodoro', 'amrap']);
  const status = await call('GET', '/v1/daemon');
  assert.deepEqual({ pid: status.body.pid, alerts: status.body.alerts, socket: status.body.socket }, { pid: process.pid, alerts: 'recording', socket: daemon.paths.socket });
});

test('operations persist before they answer and map typed errors to 400, 404 and 409', async (t) => {
  const { call, op, daemon, clock } = await startTestDaemon(t);
  const created = await op('create', { timer: { kind: 'countdown', durationMs: 60_000, name: 'Tea' } });
  assert.equal(created.status, 200);
  assert.equal(created.body.observedAt, clock.now());
  const id = created.body.timer.definition.id;
  const saved = parseStore(JSON.parse(readFileSync(daemon.paths.state, 'utf8')));
  assert.equal(saved.ok, true);
  assert.deepEqual(saved.store.timers.map((timer) => timer.definition.name), ['Tea']);
  assert.equal(statSync(daemon.paths.state).mode & 0o777, 0o600);

  const cases = [
    ['POST', '/v1/ops/start', { id }, 200, null],
    ['POST', '/v1/ops/get', { id }, 200, null],
    ['POST', '/v1/ops/list', undefined, 200, null],
    ['POST', '/v1/ops/create', {}, 400, 'invalid_input'],
    ['POST', '/v1/ops/start', { id: 'nope' }, 400, 'invalid_input'],
    ['POST', '/v1/ops/pause', { id: 't_00000000' }, 404, 'not_found'],
    ['POST', '/v1/ops/resume', { id }, 409, 'invalid_state'],
    ['POST', '/v1/ops/presets.remove', { id: 'tabata' }, 409, 'invalid_state'],
    ['POST', '/v1/ops/presets.remove', { id: 'p_00000000' }, 404, 'not_found'],
    ['POST', '/v1/ops/explode', {}, 404, 'not_found'],
    ['POST', '/v1/ops/%E0%A4%A', {}, 404, 'not_found'],
    ['GET', '/v1/ops/list', undefined, 405, 'method_not_allowed'],
    ['POST', '/v1/timers', {}, 405, 'method_not_allowed'],
    ['GET', '/v1/shutdown', undefined, 405, 'method_not_allowed'],
    ['GET', '/v2/timers', undefined, 404, 'not_found']
  ];
  for (const [method, path, body, status, code] of cases) {
    const response = await call(method, path, body);
    assert.equal(response.status, status, `${method} ${path} ${JSON.stringify(body)}`);
    assert.equal(response.body.error?.code ?? null, code, `${method} ${path}`);
  }
  for (const [body, label] of [['{"id":', 'malformed JSON'], ['null', 'null input']]) {
    const response = await rawRequest(daemon.paths.socket, 'POST', '/v1/ops/pause', body);
    assert.equal(response.status, 400, label);
    assert.equal(response.body.error.code, 'invalid_input', label);
  }
  const huge = await rawRequest(daemon.paths.socket, 'POST', '/v1/ops/create', `"${'x'.repeat(1024 * 1024)}"`);
  assert.equal(huge.status, 413);
  assert.equal(huge.body.error.code, 'invalid_input');
});

test('limit_reached is 409', async (t) => {
  const { op } = await startTestDaemon(t);
  for (let index = 0; index < TIMER_LIMITS.timers; index++) {
    assert.equal((await op('create', { timer: { kind: 'stopwatch' } })).status, 200);
  }
  const over = await op('create', { timer: { kind: 'stopwatch' } });
  assert.equal(over.status, 409);
  assert.equal(over.body.error.code, 'limit_reached');
});

test('a change the disk refuses is not applied', { skip: process.getuid?.() === 0 && 'root ignores file modes' }, async (t) => {
  const { op, call, daemon } = await startTestDaemon(t);
  chmodSync(daemon.paths.dataDir, 0o500);
  let refused;
  try {
    refused = await op('create', { timer: { kind: 'stopwatch' } });
  } finally {
    chmodSync(daemon.paths.dataDir, 0o700);
  }
  assert.equal(refused.status, 500);
  assert.equal(refused.body.error.code, 'storage_failed');
  assert.deepEqual((await call('GET', '/v1/timers')).body.structuredContent.timers, []);
});

test('state, alert and heartbeat events arrive over the socket in order', async (t) => {
  const { op, clock, daemon } = await startTestDaemon(t);
  const daemonStartedAt = clock.now();
  const events = subscribe(daemon.paths.socket);
  t.after(events.close);
  await events.waitFor((list) => list.length === 1);
  assert.equal(events.events[0].event, 'state');
  assert.deepEqual(events.events[0].data.structuredContent.timers, []);

  const started = await op('start', { timer: { kind: 'countdown', durationMs: 5_000, countdownTicks: true, name: 'Egg' } });
  const id = started.body.timer.definition.id;
  await events.waitFor((list) => list.length === 2);
  assert.equal(events.events[1].data.structuredContent.timers[0].runtime.status, 'running');

  const startedAt = clock.now();
  clock.advance(5_000);
  await events.waitFor((list) => list.length === 7);
  assert.deepEqual(events.events.slice(2).map(({ event, data }) => (event === 'alert' ? `${data.kind}@${data.at - startedAt}` : event)), [
    'tick@2000', 'tick@3000', 'tick@4000', 'finish@5000', 'state'
  ]);
  assert.ok(events.events.slice(2, 6).every(({ data }) => data.timerId === id));
  assert.equal(events.events[6].data.structuredContent.timers[0].runtime.status, 'finished');

  clock.advance(10_000);
  await events.waitFor((list) => list.length === 8);
  assert.deepEqual(events.events[7], { event: 'heartbeat', data: { at: daemonStartedAt + 15_000 } });
  clock.advance(15_000);
  await events.waitFor((list) => list.length === 9);
  assert.deepEqual(events.events[8], { event: 'heartbeat', data: { at: daemonStartedAt + 30_000 } });
});

test('shutdown answers, then removes the socket and the lock', async (t) => {
  const { call, daemon } = await startTestDaemon(t);
  const response = await call('POST', '/v1/shutdown');
  assert.deepEqual([response.status, response.body], [200, { ok: true }]);
  assert.equal(await daemon.closed, 0);
  assert.equal(existsSync(daemon.paths.socket), false);
  assert.equal(existsSync(daemon.paths.lock), false);
});

test('a restarted daemon keeps a running timer running from its timestamps', async (t) => {
  const dataDir = tempDataDir(t);
  const first = await startTestDaemon(t, { dataDir });
  const started = await first.op('start', { timer: { kind: 'countdown', durationMs: 600_000 } });
  await first.daemon.shutdown();
  first.clock.advance(60_000);
  const second = await startTestDaemon(t, { dataDir, clock: first.clock });
  const { body } = await second.op('get', { id: started.body.timer.definition.id });
  assert.equal(body.timer.runtime.status, 'running');
  assert.equal(body.timer.projection.elapsedMs, 60_000);
});

test('a daemon killed right after a skip is restarted without firing what the skip jumped over', async (t) => {
  const dataDir = tempDataDir(t);
  const run = spawnDaemonProcess(dataDir);
  t.after(() => run.child.kill('SIGKILL'));
  const socket = `${dataDir}/daemon.sock`;
  await eventually(() => existsSync(socket), 10_000);
  const started = await socketRequest(socket, 'POST', '/v1/ops/start', { preset: 'tabata' });
  const id = started.body.timer.definition.id;
  const skipped = await socketRequest(socket, 'POST', '/v1/ops/skip', { id });
  assert.equal(skipped.body.timer.projection.step.phase, 'work');
  run.child.kill('SIGKILL');
  await run.exited;

  const clock = createFakeClock(Date.now());
  const restarted = await startTestDaemon(t, { dataDir, clock });
  assert.deepEqual(restarted.sink.received, []);
  const restartedAt = clock.now();
  clock.advance(21_000);
  const timer = restarted.daemon.store.timers.find((entry) => entry.definition.id === id);
  const next = transitionsBetween(timer, restartedAt, clock.now()).map((transition) => `${transition.type}@${transition.at}`);
  assert.deepEqual(next.map((entry) => entry.split('@')[0]), ['tick', 'tick', 'tick', 'segment']);
  assert.deepEqual(restarted.sink.received.map(({ alert }) => `${alert.kind}@${alert.at}`), next);
});

test('a finish the disk refused is recorded at a later run, shown to subscribers, and the daemon then idles out', { skip: process.getuid?.() === 0 && 'root ignores file modes' }, async (t) => {
  const { op, clock, daemon, logs } = await startTestDaemon(t);
  const started = await op('start', { timer: { kind: 'countdown', durationMs: 1_000 } });
  const id = started.body.timer.definition.id;
  const events = subscribe(daemon.paths.socket);
  t.after(events.close);
  await events.waitFor((list) => list.length === 1);
  const storedStatus = () => parseStore(JSON.parse(readFileSync(daemon.paths.state, 'utf8'))).store.timers[0].runtime.status;

  chmodSync(daemon.paths.dataDir, 0o500);
  try {
    clock.advance(1_000);
  } finally {
    chmodSync(daemon.paths.dataDir, 0o700);
  }
  assert.ok(logs.some((line) => /could not save finished timers/.test(line)));
  assert.equal(storedStatus(), 'running');
  assert.equal(daemon.store.timers[0].runtime.status, 'running');

  // The disk works again; the next run, at most a minute later, records the finish and shows it.
  clock.advance(REARM_MS);
  assert.equal(storedStatus(), 'finished');
  assert.equal(daemon.store.timers[0].runtime.status, 'finished');
  const finished = await events.waitFor((list) => list.some(({ event, data }) => event === 'state' && data.structuredContent.timers[0].runtime.status === 'finished'));
  assert.deepEqual(finished.filter(({ event }) => event === 'alert').map(({ data }) => [data.timerId, data.kind]), [[id, 'finish']]);

  events.close();
  await eventually(() => daemon.subscriberCount === 0);
  clock.advance(IDLE_EXIT_MS);
  assert.equal(await daemon.closed, 0);
});

/** A valid store whose state frame is over 1 MiB: paused stopwatches holding the most laps allowed. */
function writeLargeStore(dataDir, count, now) {
  let { store, result } = runOperation('start', emptyStore(), { timer: { kind: 'stopwatch', name: 'Laps' } }, now);
  const id = result.timer.definition.id;
  for (let lap = 0; lap < TIMER_LIMITS.laps; lap++) store = runOperation('lap', store, { id }, now + (lap + 1) * 1_234).store;
  store = runOperation('pause', store, { id }, now + TIMER_LIMITS.laps * 1_234 + 1).store;
  const [timer] = store.timers;
  store = { ...store, timers: Array.from({ length: count }, (_, index) => ({ ...timer, definition: { ...timer.definition, id: `t_aa${String(index).padStart(6, '0')}` } })) };
  assert.equal(parseStore(store).ok, true);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  writeFileSync(join(dataDir, 'state.json'), JSON.stringify(store));
}

test('a subscriber that keeps reading gets every state frame, even one over 1 MiB', async (t) => {
  const dataDir = tempDataDir(t);
  const clock = createFakeClock();
  writeLargeStore(dataDir, 30, clock.now() - 2_000_000);
  const { op, daemon } = await startTestDaemon(t, { dataDir, clock });
  const events = subscribe(daemon.paths.socket);
  t.after(events.close);
  await events.waitFor((list) => list.length === 1);
  assert.ok(JSON.stringify(events.events[0].data).length > 1024 * 1024);
  assert.equal(events.events[0].data.structuredContent.timers.length, 30);

  await op('create', { timer: { kind: 'stopwatch', name: 'One more' } });
  await op('create', { timer: { kind: 'stopwatch', name: 'And another' } });
  await events.waitFor((list) => list.length === 3);
  assert.deepEqual(events.events.map(({ event, data }) => [event, data.structuredContent.timers.length]), [['state', 30], ['state', 31], ['state', 32]]);
  assert.equal(daemon.subscriberCount, 1);
});

test('a subscriber that stops reading is dropped, and the daemon carries on', async (t) => {
  const dataDir = tempDataDir(t);
  const clock = createFakeClock();
  writeLargeStore(dataDir, 30, clock.now() - 2_000_000);
  const { call, daemon } = await startTestDaemon(t, { dataDir, clock });
  const stalled = connect(daemon.paths.socket);
  t.after(() => stalled.destroy());
  stalled.write('GET /v1/events HTTP/1.1\r\nhost: daemon\r\n\r\n');
  stalled.pause();
  await eventually(() => daemon.subscriberCount === 1);
  // Heartbeats queue behind the undrained state frame until it has waited more than 30 s.
  clock.advance(30_000);
  assert.equal(daemon.subscriberCount, 1);
  clock.advance(15_000);
  await eventually(() => daemon.subscriberCount === 0);
  assert.equal((await call('GET', '/v1/daemon')).status, 200);
});

test('a request to a daemon that lost its lock is answered 503 and not applied', async (t) => {
  const { op, daemon } = await startTestDaemon(t);
  unlinkSync(daemon.paths.lock);
  const reply = await op('create', { timer: { kind: 'stopwatch' } });
  assert.deepEqual([reply.status, reply.body.error.code], [503, 'daemon_unavailable']);
  assert.equal(await daemon.closed, 1);
  assert.equal(existsSync(daemon.paths.state), false);
});

test('a request still arriving when shutdown begins is answered 503 and not applied', async (t) => {
  const { daemon } = await startTestDaemon(t);
  const reply = new Promise((resolve, reject) => {
    const outgoing = request({ socketPath: daemon.paths.socket, method: 'POST', path: '/v1/ops/create', agent: false }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
    });
    outgoing.on('error', reject);
    // The daemon is handling the request, still reading its body, when shutdown begins.
    daemon.server.once('request', () => {
      daemon.shutdown(0);
      outgoing.end('{"kind":"stopwatch"}}');
    });
    outgoing.write('{"timer":');
  });
  const { status, body } = await reply;
  assert.deepEqual([status, body.error.code], [503, 'daemon_unavailable']);
  assert.equal(await daemon.closed, 0);
  assert.equal(existsSync(daemon.paths.state), false);
});
