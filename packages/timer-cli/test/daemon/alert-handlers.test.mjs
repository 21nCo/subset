import assert from 'node:assert/strict';
import { existsSync, mkdirSync, readFileSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { join } from 'node:path';
import test from 'node:test';
import { emptyStore, runOperation, transitionsBetween } from '@subset/timer';
import { ACK_TIMEOUT_MS, SETTLED_RETENTION_MS, createAlertHandlers, createFakeClock, createRecordingSink, createScheduler, socketRequest } from '../../src/daemon/index.mjs';
import { eventually, rawRequest, spawnDaemonProcess, startTestDaemon, subscribe, tempDataDir, within } from './helpers.mjs';

const TABATA_MS = 250_000;

/** Opens an event stream and waits for its subscriber id and first state. */
async function openStream(t, context) {
  const stream = subscribe(context.daemon.paths.socket);
  t.after(stream.close);
  await stream.waitFor((list) => list.length >= 1);
  return stream;
}

const register = (context, subscriberId) => context.call('POST', '/v1/alert-handlers', { subscriberId });
const acknowledge = (context, alertId, subscriberId) => context.call('POST', `/v1/alerts/${alertId}/ack`, { subscriberId });
const alertsOf = (stream) => stream.events.filter(({ event }) => event === 'alert').map(({ data }) => data);

/** Starts a one-second countdown without ticks, so its only alert is the finish. */
async function startCountdown(context, name = 'Egg') {
  const started = await context.op('start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name } });
  assert.equal(started.status, 200);
  return started.body.timer.definition.id;
}

/** A registered handler's stream and id. */
async function registeredHandler(t, context) {
  const stream = await openStream(t, context);
  const reply = await register(context, stream.subscriberId);
  assert.equal(reply.status, 200);
  assert.deepEqual(reply.body, { subscriberId: stream.subscriberId, ackTimeoutMs: ACK_TIMEOUT_MS });
  return stream;
}

test('each event stream opens with its own subscriber id, before the first state', async (t) => {
  const context = await startTestDaemon(t);
  const [first, second] = [await openStream(t, context), await openStream(t, context)];
  assert.equal(first.firstEvent, 'subscriber');
  assert.equal(first.events[0].event, 'state');
  assert.match(first.subscriberId, /^[0-9a-f]{32}$/);
  assert.notEqual(first.subscriberId, second.subscriberId);
});

test('with no handler the sink plays each alert as it is published, and the alert asks for no acknowledgement', async (t) => {
  const context = await startTestDaemon(t);
  const stream = await openStream(t, context);
  const id = await startCountdown(context);
  context.clock.advance(1_000);
  assert.deepEqual(context.sink.received.map(({ alert }) => [alert.timerId, alert.kind]), [[id, 'finish']]);
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [alert] = alertsOf(stream);
  assert.equal(alert.kind, 'finish');
  assert.equal(['alertId', 'ackRequired', 'timerName', 'sound'].some((field) => field in alert), false);
});

test('a registered handler that acknowledges in time owns the alert: the sink is never called', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  const observer = await openStream(t, context);
  const id = await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.deepEqual([alert.timerId, alert.kind, alert.ackRequired], [id, 'finish', true]);
  // The handler gets the timer's name and sound with the alert, so removing the timer meanwhile changes nothing.
  assert.deepEqual([alert.timerName, alert.sound], ['Egg', true]);
  assert.match(alert.alertId, /^[0-9a-f]{32}$/);
  // Every subscriber sees the same alert; only the handler may take it.
  await observer.waitFor(() => alertsOf(observer).length === 1);
  assert.deepEqual(alertsOf(observer), [alert]);
  assert.equal((await acknowledge(context, alert.alertId, observer.subscriberId)).body.error.code, 'not_alert_handler');

  context.clock.advance(ACK_TIMEOUT_MS - 1);
  const ack = await acknowledge(context, alert.alertId, handler.subscriberId);
  assert.deepEqual([ack.status, ack.body], [200, { alertId: alert.alertId, acknowledged: true }]);
  // A retried acknowledgement gets the same answer.
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  context.clock.advance(60_000);
  assert.deepEqual(context.sink.received, []);
  const status = await context.call('GET', '/v1/daemon');
  assert.deepEqual(status.body.alertHandler, { registered: true, pending: 0, acknowledged: 1, fallbacks: 0 });
});

test('an alert not acknowledged within 2 s is played by the sink once, and a late acknowledgement gets 410', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  context.clock.advance(ACK_TIMEOUT_MS - 1);
  assert.equal(context.sink.received.length, 0);
  context.clock.advance(1);
  assert.deepEqual(context.sink.received.map(({ alert: played }) => played), [{ timerId: alert.timerId, kind: 'finish', at: alert.at }]);
  const late = await acknowledge(context, alert.alertId, handler.subscriberId);
  assert.deepEqual([late.status, late.body.error.code], [410, 'alert_expired']);
  context.clock.advance(60_000);
  assert.equal(context.sink.received.length, 1);
  assert.ok(context.logs.some((line) => line.includes(`alert ${alert.alertId} (finish of ${alert.timerId}) was not acknowledged within 2 s`)));
  assert.deepEqual((await context.call('GET', '/v1/daemon')).body.alertHandler, { registered: true, pending: 0, acknowledged: 0, fallbacks: 1 });
});

