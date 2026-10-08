import assert from 'node:assert/strict';
import { test } from 'node:test';
import { normalizeCursorSpend, readCursorProfile } from '../dist/cursor.js';

const profile = { id: 'work', label: 'Work', provider: 'cursor', credentialEnv: 'CURSOR_WORK_KEY', cursorUserId: 'user_Work123' };
const key = 'test-private-work-key';
const options = { env: { CURSOR_WORK_KEY: key } };
const observedAt = new Date('2026-10-01T12:00:00Z');
const cycleStart = Date.parse('2026-09-15T00:00:00Z');
const member = (userId = profile.cursorUserId, fields = {}) => ({
  userId, name: 'Private display name', email: 'private@example.test', spendCents: 2450.125487,
  overallSpendCents: 4450.125487, effectivePerUserLimitDollars: 100, monthlyLimitDollars: 200,
  hardLimitOverrideDollars: 100, ...fields
});
const page = (rows = [member()], fields = {}) => ({ teamMemberSpend: rows, subscriptionCycleStart: cycleStart, totalPages: 1, ...fields });
const json = (data, init) => new Response(JSON.stringify(data), init);
const assertPrivate = (account, secrets = [key, profile.cursorUserId, 'private@example.test', 'Private display name']) => {
  const output = JSON.stringify(account);
  for (const secret of secrets) assert.equal(output.includes(secret), false, `Output must omit ${secret}`);
};

test('normalizes fractional cents as spend, never as subscription quota', () => {
  const account = normalizeCursorSpend(profile, page(), observedAt);
  assert.equal(account.state, 'ok');
  assert.equal(account.source, 'Cursor team Admin API');
  assert.equal(account.observedAt, observedAt.toISOString());
  assert.deepEqual(account.windows, []);
  assert.equal(account.resetCredits, null);
  assert.deepEqual(account.spend, {
    kind: 'provider-reported-spend', currency: 'USD', used: 2450.125487 / 100, includedUsed: (4450.125487 - 2450.125487) / 100,
    limit: 100, periodStart: '2026-09-15T00:00:00.000Z', periodEnd: null
  });
  assert.equal(account.plan, null);
  assertPrivate(account);
});

test('keeps absent fields unknown and preserves a reported zero spending cap', () => {
  const account = normalizeCursorSpend(profile, page([member(undefined, {
    spendCents: 0, overallSpendCents: undefined, effectivePerUserLimitDollars: 0, hardLimitOverrideDollars: 0
  })]), observedAt);
  assert.equal(account.state, 'ok');
  assert.equal(account.spend.used, 0);
  assert.equal(account.spend.limit, 0);
  assert.equal(account.spend.includedUsed, null);
  const unknown = normalizeCursorSpend(profile, page([member(undefined, {
    effectivePerUserLimitDollars: undefined, monthlyLimitDollars: 200, hardLimitOverrideDollars: 0
  })], { subscriptionCycleStart: undefined }), observedAt);
  assert.equal(unknown.spend.limit, null);
  assert.equal(unknown.spend.periodStart, null);
  assert.equal(unknown.spend.periodEnd, null);
});

test('malformed spend fields retain valid fields as a safe partial result', () => {
  for (const spendCents of [-1, '20', null, undefined, Infinity, NaN, Number.MAX_SAFE_INTEGER + 1]) {
    const account = normalizeCursorSpend(profile, page([member(undefined, { spendCents })]), observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.spend.used, null);
    assert.equal(account.spend.includedUsed, null);
    assert.equal(account.spend.limit, 100);
    assertPrivate(account);
  }
  for (const fields of [
    { overallSpendCents: -1 }, { overallSpendCents: 20 }, { overallSpendCents: 'private@example.test' },
    { effectivePerUserLimitDollars: '100' }, { effectivePerUserLimitDollars: -1 }
  ]) {
    const account = normalizeCursorSpend(profile, page([member(undefined, fields)]), observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.spend.used, 2450.125487 / 100);
    assertPrivate(account);
  }
  for (const subscriptionCycleStart of [-1, '2026-09-15', 1e30, 0.5]) {
    const account = normalizeCursorSpend(profile, page(undefined, { subscriptionCycleStart }), observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.spend.periodStart, null);
  }
});

test('matches only exact encoded user ID, not email, display name or numeric ID', () => {
  for (const userId of ['user_work123', 'Work', 123, undefined]) {
    const account = normalizeCursorSpend(profile, page([member(userId, { userId, name: profile.label, email: profile.cursorUserId })]), observedAt);
    assert.equal(account.state, 'partial');
    assert.equal(account.errors[0].code, 'missing_user');
    assert.equal(account.spend, undefined);
    assertPrivate(account);
  }
  const duplicate = normalizeCursorSpend(profile, page([member(), member()]), observedAt);
  assert.equal(duplicate.errors[0].code, 'ambiguous_user');
  assert.equal(duplicate.spend, undefined);
});

