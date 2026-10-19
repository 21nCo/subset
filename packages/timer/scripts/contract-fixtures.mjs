// Builds the contract-v1 test vectors from the compiled package. `npm run fixtures` writes them to
// fixtures/contract-v1/; test/contract.test.mjs fails when the checked-in files drift from this output.
import { mkdir, writeFile } from 'node:fs/promises';
import { pathToFileURL } from 'node:url';
import { OPERATION_WRITE_CLASS, agentTimerResult, emptyStore, operations } from '../dist/index.js';

export const OBSERVED_AT = Date.UTC(2026, 9, 19, 9, 0, 0);
const at = (offsetMs) => OBSERVED_AT + offsetMs;
const minute = 60_000;

function apply(store, operation, input, now) {
  const outcome = operations[operation](store, input, now);
  if (!outcome.ok) throw new Error(`${operation} failed while building fixtures: ${outcome.error.message}`);
  return outcome;
}

/** A store with every kind in every state it can be in at `OBSERVED_AT`. */
export function fixtureStore() {
  let store = emptyStore();
  const run = (operation, input, now) => {
    const outcome = apply(store, operation, input, now);
    store = outcome.store;
    return outcome.result;
  };
  // Running interval: round 3 of 8, 12 s left in work.
  run('start', { preset: 'tabata' }, at(-78_000));
  // Running stopwatch with two laps.
  const stopwatch = run('start', { timer: { kind: 'stopwatch', name: 'Run' } }, at(-10 * minute)).timer.definition.id;
  run('lap', { id: stopwatch }, at(-7 * minute));
  run('lap', { id: stopwatch }, at(-3 * minute));
  // Paused countdown with 1:40 left.
  const tea = run('start', { timer: { kind: 'countdown', name: 'Tea', durationMs: 3 * minute } }, at(-4 * minute)).timer.definition.id;
  run('pause', { id: tea }, at(-3 * minute + 20_000));
  // Stored as running but past its end: the projection reports it finished.
  const amrap = run('start', { preset: 'amrap' }, at(-21 * minute)).timer.definition.id;
  run('lap', { id: amrap }, at(-15 * minute));
  // Finished by skipping its last segment.
  const stretch = run('start', {
    timer: { kind: 'interval', name: 'Stretch', rounds: 1, segments: [{ label: 'Hold', phase: 'work', durationMs: 30_000 }] }
  }, at(-20_000)).timer.definition.id;
  run('skip', { id: stretch }, at(-10_000));
  // Idle: a preset, and a countdown to a time whose duration is fixed when it starts.
  run('create', { preset: 'pomodoro' }, at(-2 * minute));
  run('create', { timer: { kind: 'countdown', name: 'Standup', until: new Date(at(30 * minute)).toISOString() } }, at(-minute));
  run('presets.save', {
    name: 'Ladder',
    timer: {
      kind: 'interval', rounds: 3, cooldownMs: 2 * minute,
      segments: [
        { label: 'Squats', phase: 'work', durationMs: 45_000 },
        { label: 'Rest', phase: 'rest', durationMs: 15_000 },
        { label: 'Lunges', phase: 'work', durationMs: 45_000 },
        { label: 'Rest', phase: 'rest', durationMs: 15_000 }
      ]
    }
  }, at(-30 * minute));
  return store;
}

const longName = '⏱'.repeat(60);
// Outside the Basic Multilingual Plane: two UTF-16 units, one character.
const astralName = '🏃'.repeat(60);
const tabataSpec = { kind: 'interval', rounds: 8, prepMs: 10_000, segments: [{ label: 'Work', phase: 'work', durationMs: 20_000 }, { label: 'Rest', phase: 'rest', durationMs: 10_000 }] };

