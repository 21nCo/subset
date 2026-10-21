import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { McpFnTestClient, assertManifestContract, validateMcpFnSchemaPortability } from '@mcpfn/testing';
import { BUILT_IN_PRESET_IDS, schemas } from '@subset/timer';
import { defineTimerMcpServer } from '../../src/mcp/server.mjs';
import { DaemonUnavailableError, createClient } from '../../src/daemon/index.mjs';
import { FIXTURES, cliDaemon } from '../cli/helpers.mjs';
import { tempDataDir } from '../daemon/helpers.mjs';

const fixture = (name) => JSON.parse(readFileSync(join(FIXTURES, name), 'utf8'));
const agentResult = fixture('agent-result.json');
const manifest = JSON.parse(readFileSync(new URL('../../package.json', import.meta.url), 'utf8'));

const READS = ['timer_get', 'timer_list', 'timer_presets'];
const DESTRUCTIVE = ['timer_preset_remove', 'timer_remove', 'timer_reset'];
const TOOLS = [...READS, 'timer_lap', 'timer_pause', 'timer_preset_save', 'timer_resume', 'timer_skip', 'timer_start', ...DESTRUCTIVE].sort();

/** An MCP client connected in memory to the Timer server, over an in-process daemon on a fake clock. */
async function mcpSession(t, { client: wrap = (client) => client, ...options } = {}) {
  const daemon = await cliDaemon(t, options);
  const logs = [];
  const declaration = defineTimerMcpServer({ client: wrap(daemon.client), now: () => daemon.clock.now(), log: (line) => logs.push(line) });
  const mcp = await McpFnTestClient.connect(declaration.createServer());
  t.after(() => mcp.close());
  const call = (name, args = {}) => mcp.callTool(name, args);
  /** The daemon's own view of a timer, read past the server. */
  const timer = async (id) => (await daemon.op('get', { id })).body.timer;
  return { ...daemon, mcp, declaration, call, timer, logs };
}

function assertError(result, code) {
  assert.equal(result.isError, true, JSON.stringify(result));
  assert.equal(result.structuredContent.error.code, code, JSON.stringify(result.structuredContent));
  assert.equal(typeof result.structuredContent.error.message, 'string');
  assert.equal(result.content[0].text, `${code}: ${result.structuredContent.error.message}`);
  return result.structuredContent.error;
}

/** A write's result: the board after it plus the timer it changed, and text naming that timer. */
function assertWrite(result, id) {
  assert.equal(result.isError, undefined, JSON.stringify(result));
  const { affectedTimerId, ...board } = result.structuredContent;
  assert.equal(affectedTimerId, id);
  assert.deepEqual(Object.keys(board), ['schemaVersion', 'observedAt', 'timers']);
  assert.match(result.content[0].text, new RegExp(`\\(${id}\\)`));
  return board;
}

