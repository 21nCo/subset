import assert from 'node:assert/strict';
import { execFile, spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { McpFnTestClient, assertManifestContract, validateMcpFnSchemaPortability } from '@mcpfn/testing';
import { USAGE_PROVIDERS, createUsageStatus, isUsageStatus, usageText } from '@subset.dev/usage-core';
import { claudeIdentityPeriod, defineUsageMcpServer, providerProcesses } from '../src/mcp.mjs';

const hostDirectory = fileURLToPath(new URL('..', import.meta.url));
const manifest = JSON.parse(await readFile(new URL('../package.json', import.meta.url), 'utf8'));
const HOUR = 60 * 60_000;
const NOW = Date.parse('2026-10-28T12:00:00.000Z');

const window = (usedPercent, overrides = {}) => ({
  limitId: 'five_hour', label: '5-hour', kind: 'provider-reported-quota', usedPercent, remainingPercent: 100 - usedPercent,
  remainingKind: 'calculated-estimate', durationMinutes: 300, resetsAt: '2026-10-28T15:00:00.000Z', ...overrides,
});
const account = (id, provider, overrides = {}) => ({
  id, label: id, provider, source: 'Fixture', plan: null, observedAt: '2026-10-28T11:58:00.000Z', state: 'ok',
  windows: [window(25)], resetCredits: null, errors: [], ...overrides,
});
// What the host's status read returns, including the host-internal fields agents never receive.
const fixtureStatus = () => createUsageStatus([
  account('chatgpt_main', 'codex-chatgpt', { email: 'me@example.com', workspaceId: 'ws_private', retryAfterMs: 30_000, alsoIn: ['pi'] }),
  account('claude_work', 'claude-code', { source: 'Claude Code status-line snapshot', observedAt: '2026-10-28T09:00:00.000Z' }),
  account('hermes_claude', 'hermes', { service: 'claude-code', windows: [], state: 'unauthorized', errors: [{ code: 'local_sign_ins_off', message: "Turn on local sign-ins in Settings to read Hermes's stored login." }] }),
  account('amp_cli', 'amp', { state: 'unavailable', windows: [], observedAt: null, errors: [{ code: 'amp_failed', message: 'The amp usage command failed.' }] }),
], new Date(NOW));

async function session(t, options = {}) {
  const logs = [];
  const declaration = defineUsageMcpServer({
    version: manifest.version, now: () => NOW, log: (line) => logs.push(line), providers: ['codex-chatgpt', 'claude-code', 'hermes', 'amp'],
    readStatus: async () => fixtureStatus(), readHistory: async () => ({ schemaVersion: 1, series: {} }), ...options,
  });
  const mcp = await McpFnTestClient.connect(declaration.createServer());
  t.after(() => mcp.close());
  return { mcp, declaration, logs, call: (name, args = {}) => mcp.callTool(name, args) };
}

/** The error's code and message; `usage_history` declares an output schema, so its errors carry them in the text only. */
function assertError(result, code) {
  assert.equal(result.isError, true, JSON.stringify(result));
  const { text } = result.content[0];
  assert.ok(text.startsWith(`${code}: `), text);
  if (!result.structuredContent) return { code, message: text.slice(code.length + 2) };
  assert.equal(result.structuredContent.error.code, code);
  assert.equal(text, `${code}: ${result.structuredContent.error.message}`);
  return result.structuredContent.error;
}

test('tools/list returns the two read-only tools with their schemas, annotations and descriptions', async (t) => {
  const { mcp, declaration } = await session(t);
  const tools = await assertManifestContract(mcp, declaration.manifest(), { expectedToolNames: ['usage_history', 'usage_status'] });
  const byName = Object.fromEntries(tools.map((tool) => [tool.name, tool]));
  for (const tool of tools) {
    assert.equal(tool.inputSchema.type, 'object');
    assert.equal(tool.inputSchema.additionalProperties, false);
    assert.equal(tool.inputSchema.required, undefined, 'every input is optional');
    assert.deepEqual(validateMcpFnSchemaPortability(tool.inputSchema, tool.name), [], tool.name);
    // Both only read, and both report values that came from provider usage endpoints.
    assert.deepEqual(tool.annotations, { readOnlyHint: true, openWorldHint: true }, tool.name);
    assert.match(tool.description, /The data is local/, tool.name);
    // Each description lists the configured providers once each, and says how to read stale and unavailable values.
    assert.match(tool.description, /Providers configured when this server started: ChatGPT \(codex-chatgpt\), Claude \(claude-code\), Hermes \(hermes\), Amp \(amp\)\./, tool.name);
    assert.match(tool.description, /more than 5 minutes|older than 5 minutes/, tool.name);
    assert.match(tool.description, /unavailable[^.]*not zero/, tool.name);
    assert.ok(tool.title, tool.name);
  }
  assert.deepEqual(byName.usage_status.inputSchema.properties.provider.enum, [...USAGE_PROVIDERS]);
  assert.deepEqual(Object.keys(byName.usage_status.inputSchema.properties), ['provider']);
  const { hours, accountId } = byName.usage_history.inputSchema.properties;
  assert.deepEqual([hours.type, hours.minimum, hours.maximum], ['integer', 1, 168]);
  assert.equal(accountId.pattern, '^[a-zA-Z0-9_-]{1,64}$');
  assert.match(byName.usage_status.description, /older than 5 minutes is stale/);
  // The filter applies to the result; it does not make the call faster.
  assert.match(byName.usage_status.description, /only that provider's accounts; every account is still read/);
  assert.match(byName.usage_status.description, /null percentage or reset time is unavailable, not zero/);
  assert.match(byName.usage_history.description, /only while it is open/);
  // usage_status returns the UsageStatus contract (isUsageStatus); usage_history declares its envelope.
  assert.equal(byName.usage_status.outputSchema, undefined);
  const output = byName.usage_history.outputSchema;
  assert.deepEqual(validateMcpFnSchemaPortability(output, 'usage_history output'), []);
  assert.deepEqual([output.type, output.required, output.additionalProperties], ['object', ['schemaVersion', 'from', 'to', 'series'], false]);
  assert.deepEqual(output.properties.schemaVersion, { const: 1 });
  assert.deepEqual([output.properties.from.format, output.properties.to.format], ['date-time', 'date-time']);
  const point = output.properties.series.additionalProperties.additionalProperties.items;
  assert.deepEqual([point.type, point.items, point.minItems, point.maxItems], ['array', { type: 'number' }, 2, 2]);
  assert.deepEqual(mcp.client.getServerVersion(), { name: 'subset-usage', version: manifest.version });
});

test('the status description says when no accounts were configured, or the configuration could not be read', async (t) => {
  const none = (await (await session(t, { providers: [] })).mcp.listTools()).find((tool) => tool.name === 'usage_status');
  assert.match(none.description, /No accounts were configured when this server started\. Claude Code's default sign-in on this computer appears too/);
  const broken = (await (await session(t, { providers: null })).mcp.listTools()).find((tool) => tool.name === 'usage_status');
  assert.match(broken.description, /could not be read when this server started; usage_status reports why/);
});

test('usage_status returns the agent result: valid UsageStatus without host-internal fields, and the usageText fallback', async (t) => {
  const { call } = await session(t);
  const result = await call('usage_status');
  assert.equal(result.isError, undefined, JSON.stringify(result));
  const status = result.structuredContent;
  assert.ok(isUsageStatus(status));
  assert.deepEqual(status.accounts.map((item) => item.id), ['chatgpt_main', 'claude_work', 'hermes_claude', 'amp_cli']);
  assert.doesNotMatch(JSON.stringify(status), /workspaceId|ws_private|retryAfterMs/);
  // Email stays in the structured result and out of the text.
  assert.equal(status.accounts[0].email, 'me@example.com');
  assert.deepEqual(result.content, [{ type: 'text', text: usageText(status) }]);
  assert.doesNotMatch(result.content[0].text, /me@example\.com/);
  // A provider's failure is that account's errors[], not a tool error.
  assert.equal(status.accounts[3].errors[0].code, 'amp_failed');
  assert.match(result.content[0].text, /amp_failed: The amp usage command failed\./);
});

test('usage_status filters to one provider: its own accounts, logins for its subscription, and cards it is also signed in to', async (t) => {
  const { call } = await session(t);
  const ids = async (provider) => (await call('usage_status', { provider })).structuredContent.accounts.map((item) => item.id);
  assert.deepEqual(await ids('claude-code'), ['claude_work', 'hermes_claude']);
  assert.deepEqual(await ids('hermes'), ['hermes_claude']);
  assert.deepEqual(await ids('pi'), ['chatgpt_main']);
  assert.deepEqual(await ids('amp'), ['amp_cli']);
  // Every filtered result is valid and its text is usageText of exactly those accounts, also when
  // the provider has none.
  for (const provider of USAGE_PROVIDERS) {
    const filtered = await call('usage_status', { provider });
    assert.ok(isUsageStatus(filtered.structuredContent), provider);
    assert.deepEqual(filtered.content, [{ type: 'text', text: usageText(filtered.structuredContent) }], provider);
  }
  const none = await call('usage_status', { provider: 'cursor' });
  assert.deepEqual(none.structuredContent.accounts, []);
  assert.equal(none.content[0].text, usageText(createUsageStatus([], new Date(NOW))));
});

test('invalid input is an invalid_input tool error; a failed configuration read is usage_unavailable', async (t) => {
  const reads = [];
  const { call, logs } = await session(t, { readStatus: async () => { reads.push('status'); return fixtureStatus(); }, readHistory: async () => { reads.push('history'); return { schemaVersion: 1, series: {} }; } });
  assert.match(assertError(await call('usage_status', { provider: 'chatgpt' }), 'invalid_input').issues[0].path, /^provider$/);
  assert.deepEqual(assertError(await call('usage_status', { provider: 'amp', extra: true }), 'invalid_input').issues, [{ path: 'extra', message: 'is not a known field' }]);
  for (const hours of [0, 169, 1.5, '48']) assert.match(assertError(await call('usage_history', { hours }), 'invalid_input').message, /^hours: /, String(hours));
  assert.match(assertError(await call('usage_history', { accountId: '../other' }), 'invalid_input').message, /^accountId: /);
  // Rejected before any read.
  assert.deepEqual(reads, []);

  const failing = await session(t, { readStatus: async () => { throw new Error('Could not read usage profiles configuration.'); }, readHistory: async () => { throw new Error('EACCES /private/path'); } });
  const error = assertError(await failing.call('usage_status'), 'usage_unavailable');
  assert.match(error.message, /^Could not read the usage configuration\./);
  const historyError = assertError(await failing.call('usage_history'), 'usage_unavailable');
  assert.match(historyError.message, /^Could not read the stored usage history\./);
  assert.doesNotMatch(historyError.message, /private/);
  assert.equal(failing.logs.length, 2);
  assert.equal(logs.length, 0);
});

test('usage_history returns the stored points in range, time and percentages only', async (t) => {
  const key = (limitId, label) => `${limitId}\u0000${label}`;
  const history = { schemaVersion: 1, series: {
    chatgpt_main: {
      [key('five_hour', '5-hour')]: [[NOW - 169 * HOUR, 1], [NOW - 49 * HOUR, 5], [NOW - 48 * HOUR, 10], [NOW - 90 * 60_000, 20], [NOW - HOUR, 30], [NOW - 30 * 60_000, 40], [NOW, 50], [NOW + 60_000, 60]],
      [key('weekly', 'Weekly')]: [[NOW - 100 * HOUR, 70]],
    },
    claude_work: { [key('seven_day', '7-day')]: [[NOW - 2 * HOUR, 12.5]] },
    // An ordinary account ID, never the object prototype.
    ['__proto__']: { [key('five_hour', '5-hour')]: [[NOW - HOUR, 3]] },
  } };
  const { call, mcp } = await session(t, { readHistory: async () => JSON.parse(JSON.stringify(history)) });
  // With the tool list loaded, the MCP client validates every result against the declared output schema.
  await mcp.listTools();
  const read = async (args) => {
    const result = await call('usage_history', args);
    assert.equal(result.isError, undefined, JSON.stringify(result));
    return result;
  };

  // Default: the last 48 hours, both ends included; older and future points are left out, and so are windows with none in range.
  const standard = await read({});
  assert.deepEqual(standard.structuredContent, {
    schemaVersion: 1, from: new Date(NOW - 48 * HOUR).toISOString(), to: new Date(NOW).toISOString(),
    series: {
      chatgpt_main: { [key('five_hour', '5-hour')]: [[NOW - 48 * HOUR, 10], [NOW - 90 * 60_000, 20], [NOW - HOUR, 30], [NOW - 30 * 60_000, 40], [NOW, 50]] },
      claude_work: { [key('seven_day', '7-day')]: [[NOW - 2 * HOUR, 12.5]] },
      ['__proto__']: { [key('five_hour', '5-hour')]: [[NOW - HOUR, 3]] },
    },
  });
  assert.equal(Object.getPrototypeOf(standard.structuredContent.series), Object.prototype);
  assert.match(standard.content[0].text, /^Used percentage history in the last 48 hours/);
  assert.match(standard.content[0].text, /^chatgpt_main 5-hour: 5 points; used 10% at 2026-10-26T12:00:00\.000Z, 50% at 2026-10-28T12:00:00\.000Z \(lowest 10%, highest 50%\)$/m);
  assert.doesNotMatch(standard.content[0].text, /\u0000/);

  const lastHour = await read({ hours: 1 });
  assert.equal(lastHour.structuredContent.from, new Date(NOW - HOUR).toISOString());
  assert.deepEqual(lastHour.structuredContent.series.chatgpt_main, { [key('five_hour', '5-hour')]: [[NOW - HOUR, 30], [NOW - 30 * 60_000, 40], [NOW, 50]] });
  assert.equal(lastHour.structuredContent.series.claude_work, undefined);

  const week = await read({ hours: 168, accountId: 'chatgpt_main' });
  assert.deepEqual(Object.keys(week.structuredContent.series), ['chatgpt_main']);
  assert.deepEqual(week.structuredContent.series.chatgpt_main[key('weekly', 'Weekly')], [[NOW - 100 * HOUR, 70]]);
  assert.equal(week.structuredContent.series.chatgpt_main[key('five_hour', '5-hour')][0][0], NOW - 49 * HOUR);

  // The declared schema is enforced: a point that is not [time, percent] is never returned.
  const malformed = await session(t, { readHistory: async () => ({ schemaVersion: 1, series: { claude_work: { [key('five_hour', '5-hour')]: [[NOW, '10']] } } }) });
  const rejected = await malformed.call('usage_history');
  assert.equal(rejected.isError, true);
  assert.doesNotMatch(JSON.stringify(rejected), /"10"/);

  // Points stored out of order come back oldest first, and the text's first and last are by time;
  // the stored history is not changed.
  const unsorted = { schemaVersion: 1, series: { claude_work: { [key('five_hour', '5-hour')]: [[NOW - HOUR, 80], [NOW - 49 * HOUR, 1], [NOW - 48 * HOUR, 20], [NOW, 60], [NOW - 2 * HOUR, 40]] } } };
  const stored = JSON.stringify(unsorted);
  const shuffled = await session(t, { readHistory: async () => unsorted });
  await shuffled.mcp.listTools();
  const ordered = await shuffled.call('usage_history');
  assert.deepEqual(ordered.structuredContent.series.claude_work[key('five_hour', '5-hour')], [[NOW - 48 * HOUR, 20], [NOW - 2 * HOUR, 40], [NOW - HOUR, 80], [NOW, 60]]);
  assert.match(ordered.content[0].text, /^claude_work 5-hour: 4 points; used 20% at 2026-10-26T12:00:00\.000Z, 60% at 2026-10-28T12:00:00\.000Z \(lowest 20%, highest 80%\)$/m);
  assert.equal(JSON.stringify(unsorted), stored);

  const unknown = await read({ accountId: 'missing' });
  assert.deepEqual(unknown.structuredContent.series, {});
  assert.match(unknown.content[0].text, /^No usage history for account missing in the last 48 hours\. History is recorded only while the subset-usage dashboard is open/);
});

/** Every entry under `root` with its type, size and modification time. */
async function tree(root) {
  const entries = [];
  for (const name of (await readdir(root, { recursive: true })).sort()) {
    const info = await stat(join(root, name));
    entries.push([name, info.isDirectory() ? 'dir' : 'file', info.size, info.mtimeMs]);
  }
  return entries;
}

/** `subset-usage mcp` as a child process speaking newline-delimited JSON-RPC on its stdin and stdout. */
function startMcp(env, entry = 'src/server.mjs') {
  const child = spawn(process.execPath, [entry, 'mcp'], { cwd: hostDirectory, env, stdio: ['pipe', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  const frames = [];
  const waiting = new Map();
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    let end;
    while ((end = stdout.indexOf('\n')) >= 0) {
      const line = stdout.slice(0, end);
      stdout = stdout.slice(end + 1);
      // Every line on stdout must be a protocol frame; anything else fails here.
      const frame = JSON.parse(line);
      frames.push(frame);
      waiting.get(frame.id)?.(frame);
    }
  });
  child.stderr.setEncoding('utf8');
  child.stderr.on('data', (chunk) => { stderr += chunk; });
  const exited = once(child, 'exit');
  let nextId = 0;
  const send = (frame) => child.stdin.write(`${JSON.stringify({ jsonrpc: '2.0', ...frame })}\n`);
  const request = (method, params) => {
    const id = ++nextId;
    const reply = new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(`No reply to ${method}. ${stderr}`)), 15_000);
      waiting.set(id, (frame) => { clearTimeout(timer); resolve(frame); });
    });
    send({ id, method, params });
    return reply;
  };
  return { child, frames, exited, send, request, rest: () => stdout, stderr: () => stderr };
}

