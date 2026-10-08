import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { spawnSync } from 'node:child_process';
import childProcess from 'node:child_process';
import { EventEmitter } from 'node:events';
import { syncBuiltinESMExports } from 'node:module';
import { PassThrough, Writable } from 'node:stream';
import { normalizeCodexRead, readCodexProfile } from '../dist/codex.js';
import { CODEX_LIMIT_REASONS, createUsageStatus, isUsageStatus } from '../dist/index.js';

const profile = { id: 'a', label: 'A', codexHome: '/unused' };
const observedAt = new Date('2026-09-29T00:00:00Z');
const quota = { usedPercent: 25, windowDurationMins: 300, resetsAt: 1_600_000_000 };
const normalize = (limits) => normalizeCodexRead(profile, { account: { type: 'chatgpt', planType: 'plus' } }, limits, observedAt);
const validStatus = (accounts) => assert.equal(isUsageStatus(createUsageStatus(accounts, observedAt)), true);

function mockTransport(t, onWrite) {
  const child = new EventEmitter();
  const writes = [];
  child.stdout = new PassThrough();
  child.kill = () => { child.stdout.destroy(); child.stdin.destroy(); return true; };
  child.stdin = new Writable({
    write(chunk, encoding, callback) {
      const message = JSON.parse(chunk.toString());
      writes.push(message.method);
      onWrite(child, message, callback);
    }
  });
  t.mock.method(childProcess, 'spawn', () => child);
  syncBuiltinESMExports();
  t.after(() => { t.mock.restoreAll(); syncBuiltinESMExports(); });
  return writes;
}

test('normalizes reported usage while marking remaining as an estimate, keeping email, and omitting sensitive IDs', () => {
  const profile = { id: 'personal', label: 'Personal', codexHome: '/unused' };
  const account = normalizeCodexRead(profile, { account: { type: 'chatgpt', email: 'private@example.com', planType: 'plus' } }, {
    rateLimitsByLimitId: { codex: { limitId: 'codex', primary: { usedPercent: 37.5, windowDurationMins: 300, resetsAt: 1_800_000_000 } } },
    rateLimitResetCredits: { availableCount: 2, credits: [{ id: 'secret-credit-id', expiresAt: 1_810_000_000 }] }
  }, new Date('2026-09-29T00:00:00Z'));
  assert.equal(account.state, 'ok');
  assert.equal(account.windows[0].remainingPercent, 62.5);
  assert.equal(account.windows[0].remainingKind, 'calculated-estimate');
  assert.equal(account.resetCredits.availableCount, 2);
  assert.equal(account.ordinaryUsageAllowed, null);
  assert.deepEqual(account.limitAccess, [{ limitId: 'codex', label: 'codex', rateLimitReachedType: null, spendControlReached: null }]);
  assert.equal(account.email, 'private@example.com');
  assert.equal(JSON.stringify(account).includes('secret-credit-id'), false);
  validStatus([account]);
});

test('keeps missing and unsupported data explicit', () => {
  const profile = { id: 'a', label: 'A', codexHome: '/unused' };
  assert.equal(normalizeCodexRead(profile, { account: { type: 'apiKey' } }, null, new Date()).state, 'unsupported');
  const partial = normalizeCodexRead(profile, { account: { type: 'chatgpt' } }, { rateLimits: { primary: { usedPercent: 150 } } }, new Date());
  assert.equal(partial.state, 'partial');
  assert.equal(partial.windows[0].usedPercent, null);
  assert.equal(partial.windows[0].remainingPercent, null);
  assert.equal(partial.windows[0].resetsAt, null);
  validStatus([partial]);
});

test('preserves all five reached-limit reasons without overriding account permission', () => {
  assert.deepEqual(CODEX_LIMIT_REASONS, [
    'rate_limit_reached', 'workspace_owner_credits_depleted', 'workspace_member_credits_depleted',
    'workspace_owner_usage_limit_reached', 'workspace_member_usage_limit_reached'
  ]);
  for (const reason of CODEX_LIMIT_REASONS) {
    for (const permission of [true, false, null]) {
      const account = normalize({ ordinaryUsageAllowed: permission, rateLimits: { primary: quota, rateLimitReachedType: reason } });
      assert.equal(account.state, permission === false ? 'blocked' : 'partial');
      assert.equal(account.ordinaryUsageAllowed, permission);
      assert.equal(account.limitAccess[0].rateLimitReachedType, reason);
      assert.equal(account.windows[0].remainingPercent, 75);
      assert.ok(Date.parse(account.windows[0].resetsAt) < observedAt.getTime());
      assert.equal(account.errors.filter((error) => error.code === reason).length, 1);
      validStatus([account]);
    }
  }
});

