import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { spawn as nodeSpawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, unlinkSync, writeFileSync } from 'node:fs';
import { request } from 'node:http';
import { basename, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createMacosSink } from '../../src/alerts/index.mjs';
import { OSASCRIPT } from '../../src/alerts/macos.mjs';
import {
  ACK_TIMEOUT_MS,
  LEFT_PROCESS_WAIT_MS,
  ORPHANED_ALERT_MS,
  SETTLED_RETENTION_MS,
  createAlertHandlers,
  createFakeClock,
  createPlayJournal,
  createRecordingSink,
  createStateStore,
  daemonPaths,
  pidAlive,
  socketRequest,
  systemProcesses
} from '../../src/daemon/index.mjs';
import { eventually, startTestDaemon, stopBeforeRemoval, subscribe, tempDataDir, within } from './helpers.mjs';

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
const plays = (dataDir) => {
  const path = join(dataDir, 'plays.json');
  return existsSync(path) && statSync(path).isFile() ? JSON.parse(readFileSync(path, 'utf8')).plays : [];
};
const scheduler = (dataDir) => JSON.parse(readFileSync(join(dataDir, 'scheduler.json'), 'utf8'));

/** The pid the app (the alert handler) says it runs as. */
const APP = 4242;

/**
 * The processes a daemon sees: the app runs as `APP` while `live` holds it, in this boot, and a wait
 * for a part it plays polls quickly, counting its `polls`.
 */
function appProcesses(live = new Set([APP])) {
  const processes = {
    live,
    polls: 0,
    boot: () => 'b1',
    birth: (pid) => `birth-${pid}`,
    alive: ({ pid }) => live.has(pid),
    kill: () => {},
    sleep() {
      processes.polls += 1;
      return new Promise((resolve) => setTimeout(resolve, 1));
    }
  };
  return processes;
}

/** Waits until a daemon using `processes` has polled for twice as long as it ever waited for a sink process: a live app is still not taken as done. */
async function pastEveryBound(processes) {
  const from = processes.polls;
  await eventually(() => processes.polls - from > (2 * LEFT_PROCESS_WAIT_MS) / 100, 30_000);
}

/** A daemon with the macOS sink on `spawner`, with a registered handler when `handler` is true. */
async function daemonWithSink(t, spawner, { handler = false, processes = appProcesses() } = {}) {
  const context = await startTestDaemon(t, { sink: createMacosSink({ spawn: spawner.spawn }), processes });
  context.processes = processes;
  if (!handler) return { context };
  const stream = subscribe(context.daemon.paths.socket);
  t.after(stream.close);
  await stream.waitFor((list) => list.length >= 1);
  assert.equal((await call(context, '/v1/alert-handlers', { subscriberId: stream.subscriberId })).status, 200);
  return { context, stream };
}

/** Starts a one-second countdown named Egg, with sound unless `sound` is false, and runs it to its finish. */
async function finishCountdown(context, { sound = true } = {}) {
  const started = await context.op('start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg', sound } });
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

/** Makes every later write of plays.json fail. */
function breakPlays(context) {
  const path = join(context.dataDir, 'plays.json');
  rmSync(path, { force: true });
  mkdirSync(join(path, 'in-the-way'), { recursive: true });
}

/**
 * The files a daemon killed now leaves, in a new data directory: `state.json`, the last
 * `scheduler.json` it saved and `plays.json`, unless it could not be written.
 */
function filesLeftByKill(t, context) {
  const next = tempDataDir(t);
  mkdirSync(next, { recursive: true });
  const saved = join(context.dataDir, 'scheduler.json.saved');
  writeFileSync(join(next, 'scheduler.json'), readFileSync(existsSync(saved) ? saved : join(context.dataDir, 'scheduler.json')));
  for (const name of ['state.json', 'plays.json']) {
    const path = join(context.dataDir, name);
    if (existsSync(path) && statSync(path).isFile()) writeFileSync(join(next, name), readFileSync(path));
  }
  return next;
}

/** The next daemon, on the files `context` left, at the time it was killed, with its own macOS sink. */
async function successorOf(t, context, spawner = partSpawn(), dataDir = filesLeftByKill(t, context)) {
  const processes = context.processes ?? appProcesses();
  const next = await startTestDaemon(t, { dataDir, clock: createFakeClock(context.clock.now()), sink: createMacosSink({ spawn: spawner.spawn }), processes });
  next.processes = processes;
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

/** The handler takes the one alert `stream` got, and returns its id and subscriber. */
async function takeAlert(context, stream) {
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [{ alertId }] = alertsOf(stream);
  const subscriberId = stream.subscriberId;
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
  return { alertId, subscriberId };
}

/** The app's process ends, and so its stream: once `ORPHANED_ALERT_MS` has passed the sink plays what the app left. */
async function appEnds(context, stream) {
  context.processes.live.delete(APP);
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
}

test('an app that ends while playing a part has the sink play that part and the others it did not finish, never one it finished, also by the next daemon', async (t) => {
  for (const restart of [false, true]) {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    const { alertId, subscriberId } = await takeAlert(context, stream);
    // The app asks before each part and says once it finished it; saying so twice records it once.
    assert.deepEqual((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).body, { alertId, part: 'notification', playing: true });
    for (let i = 0; i < 2; i += 1) {
      assert.deepEqual((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'notification' })).body, { alertId, part: 'notification', played: true });
    }
    // The app is killed while the first Glass plays: only asking to play it is not recorded.
    assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'sound:0', pid: APP })).status, 200);
    assert.deepEqual(scheduler(context.dataDir).acknowledged[0].played, ['notification']);
    await appEnds(context, stream);
    let sink = { context, spawner };
    if (restart) {
      const { next, spawner: after } = await successorOf(t, context);
      sink = { context: next, spawner: after };
    }
    sink.context.clock.advance(ORPHANED_ALERT_MS);
    await eventually(() => sink.spawner.started.length === 3);
    await settle();
    // The Glass cut off with the app plays again, in full, and the notification it showed does not.
    assert.deepEqual(sink.spawner.started, ['Glass', 'Glass', 'Glass'], `restart ${restart}`);
    assert.equal((await call(sink.context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 410);
    if (restart) assert.deepEqual(spawner.started, []);
  }
});