test('subset-usage mcp serves on stdio, writes nothing, keeps stdout to protocol frames, and exits 0 when stdin closes', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-mcp-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const bin = join(root, 'bin');
  const config = join(root, 'config');
  const data = join(root, 'data');
  const defaultClaude = join(root, 'default-claude');
  const workClaude = join(root, 'work-claude');
  for (const directory of [bin, config, data, defaultClaude, workClaude]) await mkdir(directory);
  // Every Claude config directory is signed in with an email: a writing read would adopt the default
  // account into the profiles and record each identity in claude-identities.json.
  await writeFile(join(bin, 'claude'), `#!/bin/sh
printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"person@example.com"}'
`, { mode: 0o700 });
  const profilesFile = join(config, 'profiles.json');
  await writeFile(profilesFile, JSON.stringify([
    { id: 'claude_work', label: 'Work', provider: 'claude-code', managed: false, snapshotFile: join(data, 'usage-snapshots', 'claude_work.json'), claudeConfigDir: workClaude },
    { id: 'gemini', label: 'Gemini', provider: 'antigravity', managed: false, snapshotFile: join(data, 'usage-snapshots', 'gemini.json') },
  ]));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, SUBSET_USAGE_PROFILES_FILE: profilesFile, SUBSET_USAGE_DATA_DIR: data, CLAUDE_CONFIG_DIR: defaultClaude };
  const collect = (id, payload, extra = {}) => {
    const result = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', id], { cwd: hostDirectory, env: { ...env, ...extra }, input: JSON.stringify(payload), encoding: 'utf8', timeout: 10_000 });
    assert.equal(result.status, 0, result.stderr);
  };
  collect('claude_work', { rate_limits: { five_hour: { used_percentage: 10, resets_at: 1900000000 } } }, { CLAUDE_CONFIG_DIR: workClaude });
  collect('gemini', { quota: { gemini: { remaining_fraction: 0.4, reset_time: '2027-01-01T00:00:00Z' } } });
  const now = Date.now();
  const key = 'five_hour\u00005-hour';
  await writeFile(join(data, 'usage-history.json'), JSON.stringify({ schemaVersion: 1, series: {
    claude_work: { [key]: [[now - 50 * HOUR, 5], [now - 3 * HOUR, 8], [now - 30 * 60_000, 10]] },
  } }));
  const before = await tree(root);

  const mcp = startMcp(env);
  t.after(() => mcp.child.kill());
  const init = await mcp.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } });
  assert.deepEqual(init.result.serverInfo, { name: 'subset-usage', version: manifest.version });
  mcp.send({ method: 'notifications/initialized' });
  const listed = await mcp.request('tools/list', {});
  assert.deepEqual(listed.result.tools.map((tool) => tool.name).sort(), ['usage_history', 'usage_status']);
  assert.match(listed.result.tools.find((tool) => tool.name === 'usage_status').description, /Claude \(claude-code\), Antigravity \(antigravity\)\./);

  const status = (await mcp.request('tools/call', { name: 'usage_status', arguments: {} })).result;
  assert.equal(status.isError, undefined, JSON.stringify(status));
  assert.ok(isUsageStatus(status.structuredContent));
  // The signed-in default Claude account is shown, as `status` does, without being saved.
  assert.deepEqual(status.structuredContent.accounts.map((item) => [item.id, item.windows.map((entry) => entry.remainingPercent)]), [['claude_work', [90]], ['gemini', [40]], ['claude_default', []]]);
  assert.equal(status.content[0].text, usageText(status.structuredContent, new Date(status.structuredContent.generatedAt)));
  const filtered = (await mcp.request('tools/call', { name: 'usage_status', arguments: { provider: 'antigravity' } })).result;
  assert.deepEqual(filtered.structuredContent.accounts.map((item) => item.id), ['gemini']);
  const history = (await mcp.request('tools/call', { name: 'usage_history', arguments: { hours: 4 } })).result;
  assert.deepEqual(history.structuredContent.series, { claude_work: { [key]: [[now - 3 * HOUR, 8], [now - 30 * 60_000, 10]] } });
  const invalid = (await mcp.request('tools/call', { name: 'usage_history', arguments: { hours: 500 } })).result;
  assert.match(assertError(invalid, 'invalid_input').message, /^hours: /);

  // Calls sent right before stdin closes are still answered.
  const lastStatus = mcp.request('tools/call', { name: 'usage_status', arguments: {} });
  const lastHistory = mcp.request('tools/call', { name: 'usage_history', arguments: {} });
  mcp.child.stdin.end();
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
  assert.ok(isUsageStatus((await lastStatus).result.structuredContent));
  assert.equal((await lastHistory).result.structuredContent.series.claude_work[key].length, 2);
  // stdout held only complete JSON-RPC replies; the log line went to stderr.
  assert.equal(mcp.rest(), '');
  assert.deepEqual(mcp.frames.map((frame) => [frame.jsonrpc, frame.id, 'result' in frame]).sort((a, b) => a[1] - b[1]), [1, 2, 3, 4, 5, 6, 7, 8].map((id) => ['2.0', id, true]));
  assert.match(mcp.stderr(), new RegExp(`^subset-usage mcp: ${manifest.version.replaceAll('.', '\\.')} serving on stdio$`, 'm'));
  // No file or directory was added, removed or modified: no profile, identity, preference or history write.
  assert.deepEqual(await tree(root), before);
});