test('normalizes only strict response-level permission and never infers recovery from quota or reset time', () => {
  for (const value of [true, false, null, undefined, 'false', 0, 1, [], {}, { token: 'private-root-token' }]) {
    const account = normalize({ ...(value === undefined ? {} : { ordinaryUsageAllowed: value }), rateLimits: { primary: quota } });
    const malformed = value !== undefined && value !== null && typeof value !== 'boolean';
    assert.equal(account.ordinaryUsageAllowed, typeof value === 'boolean' ? value : null);
    assert.equal(account.state, value === false ? 'blocked' : malformed ? 'partial' : 'ok');
    assert.equal(account.windows[0].remainingPercent, 75);
    assert.equal(account.errors.some((error) => error.code === 'ordinary_usage_denied'), value === false);
    assert.equal(JSON.stringify(account).includes('private-root-token'), false);
    validStatus([account]);
  }
});

test('ignores incorrectly nested ordinary permission including conflicting and malformed values', () => {
  for (const root of [true, false, null, undefined]) {
    for (const nested of [true, false, 'invalid', { secret: 'nested-secret' }]) {
      const account = normalize({
        ...(root === undefined ? {} : { ordinaryUsageAllowed: root }),
        rateLimitsByLimitId: { codex: { primary: quota, ordinaryUsageAllowed: nested } }
      });
      assert.equal(account.ordinaryUsageAllowed, root ?? null);
      assert.equal(account.state, root === false ? 'blocked' : 'ok');
      assert.equal(JSON.stringify(account).includes('nested-secret'), false);
      validStatus([account]);
    }
  }
});

test('retains denial-only and mixed buckets, including nullable or malformed spend-control flags', () => {
  const account = normalize({ ordinaryUsageAllowed: true, rateLimitsByLimitId: {
    normal: { limitName: 'Normal', primary: quota, rateLimitReachedType: null, spendControlReached: false },
    depleted: { limitName: 'Depleted', rateLimitReachedType: 'workspace_owner_credits_depleted' },
    controlled: { primary: quota, spendControlReached: true },
    unknown: { primary: quota, spendControlReached: null }
  } });
  assert.equal(account.state, 'partial');
  assert.equal(account.ordinaryUsageAllowed, true);
  assert.equal(account.limitAccess.length, 4);
  assert.equal(account.windows.length, 3);
  assert.deepEqual(account.limitAccess[1], {
    limitId: 'depleted', label: 'Depleted', rateLimitReachedType: 'workspace_owner_credits_depleted', spendControlReached: null
  });
  assert.equal(account.limitAccess[2].spendControlReached, true);
  assert.ok(account.errors.some((error) => error.code === 'spend_control_reached'));
  validStatus([account]);
  for (const flag of [false, true, null, undefined, 'true', 1, {}, []]) {
    const result = normalize({ ordinaryUsageAllowed: true, rateLimits: { primary: quota, spendControlReached: flag } });
    const malformed = flag !== undefined && flag !== null && typeof flag !== 'boolean';
    assert.equal(result.limitAccess[0].spendControlReached, typeof flag === 'boolean' ? flag : null);
    assert.equal(result.state, flag === true || malformed ? 'partial' : 'ok');
    validStatus([result]);
  }
  const denied = normalize({ ordinaryUsageAllowed: false, rateLimits: { rateLimitReachedType: 'rate_limit_reached' } });
  assert.equal(denied.state, 'blocked');
  assert.equal(denied.windows.length, 0);
  assert.equal(denied.limitAccess[0].rateLimitReachedType, 'rate_limit_reached');
  validStatus([denied]);
});

