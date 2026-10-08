import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdir, mkdtemp, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createAccounts } from '../src/accounts.mjs';

test('connects a second ChatGPT account in its own Codex home and removes only its managed home', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset-accounts-test-'));
  const binary = join(root, 'fake-codex');
  const currentHome = join(root, 'current');
  const profilesFile = join(root, 'config', 'profiles.json');
  const managedRoot = join(root, 'managed');
  let accounts;
  try {
    await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  let result = {};
  if (message.method === 'account/read') result = { account: { type: 'chatgpt', planType: 'plus', email: 'private@example.com' } };
  if (message.method === 'account/rateLimits/read') result = { rateLimits: { primary: { usedPercent: 20 } } };
  if (message.method === 'account/login/start') {
    result = { type: 'chatgpt', loginId: 'test-login', authUrl: 'https://chatgpt.com/test-sign-in' };
    setTimeout(() => process.stdout.write(JSON.stringify({ method: 'account/login/completed', params: { loginId: 'test-login', success: true } }) + '\\n'), 30);
  }
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o700 });
    await mkdir(currentHome);
    accounts = createAccounts({ profilesFile, managedRoot, currentHome, codexBinary: binary, loginTimeoutMs: 2000 });
    const current = await accounts.addCurrent();
    assert.equal(current.id, 'current');
    const connection = await accounts.startLogin('Work account');
    assert.equal(new URL(connection.authUrl).hostname, 'chatgpt.com');
    let state;
    for (let i = 0; i < 30; i++) {
      state = accounts.connection(connection.id);
      if (state.state === 'connected' || state.state === 'error') break;
      await new Promise((resolve) => setTimeout(resolve, 30));
    }
    assert.equal(state.state, 'connected', JSON.stringify(state));
    assert.equal(accounts.activeConnection(), null);
    const profiles = await accounts.profiles();
    assert.equal(profiles.length, 2);
    assert.notEqual(profiles[0].codexHome, profiles[1].codexHome);
    assert.equal(profiles[0].provider, 'codex-chatgpt');
    assert.equal(profiles[1].provider, 'codex-chatgpt');
    assert.equal(profiles[1].managed, true);
    assert.equal(JSON.stringify(profiles).includes('private@example.com'), false);
    assert.deepEqual(await accounts.list(), [
      { id: current.id, label: '', provider: 'codex-chatgpt', managed: false, current: true },
      { id: connection.id, label: 'Work account', provider: 'codex-chatgpt', managed: true, current: false },
    ]);
    assert.equal((await stat(profilesFile)).mode & 0o077, 0);
    await accounts.removeProfile(connection.id);
    assert.equal((await accounts.profiles()).length, 1);
    await assert.rejects(stat(profiles[1].codexHome), { code: 'ENOENT' });
    assert.equal((await stat(currentHome)).isDirectory(), true);
    assert.equal((await readFile(profilesFile, 'utf8')).includes('Work account'), false);
  } finally {
    await accounts?.close();
    await rm(root, { recursive: true, force: true });
  }
});

for (const action of ['cancel', 'timeout', 'close']) {
  test(`Codex ${action} cleans only its pending managed home and preserves other providers`, async (t) => {
    const root = await mkdtemp(join(tmpdir(), 'subset-login-test-'));
    const binary = join(root, 'fake-codex');
    const currentHome = join(root, 'current');
    const managedRoot = join(root, 'managed');
    const accounts = createAccounts({ profilesFile: join(root, 'profiles.json'), managedRoot, snapshotRoot: join(root, 'snapshots'), currentHome, codexBinary: binary, loginTimeoutMs: action === 'timeout' ? 70 : 2000 });
    t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
    await mkdir(currentHome);
    await writeFile(join(currentHome, 'keep'), 'existing-account');
    await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  const result = message.method === 'account/login/start'
    ? { type: 'chatgpt', loginId: 'pending-login', authUrl: 'https://chatgpt.com/test-sign-in' } : {};
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o700 });
    const snapshot = await accounts.addProvider({ provider: 'claude-code', label: 'Claude' });
    const login = await accounts.startLogin('Pending Codex');
    assert.equal(login.state, 'pending');
    await assert.rejects(accounts.startLogin('Overlapping'), /Finish or cancel the current sign-in first/);
    if (action === 'cancel') assert.equal((await accounts.cancelLogin(login.id)).state, 'cancelled');
    else if (action === 'close') await accounts.close();
    else {
      for (let index = 0; index < 30 && accounts.connection(login.id).state !== 'error'; index++) await new Promise((resolve) => setTimeout(resolve, 20));
      assert.equal(accounts.connection(login.id).state, 'error');
      assert.equal(accounts.connection(login.id).error, 'ChatGPT sign-in timed out.');
      await new Promise((resolve) => setTimeout(resolve, 20));
    }
    assert.deepEqual(await readdir(managedRoot), []);
    assert.equal(accounts.activeConnection(), null);
    assert.equal(await readFile(join(currentHome, 'keep'), 'utf8'), 'existing-account');
    assert.deepEqual((await accounts.profiles()).map((profile) => profile.id), [snapshot.id]);
    await assert.rejects(accounts.cancelLogin(login.id), /No active sign-in was found/);
  });
}