test('the built dist/cli.mjs mcp loads the bundled MCP server, answers, and exits 0 when stdin closes', async (t) => {
  const built = await Promise.all(['cli.mjs', 'mcp-server.mjs'].map((name) => stat(join(hostDirectory, 'dist', name)).then(() => true, () => false)));
  assert.deepEqual(built, [true, true], 'dist/ is missing: run npm run build first');
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-mcp-dist-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const [config, data, claude] = ['config', 'data', 'claude'].map((name) => join(root, name));
  for (const directory of [config, data]) await mkdir(directory);
  const profilesFile = join(config, 'profiles.json');
  await writeFile(profilesFile, '[]');
  // No Claude config directory, so no default Claude account is read.
  const before = await tree(root);
  const mcp = startMcp({ ...process.env, SUBSET_USAGE_PROFILES_FILE: profilesFile, SUBSET_USAGE_DATA_DIR: data, CLAUDE_CONFIG_DIR: claude }, 'dist/cli.mjs');
  t.after(() => mcp.child.kill());
  const init = await mcp.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } });
  assert.deepEqual(init.result.serverInfo, { name: 'subset-usage', version: manifest.version });
  mcp.send({ method: 'notifications/initialized' });
  assert.deepEqual((await mcp.request('tools/list', {})).result.tools.map((tool) => tool.name).sort(), ['usage_history', 'usage_status']);
  const status = (await mcp.request('tools/call', { name: 'usage_status', arguments: {} })).result;
  assert.ok(isUsageStatus(status.structuredContent), JSON.stringify(status));
  assert.deepEqual(status.structuredContent.accounts, []);
  assert.equal(status.content[0].text, usageText(status.structuredContent, new Date(status.structuredContent.generatedAt)));
  mcp.child.stdin.end();
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null }, mcp.stderr());
  assert.equal(mcp.rest(), '');
  assert.deepEqual(mcp.frames.map((frame) => [frame.id, 'result' in frame]), [[1, true], [2, true], [3, true]]);
  assert.deepEqual(await tree(root), before);
});

