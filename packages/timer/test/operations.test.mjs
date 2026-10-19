import assert from 'node:assert/strict';
import test from 'node:test';
import {
  ID_SPACE, OPERATION_NAMES, OPERATION_WRITE_CLASS, PRESET_ID_PATTERN, TIMER_ID_PATTERN, TIMER_LIMITS, emptyStore, idSequenceOf, issuedId,
  operations, parseStore, runOperation
} from '../dist/index.js';

const T0 = Date.UTC(2026, 9, 19, 8, 0, 0);
const MISSING = 't_zzzzzzzz';

function ok(outcome) {
  assert.equal(outcome.ok, true, JSON.stringify(outcome.error));
  return outcome;
}
const code = (outcome) => (outcome.ok ? 'ok' : outcome.error.code);
function storeWith(...inputs) {
  let store = emptyStore();
  const ids = inputs.map((input) => {
    const outcome = ok(operations.create(store, input, T0));
    store = outcome.store;
    return outcome.result.timer.definition.id;
  });
  return { store, ids };
}

test('write classes match the product decision', () => {
  assert.deepEqual(OPERATION_NAMES.filter((name) => OPERATION_WRITE_CLASS[name] === 'destructive'), ['reset', 'remove', 'presets.remove']);
  assert.deepEqual(OPERATION_NAMES.filter((name) => OPERATION_WRITE_CLASS[name] === 'read'), ['list', 'get', 'presets.list']);
  assert.deepEqual(OPERATION_NAMES.filter((name) => OPERATION_WRITE_CLASS[name] === 'write'), ['create', 'start', 'pause', 'resume', 'lap', 'skip', 'presets.save']);
});

test('create fills defaults per kind and gives each timer its own id', () => {
  const { store, ids } = storeWith(
    { timer: { kind: 'countdown', durationMs: 60_000 } },
    { timer: { kind: 'stopwatch' } },
    { preset: 'tabata' },
    { preset: 'tabata', name: 'Evening' }
  );
  assert.equal(new Set(ids).size, 4);
  for (const id of ids) assert.match(id, TIMER_ID_PATTERN);
  const [countdown, stopwatch, tabata, renamed] = store.timers.map((timer) => timer.definition);
  assert.deepEqual([countdown.name, countdown.sound, countdown.countdownTicks, countdown.lapsEnabled, countdown.createdAt], ['Countdown', true, false, false, T0]);
  assert.equal(stopwatch.name, 'Stopwatch');
  assert.deepEqual([tabata.name, tabata.countdownTicks, tabata.prepMs, tabata.rounds], ['Tabata', true, 10_000, 8]);
  assert.equal(renamed.name, 'Evening');
  assert.ok(store.timers.every((timer) => timer.runtime.status === 'idle'));
  // Names need not be unique.
  assert.equal(ok(operations.create(store, { preset: 'tabata' }, T0)).store.timers.filter((timer) => timer.definition.name === 'Tabata').length, 2);
});

test('operations never change the store they were given', () => {
  const { store, ids } = storeWith({ preset: 'tabata' });
  const frozen = structuredClone(store);
  ok(operations.start(store, { id: ids[0] }, T0));
  ok(operations.remove(store, { id: ids[0] }, T0));
  ok(operations['presets.save'](store, { name: 'Mine', timer: { kind: 'stopwatch' } }, T0));
  assert.deepEqual(store, frozen);
});

