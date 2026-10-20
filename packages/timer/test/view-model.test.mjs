import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { emptyStore, operations, schemas, timerBoard } from '../dist/index.js';
import {
  CONFIRM_MS, actionIssued, boardView, cancelsRepeat, controlStates, countdownSpecFrom, createInputFrom, durationText, emptyBoardState, emptyCountdownDraft,
  emptyIntervalDraft, failureText, focusDisplaced, formatClockTime, formatElapsed, formatRemaining, intervalDraftFrom, intervalSpecFrom, keyControl,
  hostArrived, nextRead, parseDurationText, pickAnnouncements, pressDestructive, primaryControl, readBoardResult, readIssued, readOutcome, readPresets,
  readRefresh, readSettled, readsAfter, replySettled, reproject, ringProgress
} from '../dist/view/view-model.js';

const T0 = Date.UTC(2026, 9, 19, 8, 0, 0);
const ALL = { create: true, destructive: true };
const fixture = async (file) => JSON.parse(await readFile(new URL(`../fixtures/contract-v1/${file}`, import.meta.url), 'utf8'));

const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
addFormats(ajv);
const createInputValid = ajv.compile(schemas.inputs.create);

/** A store holding one timer created from `input`, then moved by `steps` of `[operation, msAfterT0]`. */
function timerAfter(input, steps = []) {
  let outcome = operations.create(emptyStore(), input, T0);
  assert.ok(outcome.ok, JSON.stringify(outcome.error));
  const id = outcome.result.timer.definition.id;
  for (const [operation, at] of steps) {
    outcome = operations[operation](outcome.store, { id }, T0 + at);
    assert.ok(outcome.ok, `${operation}: ${JSON.stringify(outcome.error)}`);
  }
  return { store: outcome.store, id, timer: outcome.store.timers[0] };
}
const snapshotAt = (timer, at) => reproject({ ...timer, projection: null }, T0 + at);

test('time formatting at its edges: 0, 59.9 s and 1 h', () => {
  assert.deepEqual([0, 59_900, 3_599_999, 3_600_000].map((ms) => [formatRemaining(ms), formatElapsed(ms)]), [
    ['0:00', '0:00'],
    // Time left rounds up so a countdown never shows 0:00 while running; elapsed time rounds down.
    ['1:00', '0:59'],
    ['1:00:00', '59:59'],
    ['1:00:00', '1:00:00']
  ]);
});

test('duration fields read seconds, m:ss and h:mm:ss, and write back what they read', () => {
  const cases = { '20': 20_000, '0.5': 500, '1:30': 90_000, '0:59.9': 59_900, '90': 90_000, '1:00:00': 3_600_000, '24:00:00': 86_400_000, ' 2:05 ': 125_000 };
  for (const [text, ms] of Object.entries(cases)) assert.equal(parseDurationText(text), ms, text);
  for (const text of ['', '   ']) assert.equal(parseDurationText(text), undefined, `blank ${JSON.stringify(text)}`);
  for (const text of ['abc', '-5', '1:60', '1:60:00', '1::30', '5m', '1:2:3:4', '1e3']) assert.equal(parseDurationText(text), null, text);
  for (const ms of [500, 1_000, 20_000, 59_900, 3_600_000, 86_400_000]) assert.equal(parseDurationText(durationText(ms)), ms, String(ms));
});

// The control table for every kind and state. "hidden" means the kind or the host's capabilities rule
// the control out; "disabled" means only the state does.
const KINDS = {
  countdown: { timer: { kind: 'countdown', durationMs: 60_000 } },
  'countdown with laps': { timer: { kind: 'countdown', durationMs: 60_000, lapsEnabled: true } },
  stopwatch: { timer: { kind: 'stopwatch' } },
  interval: { preset: 'tabata' }
};
const STATES = { idle: [], running: [['start', 0]], paused: [['start', 0], ['pause', 5_000]], finished: [['start', 0]] };
const FINISHED_AT = { countdown: 60_000, 'countdown with laps': 60_000, interval: 250_000 };
const row = (start, pause, resume, lap, skip, reset, remove) => ({ start, pause, resume, lap, skip, reset, remove });
const E = 'enabled';
const D = 'disabled';
const H = 'hidden';
const EXPECTED = {
  countdown: {
    idle: row(E, D, D, H, H, D, E), running: row(D, E, D, H, H, E, E), paused: row(D, D, E, H, H, E, E), finished: row(D, D, D, H, H, E, E)
  },
  'countdown with laps': {
    idle: row(E, D, D, D, H, D, E), running: row(D, E, D, E, H, E, E), paused: row(D, D, E, D, H, E, E), finished: row(D, D, D, D, H, E, E)
  },
  // A stopwatch never finishes.
  stopwatch: { idle: row(E, D, D, D, H, D, E), running: row(D, E, D, E, H, E, E), paused: row(D, D, E, D, H, E, E) },
  interval: {
    idle: row(E, D, D, H, D, D, E), running: row(D, E, D, H, E, E, E), paused: row(D, D, E, H, E, E, E), finished: row(D, D, D, H, D, E, E)
  }
};

test('control table for every kind and state, with and without destructive writes', () => {
  for (const [kind, input] of Object.entries(KINDS)) {
    for (const [state, steps] of Object.entries(STATES)) {
      const expected = EXPECTED[kind][state];
      if (!expected) continue;
      const { timer } = timerAfter(input, steps);
      // "Finished" is reached by time passing: the projection, not the stored status, decides.
      const at = state === 'finished' ? FINISHED_AT[kind] : 10_000;
      const { status } = snapshotAt(timer, at).projection;
      assert.equal(status, state, `${kind} ${state}`);
      assert.deepEqual(controlStates(timer.definition, status, ALL, T0 + at), expected, `${kind} ${state}`);
      assert.deepEqual(
        controlStates(timer.definition, status, { create: true, destructive: false }, T0 + at),
        { ...expected, reset: H, remove: H },
        `${kind} ${state} without destructive writes`
      );
    }
  }
});

test('an enabled control is one its operation accepts, and a disabled or hidden one is refused', () => {
  for (const [kind, input] of Object.entries(KINDS)) {
    for (const [state, steps] of Object.entries(STATES)) {
      if (!EXPECTED[kind][state]) continue;
      const { store, id, timer } = timerAfter(input, steps);
      const at = T0 + (state === 'finished' ? FINISHED_AT[kind] : 10_000);
      const table = controlStates(timer.definition, snapshotAt(timer, at - T0).projection.status, ALL, at);
      for (const [control, enabled] of Object.entries(table)) {
        const outcome = operations[control](store, { id }, at);
        // Resetting an idle timer is a harmless no-op, so the board offers no control for it.
        if (control === 'reset' && state === 'idle') continue;
        assert.equal(outcome.ok, enabled === E, `${kind} ${state} ${control}: ${JSON.stringify(outcome.error)}`);
        if (!outcome.ok) assert.equal(outcome.error.code, 'invalid_state');
      }
    }
  }
});