test('a handler that disconnects mid-alert falls back at once, and later alerts go straight to the sink', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.equal(context.sink.received.length, 0);
  handler.close();
  // No clock movement: closing the stream unregisters the handler and plays its pending alert.
  await eventually(() => context.sink.received.length === 1);
  assert.equal(context.daemon.alertHandler.registered, false);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 410);

  const observer = await openStream(t, context);
  await startCountdown(context, 'Tea');
  context.clock.advance(1_000);
  assert.equal(context.sink.received.length, 2);
  await observer.waitFor(() => alertsOf(observer).length === 1);
  assert.equal(alertsOf(observer)[0].ackRequired, undefined);
});

test('a second registration gets 409 until the first handler leaves', async (t) => {
  const context = await startTestDaemon(t);
  const first = await registeredHandler(t, context);
  const second = await openStream(t, context);
  // Registering again is harmless; another subscriber is refused.
  assert.equal((await register(context, first.subscriberId)).status, 200);
  const refused = await register(context, second.subscriberId);
  assert.deepEqual([refused.status, refused.body.error.code], [409, 'handler_registered']);

  first.close();
  await eventually(() => !context.daemon.alertHandler.registered);
  assert.equal((await register(context, second.subscriberId)).status, 200);
});

test('unregistering hands pending alerts to the sink at once; only the handler can unregister itself', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  const other = await openStream(t, context);
  const notHandler = await context.call('DELETE', `/v1/alert-handlers/${other.subscriberId}`);
  assert.deepEqual([notHandler.status, notHandler.body], [200, { unregistered: false }]);
  assert.equal(context.daemon.alertHandler.registered, true);

  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  const removed = await context.call('DELETE', `/v1/alert-handlers/${handler.subscriberId}`);
  assert.deepEqual([removed.status, removed.body], [200, { unregistered: true }]);
  assert.equal(context.sink.received.length, 1);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 410);

  // The stream stays open and can register again.
  assert.equal((await register(context, handler.subscriberId)).status, 200);
});

test('malformed handler requests are refused without changing ownership', async (t) => {
  const context = await startTestDaemon(t);
  const { socket } = context.daemon.paths;
  const unknown = await register(context, 'f'.repeat(32));
  assert.deepEqual([unknown.status, unknown.body.error.code], [404, 'not_found']);
  for (const body of ['', '{', '{"subscriberId":7}', '{"subscriberId":""}', JSON.stringify({ subscriberId: 'x'.repeat(129) })]) {
    const reply = await rawRequest(socket, 'POST', '/v1/alert-handlers', body);
    assert.deepEqual([reply.status, reply.body.error.code], [400, 'invalid_input'], body);
  }
  assert.equal((await context.call('GET', '/v1/alert-handlers')).status, 405);
  assert.equal((await context.call('GET', '/v1/alerts/abc/ack')).status, 405);
  assert.equal((await context.call('POST', '/v1/alert-handlers/abc')).status, 405);
  assert.equal((await context.call('POST', '/v1/alerts//ack', { subscriberId: 'a' })).status, 404);
  const missing = await acknowledge(context, 'a'.repeat(32), 'b'.repeat(32));
  assert.deepEqual([missing.status, missing.body.error.code], [404, 'not_found']);
  assert.equal(context.daemon.alertHandler.registered, false);
});