test('each operation returns its typed error codes', () => {
  const { store, ids: [idle, stopwatch, interval, plain, finished] } = storeWith(
    { timer: { kind: 'countdown', durationMs: 60_000, lapsEnabled: true } },
    { timer: { kind: 'stopwatch' } },
    { preset: 'tabata' },
    { timer: { kind: 'countdown', durationMs: 60_000 } },
    { timer: { kind: 'countdown', durationMs: 1_000 } }
  );
  let running = store;
  for (const id of [stopwatch, interval, plain, finished]) running = ok(operations.start(running, { id }, T0)).store;
  const at = T0 + 5_000; // `finished` is past its end, though still stored as running.
  const table = [
    ['create', { timer: { kind: 'countdown', durationMs: 10 } }, 'invalid_input'],
    ['create', { preset: 'p_zzzzzzzz' }, 'not_found'],
    ['create', { timer: { kind: 'countdown', until: new Date(at - 1_000).toISOString() } }, 'invalid_input'],
    ['create', { timer: { kind: 'countdown', until: new Date(at + 86_400_001).toISOString() } }, 'invalid_input'],
    ['create', { timer: { kind: 'countdown', until: new Date(at + 86_400_000).toISOString() } }, 'ok'],
    ['start', { id: MISSING }, 'not_found'],
    ['start', { id: stopwatch }, 'invalid_state'],
    ['start', { id: finished }, 'invalid_state'],
    ['start', { id: idle }, 'ok'],
    ['start', { id: idle, name: 'x' }, 'invalid_input'],
    ['pause', { id: MISSING }, 'not_found'],
    ['pause', { id: idle }, 'invalid_state'],
    ['pause', { id: finished }, 'invalid_state'],
    ['pause', { id: interval }, 'ok'],
    ['resume', { id: stopwatch }, 'invalid_state'],
    ['resume', { id: MISSING }, 'not_found'],
    ['lap', { id: interval }, 'invalid_state'],
    ['lap', { id: plain }, 'invalid_state'],
    ['lap', { id: idle }, 'invalid_state'],
    ['lap', { id: stopwatch }, 'ok'],
    ['lap', { id: MISSING }, 'not_found'],
    ['skip', { id: stopwatch }, 'invalid_state'],
    ['skip', { id: plain }, 'invalid_state'],
    ['skip', { id: interval }, 'ok'],
    ['skip', { id: MISSING }, 'not_found'],
    ['reset', { id: finished }, 'ok'],
    ['reset', { id: idle }, 'ok'],
    ['reset', { id: MISSING }, 'not_found'],
    ['remove', { id: MISSING }, 'not_found'],
    ['remove', { id: 'Tabata' }, 'invalid_input'],
    ['get', { id: MISSING }, 'not_found'],
    ['get', {}, 'invalid_input'],
    ['list', { all: true }, 'invalid_input'],
    ['presets.list', { all: true }, 'invalid_input'],
    ['presets.save', { name: 'x', timer: { kind: 'countdown', until: new Date(at + 60_000).toISOString() } }, 'invalid_input'],
    ['presets.remove', { id: 'tabata' }, 'invalid_state'],
    ['presets.remove', { id: 'p_zzzzzzzz' }, 'not_found']
  ];
  assert.deepEqual(
    table.map(([operation, input]) => [operation, input, code(operations[operation](running, input, at))]),
    table
  );
  // A skipped lap or pause after the finish leaves the stored state alone.
  const paused = ok(operations.pause(running, { id: interval }, at)).store;
  assert.equal(code(operations.lap(paused, { id: interval }, at)), 'invalid_state');
  assert.equal(code(operations.resume(paused, { id: interval }, at)), 'ok');
  assert.equal(code(runOperation('explode', running, {}, at)), 'invalid_input');
  assert.equal(code(runOperation('toString', running, {}, at)), 'invalid_input');
  assert.equal(code(runOperation('presets.list', running, undefined, at)), 'ok');
});

test('invalid input reports every failing field', () => {
  const outcome = operations.create(emptyStore(), { timer: { kind: 'interval', rounds: 0, segments: [{ label: '', phase: 'warmup', durationMs: 1 }] } }, T0);
  assert.equal(outcome.error.code, 'invalid_input');
  assert.deepEqual(outcome.error.issues.map((issue) => issue.path).sort(), ['timer.rounds', 'timer.segments.0.durationMs', 'timer.segments.0.label', 'timer.segments.0.phase']);
});

