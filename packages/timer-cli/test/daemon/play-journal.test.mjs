import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { spawn as nodeSpawn } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { basename, join } from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { createMacosSink } from '../../src/alerts/index.mjs';
import { OSASCRIPT } from '../../src/alerts/macos.mjs';
import {
  ACK_TIMEOUT_MS,
  LEFT_PROCESS_WAIT_MS,
  ORPHANED_ALERT_MS,
  createAlertHandlers,
  createFakeClock,
  createPlayJournal,
  createRecordingSink,
  pidAlive,
  socketRequest
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
 * for a part it plays polls quickly.
 */
function appProcesses(live = new Set([APP])) {
  return { live, boot: () => 'b1', birth: (pid) => `birth-${pid}`, alive: ({ pid }) => live.has(pid), kill: () => {}, sleep: () => new Promise((resolve) => setTimeout(resolve, 1)) };
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

for (const resumes of [true, false]) {
  test(`an app that stalls mid-part past the orphan bound${resumes ? ' and then says it finished it' : ''} has that part played once, by it: the sink waits for it and plays only the rest`, async (t) => {
    const spawner = partSpawn();
    const { context, stream } = await daemonWithSink(t, spawner, { handler: true });
    await finishCountdown(context);
    const { alertId, subscriberId } = await takeAlert(context, stream);
    for (const [part, state] of [['notification', 'playing'], ['notification', 'played'], ['sound:0', 'playing']]) {
      assert.equal((await call(context, `/v1/alerts/${alertId}/${state}`, { subscriberId, part, pid: APP })).status, 200);
    }
    // The app stalls in the first Glass: the daemon drops its stream, and its process still runs.
    stream.close();
    await eventually(() => context.daemon.alertHandler.registered === false);
    context.clock.advance(ORPHANED_ALERT_MS);
    if (resumes) {
      await eventually(() => plays(context.dataDir)[0]?.running?.['sound:0']?.app === true);
      // The sink plays the rest, so the app is told to play no more.
      assert.equal((await call(context, `/v1/alerts/${alertId}/played`, { subscriberId, part: 'sound:0' })).status, 410);
    }
    await eventually(() => spawner.started.length === 2);
    await settle();
    assert.deepEqual(spawner.started, ['Glass', 'Glass']);
    assert.ok(context.logs.some((line) => line.includes(`alert ${alertId}: of the parts left playing, notification, sound:0 finished`)));
  });
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
    // A part the app (the alert handler) started: its sound plays in the app's process.
    { name: 'the app, stalled', child: { pid: 7, birth: 'birth-7', boot: 'b1', app: true }, lives: { 7: Infinity }, done: true, killed: [] },
    { name: 'the app, which ended in it', child: { pid: 7, birth: 'birth-7', boot: 'b1', app: true }, lives: { 7: 2 }, done: false, sleeps: 2 },
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
    if (name === 'never ending' || name === 'the app, stalled') assert.equal(processes.sleeps, LEFT_PROCESS_WAIT_MS / 100, name);
  }
});

test('a part the app started is waited for only until it says it finished it', async () => {
  const processes = fakeProcesses({ lives: { 7: Infinity } });
  const { sleep } = processes;
  // The app says it finished the part during the second poll.
  processes.sleep = async () => {
    await sleep();
    if (processes.sleeps === 2) journal.done('a1', 'sound:0');
  };
  const journal = createPlayJournal({ entries: [leftRunning({ 'sound:0': { pid: 7, birth: 'birth-7', boot: 'b1', app: true } })], processes });
  assert.equal(journal.awaitsHandler('a1', 'sound:0'), true);
  await journal.settle('a1');
  assert.deepEqual([...journal.played('a1')].sort(), ['notification', 'sound:0']);
  assert.deepEqual([processes.sleeps, processes.killed], [2, []]);
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