test('tools/list returns the 12 tools with their schemas, annotations and descriptions', async (t) => {
  const { mcp, declaration } = await mcpSession(t);
  const tools = await assertManifestContract(mcp, declaration.manifest(), { expectedToolNames: TOOLS });
  assert.deepEqual(tools.map((tool) => tool.name).sort(), TOOLS);
  for (const tool of tools) {
    const { inputSchema, annotations, description } = tool;
    assert.equal(inputSchema.type, 'object', tool.name);
    assert.equal(inputSchema.additionalProperties, false, tool.name);
    // Some hosts refuse a top-level combinator, so the rules between fields are checked by the tools.
    for (const keyword of ['oneOf', 'anyOf', 'allOf', 'not', '$schema']) assert.equal(inputSchema[keyword], undefined, `${tool.name} ${keyword}`);
    assert.deepEqual(validateMcpFnSchemaPortability(inputSchema, tool.name), [], tool.name);
    assert.equal(annotations.openWorldHint, false, tool.name);
    assert.equal(annotations.readOnlyHint, READS.includes(tool.name), tool.name);
    if (!READS.includes(tool.name)) assert.equal(annotations.destructiveHint, DESTRUCTIVE.includes(tool.name), tool.name);
    assert.match(description, /run locally .* keep running after the conversation ends/, tool.name);
    // Every tool says what to report: the timer id and its end, or for the preset tools the preset id too.
    assert.match(description, /Tell the user the (?:timer id|preset id|id of the removed preset)/, tool.name);
    assert.match(description, /timer ids? and[^.]*(?:when it ends|end times)/, tool.name);
    assert.ok(tool.title, tool.name);
  }
  const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool.inputSchema]));
  // Ids, names, labels and phases come from the SET-74 schemas.
  assert.equal(byName.timer_pause.properties.id.pattern, schemas.inputs.pause.properties.id.pattern);
  assert.deepEqual(byName.timer_pause.required, ['id']);
  assert.equal(byName.timer_reset.properties.name.allOf.length, schemas.inputs.create.properties.name.allOf.length);
  assert.equal(byName.timer_preset_remove.properties.id.pattern, schemas.inputs['presets.remove'].properties.id.pattern);
  assert.deepEqual(Object.keys(byName.timer_start.properties), ['preset', 'durationSeconds', 'until', 'stopwatch', 'interval', 'name', 'sound']);
  assert.deepEqual(Object.keys(byName.timer_start.properties.interval.properties), ['work', 'rest', 'rounds', 'prep', 'cooldown', 'segments']);
  assert.deepEqual(byName.timer_start.properties.interval.properties.segments.items.properties.phase.enum, ['prep', 'work', 'rest', 'cooldown']);
  assert.deepEqual(byName.timer_preset_save.required, ['name', 'rounds']);
  assert.deepEqual(byName.timer_list, { type: 'object', properties: {}, additionalProperties: false });

  const info = mcp.client.getServerVersion();
  assert.deepEqual({ name: info.name, version: info.version }, { name: 'subset-timer', version: manifest.version });
});

test('the read tools return the SET-74 agent result and text', async (t) => {
  const { call, op } = await mcpSession(t, { fixture: true });
  const list = await call('timer_list');
  // The daemon records the AMRAP countdown that ran out as finished when it loads the fixture store.
  assert.deepEqual(list.structuredContent, (await op('list', {})).body);
  assert.equal(list.structuredContent.observedAt, agentResult.structuredContent.observedAt);
  assert.equal(list.content[0].text, agentResult.text);

  const get = await call('timer_get', { id: 't_adygqpxx' });
  const tabata = agentResult.structuredContent.timers.find((snapshot) => snapshot.definition.id === 't_adygqpxx');
  assert.deepEqual(get.structuredContent, { schemaVersion: 1, observedAt: agentResult.structuredContent.observedAt, timers: [tabata] });
  // A running timer's text says when it ends, as a local time and as ISO 8601 with the offset.
  const [line, end] = get.content[0].text.split(' Ends at ');
  assert.equal(line, agentResult.text.split('\n')[0]);
  const [, iso] = /^\d\d:\d\d:\d\d \((.+)\)\.$/.exec(end);
  assert.equal(Date.parse(iso), agentResult.structuredContent.observedAt + tabata.projection.remainingMs);

  // A paused timer has no end time.
  assert.equal((await call('timer_get', { id: 't_dk1facen' })).content[0].text, 'Tea (t_dk1facen): paused · 1:40 left');

  const presets = await call('timer_presets');
  assert.deepEqual(presets.structuredContent.presets.map((preset) => preset.id), [...BUILT_IN_PRESET_IDS, 'p_xja3zjdj']);
  assert.match(presets.content[0].text, /^Tabata \(tabata, built in\): 8 rounds of work 0:20, rest 0:10 · prep 0:10 · 4:10 total$/m);
  assert.match(presets.content[0].text, /^Ladder \(p_xja3zjdj\)/m);
});

