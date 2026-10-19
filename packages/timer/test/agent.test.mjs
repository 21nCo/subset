import assert from 'node:assert/strict';
import test from 'node:test';
import { TIMER_VIEW_ID, agentTimerResult, emptyStore, formatDuration, operations } from '../dist/index.js';

const T0 = Date.UTC(2026, 9, 19, 8, 0, 0);

function scenario(input, steps = []) {
  let outcome = operations.start(emptyStore(), input, T0);
  assert.ok(outcome.ok, JSON.stringify(outcome.error));
  const id = outcome.result.timer.definition.id;
  for (const [operation, at] of steps) {
    outcome = operations[operation](outcome.store, { id }, T0 + at);
    assert.ok(outcome.ok, JSON.stringify(outcome.error));
  }
  return { store: outcome.store, id };
}
const lineAt = ({ store }, at) => agentTimerResult(store, T0 + at).text;

test('formatDuration rounds time left up and elapsed time down', () => {
  assert.deepEqual(
    [0, 1, 999, 1_000, 59_001, 60_000, 3_599_999, 3_600_000, 36_061_000].map((ms) => [formatDuration(ms, 'up'), formatDuration(ms, 'down')]),
    [['0:00', '0:00'], ['0:01', '0:00'], ['0:01', '0:00'], ['0:01', '0:01'], ['1:00', '0:59'], ['1:00', '1:00'], ['1:00:00', '59:59'], ['1:00:00', '1:00:00'], ['10:01:01', '10:01:01']]
  );
});

test('interval text in each state', () => {
  const tabata = scenario({ preset: 'tabata' });
  const id = tabata.id;
  assert.equal(lineAt(tabata, 78_000), `Tabata (${id}): running · round 3/8 · work · 0:12 left · next rest 0:10`);
  assert.equal(lineAt(tabata, 3_000), `Tabata (${id}): running · prep · 0:07 left · next work 0:20`);
  assert.equal(lineAt(tabata, 245_500), `Tabata (${id}): running · round 8/8 · rest · 0:05 left`);
  assert.equal(lineAt(tabata, 250_000), `Tabata (${id}): finished · 4:10 total`);
  assert.equal(lineAt(scenario({ preset: 'tabata' }, [['pause', 78_000]]), 600_000), `Tabata (${id}): paused · round 3/8 · work · 0:12 left · next rest 0:10`);
  assert.equal(lineAt(scenario({ preset: 'tabata' }, [['reset', 1_000]]), 2_000), `Tabata (${id}): idle · 4:10 total`);
  // One round of several segments counts segments instead; a label that differs from the phase is shown.
  const pomodoro = scenario({ preset: 'pomodoro' });
  assert.equal(lineAt(pomodoro, 26 * 60_000), `Pomodoro (${pomodoro.id}): running · segment 2/8 · rest (Break) · 4:00 left · next work (Focus) 25:00`);
});

test('countdown and stopwatch text in each state', () => {
  const amrap = scenario({ preset: 'amrap' }, [['lap', 60_000], ['lap', 120_000]]);
  assert.equal(lineAt(amrap, 125_000), `AMRAP (${amrap.id}): running · 17:55 left · 2 laps`);
  assert.equal(lineAt(amrap, 1_200_000), `AMRAP (${amrap.id}): finished · 20:00 total · 2 laps`);
  const tea = scenario({ timer: { kind: 'countdown', name: 'Tea', durationMs: 180_000 } }, [['pause', 30_500]]);
  assert.equal(lineAt(tea, 99_000), `Tea (${tea.id}): paused · 2:30 left`);
  const run = scenario({ timer: { kind: 'stopwatch', name: 'Run' } }, [['lap', 61_000]]);
  assert.equal(lineAt(run, 90_999), `Run (${run.id}): running · 1:30 elapsed · 1 lap`);
  const idle = scenario({ timer: { kind: 'stopwatch', name: 'Run' } }, [['reset', 5_000]]);
  assert.equal(lineAt(idle, 9_000), `Run (${idle.id}): idle`);
});

test('agentTimerResult returns structured content, one line per timer and the view id', () => {
  const empty = agentTimerResult(emptyStore(), T0);
  assert.deepEqual(empty, { structuredContent: { schemaVersion: 1, observedAt: T0, timers: [] }, text: 'No timers.', viewId: 'subset.timer.board@1' });
  assert.equal(TIMER_VIEW_ID, 'subset.timer.board@1');
  let store = scenario({ preset: 'emom' }).store;
  store = operations.start(store, { timer: { kind: 'stopwatch', name: 'Two' } }, T0).store;
  const result = agentTimerResult(store, T0 + 61_000);
  assert.equal(result.structuredContent.observedAt, T0 + 61_000);
  assert.deepEqual(result.structuredContent.timers.map((timer) => [timer.definition.name, timer.projection.status, timer.projection.step?.round ?? null]), [['EMOM', 'running', 2], ['Two', 'running', null]]);
  assert.equal(result.text.split('\n').length, 2);
  // The snapshot carries what a view needs to re-project later without asking again.
  assert.deepEqual(Object.keys(result.structuredContent.timers[0]), ['definition', 'runtime', 'projection']);
});