test('an app that ends after asking to show a sound-off finish, before showing it, leaves the notification to the sink: it is shown once, never lost', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context, { sound: false });
  const { alertId, subscriberId } = await takeAlert(context, stream);
  assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 200);
  await appEnds(context, stream);
  context.clock.advance(ORPHANED_ALERT_MS);
  await eventually(() => spawner.started.length === 1);
  await settle();
  assert.deepEqual(spawner.started, ['notification']);
});

test('an app that ends after finishing every part of an alert, before its receipt is recorded, has it played once: the sink plays nothing', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  const { alertId, subscriberId } = await takeAlert(context, stream);
  for (const part of ['notification', 'sound:0', 'sound:1', 'sound:2']) {
    assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part, pid: APP })).status, 200);
    assert.equal((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part })).status, 200);
  }
  await appEnds(context, stream);
  context.clock.advance(ORPHANED_ALERT_MS);
  await settle();
  assert.deepEqual(spawner.started, []);
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 410);
  assert.equal(scheduler(context.dataDir).acknowledged, undefined);
});

test("a part is refused unless the alert is the asker's and taken, and asking to play one records the app's process as playing it", async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  await stream.waitFor(() => alertsOf(stream).length === 1);
  const [{ alertId }] = alertsOf(stream);
  const subscriberId = stream.subscriberId;
  const ask = async (state, body, id = alertId) => {
    const reply = await call(context, `/v1/alerts/${id}/${state}`, body);
    return [reply.status, reply.body.error?.code];
  };
  for (const state of ['playing', 'played']) assert.deepEqual(await ask(state, { subscriberId, part: 'sound:0', pid: APP }), [409, 'invalid_state']);
  assert.equal((await call(context, `/v1/alerts/${alertId}/ack`, { subscriberId })).status, 200);
  for (const state of ['playing', 'played']) {
    for (const part of [undefined, 'sound', 'sound:-1', 'sound:100', 'Glass', '../notification']) {
      assert.deepEqual(await ask(state, { subscriberId, part, pid: APP }), [400, 'invalid_input'], `${state} ${part}`);
    }
    assert.deepEqual(await ask(state, { subscriberId: 'another stream', part: 'sound:0', pid: APP }), [409, 'not_alert_handler']);
    assert.deepEqual(await ask(state, { subscriberId, part: 'sound:0', pid: APP }, 'f'.repeat(32)), [404, 'not_found']);
  }
  for (const pid of [undefined, 0, -1, 1.5, String(APP)]) assert.deepEqual(await ask('playing', { subscriberId, part: 'sound:0', pid }), [400, 'invalid_input'], `pid ${pid}`);
  assert.deepEqual(await ask('playing', { subscriberId, part: 'sound:0', pid: APP }), [200, undefined]);
  assert.deepEqual(scheduler(context.dataDir).acknowledged[0].started, { 'sound:0': { pid: APP, birth: `birth-${APP}`, boot: 'b1', app: true } });
  await appEnds(context, stream);
  context.clock.advance(ORPHANED_ALERT_MS);
  await eventually(() => spawner.started.length === 4);
  // Once the sink has played it, the app is told so, and plays nothing more of it.
  for (const state of ['playing', 'played']) assert.deepEqual(await ask(state, { subscriberId, part: 'sound:1', pid: APP }), [410, 'alert_expired']);
});

/**
 * The app stalls holding `part` of `alertId`: its stream closes, its process still runs and the
 * orphan bound passes, so the sink takes the alert over and holds that part for it. With `restart`,
 * the daemon then crashes once `ready(dataDir)` and the next one, on the files it left, holds it.
 * Returns the daemon and spawner that hold it.
 */
async function stallPastOrphanBound(t, context, stream, spawner, { part, restart, ready = () => true }) {
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  context.clock.advance(ORPHANED_ALERT_MS);
  await eventually(() => plays(context.dataDir)[0]?.running?.[part]?.app === true && ready(context.dataDir));
  if (!restart) return { holder: context, sink: spawner };
  const left = filesLeftByKill(t, context);
  await context.daemon.shutdown();
  const { next, spawner: after } = await successorOf(t, context, partSpawn(), left);
  return { holder: next, sink: after };
}

