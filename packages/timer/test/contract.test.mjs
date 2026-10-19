import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import test from 'node:test';
import Ajv2020 from 'ajv/dist/2020.js';
import addFormats from 'ajv-formats';
import { OPERATION_NAMES, operations, parseStore, schemas } from '../dist/index.js';
import { contractFixtures, fixtureText, inputVectors } from '../scripts/contract-fixtures.mjs';

const directory = new URL('../fixtures/contract-v1/', import.meta.url);
const readFixture = async (file) => JSON.parse(await readFile(new URL(file, directory), 'utf8'));

// Branches such as `oneOf: [{ required: ['timer'] }, ...]` name properties defined beside them, which strictRequired flags.
const ajv = new Ajv2020({ allErrors: true, strict: true, strictRequired: false });
addFormats(ajv);
const validator = (schema) => ajv.compile(schema);
function assertValid(schema, value, label) {
  const validate = validator(schema);
  assert.ok(validate(value), `${label}: ${ajv.errorsText(validate.errors)}`);
}

test('checked-in fixtures match what the package produces', async () => {
  const expected = contractFixtures();
  assert.deepEqual((await readdir(directory)).sort(), Object.keys(expected).sort(), 'run `npm run fixtures --workspace=@subset/timer`');
  for (const [file, value] of Object.entries(expected)) {
    assert.equal(await readFile(new URL(file, directory), 'utf8'), fixtureText(value), `${file} is stale; run \`npm run fixtures --workspace=@subset/timer\``);
  }
});

test('every schema compiles in strict mode, and every operation has an object input schema', () => {
  assert.deepEqual(Object.keys(schemas.inputs), OPERATION_NAMES);
  assert.deepEqual(Object.keys(schemas.outputs), OPERATION_NAMES);
  for (const [name, schema] of Object.entries(schemas.inputs)) {
    // MCP tool definitions require an object at the root.
    assert.equal(schema.type, 'object', name);
    validator(schema);
  }
  for (const schema of [...Object.values(schemas.outputs), schemas.store, schemas.result, schemas.error, schemas.viewProps]) validator(schema);
  assert.equal(schemas.viewId, 'subset.timer.board@1');
});

test('every fixture validates against its schema', async () => {
  const store = await readFixture('store.json');
  assertValid(schemas.store, store, 'store.json');
  assert.equal(parseStore(store).ok, true);

  const agent = await readFixture('agent-result.json');
  assertValid(schemas.result, agent.structuredContent, 'agent-result.json');
  assert.equal(agent.viewId, schemas.viewId);
  assert.equal(agent.text.split('\n').length, agent.structuredContent.timers.length);
  assert.deepEqual(new Set(agent.structuredContent.timers.map((timer) => timer.projection.status)), new Set(['idle', 'running', 'paused', 'finished']));

  assertValid(schemas.viewProps, await readFixture('view-props.json'), 'view-props.json');

  const { cases } = await readFixture('operations.json');
  assert.deepEqual(new Set(cases.map((item) => item.operation)), new Set(OPERATION_NAMES));
  // limit_reached needs a full store; operations.test.mjs covers it.
  assert.deepEqual(new Set(cases.filter((item) => item.error).map((item) => item.error.code)), new Set(['not_found', 'invalid_state', 'invalid_input']));
  for (const item of cases) {
    if (item.error) {
      assertValid(schemas.error, item.error, item.name);
      // Inputs that fail only for state or lookup reasons are still well-formed.
      if (item.error.code !== 'invalid_input') assertValid(schemas.inputs[item.operation], item.input, `${item.name} input`);
    } else {
      assertValid(schemas.inputs[item.operation], item.input, `${item.name} input`);
      assertValid(schemas.outputs[item.operation], item.result, `${item.name} result`);
    }
    // Replaying a case gives the recorded outcome, so the Swift client can trust these vectors.
    const outcome = operations[item.operation](store, item.input, item.now);
    assert.deepEqual(outcome.ok ? { result: outcome.result } : { error: outcome.error }, item.error ? { error: item.error } : { result: item.result }, item.name);
  }
});