test('at most 50 timers in any state; finished ones count until reset or removed', () => {
  let store = emptyStore();
  for (let index = 0; index < TIMER_LIMITS.timers; index++) {
    store = ok(operations.start(store, { timer: { kind: 'countdown', durationMs: 1_000 } }, T0 + index)).store;
  }
  const later = T0 + 60_000;
  assert.ok(ok(operations.list(store, {}, later)).result.timers.every((timer) => timer.projection.finished));
  assert.equal(code(operations.create(store, { timer: { kind: 'stopwatch' } }, later)), 'limit_reached');
  assert.equal(code(operations.start(store, { preset: 'emom' }, later)), 'limit_reached');
  const id = store.timers[0].definition.id;
  const reset = ok(operations.reset(store, { id }, later)).store;
  assert.equal(code(operations.create(reset, { timer: { kind: 'stopwatch' } }, later)), 'limit_reached');
  const removed = ok(operations.remove(store, { id }, later)).store;
  assert.equal(code(operations.create(removed, { timer: { kind: 'stopwatch' } }, later)), 'ok');
  assert.equal(new Set(store.timers.map((timer) => timer.definition.id)).size, TIMER_LIMITS.timers);
});

test('at most 999 laps per timer', () => {
  let { store, ids: [id] } = storeWith({ timer: { kind: 'stopwatch' } });
  store = ok(operations.start(store, { id }, T0)).store;
  for (let index = 1; index <= TIMER_LIMITS.laps; index++) store = ok(operations.lap(store, { id }, T0 + index)).store;
  assert.equal(code(operations.lap(store, { id }, T0 + 5_000)), 'limit_reached');
  assert.deepEqual(store.timers[0].runtime.laps.at(-1), { elapsedMs: 999, at: T0 + 999 });
});

test('saved presets: up to 50, listed after the built-ins, and usable by id', () => {
  let store = emptyStore();
  const saved = [];
  for (let index = 0; index < TIMER_LIMITS.userPresets; index++) {
    const outcome = ok(operations['presets.save'](store, { name: `Mine ${index}`, timer: { kind: 'countdown', durationMs: 1_000 * (index + 1) } }, T0));
    store = outcome.store;
    saved.push(outcome.result.preset.id);
  }
  assert.equal(new Set(saved).size, TIMER_LIMITS.userPresets);
  assert.equal(code(operations['presets.save'](store, { name: 'One more', timer: { kind: 'stopwatch' } }, T0)), 'limit_reached');
  const listed = ok(operations['presets.list'](store, {}, T0)).result.presets;
  assert.deepEqual(listed.slice(0, 5).map((preset) => preset.id), ['tabata', 'emom', 'hiit-40-20', 'pomodoro', 'amrap']);
  assert.equal(listed.length, 5 + TIMER_LIMITS.userPresets);
  const started = ok(operations.start(store, { preset: saved[2] }, T0)).result.timer;
  assert.deepEqual([started.definition.name, started.definition.durationMs, started.runtime.status], ['Mine 2', 3_000, 'running']);
  const removed = ok(operations['presets.remove'](store, { id: saved[2] }, T0));
  assert.equal(removed.result.removedId, saved[2]);
  assert.equal(code(operations.start(removed.store, { preset: saved[2] }, T0)), 'not_found');
});

test('reset returns any timer to idle and clears laps and skips', () => {
  let { store, ids: [id] } = storeWith({ preset: 'amrap' });
  store = ok(operations.start(store, { id }, T0)).store;
  store = ok(operations.lap(store, { id }, T0 + 1_000)).store;
  const outcome = ok(operations.reset(store, { id }, T0 + 2_000));
  assert.deepEqual(outcome.store.timers[0].runtime, { status: 'idle', startedAt: null, accumulatedMs: 0, pausedAt: null, laps: [], skippedMs: 0 });
  assert.equal(outcome.result.timer.projection.remainingMs, 20 * 60_000);
});