test('shutdown plays the alerts the handler has not acknowledged', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  await context.daemon.shutdown();
  assert.deepEqual(context.sink.received.map(({ alert }) => alert.kind), ['finish']);
});

/** Sends an acknowledgement whose body arrives only after `beforeBody` has run. */
function acknowledgeLate(socketPath, alertId, subscriberId, beforeBody) {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ subscriberId });
    const outgoing = request(
      { socketPath, method: 'POST', path: `/v1/alerts/${alertId}/ack`, agent: false, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } },
      (response) => {
        const chunks = [];
        response.on('data', (chunk) => chunks.push(chunk));
        response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
      }
    );
    outgoing.on('error', reject);
    outgoing.flushHeaders();
    setTimeout(async () => {
      await beforeBody();
      outgoing.end(body);
    }, 50);
  });
}

test('an acknowledgement retried while the daemon shuts down gets the outcome stop() settled, not 503', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  await startCountdown(context, 'Tea');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 2);
  const [taken, left] = alertsOf(handler);
  assert.equal((await acknowledge(context, taken.alertId, handler.subscriberId)).status, 200);
  let closed;
  const retried = acknowledgeLate(context.daemon.paths.socket, taken.alertId, handler.subscriberId, () => {
    closed = context.daemon.shutdown();
  });
  const late = acknowledgeLate(context.daemon.paths.socket, left.alertId, handler.subscriberId, () => {});
  assert.deepEqual([(await retried).status, (await late).status], [200, 410]);
  await closed;
  assert.deepEqual(context.sink.received.map(({ timer }) => timer.name), [left.timerName]);
});

test('while a handoff is not saved, the timer stays running on disk, so a daemon that ends before the fallback leaves the alert to the next one', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  const id = await startCountdown(context);
  const scheduler = join(context.dataDir, 'scheduler.json');
  const lastSaved = readFileSync(scheduler);
  // Each save of scheduler.json fails from now on: a directory is where the new file is renamed to.
  unlinkSync(scheduler);
  mkdirSync(join(scheduler, 'in-the-way'), { recursive: true });
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const stateOnDisk = () => JSON.parse(readFileSync(join(context.dataDir, 'state.json'), 'utf8'));
  const before = readFileSync(join(context.dataDir, 'state.json'), 'utf8');
  // The daemon ends abruptly now, before the handler acknowledges or the 2 s fallback: the next one
  // starts from the files as they are.
  const next = tempDataDir(t);
  mkdirSync(next, { recursive: true });
  writeFileSync(join(next, 'state.json'), before);
  writeFileSync(join(next, 'scheduler.json'), lastSaved);
  const successor = await startTestDaemon(t, { dataDir: next });
  successor.clock.advance(60_000);
  assert.deepEqual(successor.sink.received.map(({ alert, timer }) => [alert.timerId, timer.name]), [[id, 'Egg']]);
  // No operation records a change that removes the running timer while the handoff is not saved.
  assert.equal((await context.op('remove', { id })).status, 500);
  assert.equal(readFileSync(join(context.dataDir, 'state.json'), 'utf8'), before);
  // The first daemon, once scheduler.json can be saved again, records the timer as finished.
  rmSync(scheduler, { recursive: true });
  context.clock.advance(60_000);
  await eventually(() => stateOnDisk().timers.every((timer) => timer.runtime?.status === 'finished'));
});

test('a daemon that loses its lock leaves the alerts it handed over to the daemon that holds it', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true });
  handlers.register('s1');
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, { id: 't_1', name: 'Egg', sound: true });
  handlers.stop({ lockLost: true });
  clock.advance(ACK_TIMEOUT_MS);
  assert.deepEqual([sink.received.length, handlers.handoffs], [0, []]);
});

