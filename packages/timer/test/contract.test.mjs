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
  assert.deepEqual(await readFixture('inputs.json'), JSON.parse(JSON.stringify(inputVectors)));
  const store = await readFixture('store.json');
  for (const { operation, input } of inputVectors.valid) {
    assertValid(schemas.inputs[operation], input, `${operation} ${JSON.stringify(input).slice(0, 80)}`);
    const outcome = operations[operation](store, input, Date.UTC(2026, 9, 19, 9, 0, 0));
    assert.notEqual(outcome.ok ? 'ok' : outcome.error.code, 'invalid_input', `${operation} runtime rejected ${JSON.stringify(input).slice(0, 80)}`);
  }
  for (const { operation, input, why } of inputVectors.invalid) {
    assert.equal(validator(schemas.inputs[operation])(input), false, `JSON Schema accepted: ${why}`);
    const outcome = operations[operation](store, input, Date.UTC(2026, 9, 19, 9, 0, 0));
    assert.equal(outcome.ok ? 'ok' : outcome.error.code, 'invalid_input', `runtime accepted: ${why}`);
  }
});
