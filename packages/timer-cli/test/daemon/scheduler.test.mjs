import assert from 'node:assert/strict';
import { chmodSync } from 'node:fs';
import test from 'node:test';
import { BUILT_IN_PRESETS, project, transitionsBetween } from '@subset.dev/timer-core';
import { LATE_MS, REARM_MS, RECORDING_LIMIT, createFakeClock, createRecordingSink, createScheduler, socketRequest, startDaemon } from '../../src/daemon/index.mjs';
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

test('the default sink keeps only the latest alerts, however many runs and removals the daemon sees', async (t) => {
  const clock = createFakeClock();
  const daemon = await startDaemon({ dataDir: tempDataDir(t), clock, log: () => {} });
  t.after(() => daemon.shutdown());
  const op = (name, input) => socketRequest(daemon.paths.socket, 'POST', `/v1/ops/${name}`, input);
  const started = await op('start', { preset: 'tabata' });
  clock.advance(TABATA_MS + 1_000);
  assert.equal((await op('remove', { id: started.body.timer.definition.id })).status, 200);
  assert.deepEqual([daemon.sink.name, daemon.sink.limit, daemon.sink.received.length], ['recording', RECORDING_LIMIT, 68]);

  // What the daemon would record over 100 timers' runs, each removed after it: only the latest stay.
  const sink = createRecordingSink();
  const definition = started.body.timer.definition;
  for (let run = 0; run < 100; run++) {
    for (let at = 0; at < 68; at++) sink.alert({ timerId: `t_${run}`, kind: 'tick', secondsLeft: 1, at: run * 68 + at }, { ...definition, id: `t_${run}` });
  }
  assert.equal(sink.received.length, RECORDING_LIMIT);
  assert.deepEqual(sink.received.map(({ alert }) => alert.at), Array.from({ length: RECORDING_LIMIT }, (_, index) => 6_800 - RECORDING_LIMIT + index));
  const small = createRecordingSink({ limit: 2 });
  for (const at of [1, 2, 3]) small.alert({ timerId: 't', kind: 'finish', at }, definition);
  assert.deepEqual(small.received.map(({ alert }) => alert.at), [2, 3]);
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
    const scheduler = createScheduler({ clock, getTimers: () => [timer], onRun: (alerts) => delivered.push(...alerts) });
    scheduler.run();
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

function runningCountdown(clock, durationMs, countdownTicks) {
  return {
    definition: { kind: 'countdown', durationMs, lapsEnabled: false, id: 't_00000001', name: 'Countdown', sound: true, countdownTicks, createdAt: clock.now() },
    runtime: { status: 'running', startedAt: clock.now(), accumulatedMs: 0, pausedAt: null, laps: [], skippedMs: 0 }
  };
}

test('the scheduler looks again at least every 60 s, so a clock set forward is noticed', () => {
  const clock = createFakeClock();
  const timer = runningCountdown(clock, 3_600_000, false);
  const runs = [];
  const scheduler = createScheduler({ clock, getTimers: () => [timer], onRun: (alerts, now) => runs.push({ alerts, now }) });
  scheduler.run();
  clock.advance(60_000);
  assert.equal(runs.length, 2);
  // The wall clock is set forward past the finish; the next look, at most 60 s later, reports it.
  clock.jump(3_600_000);
  clock.advance(60_000);
  scheduler.stop();
  assert.deepEqual(runs.flatMap(({ alerts }) => alerts.map(({ alert }) => alert.kind)), ['missedWhileAway']);
});

test('a clock set back repeats no alert, and the ones still ahead fire once when the clock reaches them', () => {
  for (const back of [1_500, 5_000, 3_600_000]) {
    const clock = createFakeClock();
    const startedAt = clock.now();
    const timer = runningCountdown(clock, 20_000, true);
    const delivered = [];
    const scheduler = createScheduler({ clock, getTimers: () => [timer], onRun: (alerts) => delivered.push(...alerts) });
    scheduler.run();
    clock.advance(18_000);
    assert.deepEqual(delivered.map(label), [`tick@${startedAt + 17_000}`, `tick@${startedAt + 18_000}`]);
    clock.jump(-back);
    clock.advance(back + 5_000);
    scheduler.stop();
    assert.deepEqual(delivered.map(label), [17_000, 18_000, 19_000].map((at) => `tick@${startedAt + at}`).concat(`finish@${startedAt + 20_000}`), `set back ${back} ms`);
  }
});

test('a timer started after the clock was set back fires its finish and is recorded finished', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink, op, daemon } = context;
  clock.advance(10_000);
  await op('create', { timer: { kind: 'stopwatch' } });
  clock.jump(-1_500);
  const started = await op('start', { timer: { kind: 'countdown', durationMs: 1_000 } });
  const startedAt = clock.now();
  clock.advance(1_000);
  assert.deepEqual(sink.received.map(label), [`finish@${startedAt + 1_000}`]);
  assert.equal(daemon.store.timers.find((timer) => timer.definition.id === started.body.timer.definition.id).runtime.status, 'finished');
});