test('isolates keys and exact user mapping across two configured accounts', async () => {
  const other = { ...profile, id: 'personal-team', label: 'Personal team', credentialEnv: 'CURSOR_OTHER_KEY', cursorUserId: 'user_Other456' };
  const otherKey = 'test-private-other-key';
  const env = { CURSOR_WORK_KEY: key, CURSOR_OTHER_KEY: otherKey, CURSOR_API_KEY: 'must-not-use' };
  const seen = [];
  const fetch = async (url, init) => {
    assert.equal(url, 'https://api.cursor.com/teams/spend');
    assert.equal(init.method, 'POST');
    assert.equal(init.redirect, 'error');
    assert.equal(init.credentials, 'omit');
    assert.deepEqual(JSON.parse(init.body), { page: 1, pageSize: 100 });
    const decoded = Buffer.from(init.headers.Authorization.slice(6), 'base64').toString();
    seen.push(decoded);
    assert.equal(decoded.endsWith(':'), true);
    return json(page([member(), member(other.cursorUserId, { spendCents: decoded === `${otherKey}:` ? 900 : 500 })]));
  };
  const accounts = await Promise.all([readCursorProfile(profile, { fetch, env }), readCursorProfile(other, { fetch, env })]);
  assert.deepEqual(seen.sort(), [`${key}:`, `${otherKey}:`].sort());
  assert.deepEqual(accounts.map((account) => account.state), ['ok', 'ok']);
  assert.deepEqual(accounts.map((account) => account.spend.used), [2450.125487 / 100, 9]);
  for (const account of accounts) assertPrivate(account, [key, otherKey, profile.cursorUserId, other.cursorUserId, 'private@example.test']);
});

test('paginates through all bounded pages while retaining only the exact member', async () => {
  const seen = [];
  const account = await readCursorProfile(profile, { ...options, fetch: async (_, init) => {
    const request = JSON.parse(init.body);
    seen.push(request.page);
    return json(page(request.page === 2 ? [member()] : [member('user_Else')], { totalPages: 3, totalMembers: 3 }));
  } });
  assert.deepEqual(seen, [1, 2, 3]);
  assert.equal(account.state, 'ok');
  assertPrivate(account);
});

test('rejects ambiguous member records on different pages without combining or exposing them', async () => {
  let calls = 0;
  const account = await readCursorProfile(profile, { ...options, fetch: async () => {
    calls++;
    return json(page([member(undefined, { spendCents: calls * 100 })], { totalPages: 2, totalMembers: 2 }));
  } });
  assert.equal(calls, 2);
  assert.equal(account.errors[0].code, 'ambiguous_user');
  assert.equal(account.spend, undefined);
  assertPrivate(account);
});

test('nonexistent member remains unavailable after all reported pages', async () => {
  let calls = 0;
  const account = await readCursorProfile(profile, { ...options, fetch: async () => {
    calls++;
    return json(page([member('user_Else')], { totalPages: 2, totalMembers: 2 }));
  } });
  assert.equal(calls, 2);
  assert.equal(account.state, 'partial');
  assert.equal(account.errors[0].code, 'missing_user');
  assertPrivate(account);
});

test('rejects malformed or excessive pagination and row counts', async () => {
  for (const fields of [{ totalPages: 21 }, { totalMembers: 2001 }, { totalPages: 1e10 }]) {
    let calls = 0;
    const account = await readCursorProfile(profile, { ...options, fetch: async () => { calls++; return json(page([], fields)); } });
    assert.equal(calls, 1);
    assert.equal(account.errors[0].code, 'pagination_limit');
  }
  for (const data of [null, {}, page(undefined, { totalPages: '2' }), page(undefined, { totalPages: -1 }),
    page(undefined, { totalPages: 0 }), page(undefined, { totalMembers: '1' }), page(undefined, { totalMembers: 0 }),
    page(Array.from({ length: 101 }, () => member()))]) {
    const account = await readCursorProfile(profile, { ...options, fetch: async () => json(data) });
    assert.equal(account.errors[0].code, 'malformed_response');
    assertPrivate(account);
  }
  let calls = 0;
  const inconsistent = await readCursorProfile(profile, { ...options, fetch: async () => json(page([member('user_Else')], { totalPages: ++calls === 1 ? 3 : 2 })) });
  assert.equal(calls, 2);
  assert.equal(inconsistent.errors[0].code, 'malformed_response');
});

