import assert from 'node:assert/strict';
import { test } from 'node:test';
import { spawn, spawnSync } from 'node:child_process';
import { mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { createServer } from 'node:net';
import { tmpdir } from 'node:os';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { once } from 'node:events';

const hostDirectory = fileURLToPath(new URL('..', import.meta.url));

test('standalone host connects independent snapshot accounts, collects CLI JSON, and enforces mutation origins', async () => {
  const root = await mkdtemp(join(tmpdir(), 'subset usage server-'));
  const profilesFile = join(root, 'profiles.json');
  const bin = join(root, 'bin');
  await mkdir(bin);
  await writeFile(join(bin, 'codex'), `#!/usr/bin/env node
import readline from 'node:readline';
for await (const line of readline.createInterface({ input: process.stdin })) {
  const message = JSON.parse(line);
  if (!message.id) continue;
  const result = message.method === 'account/login/start'
    ? { type: 'chatgpt', loginId: 'private-login-id', authUrl: 'https://chatgpt.com/test-sign-in', token: 'private-token' } : {};
  process.stdout.write(JSON.stringify({ id: message.id, result }) + '\\n');
}
`, { mode: 0o700 });
  // Keep the developer's real Claude Code sign-in out of this test's dashboard.
  await writeFile(join(bin, 'claude'), `#!/bin/sh
if [ -n "$CLAUDE_CONFIG_DIR" ]; then printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"pro"}'; else printf '%s\\n' '{"loggedIn":false,"authMethod":"none"}'; fi
`, { mode: 0o700 });
  const web = join(root, 'web');
  await mkdir(web);
  await writeFile(join(web, 'index.html'), '<!doctype html><title>Usage</title>');
  const freePort = async () => {
    const socket = createServer();
    socket.listen(0, '127.0.0.1');
    await once(socket, 'listening');
    const free = socket.address().port;
    await new Promise((resolve) => socket.close(resolve));
    return free;
  };
  // The reserved port is released before the server binds; retry with a fresh one if another process takes it.
  let port, env, child, exited;
  // Cleanup covers startup too, so a failed start never leaves a server or temp directory behind.
  try {
    for (let attempt = 0; ; attempt++) {
      port = await freePort();
      env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, SUBSET_USAGE_PORT: String(port), SUBSET_USAGE_PROFILES_FILE: relative(hostDirectory, profilesFile), SUBSET_USAGE_DATA_DIR: root, SUBSET_USAGE_WEB_DIR: web };
      child = spawn(process.execPath, ['src/server.mjs', 'serve', '--no-open'], { cwd: hostDirectory, env, stdio: ['ignore', 'pipe', 'pipe'] });
      exited = once(child, 'exit');
      let stderr = '';
      child.stderr.on('data', (data) => { stderr += data.toString(); });
      const ready = await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error(`Server did not become ready. ${stderr}`)), 5000);
        child.stdout.on('data', (data) => { if (data.toString().includes('Subset usage listening')) { clearTimeout(timer); resolve(true); } });
        child.once('error', (error) => { clearTimeout(timer); reject(error); });
        // 'close' fires after stderr is fully read, so the port-in-use message is seen.
        child.once('close', () => { clearTimeout(timer); if (/in use/.test(stderr) && attempt < 3) resolve(false); else reject(new Error(`Server exited before readiness. ${stderr}`)); });
      });
      if (ready) break;
    }
    const base = `http://127.0.0.1:${port}`;
    const request = (path, method = 'GET', body, origin = base, extra = { 'X-Subset-Request': '1' }) => fetch(`${base}${path}`, {
      method, headers: { ...(origin ? { Origin: origin } : {}), ...(body ? { 'Content-Type': 'application/json' } : {}), ...extra },
      body: body ? JSON.stringify(body) : undefined,
    });
    // Reads need the dashboard's header, and requests a browser marks as cross-site are refused.
    assert.equal((await request('/api/status', 'GET', undefined, '', {})).status, 403);
    assert.equal((await request('/api/profiles', 'GET', undefined, '', { 'X-Subset-Request': '1', 'Sec-Fetch-Site': 'cross-site' })).status, 403);
    assert.equal((await request('/', 'GET', undefined, '', {})).status, 200);
    // Local sign-ins stay off until the user chooses, and stored logins are not listed meanwhile.
    assert.deepEqual(await (await request('/api/preferences')).json(), { localCredentials: false, localCredentialsChosen: false });
    assert.deepEqual(await (await request('/api/stored-logins')).json(), { pi: [], opencode: [], omp: [], hermes: [] });
    assert.equal((await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Blocked' }, '')).status, 403);
    assert.equal((await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Blocked' }, 'http://evil.example')).status, 403);
    assert.equal((await request('/api/connections/active', 'GET', undefined, 'http://evil.example')).status, 403);
    assert.deepEqual(await (await request('/api/connections/active')).json(), { connection: null });
    const pending = await (await request('/api/connections', 'POST', { label: 'Pending Codex' })).json();
    const recovered = await (await request('/api/connections/active')).json();
    assert.deepEqual(recovered, { connection: { id: pending.id, state: 'pending', error: null, authUrl: pending.authUrl } });
    assert.doesNotMatch(JSON.stringify(recovered), /private-login-id|private-token|codexHome/);
    assert.equal((await request('/api/connections', 'POST', { label: 'Overlapping' })).status, 400);
    assert.equal((await request(`/api/connections/${recovered.connection.id}/cancel`, 'POST')).status, 200);
    assert.deepEqual(await (await request('/api/connections/active')).json(), { connection: null });
    const firstResponse = await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Personal Claude' });
    assert.equal(firstResponse.status, 201);
    const first = await firstResponse.json();
    const secondResponse = await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Work Claude' });
    assert.equal(secondResponse.status, 201);
    const second = await secondResponse.json();
    const thirdResponse = await request('/api/profiles', 'POST', { provider: 'antigravity', label: 'Google' });
    assert.equal(thirdResponse.status, 201);
    const third = await thirdResponse.json();
    const snapshots = [
      [first, { rate_limits: { five_hour: { used_percentage: 10, resets_at: 1800000000 } }, transcript_path: 'private-transcript', token: 'private-token' }],
      [second, { rate_limits: { seven_day: { used_percentage: 80, resets_at: 1800000000 } } }],
      [third, { quota: { gemini: { remaining_fraction: 0.4, reset_time: '2027-01-01T00:00:00Z' } }, email: 'private@example.com' }],
    ];
    for (const [profile, payload] of snapshots) {
      const result = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', profile.id], { cwd: hostDirectory, env, input: JSON.stringify(payload), encoding: 'utf8', timeout: 5000 });
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout, '');
    }
    const status = await (await request('/api/status')).json();
    assert.deepEqual(status.accounts.map((account) => account.provider), ['claude-code', 'claude-code', 'antigravity']);
    assert.deepEqual(status.accounts.map((account) => account.windows[0].remainingPercent), [90, 20, 40]);
    const observedAt = status.accounts[0].observedAt;
    assert.equal((await (await request('/api/status')).json()).accounts[0].observedAt, observedAt);
    assert.doesNotMatch(JSON.stringify(status), /private-token|private-transcript|private@example/);
    const profiles = await (await request('/api/profiles')).json();
    // Installed status lines call the stable shim in the data directory.
    // A custom profiles file gets its own shim, so another configuration never redirects these collectors.
    assert.match(profiles.profiles[0].collectCommand, new RegExp(`^'${join(root, 'bin', 'subset-usage-collect-')}[0-9a-f]{10}' --account '${first.id}'$`));
    assert.doesNotMatch(JSON.stringify(profiles), /snapshotFile|codexHome|private-token/);
    const generatedCollector = spawnSync('/bin/sh', ['-c', profiles.profiles[0].collectCommand], {
      cwd: root, env: process.env, input: JSON.stringify(snapshots[0][1]), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(generatedCollector.status, 0, generatedCollector.stderr);
    const config = JSON.parse(await readFile(profilesFile, 'utf8'));
    assert.doesNotMatch(await readFile(config[0].snapshotFile, 'utf8'), /private-token|private-transcript/);
    const invalidCollector = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', '../other'], { cwd: hostDirectory, env, input: '{}', encoding: 'utf8', timeout: 5000 });
    assert.equal(invalidCollector.status, 1);
    const workDir = join(root, 'claude work');
    const bound = await (await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Bound Claude', claudeConfigDir: workDir })).json();
    assert.equal((await request('/api/profiles', 'POST', { provider: 'claude-code', label: 'Same dir', claudeConfigDir: workDir })).status, 400);
    const boundSetup = (await (await request('/api/profiles')).json()).profiles.find((profile) => profile.id === bound.id);
    assert.equal(boundSetup.claudeConfigDir, workDir);
    assert.equal(boundSetup.claudeSettingsFile, join(workDir, 'settings.json'));
    assert.equal(boundSetup.claudeLaunchCommand, `CLAUDE_CONFIG_DIR='${workDir}' claude`);
    const crossDirectory = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', bound.id], {
      cwd: hostDirectory, env, input: JSON.stringify({ ...snapshots[0][1], transcript_path: join(root, 'other', 'projects', 'p', 's.jsonl') }), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(crossDirectory.status, 1);
    assert.match(crossDirectory.stderr, /different Claude Code config directory/);
    // An installed collector keeps rendering the CLI's previous status line from the same input.
    await mkdir(workDir);
    await writeFile(join(workDir, 'settings.json'), JSON.stringify({ statusLine: { type: 'command', command: 'cat >/dev/null; printf previous-line' } }));
    assert.equal((await request(`/api/profiles/${bound.id}/collector`, 'POST')).status, 200);
    const installedCommand = JSON.parse(await readFile(join(workDir, 'settings.json'), 'utf8')).statusLine.command;
    assert.equal((await (await request('/api/profiles')).json()).profiles.find((profile) => profile.id === bound.id).collector.state, 'installed');
    const chainedRun = spawnSync('/bin/sh', ['-c', installedCommand], {
      cwd: root, env: process.env, input: JSON.stringify({ ...snapshots[0][1], transcript_path: join(workDir, 'projects', 'p', 's.jsonl') }), encoding: 'utf8', timeout: 5000,
    });
    assert.equal(chainedRun.status, 0, chainedRun.stderr);
    assert.equal(chainedRun.stdout, 'previous-line');
    assert.equal((await (await request('/api/status')).json()).accounts.find((account) => account.id === bound.id).windows[0].usedPercent, 10);
    assert.equal((await request(`/api/profiles/${bound.id}/collector`, 'POST', undefined, 'http://evil.example')).status, 403);
    assert.equal((await request(`/api/profiles/${bound.id}`, 'DELETE', { confirmation: bound.id })).status, 200);
    assert.equal(JSON.parse(await readFile(join(workDir, 'settings.json'), 'utf8')).statusLine.command, 'cat >/dev/null; printf previous-line');
    assert.equal((await request(`/api/profiles/${first.id}`, 'DELETE', { confirmation: first.id })).status, 200);
    assert.equal((await (await request('/api/status')).json()).accounts.length, 2);
    await assert.rejects(readFile(config[0].snapshotFile), { code: 'ENOENT' });
  } finally {
    child?.kill('SIGTERM');
    if (exited) await exited;
    await rm(root, { recursive: true, force: true });
  }
});

test('status is read-only and does not show a snapshot under a different signed-in account', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-status-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const bin = join(root, 'fake-bin');
  const configDir = join(root, 'claude');
  await mkdir(bin);
  await mkdir(configDir);
  await writeFile(join(bin, 'claude'), `#!/bin/sh
printf '%s\\n' '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","email":"new@example.com"}'
`, { mode: 0o700 });
  const profilesFile = join(root, 'profiles.json');
  const snapshotFile = join(root, 'snapshot.json');
  await writeFile(profilesFile, JSON.stringify([{ id: 'claude_work', label: 'Work', provider: 'claude-code', managed: false, snapshotFile, claudeConfigDir: configDir }]));
  const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, SUBSET_USAGE_PROFILES_FILE: profilesFile, SUBSET_USAGE_DATA_DIR: root, CLAUDE_CONFIG_DIR: join(root, 'default-claude') };
  await mkdir(join(root, 'default-claude'));
  const collected = spawnSync(process.execPath, ['src/server.mjs', 'collect', '--account', 'claude_work'], { cwd: hostDirectory, env: { ...env, CLAUDE_CONFIG_DIR: configDir }, input: JSON.stringify({ rate_limits: { five_hour: { used_percentage: 10, resets_at: 1900000000 } } }), encoding: 'utf8', timeout: 5000 });
  assert.equal(collected.status, 0, collected.stderr);
  const before = await readFile(profilesFile, 'utf8');
  const run = () => JSON.parse(spawnSync(process.execPath, ['src/server.mjs', 'status'], { cwd: hostDirectory, env, encoding: 'utf8', timeout: 15000 }).stdout);
  // First sighting of the identity adopts the existing snapshot; the signed-in default Claude account is shown without being saved.
  const first = run();
  assert.equal(first.accounts[0].windows.length, 1);
  assert.deepEqual(first.accounts.map((account) => account.id), ['claude_work', 'claude_default']);
  // The account was previously seen signed in as someone else: the older snapshot is not theirs.
  await writeFile(join(root, 'claude-identities.json'), JSON.stringify({ claude_work: { email: 'old@example.com', since: 0 } }));
  const switched = run().accounts[0];
  assert.equal(switched.windows.length, 0);
  assert.equal(switched.errors[0].code, 'claude_identity_changed');
  // Nothing was written: no profile added, no identity change persisted, no history.
  assert.equal(await readFile(profilesFile, 'utf8'), before);
  assert.deepEqual(JSON.parse(await readFile(join(root, 'claude-identities.json'), 'utf8')), { claude_work: { email: 'old@example.com', since: 0 } });
  await assert.rejects(readFile(join(root, 'usage-history.json')), { code: 'ENOENT' });
});