test('parseStore accepts a store built by the operations and rejects inconsistent ones', () => {
  let { store, ids } = storeWith({ preset: 'tabata' }, { timer: { kind: 'stopwatch' } });
  store = ok(operations.start(store, { id: ids[0] }, T0)).store;
  store = ok(operations['presets.save'](store, { name: 'Mine', timer: { kind: 'stopwatch' } }, T0)).store;
  assert.deepEqual(ok(parseStore(JSON.parse(JSON.stringify(store)))).store, store);
  const broken = (change) => {
    const copy = structuredClone(store);
    change(copy);
    return code(parseStore(copy));
  };
  assert.equal(broken((copy) => { copy.timers[0].runtime.startedAt = null; }), 'invalid_input');
  assert.equal(broken((copy) => { copy.timers[1].definition.id = copy.timers[0].definition.id; }), 'invalid_input');
  assert.equal(broken((copy) => { copy.schemaVersion = 2; }), 'invalid_input');
  assert.equal(broken((copy) => { copy.presets[0].builtIn = true; }), 'invalid_input');
  assert.equal(code(parseStore(null)), 'invalid_input');
});

test('a removed id is not issued again, even in the same millisecond', () => {
  const first = ok(operations.create(emptyStore(), { timer: { kind: 'stopwatch' } }, T0));
  const id = first.result.timer.definition.id;
  const removed = ok(operations.remove(first.store, { id }, T0)).store;
  assert.equal(removed.timers.length, 0);
  assert.notEqual(ok(operations.create(removed, { timer: { kind: 'stopwatch' } }, T0)).result.timer.definition.id, id);
  const preset = ok(operations['presets.save'](removed, { name: 'Mine', timer: { kind: 'stopwatch' } }, T0));
  const presetId = preset.result.preset.id;
  const presetRemoved = ok(operations['presets.remove'](preset.store, { id: presetId }, T0)).store;
  assert.notEqual(ok(operations['presets.save'](presetRemoved, { name: 'Mine', timer: { kind: 'stopwatch' } }, T0)).result.preset.id, presetId);
});

test('issued ids are injective in the sequence and decode back to it', () => {
  const sequences = [0, 1, ID_SPACE - 1, ...Array.from({ length: 100_000 }, (_, index) => index + 2)];
  for (let index = 0; index < 20_000; index++) sequences.push(Math.floor(Math.random() * ID_SPACE));
  const bodies = new Map();
  for (const sequence of sequences) {
    const id = issuedId('t', sequence);
    assert.match(id, TIMER_ID_PATTERN);
    assert.match(issuedId('p', sequence), PRESET_ID_PATTERN);
    assert.equal(issuedId('p', sequence).slice(2), id.slice(2));
    assert.equal(idSequenceOf(id), sequence, id);
    const earlier = bodies.get(id);
    assert.ok(earlier === undefined || earlier === sequence, `${id} issued for ${earlier} and ${sequence}`);
    bodies.set(id, sequence);
  }
  assert.equal(idSequenceOf('tabata'), null);
});

test('timers and presets never repeat an id across removals, whatever the clock', () => {
  let store = emptyStore();
  const seen = new Set();
  const issue = (id) => {
    assert.ok(!seen.has(id.slice(2)), `reissued ${id}`);
    seen.add(id.slice(2));
  };
  for (let index = 0; index < 3_000; index++) {
    // Half the operations share one millisecond; the rest move the clock forward or back.
    const now = index % 2 ? T0 : T0 + ((index * 7_919) % 100_000) - 50_000;
    if (index % 3 === 2) {
      const saved = ok(operations['presets.save'](store, { name: 'Mine', timer: { kind: 'stopwatch' } }, now));
      issue(saved.result.preset.id);
      store = ok(operations['presets.remove'](saved.store, { id: saved.result.preset.id }, now)).store;
    } else {
      const created = ok(operations[index % 3 ? 'start' : 'create'](store, { timer: { kind: 'stopwatch' } }, now));
      issue(created.result.timer.definition.id);
      store = index % 5 ? ok(operations.remove(created.store, { id: created.result.timer.definition.id }, now)).store : created.store;
      if (store.timers.length === TIMER_LIMITS.timers) store = { ...store, timers: [] };
    }
  }
  assert.equal(store.idSequence, 3_000);
  assert.equal(parseStore(store).ok, true);
});