test('an until countdown can start only while its time is 1 s to 24 h away', () => {
  const { timer } = timerAfter({ timer: { kind: 'countdown', until: new Date(T0 + 60_000).toISOString() } });
  assert.equal(controlStates(timer.definition, 'idle', ALL, T0).start, E);
  assert.equal(controlStates(timer.definition, 'idle', ALL, T0 + 59_500).start, D);
  assert.equal(controlStates(timer.definition, 'idle', ALL, T0 + 120_000).start, D);
});

test('Space runs the enabled primary control, L laps and S skips, and nothing else', () => {
  const running = row(D, E, D, E, H, E, E);
  const key = (value) => ({ key: value });
  assert.equal(primaryControl(running), 'pause');
  assert.equal(keyControl(key(' '), running), 'pause');
  assert.equal(keyControl(key('l'), running), 'lap');
  assert.equal(keyControl(key('L'), running), 'lap');
  assert.equal(keyControl(key('s'), running), null, 'skip is hidden');
  assert.equal(keyControl(key('r'), running), null);
  assert.equal(keyControl(key(' '), row(D, D, D, H, H, E, E)), null);
  assert.equal(keyControl(key('S'), row(D, D, E, H, E, E, E)), 'skip');
  assert.equal(keyControl(key(' '), row(E, D, D, H, D, D, E)), 'start');
});

test('a held key acts once: auto-repeated keydowns run no control', () => {
  const running = row(D, E, D, E, E, E, E);
  for (const key of [' ', 'l', 'L', 's', 'S']) {
    assert.notEqual(keyControl({ key, repeat: false }, running), null, key);
    assert.equal(keyControl({ key, repeat: true }, running), null, `${JSON.stringify(key)} repeated`);
  }
});

test('a held Enter acts once on every control, so reset and remove need two distinct presses', () => {
  const enter = { key: 'Enter' };
  const held = { key: 'Enter', repeat: true };
  assert.equal(cancelsRepeat(enter), false, 'a first press activates as usual');
  assert.equal(cancelsRepeat({ ...enter, repeat: false }), false);
  assert.equal(cancelsRepeat(held), true);
  // Other held keys keep their meaning: Space presses a button on release, and a held letter types in a field.
  for (const key of [' ', 'l', 'a', 'Tab']) assert.equal(cancelsRepeat({ key, repeat: true }), false, JSON.stringify(key));
  // The presses that reach a destructive control while Enter is held down, then pressed again.
  for (const control of ['reset', 'remove']) {
    const presses = (keys) => keys.filter((key) => !cancelsRepeat(key)).reduce(
      (state, _key, index) => { const press = pressDestructive(state.armed, 't_1', control, T0 + index * 30); return { armed: press.armed, runs: state.runs + Number(press.run) }; },
      { armed: null, runs: 0 }
    );
    assert.equal(presses([enter, held, held, held]).runs, 0, `${control} held`);
    assert.equal(presses([enter, held, held, enter]).runs, 1, `${control} pressed twice`);
  }
});

test('after an action focus moves only when the action took it away', () => {
  const page = { isConnected: true };
  const control = { isConnected: true, disabled: false };
  const elsewhere = { isConnected: true, disabled: false };
  assert.equal(focusDisplaced(control, control, page), false, 'still on its control');
  assert.equal(focusDisplaced(control, elsewhere, page), false, 'the user moved to another control while the host replied');
  assert.equal(focusDisplaced(null, page, page), false, 'the action did not start from the card');
  assert.equal(focusDisplaced(control, page, page), true, 'lost to the page, as when its control disappears');
  assert.equal(focusDisplaced(control, null, page), true);
  assert.equal(focusDisplaced(control, { isConnected: false }, page), true, 'on an element that was removed');
  const disabled = { isConnected: true, disabled: true };
  assert.equal(focusDisplaced(disabled, disabled, page), true, 'left on a control the action disabled');
});

test('reset and remove run only on a second press of the same control within 3 s', () => {
  let press = pressDestructive(null, 't_1', 'reset', T0);
  assert.deepEqual(press, { run: false, armed: { timerId: 't_1', control: 'reset', at: T0 } });
  assert.deepEqual(pressDestructive(press.armed, 't_1', 'reset', T0 + CONFIRM_MS - 1), { run: true, armed: null });
  // Too late, another control, another timer, or a clock that went backward: arm afresh.
  assert.equal(pressDestructive(press.armed, 't_1', 'reset', T0 + CONFIRM_MS).run, false);
  assert.equal(pressDestructive(press.armed, 't_1', 'remove', T0 + 100).run, false);
  assert.equal(pressDestructive(press.armed, 't_2', 'reset', T0 + 100).run, false);
  assert.equal(pressDestructive(press.armed, 't_1', 'reset', T0 - 1).run, false);
  press = pressDestructive(press.armed, 't_1', 'remove', T0 + 100);
  assert.equal(pressDestructive(press.armed, 't_1', 'remove', T0 + 200).run, true);
});

/** Every announcement made while re-projecting each 250 ms from `from` to `to`, with when it was made. */
function announcementsBetween(timers, from, to) {
  let states = null;
  const heard = [];
  for (let at = from; at <= to; at += 250) {
    const picked = pickAnnouncements(states, timers.map((timer) => snapshotAt(timer, at)));
    states = picked.states;
    for (const message of picked.messages) heard.push([at, message]);
  }
  return heard;
}

test('announcements name each new interval step and never the passing seconds', () => {
  const { timer } = timerAfter({ preset: 'tabata' }, [['start', 0]]);
  assert.deepEqual(announcementsBetween([timer], 0, 75_000), [
    [10_000, 'Tabata: Work, round 1 of 8, 0:20.'],
    [30_000, 'Tabata: Rest, round 1 of 8, 0:10.'],
    [40_000, 'Tabata: Work, round 2 of 8, 0:20.'],
    [60_000, 'Tabata: Rest, round 2 of 8, 0:10.'],
    [70_000, 'Tabata: Work, round 3 of 8, 0:20.']
  ]);
  // A five-minute countdown says nothing until it finishes.
  const { timer: countdown } = timerAfter({ timer: { kind: 'countdown', durationMs: 300_000, name: 'Tea' } }, [['start', 0]]);
  assert.deepEqual(announcementsBetween([countdown], 0, 301_000), [[300_000, 'Tea finished.']]);
  // A label that differs from its phase names both.
  const { timer: pomodoro } = timerAfter({ preset: 'pomodoro' }, [['start', 0]]);
  assert.deepEqual(announcementsBetween([pomodoro], 25 * 60_000 - 500, 25 * 60_000), [[25 * 60_000, 'Pomodoro: Break (rest), 5:00.']]);
});

