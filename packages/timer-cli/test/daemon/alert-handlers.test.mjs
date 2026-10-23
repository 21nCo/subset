import assert from 'node:assert/strict';
import test from 'node:test';
import { emptyStore, runOperation, transitionsBetween } from '@subset/timer';
import { ACK_TIMEOUT_MS, createAlertHandlers, createFakeClock, createRecordingSink, createScheduler } from '../../src/daemon/index.mjs';
import { eventually, rawRequest, startTestDaemon, subscribe } from './helpers.mjs';

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
