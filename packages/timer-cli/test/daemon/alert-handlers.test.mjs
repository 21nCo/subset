import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, unlinkSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { join } from 'node:path';
import test from 'node:test';
import { emptyStore, runOperation, transitionsBetween } from '@subset/timer';
import { ACK_TIMEOUT_MS, MAX_UNRECEIVED, ORPHANED_ALERT_MS, SETTLED_RETENTION_MS, createAlertHandlers, createFakeClock, createRecordingSink, createScheduler, createStateStore, daemonPaths, socketRequest } from '../../src/daemon/index.mjs';
import { eventually, rawRequest, spawnDaemonProcess, startTestDaemon, subscribe, tempDataDir, within } from './helpers.mjs';

const TABATA_MS = 250_000;

/** Saved acknowledgements by alert and handler, without the alert and timer they also keep. */
const ids = (acknowledged) => acknowledged.map(({ alertId, subscriberId }) => ({ alertId, subscriberId }));

/** Opens an event stream and waits for its subscriber id and first state. */
async function openStream(t, context) {
  const stream = subscribe(context.daemon.paths.socket);
  t.after(stream.close);
  await stream.waitFor((list) => list.length >= 1);
  return stream;
}

const register = (context, subscriberId) => context.call('POST', '/v1/alert-handlers', { subscriberId });
const acknowledge = (context, alertId, subscriberId) => context.call('POST', `/v1/alerts/${alertId}/ack`, { subscriberId });
const received = (context, alertId, subscriberId) => context.call('POST', `/v1/alerts/${alertId}/received`, { subscriberId });
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

test('shutdown resolves closed only once the sink has finished the alerts it played at shutdown', async (t) => {
  let finishPlaying;
  const playing = [];
  const sink = {
    name: 'slow',
    alert(alert, timer) {
      playing.push(timer.name);
      return new Promise((resolve) => {
        finishPlaying = resolve;
      });
    }
  };
  const context = await startTestDaemon(t, { sink });
  const handler = await registeredHandler(t, context);
  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  let closedWith = null;
  context.daemon.shutdown().then((code) => {
    closedWith = code;
  });
  await eventually(() => playing.length === 1 && !existsSync(context.daemon.paths.lock));
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.deepEqual([playing, closedWith], [['Egg'], null]);
  finishPlaying();
  assert.equal(await within(context.daemon.closed), 0);
});

test('shutdown is not held up or failed by a sink that rejects while the log cannot report it', async (t) => {
  const unhandled = [];
  const onUnhandled = (reason) => unhandled.push(reason?.message ?? String(reason));
  process.on('unhandledRejection', onUnhandled);
  t.after(() => process.off('unhandledRejection', onUnhandled));
  const sink = { name: 'broken', alert: () => Promise.reject(new Error('afplay failed')) };
  const log = (message) => {
    if (message.startsWith('alert sink')) throw new Error('log closed');
  };
  const context = await startTestDaemon(t, { sink, log });
  const handler = await registeredHandler(t, context);
  await startCountdown(context);
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const started = Date.now();
  assert.equal(await within(context.daemon.shutdown(), 3_000), 0);
  await new Promise((resolve) => setTimeout(resolve, 50));
  assert.deepEqual([Date.now() - started < 3_000, unhandled], [true, []]);
});

/** A sink whose plays last until `finishAll()`. */
function slowSink() {
  const finishes = [];
  return {
    name: 'slow',
    received: [],
    alert(alert, timer) {
      this.received.push({ alert, timer });
      return new Promise((resolve) => finishes.push(resolve));
    },
    finishAll: () => {
      for (const finish of finishes.splice(0)) finish();
    }
  };
}

/** Shuts the daemon down while its slow sink plays: closed waits until the sink has finished. */
async function assertShutdownWaitsForSink(context) {
  let closedWith = null;
  context.daemon.shutdown().then((code) => {
    closedWith = code;
  });
  await eventually(() => !existsSync(context.daemon.paths.lock));
  await new Promise((resolve) => setTimeout(resolve, 100));
  assert.equal(closedWith, null);
  context.sink.finishAll();
  assert.equal(await within(context.daemon.closed), 0);
}

test('shutdown waits for a handoff the daemon replayed at startup, though scheduler.json no longer holds it', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const handoff = { alertId: 'h1', alert: { timerId: 't_1', kind: 'finish', at: 0 }, timer: { id: 't_1', name: 'Egg', sound: true } };
  writeFileSync(join(dataDir, 'scheduler.json'), JSON.stringify({ version: 1, marks: [], handoffs: [handoff] }));
  const context = await startTestDaemon(t, { dataDir, sink: slowSink() });
  assert.deepEqual(context.sink.received.map(({ timer }) => timer.name), ['Egg']);
  assert.equal(JSON.parse(readFileSync(join(dataDir, 'scheduler.json'), 'utf8')).handoffs, undefined);
  await assertShutdownWaitsForSink(context);
});