test('announcements for pause, resume, skip and finish, and silence on mount, start, reset and removal', () => {
  const start = timerAfter({ preset: 'tabata' });
  const running = timerAfter({ preset: 'tabata' }, [['start', 0]]);
  const paused = timerAfter({ preset: 'tabata' }, [['start', 0], ['pause', 5_000]]);
  const skipped = timerAfter({ preset: 'tabata' }, [['start', 0], ['pause', 5_000], ['skip', 6_000]]);
  const resumed = timerAfter({ preset: 'tabata' }, [['start', 0], ['pause', 5_000], ['resume', 8_000]]);
  const finished = timerAfter({ preset: 'tabata' }, [['start', 0], ['pause', 5_000], ['skip', 6_000], ...Array.from({ length: 16 }, () => ['skip', 6_000])]);
  const at = (timer, ms = 9_000) => [snapshotAt(timer, ms)];
  const after = (before, now) => pickAnnouncements(pickAnnouncements(null, before).states, now).messages;

  assert.deepEqual(pickAnnouncements(null, at(running.timer)).messages, [], 'nothing on mount');
  assert.deepEqual(after(at(start.timer), at(running.timer)), [], 'starting is the user’s own action');
  assert.deepEqual(after(at(running.timer), at(paused.timer)), ['Tabata paused.']);
  assert.deepEqual(after(at(paused.timer), at(resumed.timer)), ['Tabata resumed.']);
  assert.deepEqual(after(at(paused.timer), at(skipped.timer)), ['Tabata: Work, round 1 of 8, 0:20.']);
  assert.equal(finished.timer.runtime.status, 'finished');
  assert.deepEqual(after(at(skipped.timer), at(finished.timer)), ['Tabata finished.']);
  assert.deepEqual(after(at(finished.timer), at(start.timer)), [], 'a reset says nothing');
  const removal = pickAnnouncements(pickAnnouncements(null, at(running.timer)).states, []);
  assert.deepEqual(removal, { messages: [], states: {} });
});

test('the interval editor accepts exactly the interval timers the create schema accepts', async () => {
  const { valid, invalid } = await fixture('inputs.json');
  let checked = 0;
  for (const [verdict, cases] of [[true, valid], [false, invalid]]) {
    for (const { operation, input } of cases) {
      const spec = input?.timer;
      if (spec?.kind !== 'interval') continue;
      const { name: _name, ...timerOnly } = spec;
      // Fixture inputs may be invalid for a reason outside the timer; the schema decides for the timer alone.
      const schemaAccepts = createInputValid({ timer: timerOnly });
      if (operation === 'create' || operation === 'start') assert.equal(schemaAccepts || !verdict, true);
      const outcome = intervalSpecFrom(intervalDraftFrom(timerOnly));
      assert.equal(outcome.ok, schemaAccepts, `${JSON.stringify(timerOnly)}: ${JSON.stringify(outcome.errors)}`);
      // The form omits settings left at their defaults, which the operations fill in the same way.
      if (outcome.ok) assert.deepEqual({ sound: true, countdownTicks: true, ...outcome.spec }, { sound: true, countdownTicks: true, ...timerOnly });
      checked++;
    }
  }
  assert.ok(checked >= 10, `only ${checked} interval fixtures`);
});

test('interval editor errors point at the field to fix', () => {
  const draft = (change) => {
    const value = emptyIntervalDraft();
    change(value);
    return intervalSpecFrom(value);
  };
  const errorKeys = (outcome) => (outcome.ok ? [] : Object.keys(outcome.errors).sort());
  assert.equal(draft(() => {}).ok, true);
  assert.deepEqual(errorKeys(draft((value) => (value.rounds = 'eight'))), ['rounds']);
  assert.deepEqual(errorKeys(draft((value) => (value.rounds = '0'))), ['rounds']);
  assert.deepEqual(errorKeys(draft((value) => (value.rounds = '100'))), ['rounds']);
  assert.deepEqual(errorKeys(draft((value) => (value.prep = '0.5'))), ['prep']);
  assert.deepEqual(errorKeys(draft((value) => (value.cooldown = 'soon'))), ['cooldown']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments = []))), ['segments']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments = Array.from({ length: 101 }, () => value.segments[0])))), ['segments']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments[1].duration = ''))), ['segments.1.duration']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments[1].duration = '24:00:01'))), ['segments.1.duration']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments[0].label = 'x'.repeat(41)))), ['segments.0.label']);
  assert.deepEqual(errorKeys(draft((value) => (value.segments[0].phase = 'warmup'))), ['segments.0.phase']);
  assert.deepEqual(errorKeys(draft((value) => (value.name = 'Line\nbreak'))), ['name']);
  // A blank name lets the operation choose its default; blank prep and cooldown are omitted.
  const outcome = draft((value) => Object.assign(value, { name: '  ', prep: '', cooldown: '1:00' }));
  assert.deepEqual(outcome.spec, {
    kind: 'interval', rounds: 8, cooldownMs: 60_000,
    segments: [{ label: 'Work', phase: 'work', durationMs: 20_000 }, { label: 'Rest', phase: 'rest', durationMs: 10_000 }]
  });
  const quiet = draft((value) => Object.assign(value, { sound: false, countdownTicks: false }));
  assert.equal(quiet.spec.sound, false);
  assert.equal(quiet.spec.countdownTicks, false);
});

test('the duration form builds the countdown the create schema accepts', () => {
  assert.deepEqual(countdownSpecFrom({ name: 'Tea', sound: true, duration: '4:00', lapsEnabled: false }), { ok: true, spec: { kind: 'countdown', name: 'Tea', durationMs: 240_000 } });
  assert.deepEqual(countdownSpecFrom({ name: '', sound: false, duration: '20:00', lapsEnabled: true }).spec, { kind: 'countdown', sound: false, durationMs: 1_200_000, lapsEnabled: true });
  for (const duration of ['', '0.5', '24:00:01', 'later']) {
    const outcome = countdownSpecFrom({ name: '', sound: true, duration, lapsEnabled: false });
    assert.deepEqual(Object.keys(outcome.errors ?? {}), ['duration'], duration);
  }
});

test('the board reads its result through the contract', async () => {
  const props = await fixture('view-props.json');
  const read = readBoardResult(props.result);
  assert.equal(read.ok, true);
  assert.equal(readBoardResult({ ...props.result, schemaVersion: 2 }).ok, false);
  assert.equal(readBoardResult(null).ok, false);
  // With nothing pending and no read of its own, the board shows the host's result as it is.
  assert.equal(boardView(read.result, emptyBoardState()), read.result);
});