/**
 * `subset-usage mcp` with one account, Amp, and a `usage_status` call (id 3) waiting on it. `amp` is
 * the given shell script body; it writes the PIDs it wants checked to `$PIDS` as one line. When
 * `claude` is given, the default Claude config directory exists and `claude` runs that body, so the
 * read checks its sign-in before it reads Amp. Returns once the script that must stall first wrote its PIDs.
 */
async function stalledRead(t, { amp, claude }) {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-mcp-stall-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const [bin, config, data, defaultClaude] = ['bin', 'config', 'data', 'claude'].map((name) => join(root, name));
  for (const directory of [bin, config, data, ...(claude ? [defaultClaude] : [])]) await mkdir(directory);
  const pidFiles = { amp: join(root, 'amp.pids'), claude: join(root, 'claude.pids') };
  for (const [name, body] of Object.entries({ amp, claude })) {
    if (body) await writeFile(join(bin, name), `#!/bin/sh\nPIDS='${pidFiles[name]}'\n${body}\n`, { mode: 0o700 });
  }
  const profilesFile = join(config, 'profiles.json');
  await writeFile(profilesFile, JSON.stringify([{ id: 'amp_cli', label: 'Amp', provider: 'amp' }]));
  const mcp = startMcp({ ...process.env, PATH: `${bin}:${process.env.PATH}`, SUBSET_USAGE_PROFILES_FILE: profilesFile, SUBSET_USAGE_DATA_DIR: data, CLAUDE_CONFIG_DIR: defaultClaude });
  const pids = async (name) => readFile(pidFiles[name], 'utf8').then((text) => text.trim().split(' ').map(Number).filter((pid) => pid > 0), () => []);
  t.after(async () => {
    mcp.child.kill('SIGKILL');
    for (const pid of [...await pids('amp'), ...await pids('claude')]) try { process.kill(pid, 'SIGKILL'); } catch { /* already gone */ }
  });
  await mcp.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } });
  mcp.send({ method: 'notifications/initialized' });
  mcp.send({ id: 3, method: 'tools/call', params: { name: 'usage_status', arguments: {} } });
  const first = claude ? 'claude' : 'amp';
  for (let tries = 0; !(await pids(first)).length; tries += 1) {
    assert.ok(tries < 500, `${first} never started. ${mcp.stderr()}`);
    await new Promise((resolveWait) => setTimeout(resolveWait, 20));
  }
  return { mcp, pids };
}