test('shutdown waits for an alert the sink plays with no handler registered', async (t) => {
  const context = await startTestDaemon(t, { sink: slowSink() });
  await startCountdown(context);
  context.clock.advance(1_000);
  await eventually(() => context.sink.received.length === 1);
  await assertShutdownWaitsForSink(context);
});

test('stop() waits for every sink play, with or without a handler, and once stopped nothing more plays', async () => {
  const clock = createFakeClock();
  const sink = slowSink();
  let next = 0;
  const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, newId: () => `a${++next}` });
  const timer = { id: 't_1', name: 'Egg', sound: true };
  const alert = (kind) => ({ timerId: 't_1', kind, at: clock.now() });
  handlers.replay([{ alertId: 'h1', alert: alert('finish'), timer }]);
  handlers.deliver(alert('segment'), timer);
  let stopped = false;
  const stopping = handlers.stop().then(() => {
    stopped = true;
  });
  // Once stopped: a replay, an alert with no handler and a handler's timeout all play nothing.
  handlers.replay([{ alertId: 'h2', alert: alert('finish'), timer }]);
  handlers.deliver(alert('tick'), timer);
  handlers.register('s1');
  handlers.deliver(alert('tick'), timer);
  clock.advance(ACK_TIMEOUT_MS);
  await new Promise((resolve) => setImmediate(resolve));
  assert.deepEqual([sink.received.map(({ alert: { kind } }) => kind), stopped], [['finish', 'segment'], false]);
  sink.finishAll();
  await stopping;
  assert.equal(stopped, true);
});