test('the preset picker uses a presets.list result only when it matches the contract', () => {
  const listed = operations['presets.list'](emptyStore(), {}, T0);
  assert.deepEqual(readPresets(listed.result).map((preset) => preset.id), ['tabata', 'emom', 'hiit-40-20', 'pomodoro', 'amrap']);
  assert.equal(readPresets({ presets: [{ id: 'x' }] }), null);
  assert.equal(readPresets({}), null);
});

test('a failed action names its operation', () => {
  const refused = readOutcome('pause', 't_1', { error: { code: 'invalid_state', message: 'Timer t_1 is paused; only a running timer can pause.' } });
  assert.deepEqual(refused, { ok: false, failure: { operation: 'pause', timerId: 't_1', message: 'Timer t_1 is paused; only a running timer can pause.' } });
  assert.equal(failureText(refused.failure), 'Pause failed: Timer t_1 is paused; only a running timer can pause.');
  assert.equal(failureText(readOutcome('create', null, new Error('socket closed')).failure), 'Create failed: socket closed');
  assert.equal(readOutcome('reset', 't_1', undefined).ok, false);
  assert.equal(readOutcome('reset', 't_1', { error: {} }).ok, false);
  assert.deepEqual(readOutcome('remove', 't_1', { removedId: 't_1', observedAt: T0 }), { ok: true, result: { removedId: 't_1', observedAt: T0 } });
});

// One store per timer operation in which it succeeds, with its input; create starts from an empty store.
const STOPWATCH = { timer: { kind: 'stopwatch', name: 'Tea' } };
const SCENARIOS = {
  create: () => ({ store: emptyStore(), id: null, input: STOPWATCH }),
  start: () => timerAfter(STOPWATCH),
  pause: () => timerAfter(STOPWATCH, [['start', 0]]),
  resume: () => timerAfter(STOPWATCH, [['start', 0], ['pause', 5_000]]),
  lap: () => timerAfter(STOPWATCH, [['start', 0]]),
  skip: () => timerAfter({ preset: 'tabata' }, [['start', 0]]),
  reset: () => timerAfter(STOPWATCH, [['start', 0]]),
  remove: () => timerAfter(STOPWATCH)
};
const AT = T0 + 10_000;
function scenario(operation) {
  const { store, id, input = { id } } = SCENARIOS[operation]();
  const reply = operations[operation](store, input, AT);
  assert.ok(reply.ok, `${operation}: ${JSON.stringify(reply.error)}`);
  return { id, timers: timerBoard(store, AT).timers, reply: reply.result, after: reply.store };
}