test('a store that has issued every id returns limit_reached without writing', () => {
  const exhausted = { ...emptyStore(), idSequence: ID_SPACE };
  assert.equal(parseStore(exhausted).ok, true);
  assert.equal(code(parseStore({ ...exhausted, idSequence: ID_SPACE + 1 })), 'invalid_input');
  for (const [name, input] of [['create', { timer: { kind: 'stopwatch' } }], ['start', { preset: 'tabata' }], ['presets.save', { name: 'Mine', timer: { kind: 'stopwatch' } }]]) {
    const outcome = operations[name](exhausted, input, T0);
    assert.equal(code(outcome), 'limit_reached', name);
  }
  assert.deepEqual(exhausted, { ...emptyStore(), idSequence: ID_SPACE });
  const last = ok(operations.create({ ...emptyStore(), idSequence: ID_SPACE - 1 }, { timer: { kind: 'stopwatch' } }, T0));
  assert.equal(last.result.timer.definition.id, issuedId('t', ID_SPACE - 1));
  assert.equal(last.store.idSequence, ID_SPACE);
});

test('every operation rejects a now that is not whole epoch milliseconds, without writing', () => {
  const { store, ids: [id] } = storeWith({ preset: 'tabata' });
  const inputs = {
    create: { timer: { kind: 'stopwatch' } }, start: { id }, pause: { id }, resume: { id }, lap: { id }, skip: { id }, reset: { id },
    remove: { id }, list: {}, get: { id }, 'presets.list': {}, 'presets.save': { name: 'Mine', timer: { kind: 'stopwatch' } }, 'presets.remove': { id: 'tabata' }
  };
  assert.deepEqual(Object.keys(inputs), OPERATION_NAMES);
  for (const now of [Number.NaN, Number.POSITIVE_INFINITY, T0 + 0.5, -1, `${T0}`]) {
    for (const name of OPERATION_NAMES) {
      const outcome = operations[name](store, inputs[name], now);
      assert.deepEqual([name, now, outcome.ok, outcome.error?.issues], [name, now, false, [{ path: 'now', message: 'must be whole epoch milliseconds' }]]);
    }
  }
});

test('every store the operations write parses back', () => {
  let store = emptyStore();
  const accept = (outcome) => {
    store = ok(outcome).store;
    assert.deepEqual(ok(parseStore(JSON.parse(JSON.stringify(store)))).store, store);
    return outcome.result.timer?.definition.id;
  };
  const spec = { kind: 'interval', rounds: 2, prepMs: 5_000, cooldownMs: 10_000, segments: [{ label: 'Go', phase: 'work', durationMs: 10_000 }] };
  const interval = accept(operations.start(store, { timer: spec }, T0));
  const until = accept(operations.create(store, { timer: { kind: 'countdown', until: new Date(T0 + 60_000).toISOString(), lapsEnabled: true } }, T0));
  const stopwatch = accept(operations.start(store, { timer: { kind: 'stopwatch' } }, T0));
  const sequence = [
    ['skip', interval, 1_000], ['pause', interval, 2_000], ['skip', interval, 3_000], ['resume', interval, 4_000], ['skip', interval, 5_000],
    ['start', until, 1_000], ['lap', until, 2_000], ['pause', until, 3_000], ['resume', until, 4_000], ['pause', until, 90_000],
    ['lap', stopwatch, 1_000], ['pause', stopwatch, 2_000], ['reset', stopwatch, 3_000], ['reset', until, 91_000], ['start', until, 92_000]
  ];
  for (const [operation, id, offset] of sequence) {
    const outcome = operations[operation](store, { id }, T0 + offset);
    // `pause` after the until countdown's end finds it finished, and records nothing.
    if (operation === 'pause' && offset === 90_000) assert.equal(code(outcome), 'invalid_state');
    else accept(outcome);
  }
  assert.deepEqual(store.timers.map((timer) => timer.runtime.status), ['finished', 'running', 'idle']);
});