/** Sends an acknowledgement (or another `route` for the alert) whose body arrives only after `beforeBody` has run. */
function acknowledgeLate(socketPath, alertId, subscriberId, beforeBody, route = 'ack') {
  return new Promise((resolve, reject) => {
    const body = JSON.stringify({ subscriberId });
    const outgoing = request(
      { socketPath, method: 'POST', path: `/v1/alerts/${alertId}/${route}`, agent: false, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(body) } },
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

test('a handback or receipt whose body arrives once shutdown has begun gets 503 and the alert stays saved, so the next daemon plays it once', async (t) => {
  let finishPlaying = () => {};
  const sink = {
    name: 'slow',
    received: [],
    alert(alert, timer) {
      this.received.push(timer.name);
      return new Promise((resolve) => {
        finishPlaying = resolve;
      });
    }
  };
  const context = await startTestDaemon(t, { sink });
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  let closed;
  const released = acknowledgeLate(context.daemon.paths.socket, alert.alertId, handler.subscriberId, () => {
    closed = context.daemon.shutdown();
  }, 'release');
  const confirmed = acknowledgeLate(context.daemon.paths.socket, alert.alertId, handler.subscriberId, () => {}, 'received');
  assert.deepEqual([(await released).status, (await confirmed).status], [503, 503]);
  assert.equal(await within(closed), 0);
  assert.deepEqual([sink.received, savedAcknowledged(context)], [[], [{ alertId: alert.alertId, subscriberId: handler.subscriberId }]]);
  finishPlaying();
  // The handler sends its handback again; the next daemon takes it and its sink plays the alert once.
  const next = await startTestDaemon(t, { dataDir: context.dataDir });
  assert.equal((await next.call('POST', `/v1/alerts/${alert.alertId}/release`, { subscriberId: handler.subscriberId })).status, 200);
  assert.deepEqual(next.sink.received.map(({ timer }) => timer.name), ['Egg']);
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
      saved.push([handoffs.map(({ alertId }) => alertId), ids(acknowledged)]);
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
  // in later saves while its outcome is remembered.
  assert.equal(handlers.acknowledge('a2', 's1').ok, true);
  assert.deepEqual(saved, [[['a1'], [{ alertId: 'a2', subscriberId: 's1' }]]]);
  clock.advance(ACK_TIMEOUT_MS);
  assert.deepEqual(sink.received.map(({ alert }) => alert.kind), ['finish']);
  assert.deepEqual(saved.at(-1), [[], [{ alertId: 'a2', subscriberId: 's1' }]]);
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

test(`an acknowledged alert is answered 200 until its handler says it received it; a fallback, until ${SETTLED_RETENTION_MS / 1000} s after the last request`, () => {
  const { clock, handlers } = sequentialHandlers();
  const timer = { id: 't_1', name: 'Egg', sound: true };
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, timer);
  handlers.deliver({ timerId: 't_1', kind: 'tick', at: clock.now() }, timer);
  handlers.deliver({ timerId: 't_1', kind: 'segment', at: clock.now() }, timer);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  clock.advance(ACK_TIMEOUT_MS);
  // A wall clock set forward neither ages nor drops an outcome.
  clock.jump(10 * SETTLED_RETENTION_MS);
  // A fallback is kept while its handler keeps asking, on the monotonic clock.
  for (let request = 0; request < 5; request++) {
    clock.advance(SETTLED_RETENTION_MS - ACK_TIMEOUT_MS);
    assert.equal(handlers.acknowledge('a2', 's1').status, 410);
  }
  clock.advance(SETTLED_RETENTION_MS + 1);
  assert.deepEqual([handlers.acknowledge('a2', 's1').status, handlers.acknowledge('a3', 's1').status], [404, 404]);
  // The handler whose 200 was lost asks again however long it was away, and gets it.
  clock.advance(10 * SETTLED_RETENTION_MS);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  assert.equal(handlers.received('a1', 's2').status, 409);
  assert.deepEqual(handlers.received('a1', 's1'), { ok: true, forgotten: true });
  assert.deepEqual(handlers.received('a1', 's1'), { ok: true, forgotten: false });
  assert.deepEqual([handlers.acknowledge('a1', 's1').status, handlers.checkpoint.acknowledged], [404, []]);
});

test(`however many acknowledged alerts are not yet received, none is forgotten: at ${MAX_UNRECEIVED} the sink plays the next one instead (410)`, (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const stateStore = createStateStore(daemonPaths(dataDir), { log: () => {}, now: () => 0 });
  const save = (checkpoint) => stateStore.saveMarks([], checkpoint);
  const clock = createFakeClock();
  const sink = createRecordingSink();
  let next = 0;
  const handlers = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, save, newId: () => `a${++next}` });
  handlers.register('s1');
  const egg = { id: 't_egg', name: 'Egg', sound: false };
  const interval = { id: 't_2', name: 'Interval', sound: true };
  /** alertId → plays by the handler, which plays only on a 200 it reads. */
  const playedByHandler = new Map();
  handlers.deliver({ timerId: 't_egg', kind: 'finish', at: clock.now() }, egg);
  // The daemon takes Egg's finish, but its 200 is lost: the handler keeps asking every second.
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  // 50 supported timers alert about 99 times a second; for 11 s their acknowledgements are taken
  // and none is received yet, so more are taken than the daemon keeps.
  for (let second = 0; second < 11; second++) {
    for (let index = 0; index < 99; index++) {
      handlers.deliver({ timerId: 't_2', kind: 'tick', at: clock.now() }, interval);
      const alertId = `a${next}`;
      const answer = handlers.acknowledge(alertId, 's1');
      assert.ok(answer.ok || answer.status === 410, JSON.stringify(answer));
      if (answer.ok) playedByHandler.set(alertId, 1);
    }
    clock.advance(1_000);
    assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  }
  // Each tick played exactly once, by the handler or, beyond the limit, by the sink.
  assert.equal(playedByHandler.size + sink.received.length, 11 * 99);
  assert.deepEqual([playedByHandler.size, handlers.checkpoint.acknowledged.length], [MAX_UNRECEIVED - 1, MAX_UNRECEIVED]);
  assert.equal(sink.received.filter(({ timer }) => timer.name === 'Egg').length, 0);
  // Another alert falls back, which saves the checkpoint again; then a daemon that reads it replaces this one.
  handlers.deliver({ timerId: 't_2', kind: 'tick', at: clock.now() }, interval);
  clock.advance(ACK_TIMEOUT_MS);
  const successor = createAlertHandlers({ clock: createFakeClock(), sink: createRecordingSink(), log: () => {}, publish: () => {}, isOpen: () => true, save, ...stateStore.loadAlerts() });
  assert.equal(successor.checkpoint.acknowledged.length, MAX_UNRECEIVED);
  // Egg's retry still gets its 200, so the handler plays it once and no sink does.
  if (successor.acknowledge('a1', 's1').ok) playedByHandler.set('a1', 1);
  assert.deepEqual([playedByHandler.get('a1'), sink.received.filter(({ timer }) => timer.name === 'Egg').length, successor.status.fallbacks], [1, 0, 0]);
  // Once the handler says it received it, there is room for one more.
  assert.equal(successor.received('a1', 's1').forgotten, true);
  successor.register('s1');
  successor.deliver({ timerId: 't_egg', kind: 'finish', at: 0 }, egg);
  assert.equal(successor.checkpoint.handoffs.length, 1);
  assert.equal(successor.acknowledge(successor.checkpoint.handoffs[0].alertId, 's1').ok, true);
});

test('a handler hands back an alert it may no longer present, pending or taken, and the sink plays it once', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const saved = [];
  let next = 0;
  let held = true;
  const handlers = createAlertHandlers({
    clock,
    sink,
    log: () => {},
    publish: () => {},
    isOpen: () => true,
    owns: () => held,
    save: ({ handoffs, acknowledged }) => saved.push([handoffs.map(({ alertId }) => alertId), ids(acknowledged)]),
    newId: () => `a${++next}`
  });
  handlers.register('s1');
  const timer = { id: 't_1', name: 'Egg', sound: false };
  for (const kind of ['finish', 'tick', 'segment']) handlers.deliver({ timerId: 't_1', kind, at: clock.now() }, timer);
  assert.equal(handlers.acknowledge('a2', 's1').ok, true);
  assert.equal(handlers.acknowledge('a3', 's1').ok, true);
  // Pending a1 and taken a2 are handed back: the sink plays each at once, and the next save drops a2.
  assert.deepEqual([handlers.release('a1', 's2').status, handlers.release('a9', 's1').status], [409, 404]);
  assert.deepEqual([handlers.release('a1', 's1'), handlers.release('a2', 's1')], [{ ok: true }, { ok: true }]);
  assert.deepEqual(sink.received.map(({ alert }) => alert.kind), ['finish', 'tick']);
  assert.deepEqual(saved.at(-1), [[], [{ alertId: 'a3', subscriberId: 's1' }]]);
  // Asking again, or acknowledging it, gets 410: the sink played it, so the handler does not.
  assert.deepEqual(['a1', 'a2'].flatMap((alertId) => [handlers.release(alertId, 's1').status, handlers.acknowledge(alertId, 's1').status]), [410, 410, 410, 410]);
  clock.advance(ACK_TIMEOUT_MS);
  assert.equal(sink.received.length, 2);
  // A daemon that lost daemon.lock plays nothing and answers 503, so the handler asks the one that holds it.
  held = false;
  assert.equal(handlers.release('a3', 's1').status, 503);
  assert.equal(sink.received.length, 2);
  const successor = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true, acknowledged: [{ alertId: 'a3', subscriberId: 's1', alert: { timerId: 't_1', kind: 'segment', at: 0 }, timer }] });
  assert.equal(successor.release('a3', 's1').ok, true);
  assert.deepEqual([sink.received.map(({ alert }) => alert.kind), successor.checkpoint.acknowledged], [['finish', 'tick', 'segment'], []]);
});