test('timer_start creates and starts a timer in each mode', async (t) => {
  const { call, timer, sink, clock } = await mcpSession(t);
  const started = async (args) => {
    const result = await call('timer_start', args);
    assert.equal(result.isError, undefined, JSON.stringify(result));
    const id = result.structuredContent.affectedTimerId;
    assertWrite(result, id);
    const stored = await timer(id);
    assert.equal(stored.runtime.status, 'running');
    assert.ok(result.structuredContent.timers.some((snapshot) => snapshot.definition.id === id));
    return { result, stored };
  };

  const tea = await started({ durationSeconds: 90, name: 'Tea' });
  assert.deepEqual([tea.stored.definition.durationMs, tea.stored.definition.name, tea.stored.definition.sound], [90_000, 'Tea', true]);
  assert.match(tea.result.content[0].text, /^Started Tea \(t_\w{8}\)\. Ends at \d\d:\d\d:\d\d \(.+\)\.\n\nTea \(t_\w{8}\): running · 1:30 left$/);

  const quiet = await started({ stopwatch: true, sound: false });
  assert.deepEqual([quiet.stored.definition.kind, quiet.stored.definition.sound], ['stopwatch', false]);

  // until: a time of day is the next one after the daemon's now; ISO passes through.
  const at = new Date(clock.now() + 2 * 3_600_000);
  const hhmm = `${String(at.getHours()).padStart(2, '0')}:${String(at.getMinutes()).padStart(2, '0')}`;
  const until = await started({ until: hhmm });
  assert.equal(Date.parse(until.stored.definition.until), new Date(at).setSeconds(0, 0));
  const iso = new Date(clock.now() + 600_000).toISOString();
  assert.equal((await started({ until: iso })).stored.definition.until, iso);

  const hiit = await started({ interval: { work: 40, rest: 20, rounds: 10, prep: 10, cooldown: 60 }, name: 'Rows' });
  assert.deepEqual(
    { segments: hiit.stored.definition.segments, rounds: hiit.stored.definition.rounds, prepMs: hiit.stored.definition.prepMs, cooldownMs: hiit.stored.definition.cooldownMs },
    { segments: [{ label: 'Work', phase: 'work', durationMs: 40_000 }, { label: 'Rest', phase: 'rest', durationMs: 20_000 }], rounds: 10, prepMs: 10_000, cooldownMs: 60_000 }
  );
  const ladder = await started({ interval: { segments: [{ phase: 'work', seconds: 30 }, { label: 'Walk', phase: 'rest', seconds: 15 }], rounds: 2 } });
  assert.deepEqual(ladder.stored.definition.segments, [{ label: 'Work', phase: 'work', durationMs: 30_000 }, { label: 'Walk', phase: 'rest', durationMs: 15_000 }]);

  // Presets by id, by name ignoring case and by alias; sound: false sends the preset's timer.
  assert.equal((await started({ preset: 'tabata' })).stored.definition.name, 'Tabata');
  assert.equal((await started({ preset: 'POMODORO', name: 'Focus' })).stored.definition.name, 'Focus');
  assert.equal((await started({ preset: 'hiit' })).stored.definition.rounds, 10);
  const silent = await started({ preset: 'emom', sound: false });
  assert.deepEqual([silent.stored.definition.name, silent.stored.definition.sound, silent.stored.definition.rounds], ['EMOM', false, 10]);

  // The daemon, not the session, owns them: its scheduler finishes them and its sink gets their alerts.
  clock.advance(91_000);
  assert.ok(sink.received.some(({ alert }) => alert.timerId === tea.stored.definition.id && alert.kind === 'finish'));
  assert.equal((await timer(tea.stored.definition.id)).runtime.status, 'finished');
});