// Writes the PIDs atomically, so the test never reads half a line.
const recordPids = (pids) => `echo ${pids} > "$PIDS.tmp" && mv "$PIDS.tmp" "$PIDS"`;
// A launcher, as a shell or Node entrypoint such as codex.js is: it starts the provider as its own
// child, forwards SIGTERM and SIGINT to it, and waits. SIGKILL would end only the launcher. It reaps
// the provider before it exits: where PID 1 does not reap, an orphan zombie still has its PID.
const launcher = `sleep 120 &
child=$!
trap 'kill $child; wait $child; exit 143' TERM INT
${recordPids('"$$ $child"')}
wait $child`;
// A provider that ignores SIGTERM; exec keeps both the PID and the ignored signal.
const ignoresTerm = `trap '' TERM
${recordPids('$$')}
exec sleep 120`;

/** Whether the operating system still has a process with this PID. */
function processExists(pid) {
  try { process.kill(pid, 0); return true; } catch (error) { return error.code !== 'ESRCH'; }
}

/** The waiting call (id 3) was answered with Amp's error, and stdout held only protocol frames. */
function assertAmpFailed(mcp) {
  assert.equal(mcp.rest(), '');
  const reply = mcp.frames.find((frame) => frame.id === 3);
  assert.ok(reply, `the waiting call was not answered. ${mcp.stderr()}`);
  assert.ok(isUsageStatus(reply.result.structuredContent));
  assert.deepEqual(reply.result.structuredContent.accounts.map((item) => [item.id, item.errors.map((error) => error.code)]), [['amp_cli', ['amp_failed']]]);
  assert.deepEqual(mcp.frames.map((frame) => frame.id), [1, 3]);
}

test('the server stops tracking a provider subprocess that failed to start', async () => {
  const processes = providerProcesses(() => {});
  // A provider CLI that is not installed: its subprocess emits error and close, never exit.
  const missing = join(tmpdir(), 'subset-usage-no-such-provider');
  for (let read = 0; read < 3; read += 1) {
    const child = execFile(missing, [], () => {});
    assert.equal(processes.tracked, 1);
    await new Promise((resolveClose) => child.once('close', resolveClose));
    assert.equal(processes.tracked, 0, `read ${read + 1} left its failed subprocess tracked`);
  }
});

test('subset-usage mcp ends a stalled provider and the process its launcher started, answers the call, and exits 0 when stdin closes', async (t) => {
  const { mcp, pids } = await stalledRead(t, { amp: launcher });
  const started = await pids('amp');
  assert.equal(started.length, 2);
  assert.ok(started.every(processExists));
  mcp.child.stdin.end();
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null }, mcp.stderr());
  for (const pid of started) assert.equal(processExists(pid), false, `PID ${pid} outlived the server`);
  assertAmpFailed(mcp);
  assert.match(mcp.stderr(), /stdin closed; ending the provider reads still running after 10 s/);
});

test('subset-usage mcp ends a stalled provider and the process its launcher started, and exits 0 on SIGTERM', async (t) => {
  const { mcp, pids } = await stalledRead(t, { amp: launcher });
  const started = await pids('amp');
  const signalled = Date.now();
  mcp.child.kill('SIGTERM');
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null }, mcp.stderr());
  assert.ok(Date.now() - signalled < 4_000, `stopping took ${Date.now() - signalled} ms`);
  for (const pid of started) assert.equal(processExists(pid), false, `PID ${pid} outlived the server`);
  assertAmpFailed(mcp);
});

test('subset-usage mcp ends a provider that ignores SIGTERM with SIGKILL after a grace period on SIGTERM', async (t) => {
  const { mcp, pids } = await stalledRead(t, { amp: ignoresTerm });
  const [pid] = await pids('amp');
  const signalled = Date.now();
  mcp.child.kill('SIGTERM');
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null }, mcp.stderr());
  const took = Date.now() - signalled;
  assert.ok(took >= 900 && took < 4_000, `stopping took ${took} ms`);
  assert.equal(processExists(pid), false, `amp (PID ${pid}) outlived the server`);
  assertAmpFailed(mcp);
});

test('subset-usage mcp ends a provider a read starts after SIGTERM ended its sign-in check, and exits 0', async (t) => {
  // The read waits on the default Claude sign-in check; when that ends, it goes on to read Amp.
  const { mcp, pids } = await stalledRead(t, { claude: `${recordPids('$$')}\nexec sleep 120`, amp: `${recordPids('$$')}\nexec sleep 120` });
  const [claude] = await pids('claude');
  mcp.child.kill('SIGTERM');
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null }, mcp.stderr());
  assert.equal(processExists(claude), false, `claude (PID ${claude}) outlived the server`);
  // Amp started after the server began stopping, and was ended; if it got to record its PID, that process is gone.
  assert.match(mcp.stderr(), /stopping; ending amp, which a read started meanwhile/);
  for (const pid of await pids('amp')) assert.equal(processExists(pid), false, `amp (PID ${pid}) outlived the server`);
  assertAmpFailed(mcp);
});

/**
 * A data directory with one Claude account, `claude_work`, whose sign-in email the `claude` shim
 * takes from the config directory's name (`a@example.com` in `.../a`). The auth answer is cached
 * per directory for a minute, so a test signs the account in as someone else by pointing it at
 * another directory, which is the same sign-in change to the identity check. The sign-in check of a
 * directory named `slow<name>` answers `<name>@example.com`, but first creates `started` in the gate
 * directory and waits until the test creates `open` there.
 */