test('a taken alert handed back is saved as a handoff before the sink plays it; one whose save fails stays taken and plays nothing', () => {
  const clock = createFakeClock();
  const sink = createRecordingSink();
  const saved = [];
  let failNext = false;
  let next = 0;
  const handlers = createAlertHandlers({
    clock,
    sink,
    log: () => {},
    publish: () => {},
    isOpen: () => true,
    newId: () => `a${++next}`,
    save({ handoffs, acknowledged }) {
      if (failNext) {
        failNext = false;
        throw new Error('disk full');
      }
      saved.push({ handoffs: handoffs.map(({ alertId }) => alertId), acknowledged: ids(acknowledged), played: sink.received.length });
    }
  });
  handlers.register('s1');
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, { id: 't_1', name: 'Egg', sound: false });
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  failNext = true;
  assert.throws(() => handlers.release('a1', 's1'), /disk full/);
  assert.deepEqual([sink.received.length, handlers.status.pending, ids(handlers.checkpoint.acknowledged)], [0, 0, [{ alertId: 'a1', subscriberId: 's1' }]]);
  clock.advance(ACK_TIMEOUT_MS);
  assert.equal(sink.received.length, 0);
  // The handler sends it again: saved as a handoff first, then played once, then left out.
  assert.deepEqual(handlers.release('a1', 's1'), { ok: true });
  assert.deepEqual(saved.slice(-2), [
    { handoffs: ['a1'], acknowledged: [], played: 0 },
    { handoffs: [], acknowledged: [], played: 1 }
  ]);
  // A daemon that ended after the first of those starts with no acknowledgement for it, so a retried handback gets 404.
  const successor = createAlertHandlers({ clock, sink, log: () => {}, publish: () => {}, isOpen: () => true });
  assert.equal(successor.release('a1', 's1').status, 404);
  assert.equal(sink.received.length, 1);
});

test('once stopped, the handlers hand nothing more to the sink: a handback gets 503 and the alert stays taken', () => {
  const { clock, sink, handlers } = sequentialHandlers();
  const timer = { id: 't_1', name: 'Egg', sound: false };
  for (const kind of ['finish', 'tick']) handlers.deliver({ timerId: 't_1', kind, at: clock.now() }, timer);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  handlers.stop();
  assert.deepEqual(sink.received.map(({ alert }) => alert.kind), ['tick']);
  assert.equal(handlers.release('a1', 's1').status, 503);
  assert.deepEqual([sink.received.length, ids(handlers.checkpoint.acknowledged)], [1, [{ alertId: 'a1', subscriberId: 's1' }]]);
});