test('unknown or malformed bucket reasons are unavailable, partial, and redacted', () => {
  for (const reason of ['future_limit_private@example.com', '', 0, true, {}, ['rate_limit_reached']]) {
    const account = normalizeCodexRead(profile, { account: { type: 'chatgpt', email: 'private@example.com' } }, {
      ordinaryUsageAllowed: true,
      accountId: 'secret-account-id', error: { message: 'secret-server-error' },
      rateLimits: { primary: quota, rateLimitReachedType: reason, token: 'secret-token' },
      rateLimitResetCredits: { availableCount: 2, credits: [
        { id: 'secret-credit-id', expiresAt: null }, { expiresAt: 1_810_000_000 }, { expiresAt: 1_800_000_000 }
      ] }
    }, observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.limitAccess[0].rateLimitReachedType, null);
    assert.deepEqual(account.resetCredits, { availableCount: 2, earliestExpiry: new Date(1_800_000_000_000).toISOString(), credits: [
      { title: null, description: null, grantedAt: null, expiresAt: null },
      { title: null, description: null, grantedAt: null, expiresAt: new Date(1_810_000_000_000).toISOString() },
      { title: null, description: null, grantedAt: null, expiresAt: new Date(1_800_000_000_000).toISOString() },
    ] });
    for (const secret of ['future_limit_private', 'secret-account-id', 'secret-server-error', 'secret-token', 'secret-credit-id']) {
      assert.equal(JSON.stringify(account).includes(secret), false);
    }
    validStatus([account]);
  }
  for (const reason of [null, undefined]) {
    assert.equal(normalize({ rateLimits: { primary: quota, rateLimitReachedType: reason } }).state, 'ok');
  }
});

test('drops every conflicting bucket ID instead of choosing an ambiguous access record', () => {
  const account = normalize({ rateLimitsByLimitId: {
    first: { limitId: 'same', limitName: 'First', primary: quota, rateLimitReachedType: 'rate_limit_reached' },
    second: { limitId: 'same', limitName: 'Second', primary: quota, spendControlReached: true },
    third: { limitId: 'same', primary: quota },
    healthy: { primary: quota }
  } });
  assert.equal(account.state, 'partial');
  assert.deepEqual(account.limitAccess.map((access) => access.limitId), ['healthy']);
  assert.deepEqual(account.windows.map((window) => window.limitId), ['healthy']);
  assert.ok(account.errors.some((error) => error.code === 'partial_limits'));
  validStatus([account]);
});

test('keeps bucket, window, string, plan, and deduplicated error bounds valid alongside healthy accounts', () => {
  const buckets = Object.fromEntries(Array.from({ length: 55 }, (_, index) => [`bucket_${index}`, {
    limitId: `bucket_${index}`, limitName: 'x'.repeat(128), primary: quota, secondary: quota,
    rateLimitReachedType: CODEX_LIMIT_REASONS[index % CODEX_LIMIT_REASONS.length], spendControlReached: true
  }]));
  const bounded = normalize({ ordinaryUsageAllowed: false, rateLimitsByLimitId: buckets });
  assert.equal(bounded.state, 'blocked');
  assert.equal(bounded.limitAccess.length, 50);
  assert.equal(bounded.windows.length, 100);
  assert.ok(bounded.limitAccess.every((access) => access.label.length === 128));
  assert.equal(bounded.errors.length, 8);
  assert.equal(new Set(bounded.errors.map((error) => error.code)).size, bounded.errors.length);
  const malformed = normalizeCodexRead({ ...profile, id: 'bad' }, { account: { type: 'chatgpt', planType: 'p'.repeat(81) } }, {
    rateLimitsByLimitId: {
      bad: { limitId: 'i'.repeat(129), limitName: 'l'.repeat(129), primary: { usedPercent: -1, resetsAt: -1, windowDurationMins: -1 } }
    }
  }, observedAt);
  assert.equal(malformed.state, 'partial');
  assert.equal(malformed.plan, null);
  assert.equal(malformed.limitAccess[0].limitId, 'bad');
  assert.equal(malformed.limitAccess[0].label, 'bad');
  assert.equal(malformed.windows[0].usedPercent, null);
  assert.equal(malformed.windows[0].durationMinutes, null);
  assert.equal(malformed.windows[0].resetsAt, null);
  const healthy = normalizeCodexRead({ ...profile, id: 'healthy' }, { account: { type: 'chatgpt', planType: 'p'.repeat(80) } }, {
    ordinaryUsageAllowed: true, rateLimits: { primary: quota }
  }, observedAt);
  assert.equal(healthy.state, 'ok');
  assert.equal(healthy.plan.length, 80);
  validStatus([bounded, malformed, healthy]);
});

