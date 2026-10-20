import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { emptyStore, runOperation } from '@subset/timer';
import { createStateStore, daemonPaths } from '../../src/daemon/index.mjs';
import { startTestDaemon, tempDataDir } from './helpers.mjs';

const NOW = Date.UTC(2026, 0, 1);

function storeIn(t) {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const logs = [];
  const paths = daemonPaths(dataDir);
  return { paths, logs, stateStore: createStateStore(paths, { log: (message) => logs.push(message), now: () => NOW }) };
}

function storeWithTimer(name) {
  const outcome = runOperation('create', emptyStore(), { timer: { kind: 'stopwatch', name } }, NOW);
  assert.equal(outcome.ok, true);
  return outcome.store;
}

test('a saved store reads back, written with mode 0600 and no temp file left', (t) => {
  const { paths, stateStore } = storeIn(t);
  assert.deepEqual(stateStore.load(), emptyStore());
  const store = storeWithTimer('One');
  stateStore.save(store);
  assert.deepEqual(stateStore.load(), store);
  assert.equal(statSync(paths.state).mode & 0o777, 0o600);
  assert.deepEqual(readdirSync(paths.dataDir), ['state.json']);
});

test('a crash between the write and the rename keeps the previous store', (t) => {
  const { paths, stateStore } = storeIn(t);
  const before = storeWithTimer('Before');
  stateStore.save(before);
  // A separate process writes a new store and dies just before its rename, as in a crash.
  const storeModule = new URL('../../src/daemon/store.mjs', import.meta.url).href;
  const script = `
    import * as fs from 'node:fs';
    import { writeFileAtomic } from ${JSON.stringify(storeModule)};
    const crashing = { ...fs, renameSync: () => process.exit(9) };
    writeFileAtomic(${JSON.stringify(paths.state)}, '{"partial":', { fs: crashing });
  `;
  const crashed = spawnSync(process.execPath, ['--input-type=module', '-e', script]);
  assert.equal(crashed.status, 9, crashed.stderr.toString());
  const leftovers = readdirSync(paths.dataDir).filter((name) => name.endsWith('.tmp'));
  assert.equal(leftovers.length, 1);
  assert.equal(readFileSync(join(paths.dataDir, leftovers[0]), 'utf8'), '{"partial":');

  assert.deepEqual(stateStore.load(), before);
  assert.deepEqual(readdirSync(paths.dataDir), ['state.json']);
});

for (const [label, content] of [
  ['invalid JSON', '{"schemaVersion": 1, "timers": ['],
  ['an empty file', ''],
  ['a store that fails validation', JSON.stringify({ schemaVersion: 2, idSequence: 0, timers: [], presets: [] })]
]) {
  test(`${label} is moved aside to state.corrupt-<ts>.json and the store starts empty`, (t) => {
    const { paths, stateStore, logs } = storeIn(t);
    writeFileSync(paths.state, content);
    assert.deepEqual(stateStore.load(), emptyStore());
    assert.equal(existsSync(paths.state), false);
    assert.equal(readFileSync(join(paths.dataDir, `state.corrupt-${NOW}.json`), 'utf8'), content);
    assert.equal(logs.length, 1);
    assert.match(logs[0], new RegExp(`moved it to state\\.corrupt-${NOW}\\.json`));
  });
}

test('a second corrupt file in the same millisecond does not overwrite the first', (t) => {
  const { paths, stateStore } = storeIn(t);
  writeFileSync(paths.state, 'first');
  stateStore.load();
  writeFileSync(paths.state, 'second');
  stateStore.load();
  assert.equal(readFileSync(join(paths.dataDir, `state.corrupt-${NOW}.json`), 'utf8'), 'first');
  assert.equal(readFileSync(join(paths.dataDir, `state.corrupt-${NOW}-1.json`), 'utf8'), 'second');
});

test('the daemon starts empty from a corrupt state file and logs the move', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  writeFileSync(join(dataDir, 'state.json'), 'not json');
  const { call, logs } = await startTestDaemon(t, { dataDir });
  const { body } = await call('GET', '/v1/timers');
  assert.deepEqual(body.structuredContent.timers, []);
  assert.ok(logs.some((line) => /state\.json could not be read .*moved it to state\.corrupt-\d+\.json/.test(line)));
  assert.ok(readdirSync(dataDir).some((name) => /^state\.corrupt-\d+\.json$/.test(name)));
});

test('an unreadable mark is ignored', (t) => {
  const { paths, stateStore } = storeIn(t);
  assert.equal(stateStore.loadMark(), null);
  writeFileSync(paths.scheduler, '{');
  assert.equal(stateStore.loadMark(), null);
  stateStore.saveMark(NOW);
  assert.equal(stateStore.loadMark(), NOW);
});