/** A fake clock whose wall time moves on by 1 ms every time it is read, as a real one may between two reads. */
function driftingClock() {
  const base = createFakeClock();
  return {
    ...base,
    now() {
      const value = base.now();
      base.jump(1);
      return value;
    },
    advance: base.advance,
    jump: base.jump
  };
}

test('skip fires the same alerts however much time passes between reads of the clock', async (t) => {
  const outcomes = [];
  for (const clock of [createFakeClock(), driftingClock()]) {
    const context = await startTestDaemon(t, { clock });
    const { id } = await startTabata(context);
    clock.advance(12_000);
    const beforeSkip = context.sink.received.length;
    await context.op('skip', { id });
    clock.advance(11_000);
    outcomes.push(context.sink.received.slice(beforeSkip).map(({ alert }) => `${alert.kind}:${alert.secondsLeft ?? alert.segment.phase}`));
  }
  assert.deepEqual(outcomes[0], ['tick:3', 'tick:2', 'tick:1', 'segment:work']);
  assert.deepEqual(outcomes[1], outcomes[0]);
});

test('after a skip, resume or start a restart fires nothing, and the next transitions once each', async (t) => {
  for (const scenario of ['skip', 'resume', 'start']) {
    const dataDir = tempDataDir(t);
    const first = await startTestDaemon(t, { dataDir });
    const { clock } = first;
    const { id } = await startTabata(first);
    clock.advance(3_000);
    if (scenario === 'skip') assert.equal((await first.op('skip', { id })).body.timer.projection.step.phase, 'work');
    if (scenario === 'resume') {
      await first.op('pause', { id });
      clock.advance(2_000);
      await first.op('resume', { id });
    }
    const changedAt = clock.now();
    clock.advance(1_000);
    await first.daemon.shutdown();
    assert.deepEqual(first.sink.received, [], scenario);

    // The daemon is down for a second; no transition falls in the 2 s since the change.
    clock.jump(1_000);
    const again = await startTestDaemon(t, { dataDir, clock });
    assert.deepEqual(again.sink.received, [], scenario);
    clock.advance(25_000);
    const timer = again.daemon.store.timers.find((entry) => entry.definition.id === id);
    const expected = expectedAlerts(timer, changedAt, clock.now());
    assert.ok(expected.length > 0);
    assert.deepEqual(again.sink.received.map(label), expected, scenario);
  }
});

test('a transition that falls due while another is delivered fires as itself, on time', async (t) => {
  const context = await startTestDaemon(t);
  const { clock, sink, op } = context;
  const startedAt = clock.now();
  for (const durationMs of [1_000, 1_005]) assert.equal((await op('start', { timer: { kind: 'countdown', durationMs } })).status, 200);
  const deliveredAt = [];
  const record = sink.alert.bind(sink);
  sink.alert = (alert, timer) => {
    deliveredAt.push(clock.now());
    record(alert, timer);
    // The first delivery (or the save after it) takes 10 ms, past the second timer's finish.
    if (deliveredAt.length === 1) clock.jump(10);
  };
  clock.advance(2_000);
  assert.deepEqual(sink.received.map(label), [`finish@${startedAt + 1_000}`, `finish@${startedAt + 1_005}`]);
  assert.ok(deliveredAt[1] - (startedAt + 1_005) <= LATE_MS, `${deliveredAt[1] - startedAt}`);
});

test('a checkpoint the disk refused after an alert is saved at a later run, so a restart reports nothing', { skip: process.getuid?.() === 0 && 'root ignores file modes' }, async (t) => {
  const dataDir = tempDataDir(t);
  const first = await startTestDaemon(t, { dataDir });
  const { clock } = first;
  const segments = [{ label: 'Work', phase: 'work', durationMs: 5_000 }, { label: 'Rest', phase: 'rest', durationMs: 200_000 }];
  const started = await first.op('start', { timer: { kind: 'interval', rounds: 2, segments, countdownTicks: false } });
  const startedAt = clock.now();
  const { id } = started.body.timer.definition;

  chmodSync(dataDir, 0o500);
  try {
    clock.advance(5_000);
  } finally {
    chmodSync(dataDir, 0o700);
  }
  assert.deepEqual(first.sink.received.map(label), [`segment@${startedAt + 5_000}`]);
  assert.ok(first.logs.some((line) => /could not save scheduler\.json/.test(line)));
  // The disk works again; the next run has no transition, a re-arm a minute later.
  clock.advance(REARM_MS);
  await first.daemon.shutdown();

  const again = await startTestDaemon(t, { dataDir, clock });
  assert.deepEqual(again.sink.received, []);
  clock.advance(startedAt + 205_000 - clock.now());
  assert.deepEqual(again.sink.received.map(({ alert }) => [alert.timerId, alert.kind, alert.at]), [[id, 'segment', startedAt + 205_000]]);
});