test('reads two separate Codex homes through isolated app-server processes', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-codex-test-'));
  const first = join(root, 'first');
  const second = join(root, 'second');
  const binary = join(root, 'fake-codex');
  try {
    await Promise.all([mkdir(first), mkdir(second)]);
    await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
const isFirst = process.env.CODEX_HOME.endsWith('/first');
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  const result = message.method === 'account/read'
    ? { account: { type: 'chatgpt', planType: isFirst ? 'plus' : 'pro', email: 'do-not-output@example.com' } }
    : message.method === 'account/rateLimits/read'
      ? { rateLimits: { limitId: 'codex', primary: { usedPercent: isFirst ? 10 : 80, windowDurationMins: 300, resetsAt: 1800000000 } } }
      : {};
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o755 });
    const smoke = spawnSync(binary, ['app-server'], { input: '{"id":1,"method":"initialize"}\n', env: { ...process.env, CODEX_HOME: first }, encoding: 'utf8', timeout: 1000 });
    assert.equal(smoke.status, 0, smoke.stderr);
    assert.match(smoke.stdout, /"id":1/);
    const accounts = await Promise.all([
      readCodexProfile({ id: 'first', label: 'First', codexHome: first }, { codexBinary: binary }),
      readCodexProfile({ id: 'second', label: 'Second', codexHome: second }, { codexBinary: binary })
    ]);
    assert.deepEqual(accounts.map((item) => item.state), ['ok', 'ok'], JSON.stringify(accounts.map((item) => item.errors)));
    assert.deepEqual(accounts.map((item) => item.windows[0].usedPercent), [10, 80]);
    assert.deepEqual(accounts.map((item) => item.plan), ['plus', 'pro']);
    assert.deepEqual(accounts.map((account) => account.email), ['do-not-output@example.com', 'do-not-output@example.com']);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a closed Codex input pipe returns a per-account failure without crashing the host', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-codex-pipe-test-'));
  const binary = join(root, 'fake-codex');
  try {
    await writeFile(binary, `#!/usr/bin/env node
import { closeSync } from 'node:fs';
closeSync(0);
process.stdout.write(JSON.stringify({ id: 1, result: {} }) + '\\n');
setTimeout(() => process.exit(0), 2000);
`, { mode: 0o755 });
    const account = await readCodexProfile({ id: 'closed', label: 'Closed', codexHome: root }, { codexBinary: binary, timeoutMs: 1000 });
    assert.equal(account.state, 'unavailable');
    assert.equal(account.errors[0].code, 'unavailable');
    validStatus([account]);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('early Codex exit is an isolated unavailable result', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-codex-exit-test-'));
  const binary = join(root, 'fake-codex');
  try {
    await writeFile(binary, '#!/usr/bin/env node\nprocess.exit(0);\n', { mode: 0o755 });
    const account = await readCodexProfile({ ...profile, codexHome: root }, { codexBinary: binary, timeoutMs: 1000 });
    assert.equal(account.state, 'unavailable');
    assert.equal(account.errors[0].message, 'Codex app-server closed.');
    validStatus([account]);
  } finally { await rm(root, { recursive: true, force: true }); }
});