async function claudeFixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-mcp-identity-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const [bin, config, data, gate] = ['bin', 'config', 'data', 'gate'].map((name) => join(root, name));
  for (const directory of [bin, config, data, gate, ...['a', 'b', 'slowa', 'slowb', 'default'].map((name) => join(root, name))]) await mkdir(directory);
  await writeFile(join(bin, 'claude'), `#!/bin/sh
name="$(basename "$CLAUDE_CONFIG_DIR")"
case "$name" in slow*)
  : > "$SUBSET_TEST_GATE/started"
  while [ ! -e "$SUBSET_TEST_GATE/open" ]; do sleep 0.02; done
  name="\${name#slow}";;
esac
printf '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"%s@example.com"}\n' "$name"
`, { mode: 0o700 });
  const profilesFile = join(config, 'profiles.json');
  const signIn = (name) => writeFile(profilesFile, JSON.stringify([
    { id: 'claude_work', label: 'Work', provider: 'claude-code', managed: false, snapshotFile: join(data, 'usage-snapshots', 'claude_work.json'), claudeConfigDir: join(root, name) },
  ]));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, SUBSET_USAGE_PROFILES_FILE: profilesFile, SUBSET_USAGE_DATA_DIR: data, CLAUDE_CONFIG_DIR: join(root, 'default'), SUBSET_TEST_GATE: gate };
  const collect = (name, usedPercentage) => {
    const result = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', 'claude_work'], {
      cwd: hostDirectory, env: { ...env, CLAUDE_CONFIG_DIR: join(root, name) }, encoding: 'utf8', timeout: 10_000,
      input: JSON.stringify({ rate_limits: { five_hour: { used_percentage: usedPercentage, resets_at: 1900000000 } } }),
    });
    assert.equal(result.status, 0, result.stderr);
  };
  /** Resolves once a slow sign-in check is waiting; observed on the file system, not timed. */
  const gateStarted = async () => {
    for (let tries = 0; !(await readdir(gate)).includes('started'); tries += 1) {
      assert.ok(tries < 500, 'no sign-in check reached the gate');
      await new Promise((resolveWait) => setTimeout(resolveWait, 20));
    }
  };
  const openGate = () => writeFile(join(gate, 'open'), '');
  const start = async () => {
    const mcp = startMcp(env);
    t.after(() => mcp.child.kill());
    await mcp.request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'test', version: '1.0.0' } });
    mcp.send({ method: 'notifications/initialized' });
    const call = async (name) => (await mcp.request('tools/call', { name, arguments: name === 'usage_status' ? { provider: 'claude-code' } : {} })).result;
    const work = async () => {
      const result = await call('usage_status');
      assert.ok(isUsageStatus(result.structuredContent));
      const account = result.structuredContent.accounts.find((item) => item.id === 'claude_work');
      return { email: account.email, state: account.state, remaining: account.windows.map((entry) => entry.remainingPercent), errors: account.errors.map((error) => error.code) };
    };
    const stop = async () => {
      mcp.child.stdin.end();
      const [code] = await mcp.exited;
      assert.equal(code, 0, mcp.stderr());
    };
    return { call, work, stop, stderr: mcp.stderr };
  };
  return { root, data, profilesFile, signIn, collect, gateStarted, openGate, start };
}

const hidden = (email) => ({ email, state: 'unavailable', remaining: [], errors: ['claude_identity_changed'] });
const shown = (email, remaining) => ({ email, state: 'ok', remaining: [remaining], errors: [] });
const awaiting = (email) => ({ email, state: 'unavailable', remaining: [], errors: ['claude_awaiting_snapshot'] });

/** Apart from what the test itself wrote (`written`), nothing under the fixture changed. */
async function assertOnlyTestWrites(root, before, written) {
  const after = new Map((await tree(root)).map(([name, ...rest]) => [name, rest]));
  for (const [name, ...rest] of before) if (!written.test(name)) assert.deepEqual(after.get(name), rest, name);
  assert.deepEqual([...after.keys()].filter((name) => !written.test(name) && !before.some(([known]) => known === name)), []);
}
// The test signs in by rewriting the profiles, the collector writes the snapshot and its run record,
// and the gate holds the slow sign-in's signals. A first snapshot also adds its directories to data/.
const testWrites = /^(config|data\/(usage-snapshots|collector-runs)|gate)(\/|$)|^data$/;