for (const restart of [false, true]) {
  test(`an app suspended after asking to show a sound-off finish, before showing it, past the orphan bound${restart ? ' and a daemon crash' : ''}: the notification is held while the app runs and shown once when it is killed`, async (t) => {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context, { sound: false });
    const { alertId, subscriberId } = await takeAlert(context, stream);
    assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 200);
    const { holder, sink } = await stallPastOrphanBound(t, context, stream, spawner, { part: 'notification', restart });
    // However long the app runs, the part stays its own, in the journal: nothing is shown and nothing is forgotten.
    await pastEveryBound(holder.processes);
    assert.deepEqual([spawner.started, sink.started], [[], []]);
    assert.equal(plays(holder.dataDir)[0].running.notification.app, true);
    // Killed: its notification was never shown, so the sink shows it, once.
    holder.processes.live.delete(APP);
    await eventually(() => sink.started.length === 1);
    await eventually(() => plays(holder.dataDir).length === 0);
    assert.deepEqual([spawner.started, sink.started], restart ? [[], ['notification']] : [['notification'], ['notification']]);
    assert.ok(holder.logs.some((line) => line.includes(`alert ${alertId}: its handler ended without saying it finished notification`)));
  });

  for (const resumes of [true, false]) {
    test(`an app that stalls mid-sound past the orphan bound${restart ? ' and a daemon crash' : ''}, then ${resumes ? 'says it finished it and ends' : 'is killed'}: the sink plays the other sounds at once, and that one ${resumes ? 'never' : 'once'}`, async (t) => {
      const spawner = partSpawn();
      const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
      await finishCountdown(context);
      const { alertId, subscriberId } = await takeAlert(context, stream);
      for (const [part, state] of [['notification', 'playing'], ['notification', 'played'], ['sound:0', 'playing']]) {
        assert.equal((await call(context, `/v1/alerts/${alertId}/${state}`, { subscriberId, part, pid: APP })).status, 200);
      }
      // The sink does not wait for the held Glass: it plays the other two while the app is stalled in it.
      const others = (dataDir) => ['sound:1', 'sound:2'].every((part) => plays(dataDir)[0]?.played.includes(part));
      const { holder, sink } = await stallPastOrphanBound(t, context, stream, spawner, { part: 'sound:0', restart, ready: others });
      assert.deepEqual(spawner.started, ['Glass', 'Glass']);
      await pastEveryBound(holder.processes);
      assert.deepEqual(plays(holder.dataDir)[0].running['sound:0'].app, true);
      if (resumes) {
        // The sink played the rest, so the app is told to play no more, and its Glass counts as played,
        // however long after the sink took the alert over.
        holder.clock.advance(SETTLED_RETENTION_MS + 1);
        assert.equal((await call(holder, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'sound:0' })).status, 410);
        await eventually(() => plays(holder.dataDir).length === 0);
        // The play has finished, so the app ending later replays nothing.
        holder.processes.live.delete(APP);
        await settle();
      } else {
        holder.processes.live.delete(APP);
        await eventually(() => plays(holder.dataDir).length === 0);
      }
      const replayed = resumes ? [] : ['Glass'];
      assert.deepEqual([spawner.started, sink.started], restart ? [['Glass', 'Glass'], replayed] : [['Glass', 'Glass', ...replayed], ['Glass', 'Glass', ...replayed]]);
    });
  }
}

/** Lets `scheduler.json` be saved again, as it was before `breakScheduler`. */
function fixScheduler(context) {
  const path = join(context.dataDir, 'scheduler.json');
  rmSync(path, { recursive: true });
  renameSync(`${path}.saved`, path);
}

for (const crash of [false, true]) {
  test(`a finished part whose scheduler.json save fails is answered once plays.json holds it, so an app that then ends has it played once${crash ? ', also after a daemon crash' : ''}`, async (t) => {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    const { alertId, subscriberId } = await takeAlert(context, stream);
    assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 200);
    breakScheduler(context);
    assert.equal((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'notification' })).status, 200);
    assert.deepEqual(JSON.parse(readFileSync(join(context.dataDir, 'plays.json'), 'utf8')).progress, [{ alertId, played: ['notification'] }]);
    await appEnds(context, stream);
    let sink = { context, spawner };
    if (crash) {
      const { next, spawner: after } = await successorOf(t, context);
      sink = { context: next, spawner: after };
    }
    sink.context.clock.advance(ORPHANED_ALERT_MS);
    await eventually(() => sink.spawner.started.length === 3);
    await settle();
    // The notification the app showed is not shown again; the Glass sounds it never started play.
    assert.deepEqual(sink.spawner.started, ['Glass', 'Glass', 'Glass']);
    if (crash) {
      assert.deepEqual(spawner.started, []);
      // Once scheduler.json is saved without the acknowledgement, plays.json no longer holds the part.
      await eventually(() => JSON.parse(readFileSync(join(sink.context.dataDir, 'plays.json'), 'utf8')).progress === undefined);
    }
  });
}

for (const retry of [false, true]) {
  test(`a finished part neither file can record gets 500 yet this daemon never plays it${retry ? ', and saying so again saves it' : ''}`, async (t) => {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    const { alertId, subscriberId } = await takeAlert(context, stream);
    assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 200);
    breakScheduler(context);
    breakPlays(context);
    const played = await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'notification' });
    assert.deepEqual([played.status, played.body.error?.code], [500, 'storage_failed']);
    if (retry) {
      fixScheduler(context);
      assert.equal((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'notification' })).status, 200);
      assert.deepEqual(scheduler(context.dataDir).acknowledged[0].played, ['notification']);
      return;
    }
    await appEnds(context, stream);
    context.clock.advance(ORPHANED_ALERT_MS);
    await eventually(() => spawner.started.length === 3);
    await settle();
    assert.deepEqual(spawner.started, ['Glass', 'Glass', 'Glass']);
  });
}