test('each write tool changes the daemon state and returns the board with the affected timer', async (t) => {
  const { call, timer } = await mcpSession(t, { fixture: true });

  let board = assertWrite(await call('timer_pause', { id: 't_adygqpxx' }), 't_adygqpxx');
  assert.equal((await timer('t_adygqpxx')).runtime.status, 'paused');
  assert.equal(board.timers.find((snapshot) => snapshot.definition.id === 't_adygqpxx').projection.status, 'paused');

  const resumed = await call('timer_resume', { id: 't_adygqpxx' });
  assertWrite(resumed, 't_adygqpxx');
  assert.match(resumed.content[0].text, /^Resumed Tabata \(t_adygqpxx\)\. Ends at /);
  assert.equal((await timer('t_adygqpxx')).runtime.status, 'running');

  const before = (await timer('t_adygqpxx')).runtime.skippedMs;
  assertWrite(await call('timer_skip', { id: 't_adygqpxx' }), 't_adygqpxx');
  assert.ok((await timer('t_adygqpxx')).runtime.skippedMs > before);

  assertWrite(await call('timer_lap', { id: 't_rcrt44q9' }), 't_rcrt44q9');
  assert.equal((await timer('t_rcrt44q9')).runtime.laps.length, 3);

  assertWrite(await call('timer_reset', { id: 't_dk1facen' }), 't_dk1facen');
  assert.equal((await timer('t_dk1facen')).runtime.status, 'idle');
  assertWrite(await call('timer_reset', { name: 'stretch' }), 't_daesff02');
  assert.equal((await timer('t_daesff02')).runtime.status, 'idle');

  const removed = await call('timer_remove', { name: 'STANDUP' });
  board = assertWrite(removed, 't_v9pdg8p9');
  assert.equal(removed.content[0].text.split('\n')[0], 'Removed Standup (t_v9pdg8p9).');
  assert.ok(!board.timers.some((snapshot) => snapshot.definition.id === 't_v9pdg8p9'));
  assert.equal((await timer('t_v9pdg8p9')), undefined);
  assertWrite(await call('timer_remove', { id: 't_ac50bvkp' }), 't_ac50bvkp');
  assert.equal((await timer('t_ac50bvkp')), undefined);
});

test('the preset tools save and remove presets in the daemon', async (t) => {
  const { call, op } = await mcpSession(t, { fixture: true });
  const saved = await call('timer_preset_save', { name: 'Sprints', work: 30, rest: 90, rounds: 6, prep: 10, sound: false });
  assert.equal(saved.isError, undefined, JSON.stringify(saved));
  const id = saved.structuredContent.affectedPresetId;
  assert.match(saved.content[0].text, new RegExp(`^Saved preset Sprints \\(${id}\\)\\.\\n\\n`));
  let presets = (await op('presets.list', {})).body.presets;
  assert.deepEqual(presets.find((preset) => preset.id === id).timer, {
    kind: 'interval', segments: [{ label: 'Work', phase: 'work', durationMs: 30_000 }, { label: 'Rest', phase: 'rest', durationMs: 90_000 }], rounds: 6, prepMs: 10_000, sound: false
  });
  assert.deepEqual(saved.structuredContent.presets, presets);

  // A saved preset starts by name.
  const started = await call('timer_start', { preset: 'sprints' });
  assert.equal(started.isError, undefined, JSON.stringify(started));

  const removed = await call('timer_preset_remove', { name: 'Sprints' });
  assert.equal(removed.structuredContent.affectedPresetId, id);
  assert.equal(removed.content[0].text.split('\n')[0], `Removed preset ${id}.`);
  presets = (await op('presets.list', {})).body.presets;
  assert.ok(!presets.some((preset) => preset.id === id));
  assert.equal((await call('timer_preset_remove', { id: 'p_xja3zjdj' })).isError, undefined);
});