test('uses only the explicitly selected environment key and validates configuration', async () => {
  let calls = 0;
  const fetch = async () => { calls++; throw new Error('must not call'); };
  for (const env of [{}, { CURSOR_API_KEY: key }, Object.create({ CURSOR_WORK_KEY: key })]) {
    const account = await readCursorProfile(profile, { env, fetch });
    assert.equal(account.errors[0].code, 'missing_credentials');
    assert.equal(account.state, 'unauthorized');
  }
  for (const changed of [{ id: 123 }, { credentialEnv: '../secret' }, { cursorUserId: 'private@example.test' }, { cursorUserId: 'user_%2F' }, { cursorUserId: 123 }]) {
    const account = await readCursorProfile({ ...profile, ...changed }, { ...options, fetch });
    assert.equal(account.errors[0].code, 'invalid_profile');
  }
  for (const value of ['contains:password', 'line\nbreak', ' space']) {
    const account = await readCursorProfile(profile, { env: { CURSOR_WORK_KEY: value }, fetch });
    assert.equal(account.errors[0].code, 'invalid_credentials');
  }
  assert.equal(calls, 0);
});

test('safe HTTP errors discard provider bodies, keys, emails, and identifiers', async () => {
  for (const [status, state, code] of [[401, 'unauthorized', 'unauthorized'], [403, 'unauthorized', 'forbidden'], [429, 'unavailable', 'rate_limited'], [500, 'unavailable', 'request_failed'], [302, 'unavailable', 'redirect_rejected']]) {
    const account = await readCursorProfile(profile, { ...options, fetch: async () => new Response(`${key} ${profile.cursorUserId} private@example.test`, { status }) });
    assert.equal(account.state, state);
    assert.equal(account.errors[0].code, code);
    assert.equal(account.observedAt, null);
    assertPrivate(account);
  }
  const account = await readCursorProfile(profile, { ...options, fetch: async () => { throw new Error(`${key} ${profile.cursorUserId} private@example.test`); } });
  assert.equal(account.errors[0].code, 'request_failed');
  assertPrivate(account);
});

test('rejects invalid JSON and bounds actual response bytes, even without content-length', async () => {
  const malformed = await readCursorProfile(profile, { ...options, fetch: async () => new Response(`${key} {`) });
  assert.equal(malformed.errors[0].code, 'malformed_response');
  assertPrivate(malformed);
  for (const response of [new Response('x'.repeat(1024 * 1024 + 1)), new Response('{}', { headers: { 'content-length': String(1024 * 1024 + 1) } })]) {
    const account = await readCursorProfile(profile, { ...options, fetch: async () => response });
    assert.equal(account.errors[0].code, 'response_too_large');
  }
});

test('bounds aggregate response bytes across pages and accepts empty teams', async () => {
  let calls = 0;
  const account = await readCursorProfile(profile, { ...options, fetch: async () => {
    calls++;
    return json(page([], { totalPages: 10, padding: 'x'.repeat(900000) }));
  } });
  assert.equal(calls, 5);
  assert.equal(account.errors[0].code, 'response_too_large');
  const empty = await readCursorProfile(profile, { ...options, fetch: async () => json(page([], { totalPages: 0, totalMembers: 0 })) });
  assert.equal(empty.errors[0].code, 'missing_user');
  assert.equal(empty.spend, undefined);
});

test('never treats a mocked redirected response as authorized data', async () => {
  const response = json(page());
  Object.defineProperty(response, 'redirected', { value: true });
  const account = await readCursorProfile(profile, { ...options, fetch: async () => response });
  assert.equal(account.errors[0].code, 'redirect_rejected');
  assert.equal(account.spend, undefined);
});

test('deadline covers a fetch that ignores abort and cancels its signal', async () => {
  let signal;
  const account = await readCursorProfile(profile, { ...options, timeoutMs: 20, fetch: (_, init) => {
    signal = init.signal;
    return new Promise(() => {});
  } });
  assert.equal(account.errors[0].code, 'timeout');
  assert.equal(signal.aborted, true);
  assertPrivate(account);
});

test('deadline covers stalled response body and cancels the read', async () => {
  let cancelled = false;
  const account = await readCursorProfile(profile, { ...options, timeoutMs: 20, fetch: async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{')); },
    cancel() { cancelled = true; }
  })) });
  assert.equal(account.errors[0].code, 'timeout');
  assert.equal(cancelled, true);
});

test('deadline is shared across pages instead of resetting for each request', async () => {
  let calls = 0;
  const signals = [];
  const account = await readCursorProfile(profile, { ...options, timeoutMs: 45, fetch: async (_, init) => {
    calls++;
    signals.push(init.signal);
    await new Promise((resolve) => setTimeout(resolve, 30));
    return json(page([member('user_Else')], { totalPages: 3 }));
  } });
  assert.equal(account.errors[0].code, 'timeout');
  assert.equal(calls, 2);
  assert.equal(signals[0], signals[1]);
  await new Promise((resolve) => setTimeout(resolve, 40));
  assert.equal(calls, 2, 'Late fetch completion must not start another request');
});