for (const [path, settle] of [
  ['the 2 s timeout', (handlers, clock) => clock.advance(ACK_TIMEOUT_MS)],
  ['a disconnect', (handlers) => handlers.disconnected('s1')],
  ['unregistering', (handlers) => handlers.unregister('s1')],
  ['a graceful stop', (handlers) => handlers.stop()]
]) {
  test(`a pending alert is not played on ${path} once the daemon has lost its lock`, () => {
    const clock = createFakeClock();
    const sink = createRecordingSink();
    let held = true;
    const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, owns: () => held });
    handlers.register('s1');
    const timer = { id: 't_1', name: 'Egg', sound: true };
    handlers.deliver({ timerId: 't_1', kind: 'segment', at: clock.now() }, timer);
    handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, timer);
    held = false;
    settle(handlers, clock);
    clock.advance(60_000);
    assert.deepEqual([sink.received.length, handlers.status.pending, handlers.status.fallbacks], [0, 0, 0]);
  });
}

test('a pending alert falls back through the sink while the daemon holds its lock', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  let checks = 0;
  const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, owns: () => ++checks > 0 });
  handlers.register('s1');
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, { id: 't_1', name: 'Egg', sound: true });
  clock.advance(ACK_TIMEOUT_MS);
  assert.deepEqual([sink.received.length, checks], [1, 1]);
});

test('a daemon whose lock is replaced while an alert is pending leaves it to the next daemon, which plays it once', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  const id = await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  writeFileSync(context.daemon.paths.lock, JSON.stringify({ pid: 1, token: 'another daemon' }));
  context.clock.advance(ACK_TIMEOUT_MS);
  assert.equal(await within(context.daemon.closed), 1);
  assert.equal(context.sink.received.length, 0);
  // The daemon that replaced the lock has gone, so the next one takes it.
  unlinkSync(context.daemon.paths.lock);
  const next = await startTestDaemon(t, { dataDir: context.daemon.paths.dataDir });
  next.clock.advance(60_000);
  assert.deepEqual(next.sink.received.map(({ alert, timer }) => [alert.timerId, alert.kind, timer.name]), [[id, 'finish', 'Egg']]);
});

test('an acknowledgement is answered only once it is saved; one that fails to save leaves the alert to the sink', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const saved = [];
  let failNext = true;
  const handlers = createAlertHandlers({
    clock,
    sink,
    log: () => {},
    publish: () => {},
    isOpen: () => true,
    newId: (() => {
      let next = 0;
      return () => `a${++next}`;
    })(),
    save({ handoffs, acknowledged }) {
      if (failNext) {
        failNext = false;
        throw new Error('disk full');
      }
      saved.push([handoffs.map(({ alertId }) => alertId), acknowledged]);
    }
  });
  handlers.register('s1');
  const timer = { id: 't_1', name: 'Egg', sound: true };
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, timer);
  handlers.deliver({ timerId: 't_1', kind: 'tick', at: clock.now() }, timer);
  assert.deepEqual(handlers.handoffs.map(({ alertId, timer: { name } }) => [alertId, name]), [['a1', 'Egg'], ['a2', 'Egg']]);
  assert.throws(() => handlers.acknowledge('a1', 's1'), /disk full/);
  assert.equal(handlers.status.pending, 2);
  // The acknowledgement that saves records the alert as taken before it is answered, and it stays
  // saved until its 200 has been written.
  assert.equal(handlers.acknowledge('a2', 's1').ok, true);
  assert.deepEqual(saved, [[['a1'], [{ alertId: 'a2', subscriberId: 's1' }]]]);
  handlers.answered('a2');
  clock.advance(ACK_TIMEOUT_MS);
  assert.deepEqual(sink.received.map(({ alert }) => alert.kind), ['finish']);
  assert.deepEqual(saved.at(-1), [[], []]);
  assert.equal(handlers.acknowledge('a1', 's1').status, 410);
});

/** Alert handlers on a fake clock with ids `a1`, `a2`, … and handler `s1` registered. */
function sequentialHandlers() {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  let next = 0;
  const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, newId: () => `a${++next}` });
  handlers.register('s1');
  return { clock, sink, handlers };
}

