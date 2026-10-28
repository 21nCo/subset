import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import test from 'node:test';
import { createMacosSink } from '../../src/alerts/index.mjs';
import { OSASCRIPT } from '../../src/alerts/macos.mjs';
import { ACK_TIMEOUT_MS, ORPHANED_ALERT_MS, createFakeClock, createPlayJournal } from '../../src/daemon/index.mjs';
import { eventually, startTestDaemon, subscribe, tempDataDir } from './helpers.mjs';

/**
 * A `spawn` for the macOS sink that records what each process plays (`notification` or the sound's
 * name) and exits it 0 on the next tick, except those `hold(started)` picks, which run until
 * `release()`: a sound cut off by a crash.
 */
function partSpawn({ hold = () => false } = {}) {
  const started = [];
  const held = [];
  const spawn = (command, args) => {
    const child = new EventEmitter();
    child.kill = () => {};
    started.push(command === OSASCRIPT ? 'notification' : basename(args[0], '.aiff'));
    const exit = () => child.emit('exit', 0, null);
    if (hold(started)) held.push(exit);
    else setImmediate(exit);
    return child;
  };
  return { spawn, started, release: () => held.splice(0).forEach((exit) => exit()) };
}

/** Holds the second Glass: the notification and the first Glass finish, and the crash cuts the second off. */
const holdSecondGlass = (started) => started.filter((what) => what === 'Glass').length === 2;

const call = (context, path, body) => context.call('POST', path, body);
const alertsOf = (stream) => stream.events.filter(({ event }) => event === 'alert').map(({ data }) => data);
const plays = (dataDir) => (existsSync(join(dataDir, 'plays.json')) ? JSON.parse(readFileSync(join(dataDir, 'plays.json'), 'utf8')).plays : []);
const scheduler = (dataDir) => JSON.parse(readFileSync(join(dataDir, 'scheduler.json'), 'utf8'));

/** A daemon with the macOS sink on `spawner`, with a registered handler when `handler` is true. */
async function daemonWithSink(t, spawner, { handler = false } = {}) {
  const context = await startTestDaemon(t, { sink: createMacosSink({ spawn: spawner.spawn }) });
  if (!handler) return { context };
  const stream = subscribe(context.daemon.paths.socket);
  t.after(stream.close);
  await stream.waitFor((list) => list.length >= 1);
  assert.equal((await call(context, '/v1/alert-handlers', { subscriberId: stream.subscriberId })).status, 200);
  return { context, stream };
}

/** Starts a one-second countdown named Egg, with sound, and runs it to its finish. */
async function finishCountdown(context) {
  const started = await context.op('start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg' } });
  assert.equal(started.status, 200);
  context.clock.advance(1_000);
  return started.body.timer.definition.id;
}

/** Makes every later save of scheduler.json fail, keeping the last saved one as `scheduler.json.saved`. */
function breakScheduler(context) {
  const path = join(context.dataDir, 'scheduler.json');
  renameSync(path, `${path}.saved`);
  mkdirSync(join(path, 'in-the-way'), { recursive: true });
}

/**
 * The files a daemon killed now leaves, in a new data directory: `state.json`, the last
 * `scheduler.json` it saved and `plays.json`.
 */
function filesLeftByKill(t, context) {
  const next = tempDataDir(t);
  mkdirSync(next, { recursive: true });
  const saved = join(context.dataDir, 'scheduler.json.saved');
  writeFileSync(join(next, 'scheduler.json'), readFileSync(existsSync(saved) ? saved : join(context.dataDir, 'scheduler.json')));
  for (const name of ['state.json', 'plays.json']) {
    if (existsSync(join(context.dataDir, name))) writeFileSync(join(next, name), readFileSync(join(context.dataDir, name)));
  }
  return next;
}

/** The next daemon, on the files `context` left, at the time it was killed, with its own macOS sink. */
async function successorOf(t, context, spawner = partSpawn()) {
  const next = await startTestDaemon(t, { dataDir: filesLeftByKill(t, context), clock: createFakeClock(context.clock.now()), sink: createMacosSink({ spawn: spawner.spawn }) });
  return { next, spawner };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 50));

