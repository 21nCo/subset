import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdir, mkdtemp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { McpFnTestClient, assertManifestContract, validateMcpFnSchemaPortability } from '@mcpfn/testing';
import { USAGE_PROVIDERS, createUsageStatus, isUsageStatus, usageText } from '@subset.dev/usage-core';
import { defineUsageMcpServer } from '../src/mcp.mjs';

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

function assertError(result, code) {
  assert.equal(result.isError, true, JSON.stringify(result));
  assert.equal(result.structuredContent.error.code, code);
  assert.equal(result.content[0].text, `${code}: ${result.structuredContent.error.message}`);
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
    assert.equal(tool.annotations.readOnlyHint, true, tool.name);
    assert.match(tool.description, /local/, tool.name);
    assert.ok(tool.title, tool.name);
  }
  assert.deepEqual(byName.usage_status.inputSchema.properties.provider.enum, [...USAGE_PROVIDERS]);
  assert.deepEqual(Object.keys(byName.usage_status.inputSchema.properties), ['provider']);
  // A status read may call provider usage endpoints when local sign-ins are on; the history read calls none.
  assert.equal(byName.usage_status.annotations.openWorldHint, true);
  assert.equal(byName.usage_history.annotations.openWorldHint, false);
  const { hours, accountId } = byName.usage_history.inputSchema.properties;
  assert.deepEqual([hours.type, hours.minimum, hours.maximum], ['integer', 1, 168]);
  assert.equal(accountId.pattern, '^[a-zA-Z0-9_-]{1,64}$');
  // The status description lists the configured providers once each, and says how to read stale and unavailable values.
  assert.match(byName.usage_status.description, /Providers configured when this server started: ChatGPT \(codex-chatgpt\), Claude \(claude-code\), Hermes \(hermes\), Amp \(amp\)\./);
  assert.match(byName.usage_status.description, /older than 5 minutes is stale/);
  assert.match(byName.usage_status.description, /null percentage or reset time is unavailable, not zero/);
  assert.match(byName.usage_history.description, /only while it is open/);
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
  const filtered = await call('usage_status', { provider: 'claude-code' });
  assert.ok(isUsageStatus(filtered.structuredContent));
  assert.equal(filtered.content[0].text, usageText(filtered.structuredContent));
  // No account of that provider: the text names it rather than saying nothing is configured.
  const none = await call('usage_status', { provider: 'cursor' });
  assert.deepEqual(none.structuredContent.accounts, []);
  assert.equal(none.content[0].text, 'No Cursor team (cursor) accounts are configured.');
});

test('invalid input is an invalid_input tool error; a failed configuration read is usage_unavailable', async (t) => {
  const reads = [];
  const { call, logs } = await session(t, { readStatus: async () => { reads.push('status'); return fixtureStatus(); }, readHistory: async () => { reads.push('history'); return { schemaVersion: 1, series: {} }; } });
  assert.match(assertError(await call('usage_status', { provider: 'chatgpt' }), 'invalid_input').issues[0].path, /^provider$/);
  assert.deepEqual(assertError(await call('usage_status', { provider: 'amp', extra: true }), 'invalid_input').issues, [{ path: 'extra', message: 'is not a known field' }]);
  for (const hours of [0, 169, 1.5, '48']) assert.equal(assertError(await call('usage_history', { hours }), 'invalid_input').issues[0].path, 'hours', String(hours));
  assert.equal(assertError(await call('usage_history', { accountId: '../other' }), 'invalid_input').issues[0].path, 'accountId');
  // Rejected before any read.
  assert.deepEqual(reads, []);

  const failing = await session(t, { readStatus: async () => { throw new Error('Could not read usage profiles configuration.'); }, readHistory: async () => { throw new Error('EACCES /private/path'); } });
  const error = assertError(await failing.call('usage_status'), 'usage_unavailable');
  assert.doesNotMatch(error.message, /private/);
  assertError(await failing.call('usage_history'), 'usage_unavailable');
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
  const { call } = await session(t, { readHistory: async () => JSON.parse(JSON.stringify(history)) });
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
function startMcp(env) {
  const child = spawn(process.execPath, ['src/server.mjs', 'mcp'], { cwd: hostDirectory, env, stdio: ['pipe', 'pipe', 'pipe'] });
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
  assert.deepEqual([invalid.isError, invalid.structuredContent.error.code], [true, 'invalid_input']);

  mcp.child.stdin.end();
  const [code, signal] = await mcp.exited;
  assert.deepEqual({ code, signal }, { code: 0, signal: null });
  // stdout held only complete JSON-RPC replies; the log line went to stderr.
  assert.equal(mcp.rest(), '');
  assert.deepEqual(mcp.frames.map((frame) => [frame.jsonrpc, frame.id, 'result' in frame]), [1, 2, 3, 4, 5, 6].map((id) => ['2.0', id, true]));
  assert.match(mcp.stderr(), new RegExp(`^subset-usage mcp: ${manifest.version.replaceAll('.', '\\.')} serving on stdio$`, 'm'));
  // No file or directory was added, removed or modified: no profile, identity, preference or history write.
  assert.deepEqual(await tree(root), before);
});

test('subset-usage mcp takes no arguments and is listed in --help', () => {
  const extra = spawnSync(process.execPath, ['src/server.mjs', 'mcp', 'now'], { cwd: hostDirectory, encoding: 'utf8', timeout: 10_000 });
  assert.equal(extra.status, 2);
  assert.equal(extra.stdout, '');
  const help = spawnSync(process.execPath, ['src/server.mjs', '--help'], { cwd: hostDirectory, encoding: 'utf8', timeout: 10_000 });
  assert.match(help.stdout, /^ {2}mcp {2,}Run a read-only MCP server on stdin and stdout/m);
});