test('parseStore rejects runtimes that the definition cannot hold or that the engine would project inconsistently', () => {
  const { store } = storeWith(
    { timer: { kind: 'countdown', durationMs: 60_000 } },
    { timer: { kind: 'countdown', until: new Date(T0 + 60_000).toISOString(), lapsEnabled: true } },
    { timer: { kind: 'stopwatch' } },
    { preset: 'tabata' }
  );
  const lapEntry = { elapsedMs: 1_000, at: T0 + 1_000 };
  const running = { status: 'running', startedAt: T0, pausedAt: null };
  const paused = { status: 'paused', startedAt: null, pausedAt: T0 };
  const finished = { status: 'finished', startedAt: null, pausedAt: null };
  const withRuntime = (index, runtime) => {
    const copy = structuredClone(store);
    Object.assign(copy.timers[index].runtime, runtime);
    return copy;
  };
  const accepted = [
    withRuntime(0, { ...paused, accumulatedMs: 59_999 }),
    withRuntime(0, { ...finished, accumulatedMs: 60_000 }),
    withRuntime(2, { ...paused, accumulatedMs: 86_400_000 * 3, laps: [lapEntry] }),
    withRuntime(3, { ...running, accumulatedMs: 1_000, skippedMs: 9_000 }),
    withRuntime(3, { ...finished, accumulatedMs: 200_000, skippedMs: 50_000 })
  ];
  for (const value of accepted) ok(parseStore(value));
  const rejected = [
    ['idle with a position', withRuntime(0, { accumulatedMs: 1_000 })],
    ['idle with laps', withRuntime(2, { laps: [lapEntry] })],
    ['idle with skips', withRuntime(3, { skippedMs: 1_000 })],
    ['an until countdown started without a fixed duration', withRuntime(1, { ...running, accumulatedMs: 0 })],
    ['paused at its end', withRuntime(0, { ...paused, accumulatedMs: 60_000 })],
    ['running from past its end', withRuntime(3, { ...running, accumulatedMs: 240_000, skippedMs: 10_000 })],
    ['finished before its end', withRuntime(0, { ...finished, accumulatedMs: 30_000 })],
    ['a finished stopwatch', withRuntime(2, { ...finished, accumulatedMs: 1_000 })],
    ['laps on a countdown without laps', withRuntime(0, { ...running, laps: [lapEntry] })],
    ['laps on an interval timer', withRuntime(3, { ...running, laps: [lapEntry] })],
    ['skips on a countdown', withRuntime(0, { ...running, skippedMs: 1_000 })],
    ['skips on a stopwatch', withRuntime(2, { ...running, skippedMs: 1_000 })]
  ];
  for (const [why, value] of rejected) assert.equal(code(parseStore(value)), 'invalid_input', why);
});

test('a huge malformed name or label is rejected quickly on every path', () => {
  const huge = `${'a'.repeat(200_000)}\n`;
  const interval = (label) => ({ kind: 'interval', rounds: 1, segments: [{ label, phase: 'work', durationMs: 1_000 }] });
  const store = emptyStore();
  const paths = [
    ['create name', () => operations.create(store, { timer: { kind: 'stopwatch', name: huge } }, T0)],
    ['create label', () => operations.create(store, { timer: interval(huge) }, T0)],
    ['start name', () => operations.start(store, { preset: 'tabata', name: huge }, T0)],
    ['start label', () => operations.start(store, { timer: interval(huge) }, T0)],
    ['presets.save name', () => operations['presets.save'](store, { name: huge, timer: { kind: 'stopwatch' } }, T0)],
    ['presets.save label', () => operations['presets.save'](store, { name: 'Huge', timer: interval(huge) }, T0)],
    ['runOperation', () => runOperation('create', store, { timer: { kind: 'stopwatch', name: huge } }, T0)],
    ['parseStore', () => parseStore({ ...store, presets: [{ id: 'p_ab12cd34', name: huge, builtIn: false, timer: interval(huge) }] })]
  ];
  for (const [path, run] of paths) {
    const started = performance.now();
    const outcome = run();
    const elapsed = performance.now() - started;
    assert.equal(code(outcome), 'invalid_input', path);
    // Linear validation takes well under 1 ms here; the old backtracking pattern took seconds.
    assert.ok(elapsed < 1_000, `${path} took ${elapsed.toFixed(1)} ms`);
  }
});