test('the session identity rule: periods only move forward, and an out-of-date sign-in answer changes nothing', () => {
  const period = (email, since, observedAt) => ({ email, since, observedAt });
  const answer = (email, observedAt) => ({ email, observedAt });
  const rule = (kept, stored, given, now = 1000) => claudeIdentityPeriod(kept, stored, given, now);
  // A first sighting adopts the snapshots already collected; a recorded period applies as recorded.
  assert.deepEqual(rule(undefined, undefined, answer('a', 10)), { period: period('a', 0, 10), current: true });
  assert.deepEqual(rule(undefined, { email: 'a', since: 0 }, answer('a', 10)), { period: period('a', 0, 10), current: true });
  // A newer answer for another email starts a period when the session observes it.
  assert.deepEqual(rule(undefined, { email: 'a', since: 0 }, answer('b', 10)), { period: period('b', 1000, 10), current: true });
  assert.deepEqual(rule(period('a', 0, 10), undefined, answer('b', 20)), { period: period('b', 1000, 20), current: true });
  // The same email keeps the period, and its latest observation, whatever order answers arrive in.
  assert.deepEqual(rule(period('b', 500, 20), undefined, answer('b', 30)), { period: period('b', 500, 30), current: true });
  assert.deepEqual(rule(period('b', 500, 30), undefined, answer('b', 20)), { period: period('b', 500, 30), current: true });
  // An older answer for another email is out of date: it starts no period. Queried before the period
  // started it changes nothing; queried after, the account was signed in elsewhere in between, so the
  // period restarts at the latest observation of its email.
  assert.deepEqual(rule(period('b', 500, 600), undefined, answer('a', 400)), { period: period('b', 500, 600), current: false });
  assert.deepEqual(rule(period('b', 0, 20), undefined, answer('a', 10)), { period: period('b', 20, 20), current: false });
  // A later period the dashboard recorded applies: the same email signed in again, or another email
  // after the session's latest observation.
  assert.deepEqual(rule(period('b', 500, 520), { email: 'b', since: 700 }, answer('b', 520)), { period: period('b', 700, 700), current: true });
  assert.deepEqual(rule(period('a', 0, 520), { email: 'a', since: 700 }, answer('a', 520)), { period: period('a', 700, 700), current: true });
  assert.deepEqual(rule(period('b', 500, 520), { email: 'a', since: 700 }, answer('a', 520)), { period: period('a', 700, 700), current: true });
  // A recorded change to another email that the session's own later observation contradicts: its
  // email signed in again, so its period restarts there.
  assert.deepEqual(rule(period('b', 500, 900), { email: 'a', since: 700 }, answer('b', 900)), { period: period('b', 900, 900), current: true });
  // Recorded periods no later than the session's are ignored, so the session never moves back.
  assert.deepEqual(rule(period('b', 700, 720), { email: 'a', since: 700 }, answer('b', 720)), { period: period('b', 700, 720), current: true });
  assert.deepEqual(rule(period('b', 700, 720), { email: 'a', since: 0 }, answer('b', 720)), { period: period('b', 700, 720), current: true });
  assert.deepEqual(rule(period('b', 700, 720), undefined, answer('b', 720)), { period: period('b', 700, 720), current: true });
  // A record that cannot be read (null) or is malformed is unknown: a held period stays and the
  // answer applies to it as usual, but a session without one shows nothing and starts no period.
  for (const stored of [null, 'b', { email: 'a' }, { email: 'a', since: 'later' }, { email: 'a', since: '700' }, { since: 900 }]) {
    assert.deepEqual(rule(period('b', 700, 720), stored, answer('b', 720)), { period: period('b', 700, 720), current: true }, JSON.stringify(stored));
    assert.deepEqual(rule(period('b', 700, 720), stored, answer('a', 800)), { period: period('a', 1000, 800), current: true }, JSON.stringify(stored));
    assert.deepEqual(rule(undefined, stored, answer('a', 10)), { period: undefined, current: false }, JSON.stringify(stored));
  }
  // A recorded start later than now is no evidence: it is handled as if there were no record, so it
  // neither hides the snapshots of a sign-in that matches nor makes a newer sign-in change look out of date.
  assert.deepEqual(rule(undefined, { email: 'a', since: 2000 }, answer('a', 10)), { period: period('a', 0, 10), current: true });
  assert.deepEqual(rule(period('a', 0, 900), { email: 'a', since: 2000 }, answer('a', 950)), { period: period('a', 0, 950), current: true });
  assert.deepEqual(rule(period('a', 0, 900), { email: 'a', since: 2000 }, answer('b', 950)), { period: period('b', 1000, 950), current: true });
  assert.deepEqual(rule(period('a', 0, 900), { email: 'b', since: 2000 }, answer('a', 950)), { period: period('a', 0, 950), current: true });
  // Once now passes it, the same start is a recorded period like any other.
  assert.deepEqual(rule(period('a', 0, 900), { email: 'b', since: 2000 }, answer('b', 950), 2500), { period: period('b', 2000, 2000), current: true });
});

test('subset-usage mcp keeps a sign-in change from the stored identity for the session, without writing it', async (t) => {
  const fixture = await claudeFixture(t);
  await fixture.signIn('b');
  // The dashboard last saw this account signed in as a@; it is now b@.
  const identities = JSON.stringify({ claude_work: { email: 'a@example.com', since: 0 } });
  await writeFile(join(fixture.data, 'claude-identities.json'), identities);
  fixture.collect('b', 10);
  // A history file that cannot be parsed is an error, not an empty history.
  await writeFile(join(fixture.data, 'usage-history.json'), '{"schemaVersion":1,');
  const mcp = await fixture.start();

  // The snapshot predates the change this read observes, so it could be a@'s.
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  fixture.collect('b', 20);
  const before = await tree(fixture.root);
  // The change is kept for the session: snapshots collected after it show, on every later read.
  assert.deepEqual(await mcp.work(), shown('b@example.com', 80));
  assert.deepEqual(await mcp.work(), shown('b@example.com', 80));
  const history = await mcp.call('usage_history');
  assert.match(assertError(history, 'usage_unavailable').message, /^Could not read the stored usage history\./);
  assert.match(mcp.stderr(), /usage_history failed: SyntaxError/);
  await mcp.stop();
  assert.deepEqual(await tree(fixture.root), before);
  assert.equal(await readFile(join(fixture.data, 'claude-identities.json'), 'utf8'), identities);
});

test('subset-usage mcp hides an earlier sign-in\'s snapshot after a change in the session, without writing the identity', async (t) => {
  const fixture = await claudeFixture(t);
  await fixture.signIn('a');
  fixture.collect('a', 10);
  const mcp = await fixture.start();
  // No history file is an empty history, not an error.
  const history = await mcp.call('usage_history');
  assert.deepEqual([history.isError, history.structuredContent.series], [undefined, {}]);

  // With no stored identity the first sighting adopts the snapshot.
  assert.deepEqual(await mcp.work(), shown('a@example.com', 90));
  await fixture.signIn('b');
  // a@'s snapshot is not shown as b@'s.
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  fixture.collect('b', 30);
  const before = await tree(fixture.root);
  assert.deepEqual(await mcp.work(), shown('b@example.com', 70));
  await mcp.stop();
  assert.deepEqual(await tree(fixture.root), before);
  // No read recorded an identity, adopted the default account or recorded history; only the collector wrote.
  assert.deepEqual((await readdir(fixture.data)).sort(), ['collector-runs', 'usage-snapshots']);
  assert.deepEqual(JSON.parse(await readFile(fixture.profilesFile, 'utf8')).map((profile) => profile.id), ['claude_work']);
});

test('subset-usage mcp keeps one period for a sign-in change that overlapping reads observe', async (t) => {
  const fixture = await claudeFixture(t);
  const identities = JSON.stringify({ claude_work: { email: 'a@example.com', since: 0 } });
  await writeFile(join(fixture.data, 'claude-identities.json'), identities);
  await fixture.signIn('b');
  fixture.collect('b', 10);
  await fixture.signIn('slowb');
  const mcp = await fixture.start();
  const before = await tree(fixture.root);

  // The first read asks for the sign-in (b@) and waits at the gate.
  const first = mcp.work();
  await fixture.gateStarted();
  // A second read observes the change from a@ to b@ and finishes first.
  await fixture.signIn('b');
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  fixture.collect('b', 20);
  // The first read then sees the same sign-in: it must not start another period after the snapshot
  // collected in between.
  await fixture.openGate();
  assert.deepEqual(await first, shown('b@example.com', 80));
  assert.deepEqual(await mcp.work(), shown('b@example.com', 80));
  await mcp.stop();
  await assertOnlyTestWrites(fixture.root, before, testWrites);
  assert.equal(await readFile(join(fixture.data, 'claude-identities.json'), 'utf8'), identities);
});