test('a failure after the initialize response prevents initialized and all later writes', async (t) => {
  const writes = mockTransport(t, (child, message, callback) => {
    child.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\n');
    child.stdin.emit('error', new Error('EPIPE private-transport-token'));
    child.emit('exit', 0);
    callback();
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
  assert.equal(account.state, 'unavailable');
  assert.equal(account.errors[0].message, 'Could not read Codex usage from this profile.');
  assert.deepEqual(writes, ['initialize']);
  assert.equal(JSON.stringify(account).includes('private-transport-token'), false);
  validStatus([account]);
});

test('an initialized notification write failure prevents the account request', async (t) => {
  const writes = mockTransport(t, (child, message, callback) => {
    if (message.method === 'initialize') {
      callback();
      child.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\n');
    } else {
      callback(new Error('EPIPE secret-notification-token'));
    }
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
  assert.equal(account.state, 'unavailable');
  assert.deepEqual(writes, ['initialize', 'initialized']);
  assert.equal(JSON.stringify(account).includes('secret-notification-token'), false);
  validStatus([account]);
});

test('a stdout error is contained by both the stream and readline interface without later writes', async (t) => {
  const writes = mockTransport(t, (child, message, callback) => {
    child.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\n');
    child.stdout.emit('error', new Error('private-stdout-error'));
    callback();
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
  assert.equal(account.state, 'unavailable');
  assert.deepEqual(writes, ['initialize']);
  assert.equal(JSON.stringify(account).includes('private-stdout-error'), false);
  validStatus([account]);
});

test('an exit after the account response prevents the limits request and latches the first failure', async (t) => {
  const writes = mockTransport(t, (child, message, callback) => {
    callback();
    if (message.id) {
      child.stdout.write(JSON.stringify({ id: message.id, result: message.method === 'account/read' ? { account: { type: 'chatgpt' } } : {} }) + '\n');
    }
    if (message.method === 'account/read') {
      child.emit('exit', 0);
      child.stdin.emit('error', new Error('EPIPE second-private-error'));
    }
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
  assert.equal(account.state, 'unavailable');
  assert.equal(account.errors[0].message, 'Codex app-server closed.');
  assert.deepEqual(writes, ['initialize', 'initialized', 'account/read']);
  validStatus([account]);
});

test('a transport failure during the account read rejects the pending request immediately', async (t) => {
  const writes = mockTransport(t, (child, message, callback) => {
    callback();
    if (message.method === 'initialize') child.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\n');
    if (message.method === 'account/read') child.stdin.emit('error', new Error('EPIPE pending-secret'));
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
  assert.equal(account.state, 'unavailable');
  assert.notEqual(account.errors[0].message, 'Codex app-server timed out.');
  assert.deepEqual(writes, ['initialize', 'initialized', 'account/read']);
  validStatus([account]);
});

test('request errors and malformed responses are safe failures distinct from transport failures', async (t) => {
  for (const response of [
    { error: { code: 500, message: 'secret-server-error' } },
    {},
    'invalid-json',
    []
  ]) {
    await t.test(JSON.stringify(response), async (t) => {
      const writes = mockTransport(t, (child, message, callback) => {
        callback();
        child.stdout.write((response === 'invalid-json' ? 'not-json-secret' : JSON.stringify(Array.isArray(response) ? response : { id: message.id, ...response })) + '\n');
      });
      const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 1000 });
      assert.equal(account.state, 'unavailable');
      assert.equal(account.errors[0].message, response.error ? 'Codex app-server request failed.' : 'Codex app-server response malformed.');
      assert.deepEqual(writes, ['initialize']);
      assert.equal(JSON.stringify(account).includes('secret'), false);
      validStatus([account]);
    });
  }
});

test('ignores server-initiated requests that reuse a pending response ID', async (t) => {
  mockTransport(t, (child, message, callback) => {
    callback();
    if (message.id === undefined) return;
    // A server request with the same numeric ID must not resolve or reject the client's request.
    child.stdout.write(JSON.stringify({ id: message.id, method: 'item/tool/requestUserInput', params: {} }) + '\n');
    const result = message.method === 'account/read' ? { account: { type: 'chatgpt', planType: 'plus' } }
      : message.method === 'account/rateLimits/read' ? { rateLimits: { primary: quota } } : {};
    child.stdout.write(JSON.stringify({ id: message.id, result }) + '\n');
  });
  const account = await readCodexProfile({ ...profile, codexHome: tmpdir() }, { timeoutMs: 2000 });
  assert.equal(account.state, 'ok', JSON.stringify(account.errors));
  assert.equal(account.windows[0].usedPercent, 25);
});

test('redeems a banked reset through the documented consume method with the idempotency key', async (t) => {
  const { consumeCodexResetCredit } = await import('../dist/codex.js');
  const writes = mockTransport(t, (child, message, callback) => {
    callback();
    if (message.id === undefined) return;
    if (message.method === 'account/rateLimits/read') {
      child.stdout.write(JSON.stringify({ id: message.id, result: { rateLimitResetCredits: { availableCount: 2, credits: [
        { id: 'later', status: 'available', expiresAt: 1_900_000_000 }, { id: 'sooner', status: 'available', expiresAt: 1_800_000_000 }, { id: 'used', status: 'redeemed', expiresAt: 1 },
      ] } } }) + '\n');
    } else if (message.method === 'account/rateLimitResetCredit/consume') {
      assert.deepEqual(message.params, { idempotencyKey: '00000000-0000-4000-8000-000000000001', creditId: 'sooner' });
      child.stdout.write(JSON.stringify({ id: message.id, result: { outcome: 'reset' } }) + '\n');
    } else child.stdout.write(JSON.stringify({ id: message.id, result: {} }) + '\n');
  });
  const outcome = await consumeCodexResetCredit({ ...profile, codexHome: tmpdir() }, { idempotencyKey: '00000000-0000-4000-8000-000000000001', timeoutMs: 2000 });
  assert.equal(outcome, 'reset');
  assert.deepEqual(writes, ['initialize', 'initialized', 'account/rateLimits/read', 'account/rateLimitResetCredit/consume']);
});
