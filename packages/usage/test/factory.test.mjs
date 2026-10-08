import assert from 'node:assert/strict';
import { test } from 'node:test';
import { createCipheriv, randomBytes } from 'node:crypto';
import { mkdtemp, mkdir, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { decryptFactoryCredential, normalizeFactoryLimits, readFactoryLocalAuth, readFactoryProfile } from '../dist/factory.js';
import { createUsageStatus, isUsageStatus } from '../dist/index.js';

const encrypt = (value, key) => {
  const iv = randomBytes(16);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const data = Buffer.concat([cipher.update(JSON.stringify(value)), cipher.final()]);
  return [iv, cipher.getAuthTag(), data].map((part) => part.toString('base64')).join(':');
};
const jwt = (claims) => `h.${Buffer.from(JSON.stringify(claims)).toString('base64url')}.s`;
const limits = { usesTokenRateLimitsBilling: true, extraUsageBalanceCents: 1250, limits: {
  standard: { fiveHour: { usedPercent: 12, windowEnd: '2026-10-08T15:00:00Z' }, weekly: { usedPercent: 40, windowEnd: '2026-10-12T00:00:00Z' }, monthly: { usedPercent: 70, windowEnd: '2026-11-01T00:00:00Z' } },
  core: { fiveHour: { usedPercent: 3, windowEnd: '2026-10-08T15:00:00Z' } },
} };
const profile = (home, extra = {}) => ({ id: 'droid_a', label: 'Work', provider: 'factory-droid', factoryHome: home, ...extra });
const response = (status, body) => new Response(JSON.stringify(body), { status, headers: { 'content-type': 'application/json' } });

async function home(t, layout = 'keychain', claims = { exp: Date.now() / 1000 + 3600, email: 'dev@example.com' }) {
  const root = await mkdtemp(join(tmpdir(), 'subset-factory-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  await mkdir(join(root, '.factory'));
  const key = randomBytes(32);
  const contents = encrypt({ access_token: jwt(claims), active_organization_id: 'org_1', region: 'global', refresh_token: 'never-used' }, key);
  if (layout === 'keychain') await writeFile(join(root, '.factory', 'auth.v2.loginkeychain'), contents);
  else { await writeFile(join(root, '.factory', 'auth.v2.file'), contents); await writeFile(join(root, '.factory', 'auth.v2.key'), key.toString('base64')); }
  return { root, key };
}

test('decrypts the v2 store and rejects tampering', () => {
  const key = randomBytes(32);
  const contents = encrypt({ access_token: 'a' }, key);
  assert.deepEqual(decryptFactoryCredential(contents, key), { access_token: 'a' });
  // Flip one bit of the ciphertext itself, so only GCM authentication can detect it.
  const [iv, tag, data] = contents.split(':');
  const tampered = Buffer.from(data, 'base64');
  tampered[0] ^= 1;
  assert.equal(decryptFactoryCredential([iv, tag, tampered.toString('base64')].join(':'), key), null);
  assert.equal(decryptFactoryCredential(contents, randomBytes(32)), null);
});

test('reads keychain and key-file layouts without exposing the refresh token', async (t) => {
  const keychain = await home(t, 'keychain');
  const requests = [];
  const auth = await readFactoryLocalAuth(keychain.root, async (service, account) => { requests.push([service, account]); return keychain.key.toString('base64'); });
  assert.equal(auth.orgId, 'org_1');
  assert.equal(auth.email, 'dev@example.com');
  assert.deepEqual(requests, [['Factory CLI', 'auth-encryption-key-security-cli']]);
  assert.doesNotMatch(JSON.stringify(auth), /never-used/);
  const file = await home(t, 'file');
  assert.equal((await readFactoryLocalAuth(file.root, async () => null)).orgId, 'org_1');
  assert.equal(await readFactoryLocalAuth(keychain.root, async () => null), 'unreadable');
  assert.equal(await readFactoryLocalAuth(join(keychain.root, 'none')), null);
});

test('normalizes standard and core windows plus the extra usage balance', () => {
  const account = normalizeFactoryLimits(profile('/h'), limits, new Date('2026-10-08T12:00:00Z'), { email: null, source: 'x' });
  assert.deepEqual(account.windows.map((window) => [window.limitId, window.usedPercent, window.durationMinutes]), [
    ['standard_fiveHour', 12, 300], ['standard_weekly', 40, 10080], ['standard_monthly', 70, 43200], ['core_fiveHour', 3, 300],
  ]);
  assert.deepEqual(account.balances, [{ kind: 'provider-reported-balance', currency: 'USD', amount: 12.5, label: 'Extra usage balance' }]);
  assert.equal(isUsageStatus(createUsageStatus([account])), true);
  assert.equal(normalizeFactoryLimits(profile('/h'), { usesTokenRateLimitsBilling: false }, new Date(), { email: null, source: 'x' }).state, 'unsupported');
});

test('uses the local sign-in only when allowed, otherwise the named API key', async (t) => {
  const keychain = await home(t, 'keychain');
  const calls = [];
  const fetch = async (url, init) => {
    calls.push([url, init.headers.Authorization.slice(0, 12), init.headers['X-Factory-Org-Id'] ?? null]);
    if (url.endsWith('/api/cli/whoami')) return response(200, { orgId: 'org_key', userId: 'u', region: 'global' });
    return response(200, limits);
  };
  const readSecret = async () => keychain.key.toString('base64');
  const local = await readFactoryProfile(profile(keychain.root), { localCredentials: true, fetch, readSecret });
  assert.equal(local.state, 'ok');
  assert.equal(local.source, 'Factory rate limits (local sign-in)');
  assert.equal(calls.at(-1)[2], 'org_1');
  const off = await readFactoryProfile(profile(keychain.root), { localCredentials: false, fetch, readSecret });
  assert.equal(off.state, 'unauthorized');
  assert.match(off.errors[0].message, /turn on local sign-ins/);
  const keyed = await readFactoryProfile(profile(keychain.root, { credentialEnv: 'FACTORY_KEY' }), { localCredentials: false, fetch, readSecret, env: { FACTORY_KEY: 'fk-secret' } });
  assert.equal(keyed.state, 'ok');
  assert.equal(keyed.source, 'Factory rate limits (API key)');
  assert.deepEqual(calls.slice(-2).map((call) => call[0].split('/api/')[1]), ['cli/whoami', 'billing/limits']);
  assert.doesNotMatch(JSON.stringify([local, keyed]), /fk-secret|never-used/);
  // A configured key wins over the local sign-in, which may be another account.
  const keyedWithLocal = await readFactoryProfile(profile(keychain.root, { credentialEnv: 'FACTORY_KEY' }), { localCredentials: true, fetch, readSecret, env: { FACTORY_KEY: 'fk-secret' } });
  assert.equal(keyedWithLocal.source, 'Factory rate limits (API key)');
  assert.equal(calls.at(-1)[2], 'org_key');
  const missingKey = await readFactoryProfile(profile(keychain.root, { credentialEnv: 'FACTORY_KEY' }), { localCredentials: true, fetch, readSecret, env: {} });
  assert.equal(missingKey.state, 'unauthorized');
  assert.match(missingKey.errors[0].message, /variable is not set/);
  const rejected = await readFactoryProfile(profile(keychain.root), { localCredentials: true, readSecret, fetch: async () => response(401, {}) });
  assert.equal(rejected.state, 'unauthorized');
  const expired = await home(t, 'keychain', { exp: Date.now() / 1000 - 10 });
  const stale = await readFactoryProfile(profile(expired.root), { localCredentials: true, fetch, readSecret: async () => expired.key.toString('base64') });
  assert.match(stale.errors[0].message, /expired/);
});

test('an unused Factory window without an end is not partial data', () => {
  const account = normalizeFactoryLimits(profile('/h'), { limits: { standard: { fiveHour: { usedPercent: 0 }, monthly: { usedPercent: 1, windowEnd: '2026-11-01T00:00:00Z' } } } }, new Date(), { email: null, source: 'x' });
  assert.equal(account.state, 'ok');
  assert.equal(normalizeFactoryLimits(profile('/h'), { limits: { standard: { fiveHour: { usedPercent: 5 } } } }, new Date(), { email: null, source: 'x' }).state, 'partial');
});
