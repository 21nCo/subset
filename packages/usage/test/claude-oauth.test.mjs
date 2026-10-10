import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { claudeKeychainService, normalizeClaudeOAuthUsage, readClaudeOAuthUsage } from '../dist/claude-oauth.js';
import { createUsageStatus, isUsageStatus } from '../dist/index.js';

const profile = { id: 'claude_a', label: 'Work', claudeConfigDir: '/Users/x/.claude-work' };
const usage = {
  five_hour: { utilization: 13, resets_at: '2026-10-08T15:00:00Z' },
  seven_day: { utilization: 41.5, resets_at: '2026-10-12T00:00:00Z' },
  seven_day_opus: null,
  limits: [{ kind: 'weekly_scoped', percent: 22, resets_at: '2026-10-12T00:00:00Z', scope: { model: { display_name: 'Fable' } } }, { kind: 'other' }],
};
const stored = (overrides = {}) => JSON.stringify({ claudeAiOauth: { accessToken: 'secret-access', refreshToken: 'secret-refresh', expiresAt: Date.now() + 3_600_000, subscriptionType: 'max', ...overrides } });

test('names keychain items like Claude Code', () => {
  assert.equal(claudeKeychainService('/Users/x/.claude', true), 'Claude Code-credentials');
  assert.match(claudeKeychainService('/Users/x/.claude-work', false), /^Claude Code-credentials-[0-9a-f]{8}$/);
});

test('maps five-hour, weekly, and model-scoped weekly windows such as Fable', () => {
  const account = normalizeClaudeOAuthUsage(profile, usage, new Date('2026-10-08T12:00:00Z'), 'max');
  assert.deepEqual(account.windows.map((window) => [window.limitId, window.usedPercent]), [['five_hour', 13], ['seven_day', 41.5], ['seven_day_fable', 22]]);
  // Labels match the status-line snapshot labels, so history keys agree across sources.
  assert.equal(account.windows[2].label, 'Seven-day Fable quota');
  assert.equal(account.state, 'ok');
  assert.equal(isUsageStatus(createUsageStatus([account])), true);
});

test('reads the keychain item, calls usage read-only, and never exposes tokens', async () => {
  const calls = [];
  const result = await readClaudeOAuthUsage(profile, {
    isDefault: false,
    readSecret: async (service) => service === claudeKeychainService(profile.claudeConfigDir, false) ? stored() : null,
    fetch: async (url, init) => { calls.push([url, init.headers.Authorization, init.method ?? 'GET']); return new Response(JSON.stringify(usage), { status: 200 }); },
  });
  assert.equal(result.kind, 'ok');
  assert.equal(result.account.plan, 'Max');
  assert.deepEqual(calls, [['https://api.anthropic.com/api/oauth/usage', 'Bearer secret-access', 'GET']]);
  assert.doesNotMatch(JSON.stringify(result), /secret-access|secret-refresh/);
});

test('falls back to the credentials file and reports expiry, rejection, and absence', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'subset-claude-oauth-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const local = { ...profile, claudeConfigDir: dir };
  assert.equal((await readClaudeOAuthUsage(local, { isDefault: false, readSecret: async () => null })).kind, 'no-credential');
  await writeFile(join(dir, '.credentials.json'), stored({ expiresAt: Date.now() - 1 }));
  assert.equal((await readClaudeOAuthUsage(local, { isDefault: false, readSecret: async () => null })).code, 'claude_token_expired');
  await writeFile(join(dir, '.credentials.json'), stored());
  const rejected = await readClaudeOAuthUsage(local, { isDefault: false, readSecret: async () => null, fetch: async () => new Response('{}', { status: 401 }) });
  assert.equal(rejected.state, 'unauthorized');
  const hex = Buffer.from(stored()).toString('hex');
  const fromHex = await readClaudeOAuthUsage(profile, { isDefault: true, readSecret: async () => hex, fetch: async () => new Response(JSON.stringify(usage), { status: 200 }) });
  assert.equal(fromHex.kind, 'ok');
});

test('labels Team Premium seats by subscription type, not the tier name', async () => {
  const { claudePlanName } = await import('../dist/claude-oauth.js');
  assert.equal(claudePlanName('team', 'default_claude_max_5x'), 'Team Premium 5x');
  assert.equal(claudePlanName('team', null), 'Team');
  assert.equal(claudePlanName('max', 'default_claude_max_20x'), 'Max 20x');
  assert.equal(claudePlanName('pro', 'default_claude_pro'), 'Pro');
  assert.equal(claudePlanName(null, 'default_claude_max_5x'), 'Max 5x');
});

test('reports extra usage as labeled spend', async () => {
  const result = await readClaudeOAuthUsage(profile, {
    isDefault: true, readSecret: async () => stored(),
    fetch: async () => new Response(JSON.stringify({ ...usage, extra_usage: { is_enabled: true, used_credits: 1234, monthly_limit: 5000 } }), { status: 200 }),
  });
  assert.deepEqual([result.account.spend.label, result.account.spend.used, result.account.spend.limit], ['Extra usage', 12.34, 50]);
});

test('reads only the email claim from the Antigravity id_token', async (t) => {
  const { readAntigravityEmail } = await import('../dist/local-auth.js');
  const { mkdir } = await import('node:fs/promises');
  const home = await mkdtemp(join(tmpdir(), 'subset-agy-'));
  t.after(() => rm(home, { recursive: true, force: true }));
  assert.equal(await readAntigravityEmail(home), null);
  await mkdir(join(home, '.gemini', 'antigravity-cli'), { recursive: true });
  const idToken = `h.${Buffer.from(JSON.stringify({ email: 'dev@example.com', sub: '1' })).toString('base64url')}.s`;
  await writeFile(join(home, '.gemini', 'antigravity-cli', 'antigravity-oauth-token'), JSON.stringify({ token: { access_token: 'secret' }, id_token: idToken }));
  assert.equal(await readAntigravityEmail(home), 'dev@example.com');
});