/**
 * The app finished the notification and asks to play the first Glass while `scheduler.json` cannot be
 * saved (and, with `plays`, neither can `plays.json`); then its stream closes and the daemon is killed.
 * Returns the answer, the ids, and the next daemon on the files it left, with the orphan bound passed.
 */
async function askWhileSchedulerFails(t, { plays: alsoPlays = false } = {}) {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  const { alertId, subscriberId } = await takeAlert(context, stream);
  for (const state of ['playing', 'played']) assert.equal((await call(context, `/v1/alerts/${alertId}/${state}`, { subscriberId, part: 'notification', pid: APP })).status, 200);
  breakScheduler(context);
  if (alsoPlays) breakPlays(context);
  const asked = await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'sound:0', pid: APP });
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  const left = filesLeftByKill(t, context);
  await context.daemon.shutdown();
  const { next, spawner: sink } = await successorOf(t, context, partSpawn(), left);
  next.clock.advance(ORPHANED_ALERT_MS);
  return { asked, alertId, subscriberId, spawner, next, sink };
}

for (const resumes of [true, false]) {
  test(`a part the app is permitted while scheduler.json cannot be saved is held by plays.json across a daemon crash: an app stalled past the orphan bound that then ${resumes ? 'says it finished it' : 'is killed'} has it played ${resumes ? 'by the app only' : 'once, by the sink'}`, async (t) => {
    const { asked, alertId, subscriberId, spawner, next, sink } = await askWhileSchedulerFails(t);
    assert.equal(asked.status, 200);
    // The next daemon knows the app plays the first Glass: it plays the other two at once, and holds that one.
    await eventually(() => sink.started.length === 2);
    await pastEveryBound(next.processes);
    assert.deepEqual([spawner.started, sink.started], [[], ['Glass', 'Glass']]);
    assert.equal(plays(next.dataDir)[0].running['sound:0'].app, true);
    if (resumes) {
      assert.equal((await call(next, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'sound:0' })).status, 410);
      await eventually(() => plays(next.dataDir).length === 0);
    }
    next.processes.live.delete(APP);
    await eventually(() => plays(next.dataDir).length === 0);
    await settle();
    assert.deepEqual(sink.started, resumes ? ['Glass', 'Glass'] : ['Glass', 'Glass', 'Glass']);
  });
}

test('a part neither file can record the app as playing gets 500 and is not permitted: the next daemon plays it once, with the app still running', async (t) => {
  const { asked, sink, next } = await askWhileSchedulerFails(t, { plays: true });
  assert.deepEqual([asked.status, asked.body.error?.code], [500, 'storage_failed']);
  // The app never played the first Glass, so nothing holds it: the sink plays every Glass at once, and not the notification.
  await eventually(() => sink.started.length === 3);
  await eventually(() => plays(next.dataDir).length === 0);
  await settle();
  assert.deepEqual(sink.started, ['Glass', 'Glass', 'Glass']);
});

test('a part neither file can record the app as playing is forgotten by this daemon too, so its sink does not hold it for the app', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context, { sound: false });
  const { alertId, subscriberId } = await takeAlert(context, stream);
  breakScheduler(context);
  breakPlays(context);
  assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 500);
  fixScheduler(context);
  assert.equal(scheduler(context.dataDir).acknowledged[0].started, undefined);
  stream.close();
  await eventually(() => context.daemon.alertHandler.registered === false);
  context.clock.advance(ORPHANED_ALERT_MS);
  await eventually(() => spawner.started.length === 1);
  await settle();
  assert.deepEqual(spawner.started, ['notification']);
});

test('a handback after the app asked to show a part and did not (the notification center refused it) has the sink show it, though the app still runs', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context, { sound: false });
  const { alertId, subscriberId } = await takeAlert(context, stream);
  assert.equal((await call(context, `/v1/alerts/${alertId}/playing`, { subscriberId, part: 'notification', pid: APP })).status, 200);
  assert.equal((await call(context, `/v1/alerts/${alertId}/release`, { subscriberId })).status, 200);
  await eventually(() => spawner.started.length === 1);
  await settle();
  assert.deepEqual(spawner.started, ['notification']);
});

test('a handback after the app finished some parts, then a crash before the sink recorded its play anywhere, has the next daemon play only the rest', async (t) => {
  const spawner = partSpawn();
  const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
  await finishCountdown(context);
  const { alertId, subscriberId } = await takeAlert(context, stream);
  for (const part of ['notification', 'sound:0']) assert.equal((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part })).status, 200);
  // The journal entry for the sink's play cannot be written, and the daemon dies as the sink is called.
  breakPlays(context);
  let left = null;
  context.sink.alert = async () => {
    left = filesLeftByKill(t, context);
  };
  assert.equal((await call(context, `/v1/alerts/${alertId}/release`, { subscriberId })).status, 200);
  assert.ok(left);
  assert.deepEqual(scheduler(left).handoffs.map(({ played }) => played), [['notification', 'sound:0']]);

  const { spawner: after } = await successorOf(t, context, partSpawn(), left);
  await eventually(() => after.started.length === 2);
  await settle();
  assert.deepEqual(after.started, ['Glass', 'Glass']);
});