test('a reply that does not match its operation’s result is a failure, never applied', () => {
  for (const operation of Object.keys(SCENARIOS)) {
    const { id, reply } = scenario(operation);
    assert.deepEqual(readOutcome(operation, id, reply), { ok: true, result: reply }, operation);
    const broken = operation === 'remove'
      ? [{}, { removedId: id }, { ...reply, removedId: 7 }, { ...reply, extra: true }]
      : [
          {},
          // Without the time it committed, the board could not order the change.
          { timer: reply.timer },
          { ...reply, timer: 'x' },
          // Structurally broken snapshots that `project` could not render.
          { ...reply, timer: { ...reply.timer, definition: { ...reply.timer.definition, kind: 'interval', segments: [], rounds: 0 } } },
          { ...reply, timer: { ...reply.timer, runtime: { ...reply.timer.runtime, status: 'sleeping' } } },
          { ...reply, timer: { ...reply.timer, projection: undefined } }
        ];
    for (const value of broken) {
      const outcome = readOutcome(operation, id, value);
      assert.equal(outcome.ok, false, `${operation} ${JSON.stringify(value).slice(0, 80)}`);
      assert.match(failureText(outcome.failure), /^\w+ failed: The host's reply does not match the Timer contract \(.+\)\.$/);
    }
    // A reply for another timer than the one acted on.
    if (id !== null) {
      const other = operation === 'remove' ? { ...reply, removedId: 't_zzzzzzzz' } : { ...reply, timer: { ...reply.timer, definition: { ...reply.timer.definition, id: 't_zzzzzzzz' } } };
      assert.equal(failureText(readOutcome(operation, id, other).failure), `${failureText({ operation, message: '' })}The host replied for timer t_zzzzzzzz instead of ${id}.`);
    }
  }
});

// What the board shows and what the host holds, compared by timer id and stored runtime.
const shown = (board) => board.timers.map((timer) => [timer.definition.id, timer.runtime]);
const held = (store) => store.timers.map((timer) => [timer.definition.id, timer.runtime]);
const list = (store, at) => operations.list(store, {}, at).result;
/** The board calls an action and settles its reply before it does anything else. */
function acted(state, operation, id, reply) {
  const call = actionIssued(state);
  return replySettled(call.state, operation, id, reply, call.issued).state;
}

test('a change stays shown until a board observed after it committed, from the host or a read, for every timer operation', () => {
  for (const operation of Object.keys(SCENARIOS)) {
    const { store, input, ...scene } = { input: undefined, ...SCENARIOS[operation]() };
    const reply = operations[operation](store, input ?? { id: scene.id }, AT);
    assert.ok(reply.ok, operation);
    assert.equal(reply.result.observedAt, AT, `${operation} reply carries the time it committed`);
    const id = scene.id ?? reply.result.timer.definition.id;
    const change = held(reply.store);
    // Another surface then removes the timer acted on (after a removal, adds one).
    const later = operation === 'remove'
      ? operations.create(reply.store, { timer: { kind: 'stopwatch', name: 'Later' } }, AT + 30).store
      : operations.remove(reply.store, { id }, AT + 30).store;
    const newer = timerBoard(later, AT + 40);

    // The action is called, then a read for an earlier change, then the action's reply and the read it issues.
    const call = actionIssued(emptyBoardState());
    let { state, issued: earlier } = readIssued(call.state);
    state = replySettled(state, operation, scene.id, reply.result, call.issued).state;
    const own = readIssued(state);
    state = own.state;
    // Host results observed before the commit, or in its millisecond, arriving after the reply do not hide it;
    // a created timer shows although they predate it.
    for (const before of [timerBoard(store, AT - 50), timerBoard(store, AT)]) {
      assert.deepEqual(shown(boardView(before, state)), change, `${operation} over a host result at ${before.observedAt - AT}`);
    }
    const before = timerBoard(store, AT - 50);
    // The earlier read settles late. Observed before the commit, or in its millisecond, it does not hide the
    // change; observed after it, it holds the change and retires it.
    for (const late of [list(store, AT - 10), list(store, AT)]) {
      assert.deepEqual(shown(boardView(before, readSettled(state, earlier, late).state)), change, `${operation}: earlier read at ${late.observedAt - AT}`);
    }
    assert.deepEqual(readSettled(state, earlier, list(reply.store, AT + 5)).state.pending, [], `${operation}: earlier read after the commit`);
    // Its own read fails: the change stays shown, and the board waits for the host's next result to read again.
    const failed = readSettled(state, own.issued, new Error('offline'));
    assert.equal(failureText(failed.failure), 'List failed: offline');
    assert.deepEqual(shown(boardView(before, failed.state)), change, `${operation} after a failed read`);
    assert.equal(failed.state.awaitingHost, true);
    // Newer host results then win, so a failed read never leaves the change shown over them.
    assert.deepEqual(shown(boardView(newer, failed.state)), held(later), `${operation}: newer host result after a failed read`);
    assert.deepEqual(hostArrived(failed.state, newer).pending, [], operation);
    // Its own read, in the commit's millisecond, confirms it; the earlier read settling after it changes nothing.
    const confirmed = readSettled(state, own.issued, list(reply.store, AT)).state;
    assert.deepEqual(confirmed.pending, [], operation);
    assert.deepEqual(readSettled(confirmed, earlier, list(store, AT)), { state: { ...confirmed, inFlight: confirmed.inFlight - 1 }, failure: null, taken: false });
    // A host result observed at the same time as the board's read loses the tie to it; a newer one wins.
    assert.deepEqual(shown(boardView(timerBoard(store, AT), confirmed)), change, `${operation} on a tie`);
    assert.deepEqual(shown(boardView(newer, confirmed)), held(later), `${operation} after a later change`);

    // The reply arrives only after the host passed that newer result, and every read fails: the late reply
    // hides nothing and brings back no removed timer.
    let delayed = acted(emptyBoardState(), operation, scene.id, reply.result);
    delayed = readSettled(readIssued(delayed).state, delayed.seq + 1, new Error('offline')).state;
    assert.deepEqual(shown(boardView(newer, delayed)), held(later), `${operation} reply after a newer host result`);
    assert.equal(nextRead(newer, hostArrived(delayed, newer)), false);
    // A refused change was still answered by the host, so the board reads again; a call that threw may not have.
    assert.equal(readsAfter(operation, { error: { code: 'invalid_state', message: 'no' } }), true);
    assert.equal(readsAfter(operation, new Error('offline')), false);
  }
  assert.equal(readsAfter('list', {}), false);
});

// Changes to two timers, `a` and `b`, covering every timer operation.
const STEPS = [
  ['create', () => ({ preset: 'tabata' })], ['create', () => STOPWATCH], ['start', ([a]) => ({ id: a })], ['start', ([, b]) => ({ id: b })],
  ['lap', ([, b]) => ({ id: b })], ['skip', ([a]) => ({ id: a })], ['pause', ([a]) => ({ id: a })], ['pause', ([, b]) => ({ id: b })],
  ['resume', ([a]) => ({ id: a })], ['reset', ([, b]) => ({ id: b })], ['remove', ([, b]) => ({ id: b })]
];

test('overlapping changes to two timers and reads settling in any order, or failing, end at the host state', () => {
  const steps = STEPS;
  let seed = 7;
  const random = () => (seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31;
  // `tick` ms pass between steps. With `back`, the reads issued so far settle every third step and the host
  // clock then steps back `back` ms.
  for (const [tick, back] of [[10, 0], [0, 0], [10, 3_600_000], [0, 1]]) {
    for (let trial = 0; trial < 40; trial++) {
      let store = emptyStore();
      const host = timerBoard(store, AT - 100);
      let state = hostArrived(emptyBoardState(), host);
      const ids = [];
      let reads = [];
      let at = AT;
      const deliver = () => {
        for (const read of reads.sort(() => random() - 0.5)) {
          state = readSettled(state, read.issued, read.outcome).state;
          assert.deepEqual(shown(boardView(host, state)), held(store), `tick ${tick}, back ${back}, trial ${trial}`);
        }
        reads = [];
      };
      steps.forEach(([operation, input], index) => {
        if (back && index % 3 === 0) {
          deliver();
          at -= back;
        }
        const reply = operations[operation](store, input(ids), at);
        assert.ok(reply.ok, `${operation}: ${JSON.stringify(reply.error)}`);
        store = reply.store;
        if (operation === 'create') ids.push(reply.result.timer.definition.id);
        state = acted(state, operation, operation === 'create' ? null : input(ids).id, reply.result);
        const issued = readIssued(state);
        state = issued.state;
        reads.push({ issued: issued.issued, outcome: random() < 0.25 ? new Error('offline') : list(store, at) });
        at += tick;
      });
      deliver();
      assert.deepEqual(shown(boardView(timerBoard(store, AT + 1_000), state)), held(store));
    }
  }

  // A read observed after a create retires it while a later start stays shown; once a newer host
  // result drops the timer, the start does not bring it back.
  const created = operations.create(emptyStore(), STOPWATCH, AT);
  const id = created.result.timer.definition.id;
  const started = operations.start(created.store, { id }, AT + 10);
  let state = acted(emptyBoardState(), 'create', null, created.result);
  const first = readIssued(state);
  state = acted(first.state, 'start', id, started.result);
  state = readSettled(state, first.issued, list(created.store, AT + 5)).state;
  assert.deepEqual(shown(boardView(timerBoard(emptyStore(), AT - 100), state)), held(started.store));
  assert.deepEqual(shown(boardView(timerBoard(operations.remove(started.store, { id }, AT + 20).store, AT + 30), state)), []);
  // Of two overlapping calls on one timer, the later commit stays whichever reply arrives last.
  const paused = operations.pause(started.store, { id }, AT + 20);
  const pausing = actionIssued(emptyBoardState());
  const starting = actionIssued(pausing.state);
  const replies = replySettled(replySettled(starting.state, 'pause', id, paused.result, pausing.issued).state, 'start', id, started.result, starting.issued).state;
  assert.deepEqual(shown(boardView(timerBoard(emptyStore(), AT - 100), replies)), held(paused.store));
});

test('what the board saw orders a change before a host clock that steps back, for every timer operation', () => {
  for (const operation of Object.keys(SCENARIOS)) {
    const { store, input, ...scene } = { input: undefined, ...SCENARIOS[operation]() };
    const reply = operations[operation](store, input ?? { id: scene.id }, AT);
    const id = scene.id ?? reply.result.timer.definition.id;
    const change = held(reply.store);
    const later = operation === 'remove'
      ? operations.create(reply.store, { timer: { kind: 'stopwatch', name: 'Later' } }, AT + 30).store
      : operations.remove(reply.store, { id }, AT + 30).store;
    // A host result that arrived before the call never retires its change, though observed an hour after
    // it by a clock that then stepped back, and every read fails.
    const early = timerBoard(store, AT + 3_600_000);
    let state = acted(hostArrived(emptyBoardState(), early), operation, scene.id, reply.result);
    const lost = readIssued(state);
    state = readSettled(lost.state, lost.issued, new Error('offline')).state;
    assert.deepEqual(shown(boardView(early, state)), change, `${operation} over a host result that arrived before the call`);
    assert.equal(nextRead(early, state), false, `${operation}: waits for the host after a failed read`);
    // One that arrives after the reply may have been observed before or after the commit: its observedAt
    // decides, and the change keeps its own millisecond. The board reads again while the change still shows.
    for (const [host, expected] of [[timerBoard(store, AT - 50), change], [timerBoard(store, AT), change], [timerBoard(later, AT + 40), held(later)]]) {
      assert.deepEqual(shown(boardView(host, hostArrived(state, host))), expected, `${operation}: host result at ${host.observedAt - AT} after the reply`);
      assert.equal(nextRead(host, hostArrived(state, host)), expected === change, `${operation}: read after a host result at ${host.observedAt - AT}`);
    }
    // A read issued after the reply retires the change and wins over the host result that arrived before it,
    // both though observed earlier.
    const own = readIssued(state);
    const confirmed = readSettled(own.state, own.issued, list(reply.store, AT - 1_000)).state;
    assert.deepEqual(confirmed.pending, [], operation);
    assert.deepEqual(shown(boardView(early, confirmed)), change, `${operation}: later-issued read over an earlier host result`);
    // A read already in flight when the call is made overlaps it; observed after the commit, it retires the
    // change and shows another surface's later change.
    const reading = readIssued(emptyBoardState());
    const calling = actionIssued(reading.state);
    const overlapped = replySettled(calling.state, operation, scene.id, reply.result, calling.issued).state;
    const after = readSettled(overlapped, reading.issued, list(later, AT + 40)).state;
    assert.deepEqual(shown(boardView(timerBoard(store, AT - 100), after)), held(later), `${operation}: read in flight observed after the commit`);
    // A call made after that read settled is not retired by it.
    const next = operation === 'remove' ? null : operations.reset(reply.store, { id }, AT - 2_000);
    if (next) {
      assert.deepEqual(shown(boardView(early, acted(confirmed, 'reset', id, next.result))), held(next.store), `${operation} then reset`);
    }
  }
});

test('sequential actions on one timer end at the host state across a backward clock step, whatever their reads do', () => {
  const pairs = [
    ['start', 'pause', () => timerAfter(STOPWATCH)],
    ['start', 'remove', () => timerAfter(STOPWATCH)],
    ['create', 'start', () => ({ store: emptyStore(), id: null })],
    ['pause', 'reset', () => timerAfter(STOPWATCH, [['start', 0]])]
  ];
  for (const [first, second, setup] of pairs) {
    for (const back of [1, 1_000, 3_600_000]) {
      for (const reads of [['ok'], ['offline'], ['offline', 'ok']]) {
        const name = `${first} then ${second}, clock ${back} ms back, reads ${reads.join(' then ')}`;
        let { store, id } = setup();
        const host = timerBoard(store, AT - 100);
        const one = operations[first](store, id ? { id } : STOPWATCH, AT);
        let state = acted(hostArrived(emptyBoardState(), host), first, id, one.result);
        id ??= one.result.timer.definition.id;
        // The first change's read fails, then the clock steps back before the second.
        const lost = readIssued(state);
        state = readSettled(lost.state, lost.issued, new Error('offline')).state;
        const two = operations[second](one.store, { id }, AT - back);
        assert.ok(two.ok, name);
        state = acted(state, second, id, two.result);
        for (const outcome of reads) {
          const read = readIssued(state);
          state = readSettled(read.state, read.issued, outcome === 'ok' ? list(two.store, AT - back + 1) : new Error(outcome)).state;
        }
        assert.deepEqual(shown(boardView(host, state)), held(two.store), name);
        if (reads.at(-1) === 'ok') assert.deepEqual(state.pending, [], name);
      }
    }
  }
});

test('a host result from before a change that arrives during its confirming read keeps it shown until a later read, for every timer operation', () => {
  for (const operation of Object.keys(SCENARIOS)) {
    const { store, input, ...scene } = { input: undefined, ...SCENARIOS[operation]() };
    const reply = operations[operation](store, input ?? { id: scene.id }, AT);
    const change = held(reply.store);
    for (const back of [1, 1_000, 3_600_000]) {
      for (const first of ['ok', 'offline']) {
        const name = `${operation}, clock ${back} ms back, confirming read ${first}`;
        // A host result observed before the change is delivered late: after the confirming read is issued, and
        // after the host clock stepped back, so the read is observed before it.
        const stale = timerBoard(store, AT - 10);
        let state = acted(hostArrived(emptyBoardState(), timerBoard(store, AT - 100)), operation, scene.id, reply.result);
        const confirming = readIssued(state);
        state = hostArrived(confirming.state, stale);
        assert.deepEqual(shown(boardView(stale, state)), change, `${name}: during the read`);
        state = readSettled(state, confirming.issued, first === 'ok' ? list(reply.store, AT - 10 - back) : new Error('offline')).state;
        // The stale result is the base, and it does not come after the change, so the change stays shown and pending.
        assert.deepEqual(shown(boardView(stale, state)), change, name);
        assert.equal(state.pending.length, 1, name);
        assert.equal(nextRead(stale, state), true, name);
        // The board reads again; issued after the stale result arrived, that read comes after it and retires the change.
        const again = readIssued(state);
        state = readSettled(again.state, again.issued, list(reply.store, AT - 10 - back + 1)).state;
        assert.deepEqual(shown(boardView(stale, state)), change, `${name}, then a later read`);
        assert.deepEqual(state.pending, [], name);
        assert.equal(nextRead(stale, state), false, name);
      }
    }
    // A host result observed after the commit retires the change, so the host's next result, from a clock that
    // stepped back after another surface's change, shows as passed.
    const id = scene.id ?? reply.result.timer.definition.id;
    const later = operation === 'remove'
      ? operations.create(reply.store, { timer: { kind: 'stopwatch', name: 'Later' } }, AT - 1_000).store
      : operations.remove(reply.store, { id }, AT - 1_000).store;
    let state = acted(hostArrived(emptyBoardState(), timerBoard(store, AT - 100)), operation, scene.id, reply.result);
    state = hostArrived(state, timerBoard(reply.store, AT + 5));
    assert.deepEqual(state.pending, [], operation);
    const next = timerBoard(later, AT - 990);
    assert.deepEqual(shown(boardView(next, hostArrived(state, next))), held(later), `${operation}: later host result below the commit`);
  }
});

/**
 * A board driven as TimerBoard drives it: after every event it issues the one read `nextRead` asks for.
 * `serve()` gives the outcome of a read the host runs when it is issued.
 */
function drivenBoard(host, serve) {
  const board = { state: hostArrived(emptyBoardState(), host), host, reads: [], followUps: 0 };
  const drain = () => {
    if (!nextRead(board.host, board.state)) return;
    const read = readIssued(board.state);
    board.state = read.state;
    board.reads.push({ issued: read.issued, outcome: serve() });
    board.followUps += 1;
  };
  Object.assign(board, {
    /** An action and its reply; the host answered it, so the board reads (`readsAfter`). */
    act(operation, id, reply) {
      board.state = acted(board.state, operation, id, reply);
      const read = readIssued(board.state);
      board.state = read.state;
      board.reads.push({ issued: read.issued, outcome: serve() });
      drain();
    },
    arrive(result) {
      board.host = result;
      board.state = hostArrived(board.state, result);
      drain();
    },
    /** Settles the read at `index` among those in flight, with its outcome or `outcome`. */
    settle(index, outcome) {
      const [read] = board.reads.splice(index, 1);
      board.state = readSettled(board.state, read.issued, outcome ?? read.outcome).state;
      assert.ok(board.state.inFlight >= 0 && board.state.inFlight === board.reads.length);
      drain();
    }
  });
  return board;
}

test('the board reads again whenever a change still shows and no read is in flight, however its reads settle, for every timer operation', () => {
  for (const operation of Object.keys(SCENARIOS)) {
    const { store, input, ...scene } = { input: undefined, ...SCENARIOS[operation]() };
    const reply = operations[operation](store, input ?? { id: scene.id }, AT);
    const id = scene.id ?? reply.result.timer.definition.id;
    const refused = { error: { code: 'invalid_state', message: 'no' } };
    for (const back of [1, 500, 3_600_000]) {
      for (const [order, older] of [['newest first', 'ok'], ['newest first', 'offline'], ['oldest first', 'ok'], ['oldest first', 'offline']]) {
        const name = `${operation}, clock ${back} ms back, reads settle ${order}, older read ${older}`;
        // The board changes the timer, then a refused action issues a second read. A host result captured before
        // the change arrives while both are in flight; before the second read runs, the clock steps back and
        // another surface changes the board (after a removal it adds a timer, else it removes the timer).
        const later = operation === 'remove'
          ? operations.create(reply.store, { timer: { kind: 'stopwatch', name: 'Later' } }, AT - 20 - back).store
          : operations.remove(reply.store, { id }, AT - 20 - back).store;
        let serve = () => list(reply.store, AT - 30 - back);
        const board = drivenBoard(timerBoard(store, AT - 100), () => serve());
        board.act(operation, scene.id, reply.result);
        serve = () => list(later, AT - 10 - back);
        board.act('pause', id, refused);
        board.arrive(timerBoard(store, AT - 10));
        assert.equal(board.followUps, 0, name);
        serve = () => list(later, AT - 10 - back + 1);
        const [first, second] = order === 'newest first' ? [1, 0] : [0, 0];
        board.settle(first, order === 'oldest first' && older === 'offline' ? new Error('offline') : undefined);
        assert.equal(board.followUps, 0, `${name}: a read still in flight`);
        board.settle(second, order === 'newest first' && older === 'offline' ? new Error('offline') : undefined);
        // The host result outranks both reads, so the change still shows over it: the board reads once more.
        assert.equal(board.followUps, 1, name);
        board.settle(0);
        assert.equal(board.followUps, 1, `${name}: no extra read`);
        assert.deepEqual(shown(boardView(board.host, board.state)), held(later), name);
        assert.deepEqual(board.state.pending, [], name);
        assert.equal(board.state.inFlight, 0, name);
        assert.equal(nextRead(board.host, board.state), false, name);
      }
    }

    // A read the board takes fails with no host result since it was issued: the board waits for the host's next
    // result, then reads once; when a host result arrived during the failed read, it reads again at once.
    for (const during of [false, true]) {
      const name = `${operation}, failed read, host result ${during ? 'during it' : 'after it'}`;
      const board = drivenBoard(timerBoard(store, AT - 100), () => list(reply.store, AT + 1));
      board.act(operation, scene.id, reply.result);
      if (during) board.arrive(timerBoard(store, AT - 50));
      board.settle(0, new Error('offline'));
      assert.equal(board.state.awaitingHost, !during, name);
      assert.equal(board.followUps, during ? 1 : 0, name);
      if (!during) {
        assert.equal(nextRead(board.host, board.state), false, name);
        board.arrive(timerBoard(store, AT - 50));
        assert.equal(board.followUps, 1, name);
      }
      // That read fails too, with no host result since: the board waits again rather than retrying.
      board.settle(0, new Error('offline'));
      assert.equal(board.followUps, 1, `${name}: no retry`);
      board.arrive(timerBoard(store, AT - 40));
      board.settle(0);
      assert.deepEqual(shown(boardView(board.host, board.state)), held(reply.store), name);
      assert.deepEqual([board.followUps, board.state.pending, board.state.inFlight], [2, [], 0], name);
    }
  }
});

test('retiring a change never changes the board shown, with host results delivered late or during reads, the board reading until no change shows, and a final read ends at the host state', () => {
  let seed = 11;
  const random = () => (seed = (seed * 1_103_515_245 + 12_345) % 2 ** 31) / 2 ** 31;
  const pick = (items) => items[Math.floor(random() * items.length)];
  for (const back of [0, 1, 1_000, 3_600_000]) {
    for (let trial = 0; trial < 40; trial++) {
      const name = `back ${back}, trial ${trial}`;
      let store = emptyStore();
      let at = AT;
      // Every board the host held so far; the host may pass any of them, late.
      const captured = [timerBoard(store, at - 100)];
      let host = captured[0];
      let state = hostArrived(emptyBoardState(), host);
      const ids = [];
      let reads = [];
      let failing = 0.25;
      // Issues the read `nextRead` asks for, as TimerBoard does after every event.
      const drain = () => {
        if (!nextRead(host, state)) return;
        const read = readIssued(state);
        state = read.state;
        reads.push({ issued: read.issued, outcome: random() < failing ? new Error('offline') : list(store, at + 2) });
      };
      // Moves to `next` and checks that the changes it dropped were hidden already: keeping them shows the same board.
      // A reply the host answered is followed by its own read instead (`readsAfter`).
      const move = (next, drains = true) => {
        const dropped = state.pending.filter((change) => !next.pending.some((each) => each.id === change.id));
        state = next;
        assert.deepEqual(boardView(host, { ...state, pending: [...state.pending, ...dropped] }), boardView(host, state), name);
        assert.equal(state.inFlight, reads.length, name);
        if (drains) drain();
      };
      const arrive = () => {
        host = pick(captured);
        move(hostArrived(state, host));
      };
      const settleOne = () => {
        const read = reads.splice(Math.floor(random() * reads.length), 1)[0];
        move(readSettled(state, read.issued, read.outcome).state);
      };
      for (const [operation, input] of STEPS) {
        if (random() < 0.3) at -= back;
        const reply = operations[operation](store, input(ids), at);
        assert.ok(reply.ok, `${operation}: ${JSON.stringify(reply.error)}`);
        store = reply.store;
        if (operation === 'create') ids.push(reply.result.timer.definition.id);
        const call = actionIssued(state);
        state = call.state;
        if (random() < 0.3) arrive();
        move(replySettled(state, operation, operation === 'create' ? null : input(ids).id, reply.result, call.issued).state, false);
        captured.push(timerBoard(store, at + 1));
        const issued = readIssued(state);
        state = issued.state;
        reads.push({ issued: issued.issued, outcome: random() < failing ? new Error('offline') : list(store, at + 2) });
        while (random() < 0.5 && reads.length) {
          if (random() < 0.5) arrive();
          settleOne();
        }
        at += 10;
      }
      while (reads.length) {
        if (random() < 0.5) arrive();
        settleOne();
      }
      // Quiet: no read is in flight, and a change still shows only while the board waits for the host after a
      // failed read. The host then passes its current board, and the board reads until no change shows.
      assert.ok(state.awaitingHost || !nextRead(host, state), name);
      failing = 0;
      host = timerBoard(store, at);
      move(hostArrived(state, host));
      while (reads.length) settleOne();
      assert.deepEqual([state.awaitingHost, state.inFlight, nextRead(host, state)], [false, 0, false], name);
      // A read issued after everything settles it.
      host = timerBoard(store, at);
      move(hostArrived(state, host));
      const last = readIssued(state);
      move(readSettled(last.state, last.issued, list(store, at)).state);
      assert.deepEqual(shown(boardView(host, state)), held(store), name);
      assert.deepEqual(state.pending, [], name);
    }
  }
});

test('the read after a change shows only a list result the board can render, or a List failure', async () => {
  const { result } = await fixture('view-props.json');
  assert.deepEqual(readRefresh(result), { ok: true, result });
  for (const outcome of [new Error('offline'), { error: { code: 'invalid_input', message: 'no' } }, {}, { ...result, observedAt: 8_640_000_000_000_001 }]) {
    const read = readRefresh(outcome);
    assert.equal(read.ok, false, JSON.stringify(outcome).slice(0, 60));
    assert.equal(read.failure.operation, 'list');
    assert.match(failureText(read.failure), /^List failed: .+/);
  }
});

test('board results and replies whose timers break the stored timer rules are refused', () => {
  for (const cooldownMs of [undefined, 10_000]) {
    const spec = { kind: 'interval', name: 'Laps', rounds: 2, segments: [{ label: 'Work', phase: 'work', durationMs: 20_000 }], ...(cooldownMs && { cooldownMs }) };
    const { store, id } = timerAfter({ timer: spec }, [['start', 0], ['pause', 5_000]]);
    const board = timerBoard(store, AT);
    assert.equal(readBoardResult(board).ok, true);
    assert.equal(readOutcome('pause', id, { timer: board.timers[0], observedAt: AT }).ok, true);
    // Paused at its total, as no operation leaves a timer: re-projecting it would show a zero-length step.
    const broken = structuredClone(board);
    broken.timers[0].runtime.accumulatedMs = 40_000 + (cooldownMs ?? 0);
    const read = readBoardResult(broken);
    assert.equal(read.ok, false, `cooldown ${cooldownMs}`);
    assert.match(read.message, /^timers\.0\.runtime\.accumulatedMs: /);
    const reply = readOutcome('pause', id, { timer: broken.timers[0], observedAt: AT });
    assert.equal(reply.ok, false);
    assert.match(failureText(reply.failure), /^Pause failed: The host's reply does not match the Timer contract \(timer\.runtime\.accumulatedMs: /);
  }
  // The ring stays finite whatever the projection holds.
  const projection = { status: 'running', elapsedMs: 0, totalMs: null, remainingMs: null, finished: false, step: null, next: null };
  assert.equal(ringProgress(projection), null, 'a stopwatch has no ring');
  assert.equal(ringProgress({ ...projection, totalMs: 60_000, elapsedMs: 15_000 }), 0.25);
  assert.equal(ringProgress({ ...projection, totalMs: 60_000, elapsedMs: 90_000 }), 1);
  assert.equal(ringProgress({ ...projection, finished: true }), 1);
  assert.equal(ringProgress({ ...projection, totalMs: 0 }), null);
  assert.equal(ringProgress({ ...projection, step: { elapsedMs: 0, durationMs: 0 } }), 1, 'a zero-length step is full, not NaN');
  assert.equal(ringProgress({ ...projection, step: { elapsedMs: 5_000, durationMs: 20_000 } }), 0.25);
});

test('the board shows only results it can render: observedAt within Date range, each id once', async () => {
  const { result } = await fixture('view-props.json');
  const last = 8_640_000_000_000_000;
  assert.equal(readBoardResult({ ...result, observedAt: last }).ok, true);
  assert.equal(typeof formatClockTime(last), 'string');
  assert.equal(new Date(last).toISOString(), '+275760-09-13T00:00:00.000Z');
  assert.deepEqual(readBoardResult({ ...result, observedAt: last + 1 }), { ok: false, message: 'observedAt: must be a time a Date can show' });
  assert.deepEqual(readBoardResult({ ...result, timers: [result.timers[0], result.timers[0]] }), { ok: false, message: 'timers: each timer id must appear once' });
});

test('the create form checks the name and its fields in every mode with the create schema', () => {
  const form = (mode, change = {}) => ({ mode, name: '', presetId: 'tabata', countdown: emptyCountdownDraft(), interval: emptyIntervalDraft(), ...change });
  for (const mode of ['preset', 'countdown', 'stopwatch', 'interval']) {
    const plain = createInputFrom(form(mode));
    assert.equal(plain.ok, true, `${mode}: ${JSON.stringify(plain.errors)}`);
    assert.equal(createInputValid(plain.spec), true, mode);
    const named = createInputFrom(form(mode, { name: ' Morning ' }));
    assert.equal(createInputValid(named.spec), true, mode);
    assert.equal(named.spec.name ?? named.spec.timer.name, 'Morning', mode);
    for (const name of ['Line\nbreak', 'x'.repeat(61), '\u202Eevil']) {
      const outcome = createInputFrom(form(mode, { name }));
      assert.deepEqual(Object.keys(outcome.errors ?? {}), ['name'], `${mode} ${JSON.stringify(name)}`);
      assert.equal(createInputValid({ ...(mode === 'preset' ? { preset: 'tabata' } : { timer: { kind: 'stopwatch' } }), name }), false);
    }
  }
  assert.deepEqual(createInputFrom(form('preset', { presetId: '' })).errors, { preset: 'Choose a preset.' });
  assert.deepEqual(Object.keys(createInputFrom(form('preset', { presetId: 'nope' })).errors), ['preset']);
});