/** Inputs the JSON Schemas and the runtime validators must both accept or both reject. */
export const inputVectors = {
  valid: [
    { operation: 'create', input: { timer: { kind: 'countdown', durationMs: 1_000 } } },
    { operation: 'create', input: { timer: { kind: 'countdown', durationMs: 86_400_000, lapsEnabled: true, sound: false } } },
    { operation: 'create', input: { timer: { kind: 'countdown', until: '2026-10-19T17:30:00+02:00' } } },
    { operation: 'create', input: { timer: { kind: 'stopwatch', name: longName } } },
    { operation: 'create', input: { timer: { kind: 'stopwatch', name: astralName } } },
    { operation: 'create', input: { preset: 'hiit-40-20', name: 'Morning HIIT' } },
    // A zero-width joiner sequence is one visible emoji.
    { operation: 'create', input: { timer: { kind: 'stopwatch', name: '\u{1F469}\u200D\u{1F4BB} Desk' } } },
    { operation: 'create', input: { timer: { kind: 'stopwatch', name: 'Cafe\u0301 \u202Fbreak' } } },
    { operation: 'create', input: { timer: { ...tabataSpec, name: 'Custom', countdownTicks: false, cooldownMs: 60_000 } } },
    { operation: 'start', input: { id: 't_ab12cd34' } },
    { operation: 'start', input: { preset: 'p_ab12cd34' } },
    { operation: 'start', input: { timer: { kind: 'stopwatch' }, name: 'Laps' } },
    { operation: 'presets.save', input: { name: 'Tabata x2', timer: { ...tabataSpec, rounds: 16 } } },
    { operation: 'presets.remove', input: { id: 'p_ab12cd34' } },
    { operation: 'list', input: {} }
  ],
  invalid: [
    { operation: 'create', why: 'needs a timer or a preset', input: {} },
    { operation: 'create', why: 'timer and preset together', input: { timer: { kind: 'stopwatch' }, preset: 'tabata' } },
    { operation: 'create', why: 'unknown kind', input: { timer: { kind: 'alarm' } } },
    { operation: 'create', why: 'unknown property', input: { timer: { kind: 'stopwatch', colour: 'red' } } },
    { operation: 'create', why: 'countdown under 1 s', input: { timer: { kind: 'countdown', durationMs: 999 } } },
    { operation: 'create', why: 'countdown over 24 h', input: { timer: { kind: 'countdown', durationMs: 86_400_001 } } },
    { operation: 'create', why: 'fractional milliseconds', input: { timer: { kind: 'countdown', durationMs: 1_000.5 } } },
    { operation: 'create', why: 'countdown with both durationMs and until', input: { timer: { kind: 'countdown', durationMs: 60_000, until: '2026-10-19T17:30:00Z' } } },
    { operation: 'create', why: 'countdown with neither durationMs nor until', input: { timer: { kind: 'countdown' } } },
    { operation: 'create', why: 'until without seconds', input: { timer: { kind: 'countdown', until: '2026-10-19T09:00Z' } } },
    { operation: 'create', why: 'until without a time zone', input: { timer: { kind: 'countdown', until: '2026-10-19T17:30:00' } } },
    { operation: 'create', why: 'name over 60 characters', input: { timer: { kind: 'stopwatch', name: `${longName}⏱` } } },
    { operation: 'create', why: 'name over 60 characters outside the BMP', input: { timer: { kind: 'stopwatch', name: `${astralName}🏃` } } },
    { operation: 'create', why: 'empty name', input: { timer: { kind: 'stopwatch', name: '' } } },
    { operation: 'create', why: 'blank name', input: { timer: { kind: 'stopwatch', name: '   ' } } },
    { operation: 'create', why: 'name on two lines', input: { timer: { kind: 'stopwatch', name: 'Run\nfast' } } },
    { operation: 'create', why: 'name with a line separator', input: { timer: { kind: 'stopwatch', name: 'Run\u2028fast' } } },
    { operation: 'create', why: 'name of only a zero-width space', input: { timer: { kind: 'stopwatch', name: '\u200B' } } },
    { operation: 'create', why: 'name of only word joiners and a no-break space', input: { timer: { kind: 'stopwatch', name: '\u2060\u00A0\u2060' } } },
    { operation: 'create', why: 'name of only a combining mark', input: { timer: { kind: 'stopwatch', name: '\u0301' } } },
    { operation: 'create', why: 'name of only a Hangul filler', input: { timer: { kind: 'stopwatch', name: '\u3164' } } },
    { operation: 'create', why: 'name with a right-to-left override', input: { timer: { kind: 'stopwatch', name: 'a\u202Eb' } } },
    { operation: 'create', why: 'name with a right-to-left embedding', input: { timer: { kind: 'stopwatch', name: 'a\u202Bb' } } },
    { operation: 'create', why: 'name with a first-strong isolate', input: { timer: { kind: 'stopwatch', name: 'a\u2068b\u2069' } } },
    { operation: 'create', why: 'label of only a zero-width space', input: { timer: { ...tabataSpec, segments: [{ label: '\u200B', phase: 'work', durationMs: 20_000 }] } } },
    { operation: 'create', why: 'label with a left-to-right override', input: { timer: { ...tabataSpec, segments: [{ label: 'Work\u202D', phase: 'work', durationMs: 20_000 }] } } },
    { operation: 'create', why: 'no segments', input: { timer: { ...tabataSpec, segments: [] } } },
    { operation: 'create', why: '101 segments', input: { timer: { ...tabataSpec, rounds: 1, segments: Array.from({ length: 101 }, () => tabataSpec.segments[0]) } } },
    { operation: 'create', why: 'zero rounds', input: { timer: { ...tabataSpec, rounds: 0 } } },
    { operation: 'create', why: '100 rounds', input: { timer: { ...tabataSpec, rounds: 100 } } },
    { operation: 'create', why: 'label over 40 characters', input: { timer: { ...tabataSpec, segments: [{ label: 'x'.repeat(41), phase: 'work', durationMs: 20_000 }] } } },
    { operation: 'create', why: 'unknown phase', input: { timer: { ...tabataSpec, segments: [{ label: 'Warm', phase: 'warmup', durationMs: 20_000 }] } } },
    { operation: 'create', why: 'prep under 1 s', input: { timer: { ...tabataSpec, prepMs: 500 } } },
    { operation: 'start', why: 'id and timer together', input: { id: 't_ab12cd34', timer: { kind: 'stopwatch' } } },
    { operation: 'start', why: 'renaming an existing timer', input: { id: 't_ab12cd34', name: 'Other' } },
    { operation: 'start', why: 'id, timer and name together', input: { id: 't_ab12cd34', timer: { kind: 'stopwatch' }, name: 'Other' } },
    { operation: 'start', why: 'id, preset and name together', input: { id: 't_ab12cd34', preset: 'tabata', name: 'Other' } },
    { operation: 'presets.save', why: 'preset name of only a zero-width space', input: { name: '\u200B', timer: { kind: 'stopwatch' } } },
    { operation: 'pause', why: 'malformed id', input: { id: 'T_AB12CD34' } },
    { operation: 'pause', why: 'id with a letter outside Crockford base32', input: { id: 't_ab12cd3u' } },
    { operation: 'get', why: 'missing id', input: {} },
    { operation: 'list', why: 'unknown property', input: { status: 'running' } },
    { operation: 'list', why: 'null instead of an object', input: null },
    { operation: 'presets.list', why: 'null instead of an object', input: null },
    { operation: 'pause', why: 'null instead of an object', input: null },
    { operation: 'presets.save', why: 'a preset cannot name one moment', input: { name: 'Standup', timer: { kind: 'countdown', until: '2026-10-19T17:30:00Z' } } },
    { operation: 'presets.remove', why: 'not a preset id', input: { id: 'Tabata' } }
  ]
};