for (const handler of [true, false]) {
  test(`while plays.json cannot be written, scheduler.json carries the journal, so a crash mid-play ${handler ? 'of a fallback' : 'with no handler'} is delivered once`, async (t) => {
    const spawner = partSpawn({ hold: holdSecondGlass });
    const { context } = await daemonWithSink(t, spawner, { handler });
    breakPlays(context);
    await finishCountdown(context);
    if (handler) context.clock.advance(ACK_TIMEOUT_MS);
    await eventually(() => spawner.started.length === 3 && scheduler(context.dataDir).plays?.[0]?.played.length === 2);
    const saved = scheduler(context.dataDir);
    assert.equal(saved.handoffs, undefined);
    assert.deepEqual(saved.plays[0].played.sort(), ['notification', 'sound:0']);
    assert.ok(context.logs.some((line) => line.startsWith('could not save plays.json')));

    const { next, spawner: after } = await successorOf(t, context);
    next.clock.advance(1_000);
    await eventually(() => after.started.length === 2);
    await settle();
    assert.deepEqual(after.started, ['Glass', 'Glass']);
    // Once plays.json can be written, scheduler.json no longer carries the journal.
    await eventually(() => scheduler(next.dataDir).plays === undefined && plays(next.dataDir).length === 0);
    spawner.release();
  });
}

const SINK_DAEMON = fileURLToPath(new URL('./sink-daemon.mjs', import.meta.url));
const lines = (path) => (existsSync(path) ? readFileSync(path, 'utf8').split('\n').filter(Boolean) : []);

test('a sound process that outlives a SIGKILLed daemon is waited for and not played again; the next daemon plays only the parts after it', async (t) => {
  const dataDir = tempDataDir(t);
  const heard = join(dataDir, '..', 'heard.log');
  const pids = new Set();
  stopBeforeRemoval(dataDir, async () => {
    for (const pid of pids) if (pidAlive(pid)) process.kill(pid, 'SIGKILL');
  });
  // A daemon whose macOS sink runs real processes: each logs its part to heard.log as it ends, a Glass 5 s after it starts.
  const daemon = nodeSpawn(process.execPath, [SINK_DAEMON, dataDir, heard], { stdio: ['ignore', 'pipe', 'inherit'] });
  pids.add(daemon.pid);
  const exited = new Promise((resolve) => daemon.on('exit', resolve));
  await within(new Promise((resolve) => daemon.stdout.once('data', resolve)), 40_000, 'the sink daemon to start');
  const socket = join(dataDir, 'daemon.sock');
  const started = await socketRequest(socket, 'POST', '/v1/ops/start', { timer: { kind: 'countdown', durationMs: 1_000, countdownTicks: false, name: 'Egg' } });
  assert.equal(started.status, 200);
  // Killed once the notification has ended and while a Glass plays (the first, unless the host is slow).
  const playingGlass = () => Object.keys(plays(dataDir)[0]?.running ?? {}).find((part) => part.startsWith('sound:'));
  await eventually(() => plays(dataDir)[0]?.played.includes('notification') && playingGlass(), 30_000);
  const part = playingGlass();
  const glass = plays(dataDir)[0].running[part];
  pids.add(glass.pid);
  daemon.kill('SIGKILL');
  await within(exited, 10_000, 'the sink daemon to die');
  assert.equal(pidAlive(glass.pid), true);
  const index = Number(part.slice('sound:'.length));
  const heardBefore = ['notification', ...Array(index).fill('Glass')];
  assert.deepEqual(lines(heard), heardBefore);

  const after = partSpawn();
  const heardAtFirstSpawn = [];
  const spawn = (...args) => {
    heardAtFirstSpawn.push(lines(heard));
    return after.spawn(...args);
  };
  const next = await startTestDaemon(t, { dataDir, clock: createFakeClock(Date.now()), sink: createMacosSink({ spawn }) });
  const rest = Array(2 - index).fill('Glass');
  await eventually(() => after.started.length === rest.length && plays(next.dataDir).length === 0, 30_000);
  await settle();
  // The surviving Glass finished on its own, once, before the next daemon played those after it.
  assert.deepEqual(after.started, rest);
  assert.deepEqual(lines(heard), [...heardBefore, 'Glass']);
  if (rest.length) assert.deepEqual(heardAtFirstSpawn[0], [...heardBefore, 'Glass']);
});

test('a play only scheduler.json carried, with its sound process still running, survives a crash of the next daemon after its first save: a third plays the rest once', async (t) => {
  const dataDir = tempDataDir(t);
  const paths = daemonPaths(dataDir);
  mkdirSync(dataDir, { recursive: true });
  const heard = join(dataDir, '..', 'heard.log');
  // The first Glass of a finish, still playing in a real process that outlived the daemon that spawned it.
  const glass = nodeSpawn('/bin/sh', ['-c', 'sleep 4 && echo Glass >> "$1"', 'sh', heard], { stdio: 'ignore' });
  stopBeforeRemoval(dataDir, async () => {
    if (pidAlive(glass.pid)) process.kill(glass.pid, 'SIGKILL');
  });
  const child = { pid: glass.pid, birth: systemProcesses.birth(glass.pid), boot: systemProcesses.boot() };
  // That daemon could not write plays.json, so scheduler.json alone holds the play, with the notification shown.
  const play = { ...leftRunning({ 'sound:0': child }), alertId: 'a'.repeat(32), timer: { ...egg, sound: true } };
  createStateStore(paths, { log: () => {}, now: Date.now }).saveMarks([], { plays: [play] });
  assert.deepEqual(scheduler(dataDir).plays.map(({ alertId }) => alertId), [play.alertId]);

  // The next daemon saves scheduler.json at once, without the copy, while it waits for the Glass, and crashes.
  const second = await startTestDaemon(t, { dataDir, clock: createFakeClock(Date.now()), sink: createMacosSink({ spawn: partSpawn().spawn }) });
  await eventually(() => scheduler(dataDir).plays === undefined);
  assert.deepEqual(plays(dataDir).map(({ alertId, played, running }) => [alertId, played, Object.keys(running)]), [[play.alertId, ['notification'], ['sound:0']]]);
  assert.equal(pidAlive(glass.pid), true);
  const left = filesLeftByKill(t, second);
  await second.daemon.shutdown();

  const after = partSpawn();
  const third = await startTestDaemon(t, { dataDir: left, clock: createFakeClock(Date.now()), sink: createMacosSink({ spawn: after.spawn }) });
  await eventually(() => after.started.length === 2 && plays(third.dataDir).length === 0, 30_000);
  await settle();
  // The Glass left playing finished once, on its own; the third daemon played the two after it, and not the notification.
  assert.deepEqual([lines(heard), after.started], [['Glass'], ['Glass', 'Glass']]);
});