test('the JSON Schemas and the runtime validators accept and reject the same inputs', async () => {
  const vectors = await readFixture('inputs.json');
  assert.deepEqual(vectors, JSON.parse(JSON.stringify(inputVectors)));
  // Replay from the fixture alone: its recorded store and clock.
  const store = await readFixture(vectors.store);
  const now = vectors.now;
  for (const { operation, input } of vectors.valid) {
    assertValid(schemas.inputs[operation], input, `${operation} ${JSON.stringify(input).slice(0, 80)}`);
    const outcome = operations[operation](store, input, now);
    assert.notEqual(outcome.ok ? 'ok' : outcome.error.code, 'invalid_input', `${operation} runtime rejected ${JSON.stringify(input).slice(0, 80)}`);
  }
  for (const { operation, input, why } of vectors.invalid) {
    assert.equal(validator(schemas.inputs[operation])(input), false, `JSON Schema accepted: ${why}`);
    const outcome = operations[operation](store, input, now);
    assert.equal(outcome.ok ? 'ok' : outcome.error.code, 'invalid_input', `runtime accepted: ${why}`);
  }
});

test('the store JSON Schema states the timer rules that need no arithmetic, and parseStore checks every rule', async () => {
  const store = await readFixture('store.json');
  const index = Object.fromEntries(store.timers.map((timer, position) => [timer.definition.name, position]));
  const changed = (name, change) => {
    const copy = structuredClone(store);
    change(copy.timers[index[name]]);
    return copy;
  };
  const expressible = [
    ['idle with laps', changed('Pomodoro', (timer) => { timer.runtime.laps = [{ elapsedMs: 0, at: 0 }]; })],
    ['idle with skips', changed('Pomodoro', (timer) => { timer.runtime.skippedMs = 1_000; })],
    ['idle with a position', changed('Pomodoro', (timer) => { timer.runtime.accumulatedMs = 1_000; })],
    ['a finished stopwatch', changed('Run', (timer) => { Object.assign(timer.runtime, { status: 'finished', startedAt: null }); })],
    ['skips on a stopwatch', changed('Run', (timer) => { timer.runtime.skippedMs = 1_000; })],
    ['skips on a countdown', changed('Tea', (timer) => { timer.runtime.skippedMs = 1_000; })],
    ['laps on a countdown without laps', changed('Tea', (timer) => { timer.runtime.laps = [{ elapsedMs: 0, at: 0 }]; })],
    ['laps on an interval timer', changed('Tabata', (timer) => { timer.runtime.laps = [{ elapsedMs: 0, at: 0 }]; })],
    ['an until countdown started without a fixed duration', changed('Standup', (timer) => { Object.assign(timer.runtime, { status: 'running', startedAt: 0 }); })]
  ];
  const runtimeOnly = [
    ['paused at its end', changed('Tea', (timer) => { timer.runtime.accumulatedMs = timer.definition.durationMs; })],
    ['finished before its end', changed('Stretch', (timer) => { timer.runtime.accumulatedMs -= 1; })]
  ];
  const validate = validator(schemas.store);
  assert.equal(validate(store), true);
  for (const [why, value] of expressible) assert.equal(validate(value), false, `JSON Schema accepted: ${why}`);
  for (const [why, value] of runtimeOnly) assert.equal(validate(value), true, `JSON Schema now states: ${why}; move it to the list above`);
  for (const [why, value] of [...expressible, ...runtimeOnly]) assert.equal(parseStore(value).ok, false, `parseStore accepted: ${why}`);
});

test('the create and start selector schemas agree with the runtime for every combination of fields', async () => {
  const store = await readFixture('store.json');
  const idleId = store.timers.find((timer) => timer.runtime.status === 'idle').definition.id;
  const values = {
    id: { valid: idleId, invalid: 'tea' },
    timer: { valid: { kind: 'stopwatch' }, invalid: { kind: 'alarm' } },
    preset: { valid: 'tabata', invalid: 'Tabata!' },
    name: { valid: 'Mine', invalid: '' }
  };
  // Every field absent, valid or invalid: 3^4 inputs for start and 3^3 for create.
  const inputs = (keys) => keys.reduce((partials, key) => partials.flatMap((partial) => [
    partial, { ...partial, [key]: values[key].valid }, { ...partial, [key]: values[key].invalid }
  ]), [{}]);
  const cases = [['start', ['id', 'timer', 'preset', 'name']], ['create', ['timer', 'preset', 'name']]];
  let checked = 0;
  for (const [operation, keys] of cases) {
    const validate = validator(schemas.inputs[operation]);
    for (const input of inputs(keys)) {
      const outcome = operations[operation](store, input, Date.UTC(2026, 9, 19, 9, 0, 0));
      const runtime = !(outcome.ok === false && outcome.error.code === 'invalid_input');
      assert.equal(validate(input), runtime, `${operation} ${JSON.stringify(input)}: JSON Schema ${runtime ? 'rejected' : 'accepted'} what the runtime ${runtime ? 'accepted' : 'rejected'}`);
      checked += 1;
    }
  }
  assert.equal(checked, 81 + 27);
});