test('subset-usage mcp ignores an older sign-in answer that arrives after a newer one', async (t) => {
  const fixture = await claudeFixture(t);
  await fixture.signIn('slowa');
  const mcp = await fixture.start();
  const before = await tree(fixture.root);

  // The first read asks while the account is signed in as a@, and waits at the gate.
  const first = mcp.work();
  await fixture.gateStarted();
  // The account signs in as b@; a second read observes that first.
  await fixture.signIn('b');
  assert.deepEqual(await mcp.work(), awaiting('b@example.com'));
  fixture.collect('b', 20);
  // The first read's a@ answer is out of date: b@'s snapshot is not shown under a@, and the session stays at b@.
  await fixture.openGate();
  assert.deepEqual(await first, hidden('a@example.com'));
  assert.deepEqual(await mcp.work(), shown('b@example.com', 80));
  await mcp.stop();
  await assertOnlyTestWrites(fixture.root, before, testWrites);
  assert.deepEqual((await readdir(fixture.data)).sort(), ['collector-runs', 'usage-snapshots']);
});

test('subset-usage mcp applies a period the dashboard recorded during a read, and keeps it', async (t) => {
  const fixture = await claudeFixture(t);
  const identitiesFile = join(fixture.data, 'claude-identities.json');
  await writeFile(identitiesFile, JSON.stringify({ claude_work: { email: 'a@example.com', since: 0 } }));
  await fixture.signIn('b');
  const mcp = await fixture.start();
  // The session observes the change from a@ to b@.
  assert.deepEqual(await mcp.work(), awaiting('b@example.com'));

  // A read asks for the sign-in (b@) and waits at the gate. Meanwhile the user signs in as a@ and
  // collects a snapshot, then signs back in as b@, which the dashboard records.
  await fixture.signIn('slowb');
  const first = mcp.work();
  await fixture.gateStarted();
  await fixture.signIn('a');
  fixture.collect('a', 45);
  await new Promise((resolveWait) => setTimeout(resolveWait, 5));
  await fixture.signIn('b');
  await writeFile(identitiesFile, JSON.stringify({ claude_work: { email: 'b@example.com', since: Date.now() } }));
  // a@'s quota must not show as b@'s, in the read already running either.
  await fixture.openGate();
  assert.deepEqual(await first, hidden('b@example.com'));
  // The session keeps that period even if the file no longer holds it.
  await rm(identitiesFile);
  const before = await tree(fixture.root);
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  await mcp.stop();
  assert.deepEqual(await tree(fixture.root), before);
});

test('subset-usage mcp applies a later sign-in change the dashboard recorded over the one it kept for the session', async (t) => {
  const fixture = await claudeFixture(t);
  const identitiesFile = join(fixture.data, 'claude-identities.json');
  // The dashboard records the start of a sign-in period after the snapshots collected before it.
  const recordIdentity = async (email) => {
    await new Promise((resolveWait) => setTimeout(resolveWait, 5));
    await writeFile(identitiesFile, JSON.stringify({ claude_work: { email, since: Date.now() } }));
  };
  await fixture.signIn('b');
  await writeFile(identitiesFile, JSON.stringify({ claude_work: { email: 'a@example.com', since: 0 } }));
  fixture.collect('b', 5);
  const mcp = await fixture.start();
  // The session keeps the change from a@ to b@.
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  fixture.collect('b', 10);
  assert.deepEqual(await mcp.work(), shown('b@example.com', 90));

  // Between reads the user signs in as a@ and collects a snapshot, then signs back in as b@, which
  // the dashboard records. The session's own b@ period started earlier and must not show a@'s quota.
  await fixture.signIn('a');
  fixture.collect('a', 45);
  await fixture.signIn('b');
  await recordIdentity('b@example.com');
  assert.deepEqual(await mcp.work(), hidden('b@example.com'));
  fixture.collect('b', 20);
  assert.deepEqual(await mcp.work(), shown('b@example.com', 80));

  // The session sees a@, then between reads the user collects as b@ and signs back in as a@, which
  // the dashboard records. The session's a@ period started earlier and must not show b@'s quota.
  await fixture.signIn('a');
  assert.deepEqual(await mcp.work(), hidden('a@example.com'));
  fixture.collect('a', 30);
  assert.deepEqual(await mcp.work(), shown('a@example.com', 70));
  await fixture.signIn('b');
  fixture.collect('b', 40);
  await fixture.signIn('a');
  await recordIdentity('a@example.com');
  const before = await tree(fixture.root);
  assert.deepEqual(await mcp.work(), hidden('a@example.com'));
  await mcp.stop();
  // Apart from the test's own writes, the session changed nothing.
  assert.deepEqual(await tree(fixture.root), before);
});

test('subset-usage mcp shows no Claude snapshot while the recorded sign-ins cannot be read, and adopts them once they can', async (t) => {
  const fixture = await claudeFixture(t);
  const identitiesFile = join(fixture.data, 'claude-identities.json');
  await fixture.signIn('a');
  fixture.collect('a', 10);
  // A torn record: the snapshot may have been collected under another sign-in.
  await writeFile(identitiesFile, '{"claude_work":{"email":"b@exa');
  const mcp = await fixture.start();
  const before = await tree(fixture.root);
  assert.deepEqual(await mcp.work(), hidden('a@example.com'));
  const message = async () => (await mcp.call('usage_status')).structuredContent.accounts.find((item) => item.id === 'claude_work').errors[0].message;
  assert.match(await message(), /claude-identities\.json\) cannot be read/);
  await assertOnlyTestWrites(fixture.root, before, testWrites);
  // Once the record reads again, its period applies as usual.
  await writeFile(identitiesFile, JSON.stringify({ claude_work: { email: 'a@example.com', since: 0 } }));
  const valid = await tree(fixture.root);
  assert.deepEqual(await mcp.work(), shown('a@example.com', 90));
  await mcp.stop();
  assert.deepEqual(await tree(fixture.root), valid);
});

test('subset-usage mcp takes no arguments and is listed in --help', () => {
  const extra = spawnSync(process.execPath, ['src/server.mjs', 'mcp', 'now'], { cwd: hostDirectory, encoding: 'utf8', timeout: 10_000 });
  assert.equal(extra.status, 2);
  assert.equal(extra.stdout, '');
  const help = spawnSync(process.execPath, ['src/server.mjs', '--help'], { cwd: hostDirectory, encoding: 'utf8', timeout: 10_000 });
  assert.match(help.stdout, /^ {2}mcp {2,}Run a read-only MCP server on stdin and stdout/m);
});