/** POSTs `body` to `path`, sending the body only once `between()` ran after the headers reached the daemon. */
function postSplit(socketPath, path, body, between) {
  const text = JSON.stringify(body);
  return new Promise((resolve, reject) => {
    const outgoing = request({ socketPath, method: 'POST', path, agent: false, headers: { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) } }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => resolve({ status: response.statusCode, body: JSON.parse(Buffer.concat(chunks).toString('utf8')) }));
    });
    outgoing.on('error', reject);
    outgoing.flushHeaders();
    setTimeout(() => {
      between();
      outgoing.end(text);
    }, 200);
  });
}

for (const state of ['playing', 'played']) {
  test(`a daemon whose lock is replaced while a "${state}" request is read answers 503 and records nothing; the daemon that holds the lock then delivers the alert once`, async (t) => {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    const { alertId, subscriberId } = await takeAlert(context, stream);
    for (const [part, asked] of [['notification', 'playing'], ['notification', 'played'], ...(state === 'played' ? [['sound:0', 'playing']] : [])]) {
      assert.equal((await call(context, `/v1/alerts/${alertId}/${asked}`, { subscriberId, part, pid: APP })).status, 200);
    }
    const before = [scheduler(context.dataDir), plays(context.dataDir)];
    const lockPath = context.daemon.paths.lock;
    const reply = await postSplit(context.daemon.paths.socket, `/v1/alerts/${alertId}/${state}`, { subscriberId, part: 'sound:0', pid: APP }, () =>
      writeFileSync(lockPath, JSON.stringify({ pid: 1, token: 'another daemon' }))
    );
    assert.deepEqual([reply.status, reply.body.error?.code], [503, 'daemon_unavailable']);
    assert.equal(await within(context.daemon.closed), 1);
    assert.deepEqual([scheduler(context.dataDir), plays(context.dataDir)], before);
    assert.deepEqual(spawner.started, []);

    // The daemon that replaced the lock has gone, so the next one takes it, and the app asks it again.
    unlinkSync(lockPath);
    const after = partSpawn();
    const next = await startTestDaemon(t, { dataDir: context.dataDir, clock: createFakeClock(context.clock.now()), sink: createMacosSink({ spawn: after.spawn }), processes: context.processes });
    next.processes = context.processes;
    // Refused, the app played no Glass; told it finished the first, the next daemon records it.
    if (state === 'played') assert.equal((await call(next, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'sound:0' })).status, 200);
    context.processes.live.delete(APP);
    next.clock.advance(ORPHANED_ALERT_MS);
    const rest = state === 'played' ? 2 : 3;
    await eventually(() => after.started.length === rest);
    await settle();
    assert.deepEqual(after.started, Array(rest).fill('Glass'));
  });
}

/** Processes for the journal: `boot` is the current boot id, and `alive(pid)` how many more polls each pid lives. */
function fakeProcesses({ boot = 'b1', lives = {} } = {}) {
  const killed = [];
  let sleeps = 0;
  return {
    killed,
    get sleeps() {
      return sleeps;
    },
    boot: () => boot,
    birth: (pid) => `birth-${pid}`,
    alive: ({ pid }) => (lives[pid] ?? 0) > 0 && !killed.includes(pid),
    kill: (pid) => killed.push(pid),
    async sleep() {
      sleeps += 1;
      for (const pid of Object.keys(lives)) lives[pid] -= 1;
    }
  };
}

const finish = { timerId: 't_1', kind: 'finish', at: 0 };
const egg = { id: 't_1', name: 'Egg' };
const leftRunning = (running) => ({ alertId: 'a1', alert: finish, timer: egg, keys: [], played: ['notification'], running, finished: false });

