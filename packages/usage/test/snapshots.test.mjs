import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeClaudeSnapshot, normalizeAntigravitySnapshot, normalizeSnapshot, readSnapshotProfile, sanitizeSnapshot } from '../dist/snapshots.js';

const observedAt = new Date('2026-01-01T00:00:00.000Z');
const claude = { id: 'claude-personal', label: 'Claude personal', provider: 'claude-code', snapshotFile: '/unused' };
const antigravity = { id: 'antigravity-work', label: 'Antigravity work', provider: 'antigravity', snapshotFile: '/unused' };
const claudeData = (used = 0) => ({ rate_limits: {
  five_hour: { used_percentage: used, resets_at: 1767243600 },
  seven_day: { used_percentage: 100, resets_at: 1767830400 }
} });
const antigravityData = (remaining = 0) => ({ plan_tier: 'Pro', quota: {
  'Gemini Pro': { remaining_fraction: remaining, reset_time: '2026-01-02T00:00:00Z', reset_in_seconds: 86400 }
} });
const envelope = (profile, data, timestamp = observedAt.toISOString()) => ({
  schemaVersion: 1, provider: profile.provider, accountId: profile.id, observedAt: timestamp, data: sanitizeSnapshot(profile, data)
});

test('Claude uses only subscription rate limits, retaining zero, exhausted quota and Unix resets', () => {
  const account = normalizeClaudeSnapshot(claude, claudeData(), observedAt);
  assert.equal(account.state, 'ok');
  assert.equal(account.source, 'Claude Code status-line snapshot');
  assert.equal(account.observedAt, observedAt.toISOString());
  assert.deepEqual(account.windows.map(w => [w.usedPercent, w.remainingPercent]), [[0, 100], [100, 0]]);
  assert.deepEqual(account.windows.map(w => w.durationMinutes), [300, 10080]);
  assert.equal(account.windows[0].resetsAt, '2026-01-01T05:00:00.000Z');
  assert.equal(account.windows[0].usedKind, 'provider-reported-quota');
  assert.equal(account.windows[0].remainingKind, 'calculated-estimate');
  const absent = normalizeClaudeSnapshot(claude, { context_window: { used_percentage: 25, remaining_percentage: 75 } }, observedAt);
  assert.equal(absent.state, 'unavailable');
  assert.deepEqual(absent.windows, []);
  assert.match(absent.errors[0].message, /Pro or Max.*first API response/);
});

test('Claude malformed or missing values remain unknown rather than zero', () => {
  for (const input of [null, [], 'bad', {}, { rate_limits: null }, { rate_limits: [] }]) {
    assert.equal(normalizeSnapshot(claude, input, observedAt).state, 'unavailable');
  }
  for (const value of [undefined, null, '20', -1, 101, NaN, Infinity]) {
    const account = normalizeClaudeSnapshot(claude, { rate_limits: { five_hour: { used_percentage: value, resets_at: null } } }, observedAt);
    assert.equal(account.state, 'unavailable');
    assert.equal(account.windows[0].usedPercent, null);
    assert.equal(account.windows[0].remainingPercent, null);
    assert.equal(account.windows[0].resetsAt, null);
  }
  for (const reset of [undefined, null, '1767243600', -1, Infinity, 1e100]) {
    const account = normalizeClaudeSnapshot(claude, { rate_limits: { five_hour: { used_percentage: 20, resets_at: reset } } }, observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.windows[0].resetsAt, null);
  }
  const mixed = claudeData(20);
  mixed.rate_limits.seven_day.used_percentage = 200;
  assert.equal(normalizeSnapshot(claude, mixed, observedAt).state, 'partial');
  mixed.rate_limits.five_hour.resets_at = 0;
  assert.equal(normalizeSnapshot(claude, mixed, observedAt).windows[0].resetsAt, '1970-01-01T00:00:00.000Z');
});

