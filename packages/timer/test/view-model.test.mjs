import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { emptyStore, operations, schemas } from '../dist/index.js';
import {
  CONFIRM_MS, applyResult, controlStates, countdownSpecFrom, durationText, emptyIntervalDraft, failureText, formatElapsed, formatRemaining,
  intervalDraftFrom, intervalSpecFrom, keyControl, parseDurationText, pickAnnouncements, pressDestructive, primaryControl, readBoardResult,
  readOutcome, readPresets, reproject
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
  assert.equal(primaryControl(running), 'pause');
  assert.equal(keyControl(' ', running), 'pause');
  assert.equal(keyControl('l', running), 'lap');
  assert.equal(keyControl('L', running), 'lap');
  assert.equal(keyControl('s', running), null, 'skip is hidden');
  assert.equal(keyControl('r', running), null);
  assert.equal(keyControl(' ', row(D, D, D, H, H, E, E)), null);
  assert.equal(keyControl('S', row(D, D, E, H, E, E, E)), 'skip');
  assert.equal(keyControl(' ', row(E, D, D, H, D, D, E)), 'start');
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

test('the board reads its result through the contract and keeps action results until the next one', async () => {
  const props = await fixture('view-props.json');
  const read = readBoardResult(props.result);
  assert.equal(read.ok, true);
  assert.equal(readBoardResult({ ...props.result, schemaVersion: 2 }).ok, false);
  assert.equal(readBoardResult(null).ok, false);

  const timers = read.result.timers;
  const [first, second] = timers;
  const changed = { ...first, runtime: { ...first.runtime, status: 'paused' } };
  assert.deepEqual(applyResult(timers, { timer: changed }).map((timer) => timer.runtime.status)[0], 'paused');
  assert.equal(applyResult(timers, { timer: { ...second, definition: { ...second.definition, id: 't_zzzzzzzz' } } }).length, timers.length + 1);
  assert.deepEqual(applyResult(timers, { removedId: first.definition.id }).map((timer) => timer.definition.id), timers.slice(1).map((timer) => timer.definition.id));
  assert.equal(applyResult(timers, { presets: [] }).length, timers.length);
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
  assert.deepEqual(readOutcome('remove', 't_1', { removedId: 't_1' }), { ok: true, result: { removedId: 't_1' } });
});