test('an acknowledgement whose reply is lost gets its 200 on retry however many alerts settle meanwhile', () => {
  const { clock, sink, handlers } = sequentialHandlers();
  const timer = { id: 't_1', name: 'Egg', sound: true };
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, timer);
  // The daemon takes the alert, but its reply never reaches the handler.
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  // 50 timers alerting every second settle about 100 alerts a second; the retry comes 15 s later,
  // after 1,500 more have settled, half of them acknowledged and half fallen back.
  for (let second = 0; second < 15; second++) {
    const first = 2 + second * 100;
    for (let index = 0; index < 100; index++) handlers.deliver({ timerId: 't_2', kind: 'tick', at: clock.now() }, timer);
    for (let index = 0; index < 50; index++) assert.equal(handlers.acknowledge(`a${first + index}`, 's1').ok, true);
    clock.advance(1_000);
  }
  clock.advance(ACK_TIMEOUT_MS);
  assert.equal(handlers.status.fallbacks, 1_500 / 2);
  // The handler retries until it gets a definitive answer, and plays only on a 200.
  let playedByHandler = 0;
  const retry = handlers.acknowledge('a1', 's1');
  if (retry.ok) playedByHandler += 1;
  assert.deepEqual([retry.ok, playedByHandler], [true, 1]);
  assert.equal(sink.received.filter(({ alert }) => alert.kind === 'finish').length, 0);
  // A fallen-back alert from the start of the run still answers 410, not 404.
  assert.equal(handlers.acknowledge('a52', 's1').status, 410);
});

test(`a settled outcome is kept while its handler keeps asking, and forgotten ${SETTLED_RETENTION_MS / 1000} s after the last request on the monotonic clock`, () => {
  const { clock, handlers } = sequentialHandlers();
  const timer = { id: 't_1', name: 'Egg', sound: true };
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, timer);
  handlers.deliver({ timerId: 't_1', kind: 'tick', at: clock.now() }, timer);
  handlers.deliver({ timerId: 't_1', kind: 'segment', at: clock.now() }, timer);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  clock.advance(ACK_TIMEOUT_MS);
  // A wall clock set forward neither ages nor drops an outcome.
  clock.jump(10 * SETTLED_RETENTION_MS);
  // A handler whose replies keep getting lost asks again and again, long past the retention.
  for (let request = 0; request < 5; request++) {
    clock.advance(SETTLED_RETENTION_MS - ACK_TIMEOUT_MS);
    assert.deepEqual([handlers.acknowledge('a1', 's1').ok, handlers.acknowledge('a2', 's1').status], [true, 410]);
  }
  clock.advance(SETTLED_RETENTION_MS + 1);
  assert.deepEqual([handlers.acknowledge('a1', 's1').status, handlers.acknowledge('a2', 's1').status], [404, 404]);
  // An outcome nobody asked about is forgotten 60 s after it settled.
  assert.equal(handlers.acknowledge('a3', 's1').status, 404);
});

test('a daemon answers 200 for the unanswered acknowledgements an earlier daemon saved, and only for their handler', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const saved = [];
  const handlers = createAlertHandlers({
    clock,
    sink,
    log: () => {},
    publish: () => {},
    isOpen: () => true,
    save: (checkpoint) => saved.push(checkpoint),
    acknowledged: [{ alertId: 'a1', subscriberId: 's1' }]
  });
  assert.deepEqual(handlers.checkpoint, { handoffs: [], acknowledged: [{ alertId: 'a1', subscriberId: 's1' }] });
  assert.equal(handlers.acknowledge('a1', 's2').status, 409);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  handlers.answered('a1');
  assert.deepEqual(handlers.checkpoint.acknowledged, []);
  clock.advance(SETTLED_RETENTION_MS + 1);
  assert.equal(handlers.acknowledge('a1', 's1').status, 404);
  assert.equal(sink.received.length, 0);
});

/**
 * Runs a daemon process, registers a handler, finishes a countdown and kills the daemon with
 * SIGKILL once the handler has the alert, acknowledging it first when `acknowledgeFirst`. Returns
 * the data directory and the countdown's id.
 */