test('a handback whose save fails gets 500 and plays nothing, so the handler that sends it again to the next daemon hears the alert once', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  const scheduler = join(context.dataDir, 'scheduler.json');
  const lastSaved = readFileSync(scheduler);
  // Each save of scheduler.json fails from now on: a directory is where the new file is renamed to.
  unlinkSync(scheduler);
  mkdirSync(join(scheduler, 'in-the-way'), { recursive: true });
  const release = (target) => target.call('POST', `/v1/alerts/${alert.alertId}/release`, { subscriberId: handler.subscriberId });
  assert.equal((await release(context)).status, 500);
  // The daemon is killed before the handler hears back; the next one starts from the files as they are.
  const next = tempDataDir(t);
  mkdirSync(next, { recursive: true });
  writeFileSync(join(next, 'state.json'), readFileSync(join(context.dataDir, 'state.json')));
  writeFileSync(join(next, 'scheduler.json'), lastSaved);
  const successor = await startTestDaemon(t, { dataDir: next });
  assert.equal((await release(successor)).status, 200);
  successor.clock.advance(60_000);
  const plays = [context, successor].flatMap(({ sink }) => sink.received).filter(({ timer }) => timer.name === 'Egg').length;
  assert.equal(plays, 1);
});

test('a handback whose save after the play fails still gets 200, and the next run saves it, so the next daemon plays nothing', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  // The handoff is saved before the play; while the sink plays, scheduler.json becomes unwritable.
  const scheduler = join(context.dataDir, 'scheduler.json');
  const play = context.sink.alert.bind(context.sink);
  context.sink.alert = (...args) => {
    play(...args);
    renameSync(scheduler, `${scheduler}.saved`);
    mkdirSync(join(scheduler, 'in-the-way'), { recursive: true });
  };
  const release = (target) => target.call('POST', `/v1/alerts/${alert.alertId}/release`, { subscriberId: handler.subscriberId });
  assert.equal((await release(context)).status, 200);
  assert.equal(JSON.parse(readFileSync(`${scheduler}.saved`, 'utf8')).handoffs.length, 1);
  // Once it can be written again, the next run saves it without the handoff.
  rmSync(scheduler, { recursive: true });
  renameSync(`${scheduler}.saved`, scheduler);
  context.clock.advance(60_000);
  await eventually(() => JSON.parse(readFileSync(scheduler, 'utf8')).handoffs === undefined);
  const successor = await startTestDaemon(t, { dataDir: filesLeftByKill(t, context) });
  assert.equal((await release(successor)).status, 404);
  assert.deepEqual([context.sink.received.length, successor.sink.received.length], [1, 0]);
});

test(`a daemon answers 200 for the acknowledgements an earlier daemon saved, only for their handler, and plays those not received within ${ORPHANED_ALERT_MS / 1000} s`, () => {
  const earlier = { alertId: 'a1', subscriberId: 's1', alert: { timerId: 't_1', kind: 'finish', at: 0 }, timer: { id: 't_1', name: 'Egg', sound: false } };
  const unclaimed = { ...earlier, alertId: 'a2', alert: { timerId: 't_1', kind: 'tick', at: 0 } };
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
    acknowledged: [earlier, unclaimed]
  });
  assert.deepEqual(handlers.checkpoint, { handoffs: [], acknowledged: [earlier, unclaimed] });
  assert.equal(handlers.acknowledge('a1', 's2').status, 409);
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  // Answering it does not drop it: the handler may never have read that 200.
  clock.advance(ORPHANED_ALERT_MS - 1);
  assert.deepEqual(handlers.checkpoint.acknowledged, [earlier, unclaimed]);
  assert.equal(handlers.received('a1', 's1').ok, true);
  assert.deepEqual(handlers.checkpoint.acknowledged, [unclaimed]);
  assert.equal(handlers.acknowledge('a1', 's1').status, 404);
  assert.deepEqual([saved, sink.received.length], [[], 0]);
  // No handler said it received the other, so its app ended before playing it: the sink plays it, once.
  clock.advance(1);
  assert.deepEqual(sink.received.map(({ alert }) => alert.kind), ['tick']);
  assert.deepEqual(saved, [{ handoffs: [], acknowledged: [] }]);
  assert.equal(handlers.acknowledge('a2', 's1').status, 410);
  clock.advance(ORPHANED_ALERT_MS);
  assert.equal(sink.received.length, 1);
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
  assert.deepEqual(ids(saved.acknowledged ?? []), acknowledgeFirst ? [{ alertId: alert.alertId, subscriberId: stream.subscriberId }] : []);
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
  next.clock.advance(ORPHANED_ALERT_MS - 1_000);
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 200);
  // It played the alert and says so, so the sink never plays it.
  assert.deepEqual((await received(next, alertId, subscriberId)).body, { alertId, forgotten: true });
  next.clock.advance(SETTLED_RETENTION_MS + 1_000);
  assert.equal(next.sink.received.length, 0);
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 404);
});

