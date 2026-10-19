import assert from 'node:assert/strict';
import test from 'node:test';
import { BUILT_IN_PRESETS, emptyStore, operations, project, totalDurationMs, transitionsBetween } from '../dist/index.js';

const T0 = Date.UTC(2026, 9, 19, 8, 0, 0);
const s = (seconds) => seconds * 1_000;

function started(input, now = T0) {
  const outcome = operations.start(emptyStore(), input, now);
  assert.ok(outcome.ok, JSON.stringify(outcome.error));
  return { store: outcome.store, id: outcome.result.timer.definition.id };
}
function apply(state, operation, now) {
  const outcome = operations[operation](state.store, { id: state.id }, now);
  assert.ok(outcome.ok, JSON.stringify(outcome.error));
  return { store: outcome.store, id: state.id };
}
const timerOf = (state) => state.store.timers.find((timer) => timer.definition.id === state.id);
const view = (state, now) => project(timerOf(state), now);
const stepOf = (projection) => projection.step && { round: projection.step.round, phase: projection.step.phase, remainingMs: projection.step.remainingMs };

test('interval projection changes step exactly at each segment edge', () => {
  const tabata = started({ preset: 'tabata' });
  assert.deepEqual(stepOf(view(tabata, T0)), { round: null, phase: 'prep', remainingMs: s(10) });
  assert.deepEqual(stepOf(view(tabata, T0 + s(10) - 1)), { round: null, phase: 'prep', remainingMs: 1 });
  assert.deepEqual(stepOf(view(tabata, T0 + s(10))), { round: 1, phase: 'work', remainingMs: s(20) });
  assert.deepEqual(stepOf(view(tabata, T0 + s(30))), { round: 1, phase: 'rest', remainingMs: s(10) });
  assert.deepEqual(stepOf(view(tabata, T0 + s(40))), { round: 2, phase: 'work', remainingMs: s(20) });
  const middle = view(tabata, T0 + s(78));
  assert.deepEqual(stepOf(middle), { round: 3, phase: 'work', remainingMs: s(12) });
  assert.deepEqual({ phase: middle.next.phase, round: middle.next.round, durationMs: middle.next.durationMs }, { phase: 'rest', round: 3, durationMs: s(10) });
  assert.equal(middle.remainingMs, s(250 - 78));
});

test('the last round has no next step and finishes at the total', () => {
  const tabata = started({ preset: 'tabata' });
  const lastRest = view(tabata, T0 + s(245));
  assert.deepEqual(stepOf(lastRest), { round: 8, phase: 'rest', remainingMs: s(5) });
  assert.equal(lastRest.next, null);
  assert.equal(lastRest.finished, false);
  const end = view(tabata, T0 + s(250));
  assert.equal(end.finished, true);
  assert.equal(end.status, 'finished');
  assert.equal(end.remainingMs, 0);
  assert.equal(end.step, null);
  // Long after the end the position stays at the total.
  assert.equal(view(tabata, T0 + s(9_999)).elapsedMs, s(250));
});

test('prep and cooldown frame the rounds', () => {
  const custom = started({ timer: { kind: 'interval', rounds: 2, prepMs: s(5), cooldownMs: s(30), segments: [{ label: 'Go', phase: 'work', durationMs: s(10) }] } });
  assert.equal(view(custom, T0).totalMs, s(55));
  assert.deepEqual(stepOf(view(custom, T0 + s(15))), { round: 2, phase: 'work', remainingMs: s(10) });
  const cooldown = view(custom, T0 + s(25));
  assert.deepEqual({ ...stepOf(cooldown), label: cooldown.step.label }, { round: null, phase: 'cooldown', remainingMs: s(30), label: 'Cooldown' });
  assert.equal(view(custom, T0 + s(24)).next.phase, 'cooldown');
});