test('a part an earlier daemon left running is decided by its process: waited for while alive, finished once exited in this boot, played again after a reboot', async () => {
  const cases = [
    { name: 'exited in this boot', child: { pid: 7, birth: 'birth-7', boot: 'b1' }, lives: {}, done: true },
    { name: 'still running', child: { pid: 7, birth: 'birth-7', boot: 'b1' }, lives: { 7: 3 }, done: true, sleeps: 3 },
    { name: 'never ending', child: { pid: 7, birth: 'birth-7', boot: 'b1' }, lives: { 7: Infinity }, done: true, killed: [7] },
    { name: 'never ending, birth unknown', child: { pid: 7, birth: null, boot: 'b1' }, lives: { 7: Infinity }, done: true, killed: [] },
    { name: 'from an earlier boot', child: { pid: 7, birth: 'birth-7', boot: 'b0' }, lives: { 7: Infinity }, done: false },
    { name: 'boot unknown', child: { pid: 7, birth: 'birth-7', boot: null }, lives: {}, done: false },
    // A part the app (the alert handler) started in an earlier boot ended with it.
    { name: 'the app, from an earlier boot', child: { pid: 7, birth: 'birth-7', boot: 'b0', app: true }, lives: { 7: Infinity }, done: false }
  ];
  for (const { name, child, lives, done, sleeps = undefined, killed = undefined } of cases) {
    const processes = fakeProcesses({ lives });
    const writes = [];
    const journal = createPlayJournal({ entries: [leftRunning({ 'sound:0': child })], persist: (entries) => writes.push(entries), processes });
    assert.equal(journal.left('a1'), true, name);
    await journal.settle('a1');
    assert.equal(journal.left('a1'), false, name);
    assert.deepEqual([...journal.played('a1')].sort(), done ? ['notification', 'sound:0'] : ['notification'], name);
    assert.equal(writes.at(-1)[0].running, undefined, name);
    if (sleeps !== undefined) assert.equal(processes.sleeps, sleeps, name);
    if (killed !== undefined) assert.deepEqual(processes.killed, killed, name);
    if (name === 'never ending') assert.equal(processes.sleeps, LEFT_PROCESS_WAIT_MS / 100, name);
  }
});

test('a part the app started is held, never decided by time: until the app says it finished it, or ends, or the journal is closed', async () => {
  const app = { pid: 7, birth: 'birth-7', boot: 'b1', app: true };
  // Well past any bound the journal knows, the app says it finished the part, or ends; or the daemon stops first.
  const polls = 10 * (LEFT_PROCESS_WAIT_MS / 100);
  for (const fate of ['says it finished it', 'ends', 'closed']) {
    const processes = fakeProcesses({ lives: { 7: fate === 'ends' ? polls : Infinity } });
    const writes = [];
    const journal = createPlayJournal({ entries: [{ ...leftRunning({ 'sound:0': app }), subscriberId: 's1' }], persist: (entries) => writes.push(entries), processes });
    const { sleep } = processes;
    processes.sleep = async () => {
      await sleep();
      if (processes.sleeps === polls && fate === 'says it finished it') journal.done('a1', 'sound:0');
      if (processes.sleeps === polls && fate === 'closed') journal.close();
    };
    await journal.settle('a1');
    assert.deepEqual([journal.held('a1'), writes], [['sound:0'], []], fate);
    assert.deepEqual([journal.awaitsHandler('a1', 'sound:0', 's1'), journal.awaitsHandler('a1', 'sound:0', 's2')], [true, false], fate);
    await journal.awaitHandler('a1', 'sound:0');
    assert.deepEqual([processes.sleeps, processes.killed], [polls, []], fate);
    assert.equal(journal.played('a1').has('sound:0'), fate === 'says it finished it', fate);
    assert.deepEqual(journal.held('a1'), fate === 'closed' ? ['sound:0'] : [], fate);
  }
});

test('the entries and progress earlier daemons left are written before anything else, and a lost daemon.lock is no failure to carry but is thrown to a handler', () => {
  const writes = [];
  let fail = null;
  let behindCalls = 0;
  const journal = createPlayJournal({
    entries: [leftRunning({})],
    progress: [{ alertId: 'a2', played: ['notification'] }],
    persist(entries, progress) {
      if (fail) throw fail;
      writes.push([entries.map(({ alertId }) => alertId), progress]);
    },
    onBehind: () => {
      behindCalls += 1;
    },
    processes: fakeProcesses()
  });
  assert.deepEqual(writes, []);
  journal.recover();
  assert.deepEqual(writes, [[['a1'], [{ alertId: 'a2', played: ['notification'] }]]]);
  fail = Object.assign(new Error('daemon.lock is no longer held by this daemon.'), { name: 'LockLostError' });
  journal.done('a1', 'sound:0');
  assert.deepEqual([journal.behind, behindCalls], [false, 0]);
  assert.throws(() => journal.handle('a3', { played: ['notification'] }), { name: 'LockLostError' });
  // Nothing to write: a journal with no entries left writes nothing at startup.
  const empty = [];
  createPlayJournal({ persist: () => empty.push(1), processes: fakeProcesses() }).recover();
  assert.deepEqual(empty, []);
});