test(`an alert acknowledged before the daemon was killed, whose handler never asks the next daemon, is played by it once after ${ORPHANED_ALERT_MS / 1000} s`, async (t) => {
  const { dataDir, alertId, subscriberId } = await killDaemonDuringHandoff(t, { acknowledgeFirst: true });
  const next = await startTestDaemon(t, { dataDir });
  next.clock.advance(ORPHANED_ALERT_MS - 1);
  assert.equal(next.sink.received.length, 0);
  next.clock.advance(1);
  assert.deepEqual(next.sink.received.map(({ alert, timer }) => [alert.kind, timer.name]), [['finish', 'Egg']]);
  // An app that asks after all is told not to play it, and the alert is saved as played.
  assert.equal((await acknowledge(next, alertId, subscriberId)).status, 410);
  await next.daemon.shutdown();
  const after = await startTestDaemon(t, { dataDir });
  after.clock.advance(2 * ORPHANED_ALERT_MS);
  assert.equal(after.sink.received.length, 0);
});

/** Copies the daemon's files as they are now into a new data directory, as a daemon killed now leaves them. */
function filesLeftByKill(t, context) {
  const next = tempDataDir(t);
  mkdirSync(next, { recursive: true });
  for (const name of ['state.json', 'scheduler.json']) writeFileSync(join(next, name), readFileSync(join(context.dataDir, name)));
  return next;
}

const savedAcknowledged = (context) => ids(JSON.parse(readFileSync(join(context.dataDir, 'scheduler.json'), 'utf8')).acknowledged ?? []);

test('an acknowledgement stays saved after its 200 is written, so a handler that never read it gets 200 from the next daemon', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  // The daemon writes the 200; whether the handler reads it, the daemon cannot tell.
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  // Another timer's start saves scheduler.json again before the daemon is killed.
  await startCountdown(context, 'Tea');
  context.clock.advance(500);
  await eventually(() => JSON.parse(readFileSync(join(context.dataDir, 'scheduler.json'), 'utf8')).marks.length === 1);
  assert.deepEqual(savedAcknowledged(context), [{ alertId: alert.alertId, subscriberId: handler.subscriberId }]);
  const next = await startTestDaemon(t, { dataDir: filesLeftByKill(t, context) });
  let playedByHandler = 0;
  if ((await acknowledge(next, alert.alertId, handler.subscriberId)).status === 200) playedByHandler += 1;
  assert.equal((await received(next, alert.alertId, handler.subscriberId)).status, 200);
  next.clock.advance(60_000);
  assert.deepEqual([playedByHandler, next.sink.received.filter(({ timer }) => timer.name === 'Egg').length], [1, 0]);
});

test(`a daemon whose saved acknowledgements reach ${MAX_UNRECEIVED} has its sink play the next alert, and keeps answering them, also after a restart`, async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  // An earlier daemon left that many acknowledgements whose handler never said it received the 200.
  const timer = { id: 't_old', name: 'Old', sound: false };
  const acknowledged = Array.from({ length: MAX_UNRECEIVED }, (_, index) => ({ alertId: `old${index}`, subscriberId: 'gone', alert: { timerId: 't_old', kind: 'tick', at: 0 }, timer }));
  writeFileSync(join(dataDir, 'scheduler.json'), JSON.stringify({ version: 1, marks: [], acknowledged }));
  const context = await startTestDaemon(t, { dataDir });
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  // Not taken: the sink plays it at once and the handler, told 410, does not.
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 410);
  assert.equal(context.sink.received.filter(({ timer: { name } }) => name === 'Egg').length, 1);
  assert.equal((await acknowledge(context, 'old0', 'gone')).status, 200);
  // Once one is received there is room again.
  assert.equal((await received(context, 'old0', 'gone')).status, 200);
  await startCountdown(context, 'Tea');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 2);
  const tea = alertsOf(handler)[1].alertId;
  assert.equal((await acknowledge(context, tea, handler.subscriberId)).status, 200);
  // The daemon is killed; the next one still answers the old acknowledgements and the one taken before.
  const next = await startTestDaemon(t, { dataDir: filesLeftByKill(t, context) });
  assert.deepEqual([(await acknowledge(next, 'old1', 'gone')).status, (await acknowledge(next, tea, handler.subscriberId)).status], [200, 200]);
  assert.deepEqual((await next.call('POST', `/v1/alerts/${tea}/release`, { subscriberId: handler.subscriberId })).body, { alertId: tea, released: true });
  assert.equal((await acknowledge(next, tea, handler.subscriberId)).status, 410);
  const plays = (name) => [context, next].flatMap(({ sink }) => sink.received).filter(({ timer: played }) => played.name === name).length;
  assert.deepEqual([plays('Egg'), plays('Tea'), plays('Old')], [1, 1, 0]);
});

