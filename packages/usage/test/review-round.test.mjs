import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createUsageStatus, isEmail, isUsageStatus, usageText } from '../dist/index.js';
import { historyWindowKey, recordUsageHistory } from '../dist/history.js';
import { activityGrid, limitAlerts, summarize, windowTitle } from '../dist/present.js';
import { antigravitySpan, readSnapshotProfile, sanitizeSnapshot } from '../dist/snapshots.js';
import { normalizeCursorLocalUsage, readCursorLocalProfile } from '../dist/cursor-local.js';
import { fetchJson, retryAfterOf } from '../dist/local-auth.js';
import { normalizeChatgptUsage, readStoredLoginProfile, listStoredLogins } from '../dist/stored-logins.js';
import { normalizeFactoryLimits } from '../dist/factory.js';
import { consumeCodexResetCredit, normalizeCodexRead } from '../dist/codex.js';
import { readAmpProfile } from '../dist/amp.js';

const now = Date.parse('2026-10-08T12:00:00Z');
const window = (overrides = {}) => ({ limitId: 'codex', label: 'codex · primary', kind: 'provider-reported-quota', usedPercent: 50, usedKind: 'provider-reported-quota', remainingPercent: 50, remainingKind: 'calculated-estimate', durationMinutes: 300, resetsAt: new Date(now + 3_600_000).toISOString(), ...overrides });
const account = (overrides = {}) => ({ id: 'a', label: '', provider: 'codex-chatgpt', source: 'Codex app-server', plan: null, observedAt: new Date(now).toISOString(), state: 'ok', windows: [window()], resetCredits: null, errors: [], ...overrides });

test('Claude model windows keep distinct titles and keys, also when read through a harness', () => {
  const weekly = window({ limitId: 'seven_day', label: 'Seven-day quota', durationMinutes: 10080 });
  const sonnet = window({ limitId: 'seven_day_sonnet45', label: 'Seven-day Sonnet 4.5 quota', durationMinutes: 10080 });
  for (const claude of [account({ provider: 'claude-code', windows: [weekly, sonnet] }), account({ provider: 'pi', service: 'claude-code', windows: [weekly, sonnet] })]) {
    assert.equal(windowTitle(claude, weekly), 'Weekly usage');
    assert.equal(windowTitle(claude, sonnet), 'Weekly Sonnet 4.5 usage');
  }
  // Even identical titles get distinct keys in the upcoming-reset and alert lists.
  const same = account({ provider: 'antigravity', windows: [window({ limitId: 'gemini-5h', label: 'gemini-5h', usedPercent: 100, remainingPercent: 0 }), window({ limitId: '3p-5h', label: '3p-5h', usedPercent: 100, remainingPercent: 0 })] });
  const keys = summarize(createUsageStatus([same]), now).nextResets.map((reset) => reset.key);
  assert.equal(new Set(keys).size, 2);
  assert.equal(new Set(limitAlerts([same]).exhausted.map((item) => item.key)).size, 2);
});

test('remaining-only windows still rank as highest usage', () => {
  const summary = summarize(createUsageStatus([account({ windows: [window({ usedPercent: null, remainingPercent: 5 })] })]), now);
  assert.equal(summary.highest.used, 95);
  assert.equal(summary.highest.calculated, true);
});

test('activity days follow local calendar midnights across a DST change', () => {
  const previous = process.env.TZ;
  process.env.TZ = 'America/New_York';
  try {
    // 2026-11-01 is 25 hours long in New York; a point late that day belongs to it, not the next.
    const end = Date.parse('2026-11-02T15:00:00Z');
    const late = Date.parse('2026-11-02T04:30:00Z'); // 23:30 on 1 November, local
    const history = { schemaVersion: 1, series: { a: { k: [[late - 60_000, 10], [late, 20]] } } };
    const grid = activityGrid(history, [account()], end, 7);
    const day = grid.dayStarts.findIndex((start) => new Date(start).getDate() === 1);
    assert.equal(new Date(grid.dayStarts[day]).getHours(), 0);
    assert.equal(grid.cells.reduce((sum, row) => sum + row[day].value, 0), 10);
  } finally { if (previous === undefined) delete process.env.TZ; else process.env.TZ = previous; }
});

test('history treats __proto__ as an ordinary account ID', () => {
  const status = createUsageStatus([account({ id: '__proto__' })]);
  const history = recordUsageHistory({ schemaVersion: 1, series: {} }, status, now);
  assert.deepEqual(Object.keys(history.series), ['__proto__']);
  assert.equal(Object.hasOwn(history.series.__proto__, historyWindowKey(window())), true);
  assert.equal({}.polluted, undefined);
});