test('Antigravity retains reported remaining fractions, plan, zero and explicit reset availability', () => {
  const account = normalizeAntigravitySnapshot(antigravity, antigravityData(), observedAt);
  assert.equal(account.state, 'ok');
  assert.equal(account.source, 'Antigravity CLI status-line snapshot');
  assert.equal(account.plan, 'Pro');
  assert.equal(account.windows[0].remainingPercent, 0);
  assert.equal(account.windows[0].usedPercent, 100);
  assert.equal(account.windows[0].remainingKind, 'provider-reported-quota');
  assert.equal(account.windows[0].usedKind, 'calculated-estimate');
  assert.equal(normalizeSnapshot(antigravity, antigravityData(1), observedAt).windows[0].usedPercent, 0);
  assert.equal(normalizeSnapshot(antigravity, antigravityData(0.375), observedAt).windows[0].remainingPercent, 37.5);
  for (const reset of [null, 'bad', '2026-02-30T00:00:00Z']) {
    const input = antigravityData(0.5);
    input.quota['Gemini Pro'].reset_time = reset;
    const partial = normalizeSnapshot(antigravity, input, observedAt);
    assert.equal(partial.state, 'partial');
    assert.equal(partial.windows[0].resetsAt, null);
    assert.equal(normalizeSnapshot(antigravity, sanitizeSnapshot(antigravity, input), observedAt).windows[0].resetsAt, null);
  }
});

test('Antigravity countdowns use the observation, never read time, and respect absolute timestamps', () => {
  const input = { quota: { daily: { remaining_fraction: 0.6, reset_in_seconds: 3600 } } };
  assert.equal(normalizeSnapshot(antigravity, input, observedAt).windows[0].resetsAt, '2026-01-01T01:00:00.000Z');
  input.quota.daily.reset_in_seconds = 0;
  assert.equal(normalizeSnapshot(antigravity, input, observedAt).windows[0].resetsAt, observedAt.toISOString());
  input.quota.daily.reset_time = '2026-01-02T01:00:00+01:00';
  assert.equal(normalizeSnapshot(antigravity, input, observedAt).windows[0].resetsAt, '2026-01-02T00:00:00.000Z');
  for (const seconds of [-1, null, '3600', Infinity, 253402300799]) {
    assert.equal(normalizeSnapshot(antigravity, { quota: { daily: { remaining_fraction: 0, reset_in_seconds: seconds } } }, observedAt).windows[0].resetsAt, null);
  }
});

test('Antigravity absent and malformed quota never fabricate remaining quota', () => {
  for (const input of [null, [], {}, { quota: null }, { quota: [] }, { quota: {} }]) {
    const account = normalizeSnapshot(antigravity, input, observedAt);
    assert.equal(account.state, 'unavailable');
    assert.deepEqual(account.windows, []);
  }
  for (const fraction of [undefined, null, '0.5', -0.1, 1.1, NaN, Infinity]) {
    const account = normalizeSnapshot(antigravity, { quota: { daily: { remaining_fraction: fraction, reset_time: null } } }, observedAt);
    assert.equal(account.state, 'unavailable');
    assert.equal(account.windows[0].usedPercent, null);
    assert.equal(account.windows[0].remainingPercent, null);
  }
  const mixed = { quota: { good: { remaining_fraction: 0.5, reset_time: '2026-01-02T00:00:00Z' }, bad: false } };
  assert.equal(normalizeSnapshot(antigravity, mixed, observedAt).state, 'partial');
});