/** Starts another countdown, so the daemon saves scheduler.json again, and waits for that save. */
async function saveAgain(context, name) {
  const id = await startCountdown(context, name);
  await eventually(() => JSON.parse(readFileSync(join(context.dataDir, 'scheduler.json'), 'utf8')).marks.some(({ timerId }) => timerId === id));
}

test(`an acknowledgement whose 200 was lost stays saved until its handler says it received it, however long that takes while it is the handler, and ${ORPHANED_ALERT_MS / 1000} s after`, async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  // The 200 is written but never reaches the handler, which then asks nothing for over a minute.
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  context.clock.advance(SETTLED_RETENTION_MS + 1_000);
  await saveAgain(context, 'Tea');
  const owned = [{ alertId: alert.alertId, subscriberId: handler.subscriberId }];
  assert.deepEqual(savedAcknowledged(context), owned);
  const next = await startTestDaemon(t, { dataDir: filesLeftByKill(t, context) });
  next.clock.advance(ORPHANED_ALERT_MS - 1_000);
  let playedByHandler = 0;
  if ((await acknowledge(next, alert.alertId, handler.subscriberId)).status === 200) playedByHandler += 1;
  const sinkPlays = [context, next].flatMap(({ sink }) => sink.received).filter(({ timer }) => timer.name === 'Egg').length;
  assert.deepEqual([playedByHandler, sinkPlays], [1, 0]);
  // Once the handler says it received the 200, the next save leaves it out.
  assert.equal((await received(next, alert.alertId, handler.subscriberId)).status, 200);
  await saveAgain(next, 'Rice');
  assert.deepEqual(savedAcknowledged(next), []);
  const after = await startTestDaemon(t, { dataDir: filesLeftByKill(t, next) });
  assert.equal((await acknowledge(after, alert.alertId, handler.subscriberId)).status, 404);
});

test('a handler whose stream reconnects gets the 200 it lost when it asks with the stream the alert was handed to', async (t) => {
  const context = await startTestDaemon(t);
  const handler = await registeredHandler(t, context);
  await startCountdown(context, 'Egg');
  context.clock.advance(1_000);
  await handler.waitFor(() => alertsOf(handler).length === 1);
  const [alert] = alertsOf(handler);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  handler.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  const again = await registeredHandler(t, context);
  context.clock.advance(ORPHANED_ALERT_MS - 1_000);
  await saveAgain(context, 'Tea');
  assert.equal((await acknowledge(context, alert.alertId, again.subscriberId)).status, 409);
  assert.equal((await acknowledge(context, alert.alertId, handler.subscriberId)).status, 200);
  assert.equal((await received(context, alert.alertId, again.subscriberId)).status, 409);
  assert.equal((await received(context, alert.alertId, handler.subscriberId)).status, 200);
  // It played the alert and said so, so the sink does not play it once the old stream has been gone a while.
  context.clock.advance(ORPHANED_ALERT_MS);
  assert.equal(context.sink.received.filter(({ timer }) => timer.name === 'Egg').length, 0);
});

/**
 * An alert handler app in its own process: it registers its event stream and acknowledges the
 * first alert, reading the answer when `mode` is `taken`, then prints what it did and waits.
 */
const HANDLER_APP = `
import { request } from 'node:http';
const [socketPath, mode] = process.argv.slice(1);
const post = (path, body, read) => new Promise((resolve) => {
  const outgoing = request({ socketPath, method: 'POST', path, agent: false }, (response) => {
    response.resume();
    response.on('end', () => resolve(response.statusCode));
  });
  outgoing.on('error', () => resolve(0));
  outgoing.end(JSON.stringify(body), () => read || resolve('sent'));
});
let buffer = '';
let subscriberId;
let acknowledged = false;
request({ socketPath, method: 'GET', path: '/v1/events', agent: false }, (response) => {
  response.setEncoding('utf8');
  response.on('data', async (chunk) => {
    buffer += chunk;
    for (let end; (end = buffer.indexOf('\\n\\n')) >= 0; buffer = buffer.slice(end + 2)) {
      const block = buffer.slice(0, end);
      const event = /^event: (.*)$/m.exec(block)[1];
      const data = JSON.parse(/^data: (.*)$/m.exec(block)[1]);
      if (event === 'subscriber') {
        subscriberId = data.subscriberId;
        console.log('registered', subscriberId, await post('/v1/alert-handlers', { subscriberId }, true));
      } else if (event === 'alert' && data.alertId && !acknowledged) {
        acknowledged = true;
        console.log('ack', data.alertId, await post(\`/v1/alerts/\${data.alertId}/ack\`, { subscriberId }, mode === 'taken'));
      }
    }
  });
}).end();
setInterval(() => {}, 1_000);
`;