test('pause keeps the place and resume continues across a segment edge', () => {
  let tabata = started({ preset: 'tabata' });
  tabata = apply(tabata, 'pause', T0 + s(29.5));
  // An hour passes while paused; nothing moves.
  assert.deepEqual(stepOf(view(tabata, T0 + s(3_600))), { round: 1, phase: 'work', remainingMs: s(0.5) });
  assert.equal(view(tabata, T0 + s(3_600)).status, 'paused');
  tabata = apply(tabata, 'resume', T0 + s(3_600));
  assert.deepEqual(stepOf(view(tabata, T0 + s(3_600.4))), { round: 1, phase: 'work', remainingMs: s(0.1) });
  assert.deepEqual(stepOf(view(tabata, T0 + s(3_600.6))), { round: 1, phase: 'rest', remainingMs: s(9.9) });
});

test('skip jumps to the next segment, and on the last segment of the last round finishes the timer', () => {
  let tabata = started({ preset: 'tabata' });
  tabata = apply(tabata, 'skip', T0 + s(3));
  assert.deepEqual(stepOf(view(tabata, T0 + s(3))), { round: 1, phase: 'work', remainingMs: s(20) });
  assert.equal(view(tabata, T0 + s(3)).remainingMs, s(240));
  tabata = apply(tabata, 'pause', T0 + s(4));
  tabata = apply(tabata, 'skip', T0 + s(5));
  const paused = view(tabata, T0 + s(60));
  assert.equal(paused.status, 'paused');
  assert.deepEqual(stepOf(paused), { round: 1, phase: 'rest', remainingMs: s(10) });
  tabata = apply(tabata, 'resume', T0 + s(60));
  tabata = apply(tabata, 'pause', T0 + s(60 + 240 - 22));
  assert.deepEqual(stepOf(view(tabata, T0 + s(400))), { round: 8, phase: 'rest', remainingMs: s(2) });
  tabata = apply(tabata, 'skip', T0 + s(400));
  assert.equal(timerOf(tabata).runtime.status, 'finished');
  const end = view(tabata, T0 + s(401));
  assert.equal(end.finished, true);
  assert.equal(end.elapsedMs, s(250));
});

test('a clock that goes backward clamps elapsed time instead of going negative', () => {
  const countdown = started({ timer: { kind: 'countdown', durationMs: s(60) } });
  const before = view(countdown, T0 - s(30));
  assert.equal(before.elapsedMs, 0);
  assert.equal(before.remainingMs, s(60));
  assert.equal(before.status, 'running');
  // A timer paused after 20 s keeps those 20 s when resumed and the clock then steps back.
  let resumed = apply(countdown, 'pause', T0 + s(20));
  resumed = apply(resumed, 'resume', T0 + s(100));
  assert.equal(view(resumed, T0 + s(50)).elapsedMs, s(20));
  const stopwatch = started({ timer: { kind: 'stopwatch' } });
  assert.equal(view(stopwatch, T0 - 1).elapsedMs, 0);
  assert.deepEqual(transitionsBetween(timerOf(countdown), T0 + s(10), T0 + s(5)), []);
});

test('countdown and stopwatch projections', () => {
  const countdown = started({ timer: { kind: 'countdown', durationMs: s(90) } });
  assert.deepEqual(
    (({ status, elapsedMs, remainingMs, totalMs, step, next }) => ({ status, elapsedMs, remainingMs, totalMs, step, next }))(view(countdown, T0 + s(30))),
    { status: 'running', elapsedMs: s(30), remainingMs: s(60), totalMs: s(90), step: null, next: null }
  );
  assert.equal(view(countdown, T0 + s(90)).finished, true);
  const stopwatch = started({ timer: { kind: 'stopwatch' } });
  const later = view(stopwatch, T0 + s(86_400 * 3));
  assert.deepEqual([later.elapsedMs, later.totalMs, later.remainingMs, later.finished], [s(86_400 * 3), null, null, false]);
});

test('an until countdown counts to its time while idle and fixes its duration when it starts', () => {
  const until = new Date(T0 + s(600)).toISOString();
  const created = operations.create(emptyStore(), { timer: { kind: 'countdown', until } }, T0);
  assert.ok(created.ok);
  const idle = created.store.timers[0];
  assert.equal(totalDurationMs(idle.definition, T0 + s(100)), s(500));
  const start = operations.start(created.store, { id: idle.definition.id }, T0 + s(100));
  assert.ok(start.ok);
  assert.equal(start.store.timers[0].definition.durationMs, s(500));
  // Pausing past the original time no longer changes the length.
  const paused = operations.pause(start.store, { id: idle.definition.id }, T0 + s(200));
  assert.equal(project(paused.store.timers[0], T0 + s(900)).remainingMs, s(400));
});