test('quota-only sanitization strips sensitive fields at every level and never invokes payload accessors', () => {
  for (const [profile, input] of [[claude, claudeData(12)], [antigravity, antigravityData(0.5)]]) {
    Object.assign(input, { email: 'private@example.com', transcript: 'secret transcript', path: '/secret/location', token: 'secret-token', command: 'run-this' });
    const bucket = profile === claude ? input.rate_limits.five_hour : input.quota['Gemini Pro'];
    Object.assign(bucket, { email: 'nested@example.com', token: 'nested-token', transcript: 'nested transcript' });
    const sanitized = sanitizeSnapshot(profile, input);
    assert.deepEqual(sanitizeSnapshot(profile, sanitized), sanitized);
    const output = JSON.stringify([sanitized, normalizeSnapshot(profile, input, observedAt)]);
    for (const secret of ['private@example.com', '/secret/location', 'secret-token', 'secret transcript', 'run-this', 'nested@example.com', 'nested-token', 'nested transcript']) assert.equal(output.includes(secret), false);
  }
  const malicious = { rate_limits: { five_hour: { resets_at: 1 } } };
  Object.defineProperty(malicious.rate_limits.five_hour, 'used_percentage', { get() { throw new Error('must not execute'); } });
  assert.equal(normalizeSnapshot(claude, malicious, observedAt).windows[0].usedPercent, null);
  assert.deepEqual(sanitizeSnapshot(claude, Object.create(claudeData())), {});
});

test('untrusted strings and quota counts are bounded without copying emails, paths or prototype keys', () => {
  const quota = Object.fromEntries(Array.from({ length: 100 }, (_, i) => [`bucket-${i}`, { remaining_fraction: 0.5 }]));
  const account = normalizeSnapshot(antigravity, { plan_tier: 'x'.repeat(10000), quota }, observedAt);
  assert.equal(account.windows.length, 32);
  assert.equal(account.state, 'partial');
  assert.equal(account.plan, null);
  for (const plan of ['private@example.com', '/private/path', 'bad\nplan']) assert.equal(normalizeSnapshot(antigravity, { plan_tier: plan }, observedAt).plan, null);
  const keys = JSON.parse('{"private@example.com":{},"/secret/path":{},"__proto__":{},"constructor":{}}');
  assert.deepEqual(sanitizeSnapshot(antigravity, { quota: keys }), { quota: {} });
  assert.equal(normalizeSnapshot(antigravity, { quota: { ['x'.repeat(65)]: {} } }, observedAt).windows.length, 0);
});

test('invalid or future observation dates return sanitized unavailable accounts', () => {
  for (const time of [new Date(NaN), new Date(Date.now() + 60000), new Date(-1)]) {
    const account = normalizeSnapshot(claude, claudeData(), time);
    assert.equal(account.state, 'unavailable');
    assert.equal(account.observedAt, null);
    assert.equal(account.errors[0].code, 'invalid_observation');
  }
});