for (const crash of ['after the play', 'mid-play']) {
  test(`a handback whose save after the play fails, then a daemon crash ${crash}, is delivered once: the next daemon plays only what had not finished`, async (t) => {
    const spawner = partSpawn({ hold: crash === 'mid-play' ? holdSecondGlass : () => false });
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    await stream.waitFor(() => alertsOf(stream).length === 1);
    const [{ alertId }] = alertsOf(stream);
    const subscriberId = stream.subscriberId;
    assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
    // The handoff is saved before the play; once the sink has started, scheduler.json can no longer be written.
    const play = context.sink.alert.bind(context.sink);
    context.sink.alert = (...args) => {
      const playing = play(...args);
      breakScheduler(context);
      return playing;
    };
    assert.equal((await call(context, `/v1/alerts/${alertId}/release`, { subscriberId })).status, 200);
    const expected = crash === 'mid-play' ? ['Glass', 'notification', 'Glass'] : ['Glass', 'notification', 'Glass', 'Glass'];
    await eventually(() => spawner.started.length === expected.length && plays(context.dataDir)[0]?.played.length === expected.length - (crash === 'mid-play' ? 1 : 0));
    assert.deepEqual(spawner.started, expected);
    assert.equal(scheduler(filesLeftByKill(t, context)).handoffs.length, 1);
    assert.equal(plays(context.dataDir)[0].finished, crash !== 'mid-play');

    const { next, spawner: after } = await successorOf(t, context);
    await settle();
    // Each part plays once across both daemons: the cut-off Glass plays again, the notification does not.
    assert.deepEqual(after.started, crash === 'mid-play' ? ['Glass', 'Glass'] : []);
    // The handler, asking the next daemon, is told the sink played it.
    assert.equal((await call(next, `/v1/alerts/${alertId}/release`, { subscriberId })).status, 410);
    await eventually(() => plays(next.dataDir).length === 0);
    assert.equal(scheduler(next.dataDir).handoffs, undefined);
    spawner.release();
  });
}

test('a daemon crash mid-play of a fallback leaves the rest of the alert to the next daemon, without the notification it showed', async (t) => {
  const spawner = partSpawn({ hold: holdSecondGlass });
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  await stream.waitFor(() => alertsOf(stream).length === 1);
  // Not acknowledged in time: the sink plays it, and scheduler.json is saved without the handoff at once.
  context.clock.advance(ACK_TIMEOUT_MS);
  await eventually(() => spawner.started.length === 3 && plays(context.dataDir)[0]?.played.length === 2);
  assert.equal(scheduler(context.dataDir).handoffs, undefined);
  assert.deepEqual(plays(context.dataDir)[0].played.sort(), ['notification', 'sound:0']);

  const { spawner: after } = await successorOf(t, context);
  await eventually(() => after.started.length === 2);
  await settle();
  assert.deepEqual(after.started, ['Glass', 'Glass']);
  spawner.release();
});

test('with no handler, a finish whose marks could not be saved before a daemon crash is not played again by the next daemon', async (t) => {
  const spawner = partSpawn();
  const { context } = await daemonWithSink(t, spawner);
  const started = await context.op('start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg' } });
  breakScheduler(context);
  context.clock.advance(1_000);
  await eventually(() => plays(context.dataDir)[0]?.finished === true);
  assert.deepEqual(spawner.started, ['Glass', 'notification', 'Glass', 'Glass']);
  // The saved marks are behind the finish, and the timer is still running on disk.
  assert.equal(JSON.parse(readFileSync(join(context.dataDir, 'state.json'), 'utf8')).timers[0].runtime.status, 'running');

  const { next, spawner: after } = await successorOf(t, context);
  next.clock.advance(60_000);
  await settle();
  assert.deepEqual(after.started, []);
  const id = started.body.timer.definition.id;
  assert.equal((await next.call('GET', '/v1/timers')).body.structuredContent.timers.find((timer) => timer.definition.id === id).runtime.status, 'finished');
  await eventually(() => plays(next.dataDir).length === 0);
});

test('an app that ends after starting some parts of an alert, before its receipt is recorded, has only the others played by the sink, also by the next daemon', async (t) => {
  for (const restart of [false, true]) {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    await stream.waitFor(() => alertsOf(stream).length === 1);
    const [{ alertId }] = alertsOf(stream);
    const subscriberId = stream.subscriberId;
    assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
    // The app says so before it plays each part; a part said twice is recorded once.
    for (const part of ['notification', 'sound:0', 'sound:0']) {
      assert.deepEqual((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part })).body, { alertId, part, playing: true });
    }
    assert.deepEqual(scheduler(context.dataDir).acknowledged[0].played, ['notification', 'sound:0']);
    // The app ends while playing the first Glass, before saying it received the alert.
    stream.close();
    await eventually(() => context.daemon.alertHandler.registered === false);
    let sink = { context, spawner };
    if (restart) {
      const { next, spawner: after } = await successorOf(t, context);
      sink = { context: next, spawner: after };
    }
    sink.context.clock.advance(ORPHANED_ALERT_MS);
    await eventually(() => sink.spawner.started.length === 2);
    await settle();
    assert.deepEqual(sink.spawner.started, ['Glass', 'Glass'], `restart ${restart}`);
    assert.equal((await call(sink.context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 410);
    if (restart) assert.deepEqual(spawner.started, []);
  }
});

