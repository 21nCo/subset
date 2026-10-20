import assert from 'node:assert/strict';
import test from 'node:test';
import { BUILT_IN_PRESETS, project, transitionsBetween } from '@subset/timer';
import { LATE_MS, createFakeClock, createScheduler } from '../../src/daemon/index.mjs';
import { startTestDaemon, tempDataDir } from './helpers.mjs';

const TABATA_MS = 250_000;
const label = ({ alert }) => `${alert.kind}@${alert.at}`;

/** Every alert the engine says the timer has between two times, as the scheduler should fire them. */
function expectedAlerts(timer, from, to) {
  return transitionsBetween(timer, from, to).map((transition) => `${transition.type}@${transition.at}`);
}

async function startTabata(context) {
  const started = await context.op('start', { preset: 'tabata' });
  assert.equal(started.status, 200);
  const { definition, runtime } = started.body.timer;
  return { id: definition.id, timer: { definition, runtime } };
}

test('a Tabata run fires every segment and tick alert exactly once, each at its own time', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink } = context;
  const deliveredAt = [];
  const record = sink.alert.bind(sink);
  sink.alert = (alert, timer) => {
    deliveredAt.push(clock.now());
    record(alert, timer);
  };
  const { id, timer } = await startTabata(context);
  const startedAt = clock.now();
  clock.advance(TABATA_MS + 120_000);

  const expected = expectedAlerts(timer, startedAt, startedAt + TABATA_MS);
  // 16 step starts after the prep, 3 ticks before each of the 17 step ends, and the finish.
  assert.equal(expected.length, 16 + 17 * 3 + 1);
  assert.deepEqual(sink.received.map(label), expected);
  assert.deepEqual(deliveredAt, sink.received.map(({ alert }) => alert.at));
  assert.ok(sink.received.every(({ alert, timer: definition }) => alert.timerId === id && definition.id === id));
  const [firstWork] = sink.received.filter(({ alert }) => alert.kind === 'segment');
  assert.deepEqual(firstWork.alert.segment, { index: 1, round: 1, phase: 'work', label: 'Work', durationMs: 20_000 });
  const [firstTick] = sink.received;
  assert.deepEqual([firstTick.alert.kind, firstTick.alert.secondsLeft, firstTick.alert.segment.phase], ['tick', 3, 'prep']);

  const { body } = await context.call('GET', '/v1/timers');
  assert.equal(body.structuredContent.timers[0].runtime.status, 'finished');
});

test('a paused timer fires nothing until it resumes, then continues without repeats', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink, op } = context;
  const { id, timer } = await startTabata(context);
  const startedAt = clock.now();
  clock.advance(15_000);
  const beforePause = sink.received.length;
  assert.deepEqual(sink.received.map(label), expectedAlerts(timer, startedAt, startedAt + 15_000));

  assert.equal((await op('pause', { id })).status, 200);
  clock.advance(10 * 60_000);
  assert.equal(sink.received.length, beforePause);

  const resumed = await op('resume', { id });
  const resumedTimer = resumed.body.timer;
  const resumedAt = clock.now();
  clock.advance(TABATA_MS);
  assert.deepEqual(sink.received.slice(beforePause).map(label), expectedAlerts(resumedTimer, resumedAt, resumedAt + TABATA_MS));
  // Across the pause, every step start still fired once.
  assert.equal(sink.received.filter(({ alert }) => alert.kind === 'segment').length, 16);
  assert.equal(sink.received.filter(({ alert }) => alert.kind === 'finish').length, 1);
});

test('skip re-arms for the next step instead of the one skipped', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink, op } = context;
  const { id } = await startTabata(context);
  const startedAt = clock.now();
  clock.advance(12_000);
  const beforeSkip = sink.received.length;
  const skipped = await op('skip', { id });
  assert.equal(skipped.body.timer.projection.step.phase, 'rest');
  const skippedAt = clock.now();
  clock.advance(11_000);
  // The work step's final ticks (at 27, 28 and 29 s) never fire; the rest step's do, 7 s after the skip.
  assert.deepEqual(sink.received.slice(beforeSkip).map(label), [
    `tick@${skippedAt + 7_000}`, `tick@${skippedAt + 8_000}`, `tick@${skippedAt + 9_000}`, `segment@${skippedAt + 10_000}`
  ]);
  assert.equal(skippedAt, startedAt + 12_000);
});