test('text fallback includes provider balances', () => {
  const amp = account({ provider: 'amp', source: 'amp usage', windows: [], balances: [{ kind: 'provider-reported-balance', currency: 'USD', amount: 12.5, label: 'Credit balance' }] });
  assert.match(usageText(createUsageStatus([amp]), new Date(now)), /Credit balance: USD 12\.50/);
  // Live Claude reads are not described as snapshots.
  const live = account({ provider: 'claude-code', source: 'Claude usage (local sign-in)' });
  assert.doesNotMatch(usageText(createUsageStatus([live]), new Date(now)), /last collected CLI snapshot/);
});

test('email validation is linear and keeps ordinary addresses', () => {
  assert.equal(isEmail('first.last+tag@example.co.uk'), true);
  assert.equal(isEmail('a@b'), false);
  assert.equal(isEmail('a@@b.c'), false);
  const started = performance.now();
  assert.equal(isEmail(`${'a.'.repeat(120)}@${'b.'.repeat(60)}`), false);
  assert.ok(performance.now() - started < 50);
});

test('Antigravity span lookup ignores inherited names and records truncation', async (t) => {
  assert.equal(antigravitySpan('gemini-constructor'), null);
  assert.equal(antigravitySpan('gemini-5h'), 300);
  const quota = Object.fromEntries(Array.from({ length: 32 }, (_, index) => [`b${index}-5h`, { remaining_fraction: 0.5, reset_in_seconds: 60 }]));
  assert.equal(sanitizeSnapshot({ provider: 'antigravity' }, { quota }).quota_truncated, undefined);
  assert.equal(sanitizeSnapshot({ provider: 'antigravity' }, { quota: { ...quota, extra: { remaining_fraction: 1 } } }).quota_truncated, true);
  const dir = await mkdtemp(join(tmpdir(), 'subset-review-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 's.json');
  await writeFile(file, JSON.stringify({ schemaVersion: 1, provider: 'antigravity', accountId: 'g', capturedAt: new Date(Date.now() - 1000).toISOString(), snapshot: sanitizeSnapshot({ provider: 'antigravity' }, { quota }) }));
  const read = await readSnapshotProfile({ id: 'g', label: 'x'.repeat(200), provider: 'antigravity', snapshotFile: file });
  assert.ok(read.label.length <= 80);
  if (read.observedAt) assert.equal(read.state, 'ok');
  assert.equal(isUsageStatus(createUsageStatus([read])), true);
});

test('Cursor reports on-demand spend only when both values are given, and keeps unreadable state distinct', async () => {
  const usage = { planUsage: { totalPercentUsed: 10 }, spendLimitUsage: { individualLimit: 5000 } };
  const without = normalizeCursorLocalUsage({ id: 'c', label: '', provider: 'cursor-local' }, usage, null, new Date(now), { plan: null, email: null });
  assert.equal(without.balances?.some((balance) => balance.label === 'On-demand spend') ?? false, false);
  const withRemaining = normalizeCursorLocalUsage({ id: 'c', label: '', provider: 'cursor-local' }, { ...usage, spendLimitUsage: { individualLimit: 5000, individualRemaining: 2000 } }, null, new Date(now), { plan: null, email: null });
  assert.equal(withRemaining.balances.find((balance) => balance.label === 'On-demand spend').amount, 30);
  const unreadable = await readCursorLocalProfile({ id: 'c', label: '', provider: 'cursor-local' }, { readSecret: async () => null, readState: async () => { throw new Error('locked'); } });
  assert.equal(unreadable.errors[0].code, 'cursor_state_unreadable');
  const absent = await readCursorLocalProfile({ id: 'c', label: '', provider: 'cursor-local' }, { readSecret: async () => null, readState: async () => null });
  assert.equal(absent.errors[0].code, 'cursor_signed_out');
});

test('fetchJson stops at the byte limit and parses Retry-After dates', async () => {
  let pulled = 0;
  const body = new ReadableStream({ pull(controller) { pulled++; controller.enqueue(new Uint8Array(1024)); if (pulled > 1000) controller.close(); } });
  const fetch = async () => new Response(body, { status: 200, headers: { 'retry-after': new Date(Date.now() + 120_000).toUTCString() } });
  const result = await fetchJson('https://example.test/', { headers: {} }, { fetch, maxBytes: 4096 });
  assert.equal(result.json, null);
  assert.ok(pulled < 20);
  assert.ok(result.retryAfterMs > 100_000 && result.retryAfterMs <= 120_000);
  assert.equal(retryAfterOf('30'), 30_000);
  assert.equal(retryAfterOf('soon'), null);
});

test('stored logins: API keys are not subscriptions, re-login wins, and empty windows are partial', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'subset-review-stored-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, 'oc'));
  await writeFile(join(dir, 'oc', 'auth.json'), JSON.stringify({ openai: { type: 'api', key: 'sk-api' }, anthropic: { type: 'api', key: 'sk-ant' } }));
  const options = await listStoredLogins('opencode', join(dir, 'oc'));
  const chatgpt = await readStoredLoginProfile({ id: 'oc', label: '', provider: 'opencode', login: 'chatgpt', dataDir: join(dir, 'oc') }, { fetch: async () => { throw new Error('must not be called'); } });
  assert.equal(chatgpt.errors[0].code, 'stored_login_unreadable');
  assert.ok(options.every((option) => option.kind));
  await mkdir(join(dir, 'hermes'));
  await writeFile(join(dir, 'hermes', 'auth.json'), JSON.stringify({ providers: { 'openai-codex': { tokens: {}, last_auth_error: { relogin_required: true } } } }));
  const relogin = await readStoredLoginProfile({ id: 'h', label: '', provider: 'hermes', login: 'chatgpt', dataDir: join(dir, 'hermes') });
  assert.equal(relogin.state, 'unauthorized');
  const usage = normalizeChatgptUsage({ rate_limit: { primary_window: {}, secondary_window: { used_percent: 10, limit_window_seconds: 604800, reset_at: 1900000000 } } }, now);
  assert.equal(usage.windows.length, 1);
  assert.equal(usage.incomplete, true);
});

test('Factory: a missing standard group is missing data, not an unsupported plan', () => {
  const profile = { id: 'f', label: '', provider: 'factory-droid', factoryHome: '/h' };
  assert.notEqual(normalizeFactoryLimits(profile, { limits: {} }, new Date(now), { email: null, source: 'x' }).state, 'unsupported');
  assert.equal(normalizeFactoryLimits(profile, { usesTokenRateLimitsBilling: false }, new Date(now), { email: null, source: 'x' }).state, 'unsupported');
});

test('Codex: workspace is host-internal, and earliest expiry ignores redeemed credits', () => {
  const read = normalizeCodexRead({ id: 'c', label: '', codexHome: '/h' }, { account: { type: 'chatgpt', email: 'a@example.com', planType: 'team' }, workspaceRouting: { chatgptAccountId: 'ws_1' } }, {
    rateLimits: { limitId: 'codex', primary: { usedPercent: 10, windowDurationMins: 300, resetsAt: 1900000000 } },
    rateLimitResetCredits: { availableCount: 1, credits: [{ status: 'redeemed', expiresAt: 1800000000 }, { status: 'available', expiresAt: 1850000000 }] },
  }, new Date(now));
  assert.equal(read.workspaceId, 'ws_1');
  assert.equal(read.resetCredits.earliestExpiry, new Date(1850000000 * 1000).toISOString());
});

test('Codex reset settles when the app-server cannot start, and never redeems after a failed read', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'subset-review-codex-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const started = Date.now();
  await assert.rejects(consumeCodexResetCredit({ id: 'c', label: '', codexHome: dir }, { codexBinary: join(dir, 'missing'), idempotencyKey: '00000000-0000-4000-8000-000000000001', timeoutMs: 10_000 }));
  assert.ok(Date.now() - started < 5000);
  const binary = join(dir, 'codex');
  const log = join(dir, 'calls.log');
  await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
import { appendFileSync } from 'node:fs';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (message.method) appendFileSync(${JSON.stringify(log)}, message.method + '\\n');
  if (!message.id) continue;
  if (message.method === 'account/rateLimits/read') process.stdout.write(JSON.stringify({ id: message.id, error: { message: 'failed' } }) + '\\n');
  else process.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\\n');
}
`, { mode: 0o755 });
  await assert.rejects(consumeCodexResetCredit({ id: 'c', label: '', codexHome: dir }, { codexBinary: binary, idempotencyKey: '00000000-0000-4000-8000-000000000002', timeoutMs: 5000 }), /could not use a reset/);
  const { readFile } = await import('node:fs/promises');
  assert.doesNotMatch(await readFile(log, 'utf8'), /consume/);
});

test('Amp sign-in errors on stderr are classified as signed out', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'subset-review-amp-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binary = join(dir, 'amp');
  await writeFile(binary, '#!/bin/sh\necho "Error: not logged in" >&2\nexit 1\n', { mode: 0o755 });
  const result = await readAmpProfile({ id: 'amp', label: '', provider: 'amp' }, { ampBinary: binary, env: { PATH: process.env.PATH } });
  assert.equal(result.errors[0].code, 'amp_signed_out');
});
