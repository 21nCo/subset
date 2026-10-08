import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeAmpUsage, readAmpProfile } from '../dist/amp.js';
import { allowedDevinServer, normalizeDevinStatus, parseDevinCredentials, readDevinProfile } from '../dist/devin.js';
import { listStoredLogins, storedLoginAccount, normalizeChatgptUsage, normalizeOpencodeGoUsage, readStoredLoginProfile } from '../dist/stored-logins.js';
import { createUsageStatus, isUsageStatus } from '../dist/index.js';
import { planName, windowResetText } from '../dist/present.js';
import { claudeTierName } from '../dist/claude-oauth.js';

const now = new Date('2026-10-08T12:00:00Z');
const valid = (account) => assert.equal(isUsageStatus(createUsageStatus([account])), true, JSON.stringify(account));

test('parses amp usage text into credit balances and runs only the usage command', async (t) => {
  const output = 'Signed in as dev@example.com (arv)\n**Individual credits:** $12.50 remaining (includes $5 Amp Free remaining today; resets daily) - https://ampcode.com/settings\n';
  const account = normalizeAmpUsage({ id: 'amp_a', label: '', provider: 'amp' }, output, now);
  assert.equal(account.email, 'dev@example.com');
  assert.deepEqual(account.balances.map((balance) => [balance.label, balance.amount]), [['Credits remaining', 12.5], ['Amp Free left today', 5]]);
  valid(account);
  assert.equal(normalizeAmpUsage({ id: 'amp_a', label: '', provider: 'amp' }, 'unexpected', now).state, 'partial');
  const dir = await mkdtemp(join(tmpdir(), 'subset-amp-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const binary = join(dir, 'amp');
  await writeFile(binary, `#!/bin/sh\n[ "$1" = usage ] && [ "$#" = 1 ] || exit 3\nprintf 'Signed in as %s (x)\\n**Individual credits:** $1 remaining\\n' "\${AMP_API_KEY:-default@example.com}"\n`, { mode: 0o700 });
  const keyed = await readAmpProfile({ id: 'amp_b', label: '', provider: 'amp', credentialEnv: 'AMP_WORK' }, { ampBinary: binary, env: { PATH: process.env.PATH, AMP_WORK: 'work@example.com' } });
  assert.equal(keyed.email, 'work@example.com');
  assert.equal((await readAmpProfile({ id: 'amp_c', label: '', provider: 'amp', credentialEnv: 'MISSING' }, { ampBinary: binary, env: {} })).state, 'unauthorized');
});

test('reads Devin daily and weekly quota from its stored key on allowed servers only', async (t) => {
  assert.deepEqual(parseDevinCredentials('windsurf_api_key = "sk-1"\napi_server_url = "https://server.codeium.com"\n'), { apiKey: 'sk-1', server: 'https://server.codeium.com' });
  assert.equal(allowedDevinServer('http://server.codeium.com'), null);
  assert.equal(allowedDevinServer('https://evil.example'), null);
  assert.equal(allowedDevinServer('https://server.codeium.com/x'), 'https://server.codeium.com');
  const status = { userStatus: { email: 'dev@example.com', planStatus: { dailyQuotaRemainingPercent: 80, weeklyQuotaRemainingPercent: 55, dailyQuotaResetAtUnix: 1791500000, weeklyQuotaResetAtUnix: '1791900000', planInfo: { planName: 'Pro' } } } };
  const account = normalizeDevinStatus({ id: 'devin_a', label: '', provider: 'devin' }, status, now);
  assert.deepEqual(account.windows.map((window) => [window.limitId, window.usedPercent, window.remainingPercent]), [['daily', 20, 80], ['weekly', 45, 55]]);
  assert.equal(account.plan, 'Pro');
  valid(account);
  const dir = await mkdtemp(join(tmpdir(), 'subset-devin-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const file = join(dir, 'credentials.toml');
  await writeFile(file, 'windsurf_api_key = "sk-secret"\n');
  const calls = [];
  const fetch = async (url, init) => { calls.push([url, init.method, init.headers.Authorization]); return new Response(JSON.stringify(status), { status: 200 }); };
  const local = await readDevinProfile({ id: 'devin_a', label: '', provider: 'devin' }, { localCredentials: true, credentialsFile: file, fetch });
  assert.equal(local.state, 'ok');
  assert.deepEqual(calls[0], ['https://server.codeium.com/exa.seat_management_pb.SeatManagementService/GetUserStatus', 'POST', 'Bearer sk-secret']);
  assert.doesNotMatch(JSON.stringify(local), /sk-secret/);
  assert.equal((await readDevinProfile({ id: 'devin_a', label: '', provider: 'devin' }, { localCredentials: false, credentialsFile: file, fetch })).state, 'unauthorized');
  // A profile bound to a key variable never falls back to the default local sign-in.
  const unsetKey = await readDevinProfile({ id: 'devin_w', label: 'Work', provider: 'devin', credentialEnv: 'DEVIN_WORK' }, { localCredentials: true, credentialsFile: file, fetch, env: {} });
  assert.equal(unsetKey.state, 'unauthorized');
  assert.equal(unsetKey.errors[0].code, 'devin_missing_key');
  assert.equal(calls.length, 1);
});

test('reads Pi and OpenCode stored logins by name, without exposing tokens', async (t) => {
  const dir = await mkdtemp(join(tmpdir(), 'subset-stored-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await mkdir(join(dir, 'pi'));
  await writeFile(join(dir, 'pi', 'auth.json'), JSON.stringify({
    'openai-codex': { type: 'oauth', access: 'chatgpt-secret', refresh: 'refresh-secret', expires: Date.now() + 60_000, accountId: 'acct_1' },
    anthropic: { type: 'oauth', access: 'claude-secret', expires: Date.now() - 1 },
    openrouter: { type: 'api', key: 'other' },
  }));
  assert.deepEqual((await listStoredLogins('pi', join(dir, 'pi'))).map((option) => option.kind), ['chatgpt', 'claude']);
  // Identity includes the workspace and changes when the stored login changes; it never contains the token.
  const before = await storedLoginAccount({ provider: 'pi', login: 'chatgpt', dataDir: join(dir, 'pi') });
  assert.equal(before.workspace, 'acct_1');
  assert.doesNotMatch(JSON.stringify(before), /secret/);
  const stored = JSON.parse(await readFile(join(dir, 'pi', 'auth.json'), 'utf8'));
  await writeFile(join(dir, 'pi', 'auth.json'), JSON.stringify({ ...stored, 'openai-codex': { ...stored['openai-codex'], access: 'chatgpt-secret-2' } }));
  assert.notEqual((await storedLoginAccount({ provider: 'pi', login: 'chatgpt', dataDir: join(dir, 'pi') })).identity, before.identity);
  await writeFile(join(dir, 'pi', 'auth.json'), JSON.stringify(stored));
  const calls = [];
  const fetch = async (url, init) => {
    calls.push([url, init.headers.Authorization, init.headers['ChatGPT-Account-Id']]);
    return new Response(JSON.stringify({ plan_type: 'plus', rate_limit: { primary_window: { used_percent: 30, limit_window_seconds: 18000, reset_at: 1791460000 }, secondary_window: { used_percent: 10, limit_window_seconds: 604800, reset_after_seconds: 3600 } } }), { status: 200 });
  };
  const chatgpt = await readStoredLoginProfile({ id: 'pi_a', label: '', provider: 'pi', login: 'chatgpt', dataDir: join(dir, 'pi') }, { fetch });
  assert.equal(chatgpt.state, 'ok');
  assert.deepEqual(chatgpt.windows.map((window) => [window.durationMinutes, window.usedPercent]), [[300, 30], [10080, 10]]);
  // Same window IDs and labels as the Codex app-server, so merged accounts keep one history series.
  assert.deepEqual(chatgpt.windows.map((window) => [window.limitId, window.label]), [['codex', 'codex · primary'], ['codex', 'codex · secondary']]);
  assert.deepEqual(calls[0], ['https://chatgpt.com/backend-api/wham/usage', 'Bearer chatgpt-secret', 'acct_1']);
  assert.doesNotMatch(JSON.stringify(chatgpt), /secret/);
  valid(chatgpt);
  const expired = await readStoredLoginProfile({ id: 'pi_b', label: '', provider: 'pi', login: 'claude', dataDir: join(dir, 'pi') }, { fetch });
  assert.match(expired.errors[0].message, /expired. Open Pi/);
  assert.equal((await readStoredLoginProfile({ id: 'oc', label: '', provider: 'opencode', login: 'opencode-go', dataDir: join(dir, 'none') }, { fetch })).state, 'unauthorized');
  assert.deepEqual(normalizeOpencodeGoUsage({ usage: { rolling: { percent: 12, resetsAt: '2026-10-08T15:00:00Z' }, monthly: { percent: 40 } } }).map((window) => window.limitId), ['rolling', 'monthly']);
  assert.equal(normalizeChatgptUsage({}, Date.now()).windows.length, 0);
});

test('names plans and tiers and labels windows that have not started', () => {
  assert.equal(planName('prolite'), 'Pro Lite');
  assert.equal(planName('promax'), 'Pro Max');
  assert.equal(planName('plus'), 'Plus');
  assert.equal(planName('Max 20x'), 'Max 20x');
  assert.equal(claudeTierName('default_claude_max_20x'), 'Max 20x');
  assert.equal(claudeTierName('default_claude_max_5x'), 'Max 5x');
  assert.equal(claudeTierName('something_else'), null);
  assert.equal(windowResetText({ usedPercent: 0, resetsAt: null }, Date.now()), 'Starts on first use');
  assert.equal(windowResetText({ usedPercent: 4, resetsAt: null }, Date.now()), 'Reset time unavailable');
});

test('reads personal Cursor usage with the app sign-in and reports credits and on-demand spend', async () => {
  const { readCursorLocalProfile } = await import('../dist/cursor-local.js');
  const calls = [];
  const fetch = async (url, init) => {
    calls.push([url.split('/').pop(), init.headers.Authorization]);
    return new Response(JSON.stringify(url.endsWith('GetCurrentPeriodUsage')
      ? { billingCycleStart: '1791000000000', billingCycleEnd: '1793592000000', planUsage: { totalPercentUsed: 42.5 }, spendLimitUsage: { individualLimit: 5000, individualRemaining: 3500 } }
      : { hasCreditGrants: true, totalCents: 2000, usedCents: 500 }), { status: 200 });
  };
  const state = { 'cursorAuth/stripeMembershipType': 'pro', 'cursorAuth/cachedEmail': 'dev@example.com' };
  const account = await readCursorLocalProfile({ id: 'cl', label: '', provider: 'cursor-local' }, { fetch, readSecret: async () => 'cursor-secret', readState: async (key) => state[key] ?? null });
  assert.equal(account.state, 'ok');
  assert.equal(account.windows[0].usedPercent, 42.5);
  assert.equal(account.plan, 'pro');
  assert.equal(account.email, 'dev@example.com');
  assert.equal(account.spend, undefined);
  assert.deepEqual(account.balances.map((balance) => [balance.label, balance.amount]), [['On-demand spend', 15], ['Credits remaining', 15]]);
  assert.deepEqual(calls.map((call) => call[0]), ['GetCurrentPeriodUsage', 'GetCreditGrantsBalance', 'GetPlanInfo']);
  assert.doesNotMatch(JSON.stringify(account), /cursor-secret/);
  valid(account);
  const signedOut = await readCursorLocalProfile({ id: 'cl', label: '', provider: 'cursor-local' }, { fetch, readSecret: async () => null, readState: async () => null });
  assert.equal(signedOut.state, 'unauthorized');
});

test('reports paid Codex credits as a credit count', async () => {
  const { normalizeCodexRead } = await import('../dist/codex.js');
  const account = normalizeCodexRead({ id: 'c', label: '', codexHome: '/x' }, { account: { type: 'chatgpt', planType: 'pro' } }, {
    rateLimits: { limitId: 'codex', primary: { usedPercent: 10, windowDurationMins: 300, resetsAt: 1_800_000_000 }, credits: { hasCredits: true, unlimited: false, balance: '60385.15' } },
  }, now);
  assert.deepEqual(account.balances, [{ kind: 'provider-reported-balance', currency: 'credits', amount: 60385.15, label: 'Credits' }]);
  valid(account);
});

test('splits Cursor usage into total, Auto + Composer, and API models with spend amounts', async () => {
  const { normalizeCursorLocalUsage } = await import('../dist/cursor-local.js');
  const { windowTitle } = await import('../dist/present.js');
  const account = normalizeCursorLocalUsage({ id: 'cl', label: '', provider: 'cursor-local' }, {
    billingCycleStart: '1790628913000', billingCycleEnd: '1793220913000',
    planUsage: { totalSpend: 16603, includedSpend: 2000, bonusSpend: 14603, limit: 2000, autoPercentUsed: 68.08, apiPercentUsed: 57.65, totalPercentUsed: 66.412 },
    spendLimitUsage: { totalSpend: 445749, pooledUsed: 445749, limitType: 'team' },
  }, {}, now, { plan: 'Team', email: null });
  assert.deepEqual(account.windows.map((window) => [windowTitle(account, window), window.usedPercent]), [['Total usage', 66.4], ['Auto + Composer', 68.1], ['API models', 57.7]]);
  assert.deepEqual([account.spend.label, account.spend.used, account.spend.limit], ['Included usage', 20, 20]);
  assert.deepEqual(account.balances.map((balance) => [balance.label, balance.amount]), [['Bonus usage', 146.03], ['Team pooled spend', 4457.49]]);
  valid(account);
});

test('reads omp rows and Hermes logins, mapping them to their service without exposing tokens', async (t) => {
  const { execFileSync } = await import('node:child_process');
  const dir = await mkdtemp(join(tmpdir(), 'subset-harness-'));
  t.after(() => rm(dir, { recursive: true, force: true }));
  const db = join(dir, 'agent.db');
  const data = (email) => JSON.stringify({ access: `secret-${email}`, refresh: 'r', expires: Date.now() + 60_000, accountId: `acct-${email}`, email });
  execFileSync('/usr/bin/sqlite3', [db, `create table auth_credentials (id integer primary key, provider text, credential_type text, data text, disabled_cause text);
    insert into auth_credentials (provider, credential_type, data) values ('openai-codex', 'oauth', '${data('one@example.com')}'), ('openrouter', 'api_key', '{}'), ('openai-codex', 'oauth', '${data('two@example.com')}');`]);
  assert.deepEqual(await listStoredLogins('omp', dir), [{ kind: 'chatgpt', entryId: '1', email: 'one@example.com' }, { kind: 'chatgpt', entryId: '3', email: 'two@example.com' }]);
  const calls0 = [];
  const omp = await readStoredLoginProfile({ id: 'o', label: '', provider: 'omp', login: 'chatgpt', dataDir: dir, entryId: '3' }, {
    fetch: async (url, init) => { calls0.push(init.headers.Authorization); return new Response(JSON.stringify({ rate_limit: { primary_window: { used_percent: 5, limit_window_seconds: 18000 } } }), { status: 200 }); },
  });
  assert.deepEqual(calls0, ['Bearer secret-two@example.com']);
  assert.equal(omp.email, 'two@example.com');
  assert.equal(omp.service, 'codex-chatgpt');
  await mkdir(join(dir, 'hermes'));
  await writeFile(join(dir, 'hermes', 'auth.json'), JSON.stringify({ providers: { 'openai-codex': { tokens: { access_token: 'hermes-secret', account_id: 'acct_h' }, last_auth_error: { relogin_required: false } } } }));
  assert.deepEqual(await listStoredLogins('hermes', join(dir, 'hermes')), [{ kind: 'chatgpt' }]);
  const calls = [];
  const fetch = async (url, init) => {
    calls.push([init.headers.Authorization, init.headers['ChatGPT-Account-Id']]);
    return new Response(JSON.stringify({ plan_type: 'pro', rate_limit: { primary_window: { used_percent: 12, limit_window_seconds: 18000, reset_at: 1791460000 } } }), { status: 200 });
  };
  const hermes = await readStoredLoginProfile({ id: 'h', label: '', provider: 'hermes', login: 'chatgpt', dataDir: join(dir, 'hermes') }, { fetch });
  assert.equal(hermes.service, 'codex-chatgpt');
  assert.deepEqual(calls[0], ['Bearer hermes-secret', 'acct_h']);
  assert.doesNotMatch(JSON.stringify(hermes), /hermes-secret/);
  valid(hermes);
  await writeFile(join(dir, 'hermes', 'auth.json'), JSON.stringify({ providers: { 'openai-codex': { tokens: { access_token: 'x' }, last_auth_error: { relogin_required: true } } } }));
  assert.match((await readStoredLoginProfile({ id: 'h', label: '', provider: 'hermes', login: 'chatgpt', dataDir: join(dir, 'hermes') }, { fetch })).errors[0].message, /sign in again/);
});