test('every built-in preset has its documented total duration', () => {
  const totals = Object.fromEntries(BUILT_IN_PRESETS.map((preset) => [preset.id, totalDurationMs({ ...preset.timer, id: 't_00000000', name: preset.name, sound: true, countdownTicks: true, createdAt: T0, lapsEnabled: false }, T0)]));
  assert.deepEqual(totals, {
    tabata: s(10 + 8 * 30),
    emom: s(10 * 60),
    'hiit-40-20': s(10 * 60),
    pomodoro: s(60 * (4 * 25 + 3 * 5 + 15)),
    amrap: s(20 * 60)
  });
  for (const preset of BUILT_IN_PRESETS) {
    const { store } = started({ preset: preset.id });
    assert.equal(project(store.timers[0], T0).totalMs, totals[preset.id], preset.id);
  }
});

test('transitionsBetween lists segment starts, final-3-second ticks and the finish once each', () => {
  const tabata = timerOf(started({ preset: 'tabata' }));
  const describe = (transitions) => transitions.map((item) => `${item.type}${item.secondsLeft ?? ''}@${(item.at - T0) / 1_000}${item.step ? `:${item.step.phase}${item.step.round}` : ''}`);
  assert.deepEqual(describe(transitionsBetween(tabata, T0, T0 + s(40))), [
    'tick3@7', 'tick2@8', 'tick1@9', 'segment@10:work1',
    'tick3@27', 'tick2@28', 'tick1@29', 'segment@30:rest1',
    'tick3@37', 'tick2@38', 'tick1@39', 'segment@40:work2'
  ]);
  // Windows that split the run report each transition exactly once.
  const whole = transitionsBetween(tabata, T0, T0 + s(1_000));
  const pieces = [0, 7, 7.5, 10, 123, 249, 250, 1_000].map(s).reduce((list, at, index, all) =>
    index ? [...list, ...transitionsBetween(tabata, T0 + all[index - 1], T0 + at)] : list, []);
  assert.deepEqual(pieces, whole);
  assert.equal(whole.filter((item) => item.type === 'segment').length, 16);
  assert.equal(whole.filter((item) => item.type === 'tick').length, 17 * 3);
  assert.deepEqual(describe(whole.slice(-4)), ['tick3@247', 'tick2@248', 'tick1@249', 'finish@250']);
});

test('transitions follow pause and skip, and respect countdownTicks', () => {
  let tabata = started({ preset: 'tabata' });
  tabata = apply(tabata, 'pause', T0 + s(5));
  assert.deepEqual(transitionsBetween(timerOf(tabata), T0, T0 + s(100)), []);
  tabata = apply(tabata, 'resume', T0 + s(100));
  // 5 s of prep remain, so the first work segment starts at 105 s.
  assert.equal(transitionsBetween(timerOf(tabata), T0 + s(100), T0 + s(105)).at(-1).at, T0 + s(105));
  tabata = apply(tabata, 'skip', T0 + s(101));
  const afterSkip = transitionsBetween(timerOf(tabata), T0 + s(101), T0 + s(121));
  assert.deepEqual(afterSkip.map((item) => [item.type, (item.at - T0) / 1_000]), [['tick', 118], ['tick', 119], ['tick', 120], ['segment', 121]]);

  const quiet = timerOf(started({ timer: { kind: 'countdown', durationMs: s(10) } }));
  assert.deepEqual(transitionsBetween(quiet, T0, T0 + s(20)).map((item) => item.type), ['finish']);
  const ticking = timerOf(started({ timer: { kind: 'countdown', durationMs: s(2), countdownTicks: true } }));
  assert.deepEqual(transitionsBetween(ticking, T0, T0 + s(5)).map((item) => `${item.type}@${(item.at - T0) / 1_000}`), ['tick@1', 'finish@2']);
  assert.deepEqual(transitionsBetween(timerOf(started({ timer: { kind: 'stopwatch' } })), T0, T0 + s(100)), []);
});