test('independent account files retain stale capture timestamps and re-normalize only allowed data', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-snapshots-'));
  try {
    const profiles = [
      { ...claude, snapshotFile: join(root, 'claude-personal.json') },
      { ...claude, id: 'claude-work', label: 'Claude work', snapshotFile: join(root, 'claude-work.json') },
      { ...antigravity, snapshotFile: join(root, 'antigravity-work.json') }
    ];
    const values = [claudeData(0), claudeData(75), { quota: { daily: { remaining_fraction: 0.3, reset_in_seconds: 3600 } } }];
    await Promise.all(profiles.map((profile, index) => writeFile(profile.snapshotFile, JSON.stringify(envelope(profile, values[index])))));
    const accounts = await Promise.all(profiles.map(readSnapshotProfile));
    assert.deepEqual(accounts.map(a => a.id), profiles.map(p => p.id));
    assert.deepEqual(accounts.map(a => a.windows[0].remainingPercent), [100, 25, 30]);
    assert.deepEqual(accounts.map(a => a.observedAt), profiles.map(() => observedAt.toISOString()));
    assert.equal(accounts[2].windows[0].resetsAt, '2026-01-01T01:00:00.000Z');
    const untrusted = envelope(profiles[0], claudeData());
    untrusted.data.email = 'private@example.com';
    untrusted.data.command = 'execute-secret';
    await writeFile(profiles[0].snapshotFile, JSON.stringify(untrusted));
    const output = JSON.stringify(await readSnapshotProfile(profiles[0]));
    assert.equal(output.includes('private@example.com'), false);
    assert.equal(output.includes('execute-secret'), false);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('snapshot reader rejects cross-account/provider/version, malformed and future envelopes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-invalid-snapshots-'));
  const profile = { ...claude, snapshotFile: join(root, 'snapshot.json') };
  try {
    const valid = envelope(profile, claudeData());
    for (const patch of [{ accountId: 'another-account' }, { provider: 'antigravity' }, { schemaVersion: 2 }, { observedAt: 'bad' }, { observedAt: '2026-02-30T00:00:00Z' }, { observedAt: new Date(Date.now() + 60000).toISOString() }, { observedAt: null }]) {
      await writeFile(profile.snapshotFile, JSON.stringify({ ...valid, ...patch }));
      const account = await readSnapshotProfile(profile);
      assert.equal(account.state, 'unavailable');
      assert.equal(account.observedAt, null);
      assert.deepEqual(account.windows, []);
    }
    for (const content of ['invalid secret JSON /private/path', '{}', '[]', 'null', JSON.stringify({ ...valid, data: undefined })]) {
      await writeFile(profile.snapshotFile, content);
      const output = JSON.stringify(await readSnapshotProfile(profile));
      assert.equal(JSON.parse(output).state, 'unavailable');
      assert.equal(output.includes('invalid secret'), false);
      assert.equal(output.includes('/private/path'), false);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('snapshot reads are bounded at 64 KiB and file errors do not expose paths', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-sized-snapshots-'));
  const profile = { ...claude, snapshotFile: join(root, 'private-snapshot.json') };
  try {
    const json = JSON.stringify(envelope(profile, claudeData()));
    await writeFile(profile.snapshotFile, json.padEnd(64 * 1024, ' '));
    assert.equal((await readSnapshotProfile(profile)).state, 'ok');
    await writeFile(profile.snapshotFile, json.padEnd(64 * 1024 + 1, ' '));
    const tooLarge = await readSnapshotProfile(profile);
    assert.equal(tooLarge.state, 'unavailable');
    assert.equal(tooLarge.errors[0].code, 'snapshot_too_large');
    for (const path of [root, join(root, 'missing-private.json')]) {
      const account = await readSnapshotProfile({ ...profile, snapshotFile: path });
      assert.equal(account.state, 'unavailable');
      assert.equal(JSON.stringify(account).includes(root), false);
      assert.equal(JSON.stringify(account).includes('missing-private'), false);
    }
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('absent Claude windows are not partial, and model-scoped weekly windows are kept when present', async () => {
  const { normalizeClaudeSnapshot } = await import('../dist/snapshots.js');
  const { createUsageStatus, isUsageStatus } = await import('../dist/index.js');
  const profile = { id: 'c', label: 'Claude', provider: 'claude-code', snapshotFile: '/unused' };
  const reset = Date.parse('2026-10-09T00:00:00Z') / 1000;
  const fiveHourOnly = normalizeClaudeSnapshot(profile, { rate_limits: { five_hour: { used_percentage: 13, resets_at: reset } } }, new Date('2026-10-08T10:00:00Z'));
  assert.equal(fiveHourOnly.state, 'ok');
  assert.deepEqual(fiveHourOnly.errors, []);
  const withModel = normalizeClaudeSnapshot(profile, { rate_limits: {
    five_hour: { used_percentage: 13, resets_at: reset }, seven_day_fable: { used_percentage: 40, resets_at: reset }, seven_day_unknown: { used_percentage: 1, resets_at: reset },
  } }, new Date('2026-10-08T10:00:00Z'));
  assert.deepEqual(withModel.windows.map((window) => window.limitId), ['five_hour', 'seven_day_fable']);
  assert.equal(withModel.windows[1].durationMinutes, 10080);
  assert.equal(normalizeClaudeSnapshot(profile, { rate_limits: { five_hour: { used_percentage: 13 } } }, new Date('2026-10-08T10:00:00Z')).state, 'partial');
  const emailed = { ...fiveHourOnly, email: 'person@example.com' };
  assert.equal(isUsageStatus(createUsageStatus([emailed])), true);
  assert.equal(isUsageStatus(createUsageStatus([{ ...fiveHourOnly, email: '<script>@x' }])), false);
});