test('timer_start resolves a preset as the CLI does: id, then a unique name, then an alias', async (t) => {
  const { call, op, timer } = await mcpSession(t);
  const save = async (name) => (await op('presets.save', { name, timer: { kind: 'interval', segments: [{ label: 'Work', phase: 'work', durationMs: 5_000 }], rounds: 1 } })).body.preset.id;
  const startedRounds = async (preset) => {
    const result = await call('timer_start', { preset });
    assert.equal(result.isError, undefined, JSON.stringify(result));
    return (await timer(result.structuredContent.affectedTimerId)).definition.rounds;
  };

  // With no saved preset named hiit, the alias starts the built-in hiit-40-20.
  assert.equal(await startedRounds('hiit'), 10);
  // A saved preset named HIIT is what hiit names; the alias does not shadow it.
  const first = await save('HIIT');
  assert.equal(await startedRounds('hiit'), 1);
  // Two saved presets named hiit are ambiguous, list both and start nothing.
  const second = await save('hiit');
  const count = (await op('list', {})).body.timers.length;
  const error = assertError(await call('timer_start', { preset: 'hiit' }), 'ambiguous');
  assert.deepEqual(error.candidates, [{ id: first, name: 'HIIT' }, { id: second, name: 'hiit' }]);
  assert.equal((await op('list', {})).body.timers.length, count);
  // An exact id still wins.
  assert.equal(await startedRounds('hiit-40-20'), 10);
});

test('invalid inputs return isError with the SET-74 or daemon code and change nothing', async (t) => {
  const { call, op } = await mcpSession(t, { fixture: true });
  const store = async () => (await op('list', {})).body.timers.map((snapshot) => snapshot.runtime);
  const unchanged = await store();

  let error = assertError(await call('timer_start', { durationSeconds: 60, stopwatch: true }), 'invalid_input');
  assert.match(error.message, /exactly one of preset, durationSeconds, until, stopwatch, and interval, not durationSeconds and stopwatch/);
  assertError(await call('timer_start', {}), 'invalid_input');
  assertError(await call('timer_start', { interval: { work: 20, segments: [{ phase: 'work', seconds: 20 }], rounds: 2 } }), 'invalid_input');
  assert.deepEqual(assertError(await call('timer_start', { interval: { rest: 20, rounds: 2 } }), 'invalid_input').issues, [{ path: 'interval', message: 'interval needs exactly one of work and segments.' }]);

  // Schema failures are invalid_input with SET-74 style issue paths.
  error = assertError(await call('timer_start', { durationSeconds: -5 }), 'invalid_input');
  assert.deepEqual(error.issues, [{ path: 'durationSeconds', message: 'must be >= 1' }]);
  assertError(await call('timer_start', { durationSeconds: 86_401 }), 'invalid_input');
  assertError(await call('timer_start', { durationSeconds: 1.5 }), 'invalid_input');
  assertError(await call('timer_start', { stopwatch: false }), 'invalid_input');
  error = assertError(await call('timer_start', { durationSeconds: 60, colour: 'red' }), 'invalid_input');
  assert.deepEqual(error.issues, [{ path: 'colour', message: 'is not a known field' }]);
  error = assertError(await call('timer_start', { interval: { work: 20 } }), 'invalid_input');
  assert.deepEqual(error.issues, [{ path: 'interval.rounds', message: 'is required' }]);
  assertError(await call('timer_start', { until: 'teatime' }), 'invalid_input');
  assertError(await call('timer_start', { until: '2026-10-19T09:00:00' }), 'invalid_input');
  assertError(await call('timer_start', { name: 'Two\nlines', durationSeconds: 60 }), 'invalid_input');
  assertError(await call('timer_pause', { id: 'nope' }), 'invalid_input');
  assertError(await call('timer_pause', {}), 'invalid_input');
  assertError(await call('timer_reset', { id: 't_dk1facen', name: 'Tea' }), 'invalid_input');
  assertError(await call('timer_reset', {}), 'invalid_input');

  // The daemon's own refusals keep their codes.
  assertError(await call('timer_pause', { id: 't_00000000' }), 'not_found');
  assertError(await call('timer_get', { id: 't_00000000' }), 'not_found');
  assertError(await call('timer_remove', { id: 't_00000000' }), 'not_found');
  assertError(await call('timer_reset', { name: 'Nobody' }), 'not_found');
  assertError(await call('timer_start', { preset: 'yoga' }), 'not_found');
  assertError(await call('timer_pause', { id: 't_dk1facen' }), 'invalid_state');
  assertError(await call('timer_resume', { id: 't_adygqpxx' }), 'invalid_state');
  assertError(await call('timer_lap', { id: 't_adygqpxx' }), 'invalid_state');
  assertError(await call('timer_skip', { id: 't_rcrt44q9' }), 'invalid_state');
  assertError(await call('timer_start', { until: new Date(Date.UTC(2026, 9, 21, 9)).toISOString() }), 'invalid_input');
  assertError(await call('timer_preset_remove', { name: 'tabata' }), 'invalid_state');
  assertError(await call('timer_preset_remove', { id: 'p_00000000' }), 'not_found');
  assertError(await call('timer_preset_save', { name: 'Bad', work: 0, rounds: 1 }), 'invalid_input');
  assertError(await call('timer_preset_save', { name: 'Bad', segments: [{ phase: 'jog', seconds: 5 }], rounds: 1 }), 'invalid_input');

  assert.deepEqual(await store(), unchanged);
});