test('recovers only the active pending login and cancels its recovered ID across retries', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-login-recovery-test-'));
  const binary = join(root, 'fake-codex');
  const accounts = createAccounts({ profilesFile: join(root, 'profiles.json'), managedRoot: join(root, 'managed'), codexBinary: binary, loginTimeoutMs: 2000 });
  t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
  await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  const result = message.method === 'account/login/start'
    ? { type: 'chatgpt', loginId: 'private-login-id', authUrl: 'HTTPS://CHATGPT.COM:443/test-sign-in', accessToken: 'private-access-token', refreshToken: 'private-refresh-token', home: process.env.CODEX_HOME, email: 'private@example.com' } : {};
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o700 });
  assert.equal(accounts.activeConnection(), null);
  const ids = new Set();
  for (let retry = 0; retry < 3; retry++) {
    const started = await accounts.startLogin('Private account label');
    assert.equal(started.authUrl, 'https://chatgpt.com/test-sign-in');
    assert.equal(ids.has(started.id), false);
    ids.add(started.id);
    const recovered = accounts.activeConnection();
    assert.deepEqual(recovered, { id: started.id, state: 'pending', error: null, authUrl: started.authUrl });
    assert.deepEqual(accounts.connection(recovered.id), { id: recovered.id, state: 'pending', error: null });
    const serialized = JSON.stringify(recovered);
    for (const privateValue of ['private-login-id', 'private-access-token', 'private-refresh-token', 'private@example.com', 'Private account label', root]) {
      assert.equal(serialized.includes(privateValue), false);
    }
    recovered.authUrl = 'https://example.com';
    recovered.state = 'connected';
    assert.deepEqual(accounts.activeConnection(), { id: started.id, state: 'pending', error: null, authUrl: started.authUrl });
    await assert.rejects(accounts.startLogin('Overlapping'), /Finish or cancel the current sign-in first/);
    assert.deepEqual(await accounts.cancelLogin(recovered.id), { id: recovered.id, state: 'cancelled', error: null });
    assert.equal(accounts.activeConnection(), null);
  }
  assert.deepEqual(await readdir(join(root, 'managed')), []);
  assert.deepEqual(await accounts.profiles(), []);
});