async function killDaemonDuringHandoff(t, { acknowledgeFirst }) {
  const dataDir = tempDataDir(t);
  const crashed = spawnDaemonProcess(dataDir);
  const socket = join(dataDir, 'daemon.sock');
  await eventually(() => existsSync(socket), 10_000);
  const stream = subscribe(socket);
  t.after(stream.close);
  await stream.waitFor((list) => list.length >= 1);
  assert.equal((await socketRequest(socket, 'POST', '/v1/alert-handlers', { subscriberId: stream.subscriberId })).status, 200);
  const started = await socketRequest(socket, 'POST', '/v1/ops/start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg' } });
  assert.equal(started.status, 200, JSON.stringify(started.body));
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [alert] = alertsOf(stream);
  if (acknowledgeFirst) assert.equal((await socketRequest(socket, 'POST', `/v1/alerts/${alert.alertId}/ack`, { subscriberId: stream.subscriberId })).status, 200);
  crashed.child.kill('SIGKILL');
  await crashed.exited;
  const saved = JSON.parse(readFileSync(join(dataDir, 'scheduler.json'), 'utf8'));
  assert.deepEqual((saved.handoffs ?? []).map(({ alertId }) => alertId), acknowledgeFirst ? [] : [alert.alertId]);
  assert.deepEqual(saved.acknowledged ?? [], acknowledgeFirst ? [{ alertId: alert.alertId, subscriberId: stream.subscriberId }] : []);
  return { dataDir, id: started.body.timer.definition.id, alertId: alert.alertId, subscriberId: stream.subscriberId };
}

test('an alert handed over but unacknowledged when the daemon is killed is played once by the next daemon', async (t) => {
  const { dataDir, id, alertId, subscriberId } = await killDaemonDuringHandoff(t, { acknowledgeFirst: false });
  const next = await startTestDaemon(t, { dataDir });
  next.clock.advance(60_000);
  assert.deepEqual(next.sink.received.map(({ alert, timer }) => [alert.timerId, alert.kind, timer.name]), [[id, 'finish', 'Egg']]);
  // A handler still asking about it is told it is not its to play.
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 404);
  await next.daemon.shutdown();
  const after = await startTestDaemon(t, { dataDir });
  after.clock.advance(60_000);
  assert.equal(after.sink.received.length, 0);
});

test('an alert the handler acknowledged before the daemon was killed is not played again, and its retried acknowledgement gets 200 from the next daemon', async (t) => {
  const { dataDir, alertId, subscriberId } = await killDaemonDuringHandoff(t, { acknowledgeFirst: true });
  const next = await startTestDaemon(t, { dataDir });
  // The handler whose 200 was lost when the daemon ended asks the next one, and plays on its 200.
  assert.equal((await acknowledge(next, alertId, 'another stream')).status, 409);
  assert.deepEqual((await acknowledge(next, alertId, subscriberId)).body, { alertId, acknowledged: true });
  next.clock.advance(SETTLED_RETENTION_MS);
  assert.equal(next.sink.received.length, 0);
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 200);
  next.clock.advance(SETTLED_RETENTION_MS + 1);
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 404);
});

/** A small seeded generator (mulberry32), so a failing sequence can be replayed from its seed. */
function seeded(seed) {
  let state = seed >>> 0;
  return () => {
    state = (state + 0x6d2b79f5) >>> 0;
    let value = state;
    value = Math.imul(value ^ (value >>> 15), value | 1);
    value ^= value + Math.imul(value ^ (value >>> 7), value | 61);
    return ((value ^ (value >>> 14)) >>> 0) / 4_294_967_296;
  };
}

const keyOf = (alert) => `${alert.timerId}:${alert.kind}:${alert.at}`;

/**
 * One Tabata run through the real scheduler and alert handlers on a fake clock, with handlers that
 * register, disconnect, unregister and acknowledge at random times. Returns what was published,
 * played by the sink and played by a handler, by alert.
 */