test('an app that ends after starting every part of an alert, before its receipt is recorded, has it played once: the sink plays nothing', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [{ alertId }] = alertsOf(stream);
  const subscriberId = stream.subscriberId;
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
  for (const part of ['notification', 'sound:0', 'sound:1', 'sound:2']) assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part })).status, 200);
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  context.clock.advance(ORPHANED_ALERT_MS);
  await settle();
  assert.deepEqual(spawner.started, []);
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 410);
  assert.equal(scheduler(context.dataDir).acknowledged, undefined);
});

test('a part is refused unless the alert is the asker\'s and taken, and one whose save fails is not recorded, so the sink plays it', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [{ alertId }] = alertsOf(stream);
  const subscriberId = stream.subscriberId;
  const playing = async (body, id = alertId) => {
    const reply = await call(context, `/v1/alerts/${id}/playing`, body);
    return [reply.status, reply.body.error?.code];
  };
  assert.deepEqual(await playing({ subscriberId, part: 'sound:0' }), [409, 'invalid_state']);
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
  for (const part of [undefined, 'sound', 'sound:-1', 'sound:100', 'Glass', '../notification']) assert.deepEqual(await playing({ subscriberId, part }), [400, 'invalid_input'], String(part));
  assert.deepEqual(await playing({ subscriberId: 'another stream', part: 'sound:0' }), [409, 'not_alert_handler']);
  assert.deepEqual(await playing({ subscriberId, part: 'sound:0' }, 'f'.repeat(32)), [404, 'not_found']);
  // A failed save gets 500 and records nothing.
  breakScheduler(context);
  assert.deepEqual(await playing({ subscriberId, part: 'notification' }), [500, 'storage_failed']);
  const path = join(context.dataDir, 'scheduler.json');
  rmSync(path, { recursive: true });
  renameSync(`${path}.saved`, path);
  assert.equal(scheduler(context.dataDir).acknowledged[0].played, undefined);
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  context.clock.advance(ORPHANED_ALERT_MS);
  await eventually(() => spawner.started.length === 4);
  // Once the sink has played it, the app is told so, and plays nothing more of it.
  assert.deepEqual(await playing({ subscriberId, part: 'sound:1' }), [410, 'alert_expired']);
});

test('a journal write that fails is logged and kept, so the next write records it; an entry is dropped once finished and saved', () => {
  const writes = [];
  const logs = [];
  let failing = true;
  const journal = createPlayJournal({
    log: (message) => logs.push(message),
    persist(entries) {
      if (failing) throw new Error('disk full');
      writes.push(entries.map(({ alertId, played, finished }) => ({ alertId, played, finished })));
    }
  });
  const alert = { timerId: 't_1', kind: 'finish', at: 0 };
  journal.begin('a1', { alert, timer: { id: 't_1', name: 'Egg' }, keys: ['t_1:finish:0'] });
  assert.deepEqual([logs, writes], [['could not save plays.json: disk full'], []]);
  failing = false;
  journal.done('a1', 'notification');
  assert.deepEqual(writes, [[{ alertId: 'a1', played: ['notification'], finished: false }]]);
  assert.equal(journal.delivered('t_1:finish:0'), true);
  // Finished, but scheduler.json has not been saved since it began: kept, so its keys still count.
  journal.finish('a1');
  assert.deepEqual([writes.at(-1), journal.has('a1')], [[{ alertId: 'a1', played: ['notification'], finished: true }], true]);
  journal.saved();
  assert.deepEqual([writes.at(-1), journal.has('a1'), journal.delivered('t_1:finish:0')], [[], false, false]);
  // One saved over while it plays is dropped as soon as it finishes.
  journal.begin('a2', { alert, timer: { id: 't_1', name: 'Egg' } });
  journal.saved();
  assert.equal(journal.has('a2'), true);
  journal.finish('a2');
  assert.deepEqual([writes.at(-1), journal.has('a2')], [[], false]);
});