test("a handler's started part only plays.json holds is dropped once a save holds it acknowledged as started or finished, and one a failed write could not hold is forgotten", () => {
  const writes = [];
  let fail = null;
  const journal = createPlayJournal({ persist(entries, progress) {
    if (fail) throw fail;
    writes.push(progress);
  }, processes: fakeProcesses() });
  const app = { pid: APP, birth: 'b', boot: 'b1', app: true };
  assert.equal(journal.handle('a1', { played: ['notification'], started: { 'sound:0': app } }), true);
  assert.deepEqual(writes.at(-1), [{ alertId: 'a1', played: ['notification'], started: { 'sound:0': app } }]);
  // A save that holds the finished part but not the started one keeps it; a handoff need not hold it.
  journal.saved([], [{ alertId: 'a1', subscriberId: 's1', played: ['notification'] }]);
  assert.deepEqual(journal.handled.map(({ alertId }) => alertId), ['a1']);
  journal.saved([], [{ alertId: 'a1', subscriberId: 's1', played: ['notification'], started: { 'sound:0': app } }]);
  assert.deepEqual([journal.handled, writes.at(-1)], [[], []]);
  journal.handle('a2', { played: [], started: { notification: app } });
  journal.saved([], [{ alertId: 'a2', played: [] }]);
  assert.deepEqual(journal.handled, []);
  // Not kept: a write that fails forgets it again, and an earlier one is kept as it was.
  fail = new Error('EACCES');
  assert.equal(journal.handle('a3', { played: [], started: { notification: app } }, { keep: false }), false);
  assert.deepEqual(journal.handled, []);
  fail = null;
  journal.handle('a3', { played: ['notification'] });
  fail = new Error('EACCES');
  journal.handle('a3', { played: ['notification'], started: { 'sound:0': app } }, { keep: false });
  assert.deepEqual(journal.handled, [{ alertId: 'a3', played: ['notification'] }]);
});

test("the sink records each part's process as it spawns, its pid before the birth lookup, and a daemon stopped while waiting for a left process hands nothing to its sink", async () => {
  const processes = fakeProcesses({ lives: { 7: Infinity } });
  const writes = [];
  const atBirth = [];
  const { birth } = processes;
  processes.birth = (pid) => {
    atBirth.push(writes.at(-1)[0].running);
    return birth(pid);
  };
  const journal = createPlayJournal({ persist: (entries) => writes.push(entries), processes });
  journal.begin('a2', { alert: finish, timer: egg });
  journal.started('a2', 'sound:0', 9);
  // The pid and boot are written before the birth lookup, and the birth in a second write.
  assert.deepEqual(atBirth, [{ 'sound:0': { pid: 9, birth: null, boot: 'b1' } }]);
  assert.deepEqual(writes.at(-1)[0].running, { 'sound:0': { pid: 9, birth: 'birth-9', boot: 'b1' } });
  journal.done('a2', 'sound:0');
  assert.equal(writes.at(-1)[0].running, undefined);
  // A spawn that reported no pid records nothing.
  journal.started('a2', 'sound:1', undefined);
  assert.equal(writes.length, 4);

  const sink = createRecordingSink();
  const handlers = createAlertHandlers({ clock: createFakeClock(), sink, log: () => {}, publish: () => {}, isOpen: () => true, plays: [leftRunning({ 'sound:0': { pid: 7, birth: 'birth-7', boot: 'b1' } })], processes });
  handlers.replay([]);
  await handlers.stop();
  assert.deepEqual(sink.received, []);
});

test('a journal that cannot be written is carried by scheduler.json until it can; a finished play is dropped only once neither file holds it unfinished', () => {
  const writes = [];
  const logs = [];
  let behindCalls = 0;
  let failing = true;
  const journal = createPlayJournal({
    log: (message) => logs.push(message),
    onBehind: () => {
      behindCalls += 1;
    },
    persist(entries) {
      if (failing) throw new Error('disk full');
      writes.push(entries.map(({ alertId, played, finished }) => ({ alertId, played, finished })));
    },
    processes: fakeProcesses()
  });
  journal.begin('a1', { alert: finish, timer: egg, keys: ['t_1:finish:0'] });
  assert.deepEqual([logs, writes, journal.behind, behindCalls], [['could not save plays.json: disk full'], [], true, 1]);
  journal.done('a1', 'notification');
  assert.equal(behindCalls, 2);
  const carried = journal.carried;
  assert.deepEqual(carried.map(({ alertId, played, finished }) => ({ alertId, played, finished })), [{ alertId: 'a1', played: ['notification'], finished: false }]);
  // scheduler.json saved with the unfinished copy: the play stays until a save without it.
  journal.saved(carried);
  failing = false;
  journal.finish('a1');
  assert.deepEqual([journal.behind, behindCalls, journal.carried, journal.has('a1')], [false, 3, [], true]);
  assert.equal(journal.delivered('t_1:finish:0'), true);
  journal.saved([]);
  assert.deepEqual([writes.at(-1), journal.has('a1'), journal.delivered('t_1:finish:0')], [[], false, false]);
  // One saved over while it plays is dropped as soon as it finishes.
  journal.begin('a2', { alert: finish, timer: egg });
  journal.saved([]);
  journal.finish('a2');
  assert.deepEqual([writes.at(-1), journal.has('a2')], [[], false]);
  // A write that would only drop entries, failing while behind already, asks for no save.
  journal.begin('a3', { alert: finish, timer: egg });
  journal.finish('a3');
  failing = true;
  journal.begin('a4', { alert: finish, timer: egg });
  const calls = behindCalls;
  journal.saved([]);
  assert.equal(behindCalls, calls);
});

test('copies of one play from plays.json and scheduler.json are merged, each part finished in either counting', () => {
  const journal = createPlayJournal({
    entries: [
      { ...leftRunning({ 'sound:1': { pid: 7, birth: null, boot: 'b1' } }), keys: ['k1'], played: ['notification', 'sound:0'] },
      { ...leftRunning({}), keys: ['k1', 'k2'], played: ['sound:1'] }
    ],
    processes: fakeProcesses()
  });
  assert.deepEqual([...journal.played('a1')].sort(), ['notification', 'sound:0', 'sound:1']);
  assert.equal(journal.left('a1'), false);
  assert.equal(journal.delivered('k2'), true);
  assert.equal(journal.unfinished.length, 1);
});