function randomTabataRun(seed) {
  const random = seeded(seed);
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const open = new Set();
  let nextSubscriber = 0;
  const published = [];
  /** Acknowledgements the handler side will send: { alertId, subscriberId, at } on the monotonic timeline. */
  const planned = [];
  const handlers = createAlertHandlers({
    clock,
    sink,
    log: () => {},
    isOpen: (id) => open.has(id),
    publish(alert) {
      published.push({ alert, handler: handlers.handler });
      if (!alert.ackRequired) return;
      // Most handlers answer in time, some late, some never.
      const roll = random();
      if (roll < 0.1) return;
      const delay = roll < 0.75 ? Math.floor(random() * ACK_TIMEOUT_MS) : ACK_TIMEOUT_MS + Math.floor(random() * 1_000);
      planned.push({ alertId: alert.alertId, subscriberId: handlers.handler, at: clock.monotonic() + delay, key: keyOf(alert) });
    }
  });
  let store = emptyStore();
  const started = runOperation('start', store, { preset: 'tabata' }, clock.now());
  store = started.store;
  const timer = store.timers[0];
  const startedAt = clock.now();
  const scheduler = createScheduler({ clock, getTimers: () => store.timers, onRun: (alerts) => alerts.forEach(({ alert, timer: definition }) => handlers.deliver(alert, definition)) });
  scheduler.run();

  const playedByHandler = [];
  const outcomes = { acknowledged: 0, expired: 0, refused: 0 };
  const end = TABATA_MS + 5_000;
  for (let elapsed = 0; elapsed < end; elapsed += 100) {
    const roll = random();
    if (handlers.handler === null && roll < 0.05) {
      const id = `s${nextSubscriber++}`;
      open.add(id);
      assert.equal(handlers.register(id).ok, true);
    } else if (handlers.handler !== null && roll < 0.06) {
      // Someone else tries to take over.
      const id = `s${nextSubscriber++}`;
      open.add(id);
      assert.equal(handlers.register(id).status, 409);
    } else if (handlers.handler !== null && roll < 0.075) {
      const id = handlers.handler;
      open.delete(id);
      handlers.disconnected(id);
    } else if (handlers.handler !== null && roll < 0.08) {
      handlers.unregister(handlers.handler);
    }
    for (const ack of planned.filter((entry) => entry.at <= clock.monotonic())) {
      planned.splice(planned.indexOf(ack), 1);
      const result = handlers.acknowledge(ack.alertId, ack.subscriberId);
      // The handler plays only what the daemon handed it.
      if (result.ok) {
        playedByHandler.push(ack.key);
        outcomes.acknowledged += 1;
      } else if (result.status === 410) outcomes.expired += 1;
      else outcomes.refused += 1;
    }
    clock.advance(100);
  }
  clock.advance(ACK_TIMEOUT_MS);
  scheduler.stop();
  const expected = transitionsBetween(timer, startedAt, startedAt + TABATA_MS).map((transition) => `${timer.definition.id}:${transition.type}:${transition.at}`);
  return { expected, published, playedBySink: sink.received.map(({ alert }) => keyOf(alert)), playedByHandler, outcomes, status: handlers.status };
}

test('a seeded random sequence of registrations, disconnects and acknowledgement times across a Tabata run delivers each alert exactly once', () => {
  const totals = { acknowledged: 0, expired: 0, fallbacks: 0, direct: 0 };
  for (let seed = 1; seed <= 40; seed++) {
    const run = randomTabataRun(seed);
    assert.equal(run.expected.length, 68, `seed ${seed}`);
    assert.deepEqual(run.published.map(({ alert }) => keyOf(alert)), run.expected, `seed ${seed}: every alert is published once, in order`);
    // An alert asks for acknowledgement exactly when a handler was registered as it was published.
    assert.ok(run.published.every(({ alert, handler }) => (alert.ackRequired === true) === (handler !== null)), `seed ${seed}`);
    const delivered = [...run.playedBySink, ...run.playedByHandler].sort();
    assert.deepEqual(delivered, [...run.expected].sort(), `seed ${seed}: each alert is played exactly once`);
    assert.equal(run.status.pending, 0, `seed ${seed}`);
    totals.acknowledged += run.outcomes.acknowledged;
    totals.expired += run.outcomes.expired;
    totals.fallbacks += run.status.fallbacks;
    totals.direct += run.published.filter(({ handler }) => handler === null).length;
  }
  // The seeds cover every path: handled, fallen back, refused late, and played with no handler.
  for (const [path, count] of Object.entries(totals)) assert.ok(count > 0, `${path} never happened`);
});