test('a name that matches several timers is ambiguous and lists them', async (t) => {
  const { call } = await mcpSession(t, { fixture: true });
  const second = (await call('timer_start', { durationSeconds: 60, name: 'tea' })).structuredContent.affectedTimerId;
  const error = assertError(await call('timer_remove', { name: 'TEA' }), 'ambiguous');
  assert.deepEqual(error.candidates, [{ id: 't_dk1facen', name: 'Tea' }, { id: second, name: 'tea' }]);
});

test('the limit on timers is limit_reached', async (t) => {
  const { call } = await mcpSession(t);
  for (let index = 0; index < 50; index++) assert.equal((await call('timer_start', { stopwatch: true })).isError, undefined);
  assertError(await call('timer_start', { stopwatch: true }), 'limit_reached');
});

test('a daemon that cannot start is daemon_unavailable, without its paths', async (t) => {
  const dataDir = tempDataDir(t);
  // The spawned "daemon" exits at once, so the socket never appears.
  const client = createClient({ dataDir, cliPath: '/nonexistent/subset-timer.mjs', startTimeoutMs: 300 });
  const logs = [];
  const mcp = await McpFnTestClient.connect(defineTimerMcpServer({ client, log: (line) => logs.push(line) }).createServer());
  t.after(() => mcp.close());
  const result = await mcp.callTool('timer_list', {});
  const error = assertError(result, 'daemon_unavailable');
  assert.doesNotMatch(JSON.stringify(result), new RegExp(dataDir.replaceAll(/[.*+?^${}()|[\]\\]/g, '\\$&')));
  assert.doesNotMatch(error.message, /\//);
  // The detail goes to the server's log (stderr), not to the model.
  assert.ok(logs.some((line) => line.startsWith('daemon unavailable: ')), logs.join('\n'));
});

test('a write whose later read fails says the change was made, so it is not repeated', async (t) => {
  const failRead = (client) => ({ ...client, timers: () => Promise.reject(new DaemonUnavailableError('connect ECONNREFUSED /somewhere/daemon.sock')) });
  const { call, op, logs } = await mcpSession(t, { client: failRead });
  const result = await call('timer_start', { durationSeconds: 60, name: 'Tea' });
  const error = assertError(result, 'daemon_unavailable');
  const [timer] = (await op('list', {})).body.timers;
  assert.equal(error.affectedTimerId, timer.definition.id);
  assert.match(error.message, new RegExp(`^Started Tea \\(${timer.definition.id}\\)\\. Ends at .+ Reading the timers afterwards failed: The Timer daemon could not be reached or started\\.`));
  assert.doesNotMatch(JSON.stringify(result), /somewhere/);
  assert.ok(logs.some((line) => line.includes('/somewhere/daemon.sock')));
});

test('results never carry the data directory or socket path', async (t) => {
  const { call, dataDir } = await mcpSession(t, { fixture: true });
  const results = [
    await call('timer_list'), await call('timer_presets'), await call('timer_get', { id: 't_rcrt44q9' }),
    await call('timer_start', { durationSeconds: 60 }), await call('timer_pause', { id: 't_00000000' })
  ];
  for (const result of results) assert.ok(!JSON.stringify(result).includes(dataDir), JSON.stringify(result));
});