for (const mode of ['taken', 'sent']) {
  test(`an app killed after its acknowledgement is ${mode}, before playing, leaves the alert to the running daemon, whose sink plays it once`, async (t) => {
    const context = await startTestDaemon(t);
    const app = spawn(process.execPath, ['--input-type=module', '-e', HANDLER_APP, context.daemon.paths.socket, mode], { stdio: ['ignore', 'pipe', 'inherit'] });
    const exited = new Promise((resolve) => app.once('exit', resolve));
    t.after(() => app.kill('SIGKILL'));
    let output = '';
    app.stdout.setEncoding('utf8').on('data', (chunk) => {
      output += chunk;
    });
    const line = (word) => output.split('\n').find((entry) => entry.startsWith(`${word} `))?.split(' ');
    await eventually(() => line('registered'), 10_000);
    const [, subscriberId, registered] = line('registered');
    assert.equal(registered, '200');
    await startCountdown(context, 'Egg');
    context.clock.advance(1_000);
    await eventually(() => line('ack'), 10_000);
    const [, alertId, answer] = line('ack');
    if (mode === 'taken') assert.equal(answer, '200');
    app.kill('SIGKILL');
    await exited;
    await eventually(() => context.daemon.alertHandler.registered === false);
    const eggPlays = () => context.sink.received.filter(({ timer }) => timer.name === 'Egg').length;
    context.clock.advance(ORPHANED_ALERT_MS);
    await eventually(() => eggPlays() === 1);
    // An app that still asked would be told not to play it.
    assert.equal((await acknowledge(context, alertId, subscriberId)).status, 410);
    assert.equal((await received(context, alertId, subscriberId)).status, 200);
    context.clock.advance(ORPHANED_ALERT_MS);
    assert.equal(eggPlays(), 1);
  });
}

test('a daemon that stops before a former handler\'s alerts are orphaned plays none of them; they stay saved for the next daemon', () => {
  const { clock, sink, handlers } = sequentialHandlers();
  handlers.deliver({ timerId: 't_1', kind: 'finish', at: clock.now() }, { id: 't_1', name: 'Egg', sound: true });
  assert.equal(handlers.acknowledge('a1', 's1').ok, true);
  handlers.disconnected('s1');
  handlers.stop();
  clock.advance(ORPHANED_ALERT_MS);
  assert.deepEqual([sink.received.length, ids(handlers.checkpoint.acknowledged)], [0, [{ alertId: 'a1', subscriberId: 's1' }]]);
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
  const outcomes = { acknowledged: 0, expired: 0, refused: 0, ended: 0 };
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
      // The handler plays only what the daemon handed it, and then says it received it; some apps
      // end before playing it, which closes their stream.
      if (result.ok && random() < 0.05) {
        open.delete(ack.subscriberId);
        handlers.disconnected(ack.subscriberId);
        outcomes.ended += 1;
      } else if (result.ok) {
        playedByHandler.push(ack.key);
        handlers.received(ack.alertId, ack.subscriberId);
        outcomes.acknowledged += 1;
      } else if (result.status === 410) outcomes.expired += 1;
      else outcomes.refused += 1;
    }
    clock.advance(100);
  }
  clock.advance(ORPHANED_ALERT_MS);
  scheduler.stop();
  const expected = transitionsBetween(timer, startedAt, startedAt + TABATA_MS).map((transition) => `${timer.definition.id}:${transition.type}:${transition.at}`);
  return { expected, published, playedBySink: sink.received.map(({ alert }) => keyOf(alert)), playedByHandler, outcomes, status: handlers.status };
}

test('a seeded random sequence of registrations, disconnects, acknowledgement times and apps that end before playing across a Tabata run delivers each alert exactly once', () => {
  const totals = { acknowledged: 0, expired: 0, ended: 0, fallbacks: 0, direct: 0 };
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
    totals.ended += run.outcomes.ended;
    totals.fallbacks += run.status.fallbacks;
    totals.direct += run.published.filter(({ handler }) => handler === null).length;
  }
  // The seeds cover every path: handled, fallen back, refused late, taken by an app that ended, and played with no handler.
  for (const [path, count] of Object.entries(totals)) assert.ok(count > 0, `${path} never happened`);
});