test('recovers starting and validating states without private fields, then clears recovery on success', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-login-recovery-states-test-'));
  const binary = join(root, 'fake-codex');
  const accounts = createAccounts({ profilesFile: join(root, 'profiles.json'), managedRoot: join(root, 'managed'), codexBinary: binary, loginTimeoutMs: 2000 });
  t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
  await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
import { existsSync } from 'node:fs';
import { join, dirname } from 'node:path';
const root = dirname(dirname(process.env.CODEX_HOME));
const waitFor = async (name) => {
  while (!existsSync(join(root, name))) await new Promise((resolve) => setTimeout(resolve, 10));
};
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  let result = {};
  if (message.method === 'initialize') await waitFor('start');
  if (message.method === 'account/login/start') {
    result = { type: 'chatgpt', loginId: 'private-login-id', authUrl: 'https://auth.openai.com/test-sign-in' };
    process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
    await waitFor('complete');
    process.stdout.write(JSON.stringify({ method: 'account/login/completed', params: { loginId: 'private-login-id', success: true } }) + '\\n');
    continue;
  }
  if (message.method === 'account/read') {
    await waitFor('validate');
    result = { account: { type: 'chatgpt', email: 'private@example.com', accessToken: 'private-token' } };
  }
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o700 });
  const starting = accounts.startLogin('Private label');
  t.after(() => starting.catch(() => {}));
  let recovered;
  for (let index = 0; index < 100; index++) {
    recovered = accounts.activeConnection();
    if (recovered) break;
    await new Promise((resolve) => setTimeout(resolve, 10));
  }
  assert.ok(recovered);
  assert.deepEqual(recovered, { id: recovered.id, state: 'starting', error: null, authUrl: null });
  await writeFile(join(root, 'start'), '');
  const started = await starting;
  assert.equal(recovered.id, started.id);
  assert.deepEqual(accounts.activeConnection(), { id: started.id, state: 'pending', error: null, authUrl: started.authUrl });
  await writeFile(join(root, 'complete'), '');
  for (let index = 0; index < 100 && accounts.connection(started.id).state === 'pending'; index++) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.deepEqual(accounts.activeConnection(), { id: started.id, state: 'validating', error: null, authUrl: started.authUrl });
  assert.deepEqual(accounts.connection(started.id), { id: started.id, state: 'validating', error: null });
  await writeFile(join(root, 'validate'), '');
  for (let index = 0; index < 100 && accounts.connection(started.id).state === 'validating'; index++) await new Promise((resolve) => setTimeout(resolve, 10));
  assert.equal(accounts.connection(started.id).state, 'connected');
  assert.equal(accounts.activeConnection(), null);
});

test('cancelling while a sign-in is starting does not resurrect it or leave a managed home', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-login-starting-test-'));
  const binary = join(root, 'fake-codex');
  const managedRoot = join(root, 'managed');
  const accounts = createAccounts({ profilesFile: join(root, 'profiles.json'), managedRoot, snapshotRoot: join(root, 'snapshots'), currentHome: join(root, 'current'), codexBinary: binary, loginTimeoutMs: 2000 });
  t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
  await writeFile(binary, `#!/usr/bin/env node
import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  const result = message.method === 'account/login/start'
    ? { type: 'chatgpt', loginId: 'late-login', authUrl: 'https://chatgpt.com/test-sign-in' } : {};
  setTimeout(() => process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n'), 600);
}
`, { mode: 0o700 });
  // Observe the outcome now: the rejection can land while cancelLogin is still awaited.
  const started = accounts.startLogin('Slow Codex').then(() => null, (error) => error);
  let active;
  for (let index = 0; index < 400 && !active; index++) {
    active = accounts.activeConnection();
    if (!active) await new Promise((resolve) => setTimeout(resolve, 5));
  }
  assert.equal(active.state, 'starting');
  assert.equal((await accounts.cancelLogin(active.id)).state, 'cancelled');
  assert.match((await started)?.message ?? '', /Sign-in was cancelled/);
  await new Promise((resolve) => setTimeout(resolve, 700));
  assert.equal(accounts.connection(active.id).state, 'cancelled');
  assert.equal(accounts.activeConnection(), null);
  assert.deepEqual(await readdir(managedRoot).catch(() => []), []);
  // A new sign-in drops the finished record.
  const next = await accounts.startLogin('Retry');
  assert.throws(() => accounts.connection(active.id), /Sign-in was not found/);
  await accounts.cancelLogin(next.id);
});

test('concurrent sign-in requests start only one sign-in', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-accounts-test-'));
  const accounts = createAccounts({ profilesFile: join(root, 'profiles.json'), managedRoot: join(root, 'managed'), currentHome: join(root, 'current'), codexBinary: join(root, 'missing-codex'), loginTimeoutMs: 500 });
  t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
  const results = await Promise.allSettled([accounts.startLogin('One'), accounts.startLogin('Two'), accounts.startLogin('Three')]);
  const busy = results.filter((result) => result.status === 'rejected' && /Finish or cancel/.test(result.reason.message));
  assert.equal(busy.length, 2);
});