test('transitions missed while asleep collapse into one missedWhileAway alert per timer', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink, op, call } = context;
  const tabata = await startTabata(context);
  const other = await op('start', { timer: { kind: 'countdown', durationMs: 30_000, name: 'Short' } });
  const startedAt = clock.now();
  clock.advance(5_000);
  const beforeSleep = sink.received.length;
  // The computer sleeps for a minute. The wall clock moves on; the armed timeout (the prep's tick
  // at 7 s, due 2 s after the sleep began) fires 2 s after the wake, 67 s after the start.
  clock.jump(60_000);
  clock.advance(2_000);
  const woke = sink.received.slice(beforeSleep).map(({ alert }) => alert);
  assert.deepEqual(woke.map((alert) => [alert.timerId, alert.kind]), [
    [tabata.id, 'missedWhileAway'],
    [other.body.timer.definition.id, 'missedWhileAway'],
    [tabata.id, 'tick']
  ]);
  assert.equal(woke[0].at, startedAt + 67_000);
  assert.equal(woke[0].missed, expectedAlerts(tabata.timer, startedAt + 5_000, startedAt + 65_000).length);
  assert.equal(woke[0].segment.phase, 'rest');
  assert.equal(woke[1].missed, 1);
  assert.equal(woke[2].at, startedAt + 67_000);

  const { body } = await call('GET', '/v1/timers');
  const [tabataNow, shortNow] = body.structuredContent.timers;
  assert.equal(tabataNow.projection.elapsedMs, 67_000);
  assert.equal(tabataNow.projection.step.round, 2);
  assert.equal(shortNow.runtime.status, 'finished');

  // Alerts on time continue after the wake.
  clock.advance(1_000);
  assert.deepEqual(sink.received.slice(beforeSleep + 3).map(label), [`tick@${startedAt + 68_000}`]);
});

function runningTabata(clock) {
  const preset = BUILT_IN_PRESETS.find((entry) => entry.id === 'tabata');
  return {
    definition: { ...preset.timer, id: 't_00000001', name: 'Tabata', sound: true, countdownTicks: true, createdAt: clock.now() },
    runtime: { status: 'running', startedAt: clock.now(), accumulatedMs: 0, pausedAt: null, laps: [], skippedMs: 0 }
  };
}

test('a transition at most 2 s late fires as itself; one later is missed', () => {
  for (const [lateBy, kinds] of [[LATE_MS, ['tick', 'tick', 'tick']], [LATE_MS + 1, ['missedWhileAway', 'tick', 'tick']]]) {
    const clock = createFakeClock();
    const timer = runningTabata(clock);
    const delivered = [];
    const scheduler = createScheduler({ clock, getTimers: () => [timer], deliver: (alerts) => delivered.push(...alerts), initialMark: clock.now() });
    // The prep's ticks are at 7, 8 and 9 s; the first is handled `lateBy` after it.
    clock.jump(7_000 + lateBy);
    scheduler.run();
    scheduler.stop();
    assert.deepEqual(delivered.map(({ alert }) => alert.kind), kinds, `${lateBy} ms late`);
    assert.equal(project(timer, clock.now()).step.phase, 'prep');
  }
});

test('a restart reports what was missed while the daemon was down, and nothing it already delivered', async (t) => {
  const dataDir = tempDataDir(t);
  const first = await startTestDaemon(t, { dataDir });
  const { id } = await startTabata(first);
  first.clock.advance(15_000);
  assert.ok(first.sink.received.length > 0);
  await first.daemon.shutdown();

  const again = await startTestDaemon(t, { dataDir, clock: first.clock });
  assert.deepEqual(again.sink.received, []);
  await again.daemon.shutdown();

  first.clock.jump(60_000);
  const later = await startTestDaemon(t, { dataDir, clock: first.clock });
  assert.deepEqual(later.sink.received.map(({ alert }) => [alert.timerId, alert.kind]), [[id, 'missedWhileAway']]);
});

test('the scheduler looks again at least every 60 s, so a clock set back is followed', () => {
  const clock = createFakeClock();
  const timer = {
    definition: { kind: 'countdown', durationMs: 3_600_000, id: 't_00000001', name: 'Hour', sound: true, countdownTicks: false, createdAt: clock.now() },
    runtime: { status: 'running', startedAt: clock.now(), accumulatedMs: 0, pausedAt: null, laps: [], skippedMs: 0 }
  };
  const delivered = [];
  const scheduler = createScheduler({ clock, getTimers: () => [timer], deliver: (alerts) => delivered.push(...alerts), initialMark: clock.now() });
  scheduler.run();
  clock.advance(60_000);
  assert.equal(scheduler.checkedThrough, clock.now());
  // The wall clock is set back an hour; the scheduler follows it at its next look.
  clock.jump(-3_600_000);
  clock.advance(60_000);
  assert.equal(scheduler.checkedThrough, clock.now());
  scheduler.stop();
  assert.deepEqual(delivered, []);
});