function operationCases(store) {
  const ids = Object.fromEntries(store.timers.map((timer) => [timer.definition.name, timer.definition.id]));
  const ladder = store.presets[0].id;
  const cases = [
    ['create a countdown', 'create', { timer: { kind: 'countdown', name: 'Eggs', durationMs: 6 * minute } }],
    ['create from a saved preset', 'create', { preset: ladder, name: 'Leg ladder' }],
    ['create rejects an until time more than 24 hours away', 'create', { timer: { kind: 'countdown', until: new Date(at(25 * 60 * minute)).toISOString() } }],
    ['create names an unknown preset', 'create', { preset: 'p_zzzzzzzz' }],
    ['start an idle timer', 'start', { id: ids.Pomodoro }],
    ['start fixes an until countdown to a duration', 'start', { id: ids.Standup }],
    ['start a preset in one step', 'start', { preset: 'emom' }],
    ['start a running timer', 'start', { id: ids.Tabata }],
    ['start a finished timer', 'start', { id: ids.Stretch }],
    ['pause a running interval', 'pause', { id: ids.Tabata }],
    ['pause a timer whose time is up', 'pause', { id: ids.AMRAP }],
    ['pause an unknown timer', 'pause', { id: 't_zzzzzzzz' }],
    ['resume a paused countdown', 'resume', { id: ids.Tea }],
    ['resume a running timer', 'resume', { id: ids.Run }],
    ['lap a stopwatch', 'lap', { id: ids.Run }],
    ['lap an interval timer', 'lap', { id: ids.Tabata }],
    ['skip to the next segment', 'skip', { id: ids.Tabata }],
    ['skip a stopwatch', 'skip', { id: ids.Run }],
    ['reset a finished timer', 'reset', { id: ids.Stretch }],
    ['remove a timer', 'remove', { id: ids.Run }],
    ['remove an unknown timer', 'remove', { id: 't_zzzzzzzz' }],
    ['list every timer', 'list', {}],
    ['get one timer', 'get', { id: ids.Tea }],
    ['get with a malformed id', 'get', { id: 'tea' }],
    ['list presets', 'presets.list', {}],
    ['save a preset', 'presets.save', { name: 'Plank', timer: { kind: 'countdown', durationMs: 90_000, countdownTicks: true } }],
    ['remove a saved preset', 'presets.remove', { id: ladder }],
    ['remove a built-in preset', 'presets.remove', { id: 'tabata' }],
    ['remove an unknown preset', 'presets.remove', { id: 'p_zzzzzzzz' }]
  ];
  return cases.map(([name, operation, input]) => {
    const outcome = operations[operation](store, input, OBSERVED_AT);
    return {
      name, operation, writeClass: OPERATION_WRITE_CLASS[operation], input, now: OBSERVED_AT,
      ...(outcome.ok ? { result: outcome.result } : { error: outcome.error })
    };
  });
}

export function contractFixtures() {
  const store = fixtureStore();
  const agentResult = agentTimerResult(store, OBSERVED_AT);
  return {
    'store.json': store,
    'agent-result.json': agentResult,
    'operations.json': { store: 'store.json', cases: operationCases(store) },
    'inputs.json': inputVectors,
    'view-props.json': { result: agentResult.structuredContent, capabilities: { create: true, destructive: false }, density: 'compact' }
  };
}

export const fixtureText = (value) => `${JSON.stringify(value, null, 2)}\n`;

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  const directory = new URL('../fixtures/contract-v1/', import.meta.url);
  await mkdir(directory, { recursive: true });
  for (const [file, value] of Object.entries(contractFixtures())) await writeFile(new URL(file, directory), fixtureText(value));
}
