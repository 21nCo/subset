import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, readdir, rm, stat, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { readSnapshotProfile } from '@subset/usage/snapshots';
import { createAccounts } from '../src/accounts.mjs';

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), 'subset-profiles-test-'));
  const options = {
    profilesFile: join(root, 'config', 'profiles.json'),
    managedRoot: join(root, 'managed'),
    snapshotRoot: join(root, 'snapshots'),
    currentHome: join(root, 'current'),
    antigravitySettingsFile: join(root, 'gemini', 'settings.json'),
  };
  const accounts = createAccounts(options);
  t.after(async () => { await accounts.close(); await rm(root, { recursive: true, force: true }); });
  async function configure(value) {
    await mkdir(join(root, 'config'), { recursive: true });
    await writeFile(options.profilesFile, JSON.stringify(value));
  }
  return { root, options, accounts, configure };
}

const claudeQuota = (used = 25) => ({ rate_limits: {
  five_hour: { used_percentage: used, resets_at: Date.parse('2026-10-03T00:00:00Z') / 1000 },
  seven_day: { used_percentage: 40, resets_at: Date.parse('2026-10-08T00:00:00Z') / 1000 },
} });
const antigravityQuota = (remaining = 0.8) => ({ quota: {
  gemini: { remaining_fraction: remaining, reset_in_seconds: 3600 },
} });

test('reads legacy Codex profiles and all explicit providers without leaking connection fields', async (t) => {
  const { accounts, configure, options, root } = await fixture(t);
  await configure([
    { id: 'legacy', label: ' Personal ', codexHome: options.currentHome },
    { id: 'codex', label: 'Work', provider: 'codex-chatgpt', codexHome: join(root, 'codex'), managed: true },
    { id: 'claude', label: 'Claude', provider: 'claude-code', snapshotFile: join(root, 'claude.json') },
    { id: 'google', label: 'Google', provider: 'antigravity', snapshotFile: join(root, 'google.json') },
    { id: 'cursor', label: 'Cursor', provider: 'cursor', credentialEnv: 'CURSOR_TEAM_KEY', cursorUserId: 'user_private', apiKey: 'secret-never-returned' },
  ]);
  const profiles = await accounts.profiles();
  assert.equal(profiles[0].provider, 'codex-chatgpt');
  assert.equal(profiles[0].codexHome, options.currentHome);
  assert.equal(profiles[0].label, 'Personal');
  assert.equal(JSON.stringify(profiles).includes('secret-never-returned'), false);
  const list = await accounts.list();
  assert.equal(list.length, 5);
  assert.deepEqual(list[0], { id: 'legacy', label: 'Personal', provider: 'codex-chatgpt', managed: false, current: true });
  assert.equal(list.slice(1).every((item) => !item.current), true);
  for (const item of list) assert.deepEqual(Object.keys(item).sort(), ['current', 'id', 'label', 'managed', 'provider']);
  assert.equal(JSON.stringify(list).includes('user_private'), false);
  assert.equal(JSON.stringify(list).includes(root), false);
});

test('rejects invalid profiles with generic errors and no input details', async (t) => {
  const { accounts, configure, options } = await fixture(t);
  const valid = { id: 'valid', label: 'Valid', provider: 'claude-code', snapshotFile: join(options.snapshotRoot, 'valid.json') };
  const invalid = [
    null, { ...valid, id: '../escape' }, { ...valid, id: 123 }, { ...valid, label: 42 },
    { ...valid, label: 'x'.repeat(81) }, { ...valid, label: 'line\nsecret' },
    { ...valid, provider: 'other-secret' }, { ...valid, provider: null }, { ...valid, provider: undefined },
    { ...valid, snapshotFile: 'relative/secret' },
    { id: 'codex', label: 'Codex', provider: 'codex-chatgpt', codexHome: 'relative/secret' },
    { id: 'cursor', label: 'Cursor', provider: 'cursor', credentialEnv: 'raw-secret-key!', cursorUserId: 'user_valid' },
    { id: 'cursor', label: 'Cursor', provider: 'cursor', credentialEnv: 'CURSOR_KEY', cursorUserId: 'private@example.com' },
  ];
  for (const profile of invalid) {
    await configure([profile]);
    await assert.rejects(accounts.profiles(), { message: 'Invalid usage profile configuration.' });
  }
  await configure({ secret: 'never-show' });
  await assert.rejects(accounts.profiles(), { message: 'Usage profiles configuration must contain at most 20 profiles.' });
  await writeFile(options.profilesFile, '{"secret":"unfinished');
  await assert.rejects(accounts.profiles(), { message: 'Could not read usage profiles configuration.' });
});

test('rejects duplicate IDs, normalized source paths across providers, and exact Cursor key/user pairs', async (t) => {
  const { accounts, configure, root } = await fixture(t);
  const path = join(root, 'quota.json');
  const duplicates = [
    [{ id: 'same', label: 'One', codexHome: join(root, 'one') }, { id: 'same', label: 'Two', codexHome: join(root, 'two') }],
    [{ id: 'one', label: 'One', codexHome: path }, { id: 'two', label: 'Two', provider: 'claude-code', snapshotFile: path }],
    [{ id: 'one', label: 'One', provider: 'claude-code', snapshotFile: path }, { id: 'two', label: 'Two', provider: 'antigravity', snapshotFile: `${root}/extra/../quota.json` }],
    ['one', 'two'].map((id) => ({ id, label: id, provider: 'cursor', credentialEnv: 'CURSOR_KEY', cursorUserId: 'user_same' })),
  ];
  for (const profiles of duplicates) {
    await configure(profiles);
    await assert.rejects(accounts.profiles(), { message: 'Duplicate usage profile configuration.' });
  }
});

test('adds independent same-provider accounts and permits one team key for multiple Cursor users', async (t) => {
  const { accounts, options } = await fixture(t);
  const additions = await Promise.all([
    ...Array.from({ length: 4 }, (_, index) => accounts.addProvider({ provider: 'claude-code', label: `Claude ${index}` })),
    ...Array.from({ length: 4 }, (_, index) => accounts.addProvider({ provider: 'antigravity', label: `Google ${index}` })),
    ...Array.from({ length: 4 }, (_, index) => accounts.addProvider({ provider: 'cursor', label: `Team ${index}`, credentialEnv: 'CURSOR_TEAM_KEY', cursorUserId: `user_${index}` })),
    accounts.addProvider({ provider: 'cursor', label: 'Other team', credentialEnv: 'CURSOR_OTHER_KEY', cursorUserId: 'user_0' }),
  ]);
  assert.equal(new Set(additions.map((profile) => profile.id)).size, 13);
  const profiles = await accounts.profiles();
  const snapshots = profiles.filter((profile) => profile.snapshotFile);
  assert.equal(new Set(snapshots.map((profile) => profile.snapshotFile)).size, 8);
  for (const profile of snapshots) {
    assert.equal(profile.managed, true);
    assert.equal(profile.snapshotFile, join(options.snapshotRoot, `${profile.id}.json`));
  }
  await assert.rejects(accounts.addProvider({ provider: 'cursor', label: 'Duplicate', credentialEnv: 'CURSOR_TEAM_KEY', cursorUserId: 'user_0' }), /Duplicate usage/);
  assert.equal((await accounts.profiles()).length, 13);
  assert.equal((await stat(options.profilesFile)).mode & 0o077, 0);
  assert.equal((await stat(join(options.profilesFile, '..'))).mode & 0o077, 0);
  await assert.rejects(stat(options.snapshotRoot), { code: 'ENOENT' });
});

test('validates provider additions as configuration only, without accepting credentials', async (t) => {
  const { accounts } = await fixture(t);
  const cursor = { provider: 'cursor', label: 'Team', credentialEnv: 'CURSOR_KEY', cursorUserId: 'user_valid' };
  for (const credentialEnv of ['', '1KEY', 'KEY-NAME', 'KEY=secret', 'KEY\n', 'A'.repeat(129), null]) {
    await assert.rejects(accounts.addProvider({ ...cursor, credentialEnv }), /Invalid usage account configuration/);
  }
  for (const cursorUserId of ['', 'user_', '123', 'user_has space', 'user_x/y', 'user_x%2Fy', 'user_\n', `user_${'a'.repeat(252)}`, null]) {
    await assert.rejects(accounts.addProvider({ ...cursor, cursorUserId }), /Invalid usage account configuration/);
  }
  await assert.rejects(accounts.addProvider({ ...cursor, apiKey: 'secret' }), /Invalid usage account configuration/);
  await assert.rejects(accounts.addProvider({ provider: 'claude-code', label: 'Claude', credentialEnv: 'TOKEN' }), /Invalid usage account configuration/);
  await assert.rejects(accounts.addProvider({ provider: 'codex-chatgpt', label: 'Codex' }), /Unsupported usage provider/);
  await assert.rejects(accounts.addProvider({ provider: 'claude-code', label: 'x'.repeat(81) }), /Enter an account name/);
  assert.deepEqual(await accounts.list(), []);
  await accounts.addProvider({ ...cursor, credentialEnv: `_${'a'.repeat(127)}`, cursorUserId: `user_${'b'.repeat(251)}` });
});

test('enforces one serialized 20-account cap across all providers', async (t) => {
  const { accounts, configure, root } = await fixture(t);
  await configure([{ id: 'legacy', label: 'Legacy', codexHome: join(root, 'codex') }]);
  const results = await Promise.allSettled(Array.from({ length: 23 }, (_, index) => accounts.addProvider({
    provider: index % 2 ? 'claude-code' : 'antigravity', label: `Snapshot ${index}`,
  })));
  assert.equal(results.filter((item) => item.status === 'fulfilled').length, 19);
  assert.equal(results.filter((item) => item.status === 'rejected').length, 4);
  assert.equal((await accounts.profiles()).length, 20);
  await assert.rejects(accounts.startLogin('Another Codex'), /already has 20 accounts/);
  await configure(Array.from({ length: 21 }, (_, index) => ({ id: `p${index}`, label: 'Account', codexHome: join(root, `${index}`) })));
  await assert.rejects(accounts.profiles(), /at most 20 profiles/);
});

test('captures sanitized isolated quotas with owner-only atomic envelopes and safe return values', async (t) => {
  const { accounts, options } = await fixture(t);
  const first = await accounts.addProvider({ provider: 'claude-code', label: 'Personal' });
  const second = await accounts.addProvider({ provider: 'claude-code', label: 'Work' });
  const google = await accounts.addProvider({ provider: 'antigravity', label: 'Google' });
  const before = Date.now();
  const result = await accounts.captureSnapshot(first.id, { ...claudeQuota(10), apiKey: 'raw-secret', session_id: 'private-session', transcript_path: '/private/path' });
  assert.deepEqual(result, { id: first.id, state: 'ok' });
  await accounts.captureSnapshot(second.id, claudeQuota(75));
  await accounts.captureSnapshot(google.id, { ...antigravityQuota(), access_token: 'raw-secret' });
  const profiles = await accounts.profiles();
  for (const profile of profiles) {
    const raw = await readFile(profile.snapshotFile, 'utf8');
    const envelope = JSON.parse(raw);
    assert.deepEqual(Object.keys(envelope).sort(), ['accountId', 'data', 'observedAt', 'provider', 'schemaVersion']);
    assert.equal(envelope.schemaVersion, 1);
    assert.equal(envelope.provider, profile.provider);
    assert.equal(envelope.accountId, profile.id);
    assert.ok(Date.parse(envelope.observedAt) >= before && Date.parse(envelope.observedAt) <= Date.now());
    for (const secret of ['raw-secret', 'private-session', '/private/path', 'apiKey', 'access_token', 'transcript_path']) assert.equal(raw.includes(secret), false);
    assert.equal((await stat(profile.snapshotFile)).mode & 0o077, 0);
  }
  assert.equal((await stat(options.snapshotRoot)).mode & 0o077, 0);
  assert.equal((await readdir(options.snapshotRoot)).length, 3);
  const [personal, work, antigravity] = await Promise.all(profiles.map(readSnapshotProfile));
  assert.equal(personal.windows[0].usedPercent, 10);
  assert.equal(work.windows[0].usedPercent, 75);
  assert.equal(antigravity.provider, 'antigravity');
  assert.equal(antigravity.windows[0].remainingPercent, 80);
  await writeFile(profiles[1].snapshotFile, await readFile(profiles[0].snapshotFile));
  assert.equal((await readSnapshotProfile(profiles[1])).state, 'unavailable');
  assert.equal((await readSnapshotProfile(profiles[0])).windows[0].usedPercent, 10);
});

test('startup and malformed quota payloads do not replace the previous valid observation', async (t) => {
  const { accounts } = await fixture(t);
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Claude' });
  await accounts.captureSnapshot(added.id, claudeQuota());
  const [profile] = await accounts.profiles();
  const previous = await readFile(profile.snapshotFile, 'utf8');
  for (const payload of [{ session_id: 'startup' }, {}, null, { rate_limits: { five_hour: { used_percentage: 'invalid' } } }]) {
    const result = await accounts.captureSnapshot(added.id, payload);
    assert.deepEqual(Object.keys(result).sort(), ['id', 'state']);
    assert.equal(result.state, 'unavailable');
    assert.equal(await readFile(profile.snapshotFile, 'utf8'), previous);
  }
  assert.deepEqual(await accounts.captureSnapshot(added.id, { rate_limits: { five_hour: { used_percentage: 55 } } }), { id: added.id, state: 'partial' });
  assert.equal((await readSnapshotProfile(profile)).windows[0].usedPercent, 55);
});

test('rejects capture for Codex, Cursor and missing profiles without changing configuration', async (t) => {
  const { accounts, configure, root, options } = await fixture(t);
  await configure([
    { id: 'codex', label: 'Codex', codexHome: join(root, 'codex') },
    { id: 'cursor', label: 'Cursor', provider: 'cursor', credentialEnv: 'CURSOR_KEY', cursorUserId: 'user_valid' },
  ]);
  const previous = await readFile(options.profilesFile, 'utf8');
  for (const id of ['codex', 'cursor']) await assert.rejects(accounts.captureSnapshot(id, claudeQuota()), /does not support quota snapshots/);
  await assert.rejects(accounts.captureSnapshot('missing', claudeQuota()), /Account was not found/);
  await assert.rejects(accounts.captureSnapshot('../escape', claudeQuota()), /Invalid account ID/);
  assert.equal(await readFile(options.profilesFile, 'utf8'), previous);
  await assert.rejects(stat(options.snapshotRoot), { code: 'ENOENT' });
});

test('removal deletes only exact managed snapshot and Codex paths, preserving arbitrary user files', async (t) => {
  const { accounts, configure, options, root } = await fixture(t);
  const own = await accounts.addProvider({ provider: 'claude-code', label: 'Managed' });
  await accounts.captureSnapshot(own.id, claudeQuota());
  const [managed] = await accounts.profiles();
  const files = [join(root, 'external.json'), join(options.snapshotRoot, 'wrong-id.json'), join(options.snapshotRoot, 'unmanaged.json')];
  for (const path of files) await writeFile(path, 'user-data');
  const externalHome = join(root, 'external-home');
  const ownHome = join(options.managedRoot, 'own-codex');
  await mkdir(externalHome);
  await mkdir(ownHome, { recursive: true });
  await configure([
    managed,
    { id: 'external', label: 'External', provider: 'claude-code', snapshotFile: files[0], managed: true },
    { id: 'wrong', label: 'Wrong', provider: 'antigravity', snapshotFile: files[1], managed: true },
    { id: 'unmanaged', label: 'Unmanaged', provider: 'claude-code', snapshotFile: files[2], managed: false },
    { id: 'legacy-external', label: 'Legacy external', codexHome: externalHome, managed: true },
    { id: 'own-codex', label: 'Legacy managed', codexHome: ownHome, managed: true },
  ]);
  for (const profile of await accounts.profiles()) assert.deepEqual(await accounts.removeProfile(profile.id), { id: profile.id });
  await assert.rejects(stat(managed.snapshotFile), { code: 'ENOENT' });
  await assert.rejects(stat(ownHome), { code: 'ENOENT' });
  for (const path of files) assert.equal(await readFile(path, 'utf8'), 'user-data');
  assert.equal((await stat(externalHome)).isDirectory(), true);
  assert.deepEqual(await accounts.list(), []);
  await assert.rejects(accounts.removeProfile(undefined), /Invalid account ID/);
  await assert.rejects(accounts.removeProfile('missing'), /Account was not found/);
});

test('serializes capture, removal and additions without resurrecting a removed snapshot', async (t) => {
  const { accounts, options } = await fixture(t);
  const first = await accounts.addProvider({ provider: 'claude-code', label: 'First' });
  const capture = accounts.captureSnapshot(first.id, claudeQuota());
  const remove = accounts.removeProfile(first.id);
  const staleCapture = accounts.captureSnapshot(first.id, claudeQuota(90));
  const second = accounts.addProvider({ provider: 'antigravity', label: 'Second' });
  const results = await Promise.allSettled([capture, remove, staleCapture, second]);
  assert.deepEqual(results.map((item) => item.status), ['fulfilled', 'fulfilled', 'rejected', 'fulfilled']);
  assert.match(results[2].reason.message, /Account was not found/);
  assert.deepEqual((await accounts.profiles()).map((profile) => profile.id), [results[3].value.id]);
  await assert.rejects(stat(join(options.snapshotRoot, `${first.id}.json`)), { code: 'ENOENT' });
});

test('separate collector and host instances do not leave a removed managed snapshot behind', async (t) => {
  const { accounts, options } = await fixture(t);
  const collector = createAccounts(options);
  t.after(() => collector.close());
  for (let attempt = 0; attempt < 30; attempt++) {
    const profile = await accounts.addProvider({ provider: 'claude-code', label: `Concurrent ${attempt}` });
    const result = await Promise.allSettled([
      collector.captureSnapshot(profile.id, claudeQuota()),
      accounts.removeProfile(profile.id),
    ]);
    assert.equal(result[1].status, 'fulfilled');
    await assert.rejects(stat(join(options.snapshotRoot, `${profile.id}.json`)), { code: 'ENOENT' });
    assert.deepEqual(await accounts.list(), []);
  }
});

test('snapshot write failures return generic errors and leave the mutation queue usable', async (t) => {
  const { accounts, configure, root } = await fixture(t);
  const blockingFile = join(root, 'private-blocker');
  await writeFile(blockingFile, 'do-not-replace');
  await configure([{ id: 'blocked', label: 'Blocked', provider: 'claude-code', snapshotFile: join(blockingFile, 'quota.json') }]);
  await assert.rejects(accounts.captureSnapshot('blocked', claudeQuota()), { message: 'Could not save usage quota snapshot.' });
  assert.equal(await readFile(blockingFile, 'utf8'), 'do-not-replace');
  await accounts.addProvider({ provider: 'claude-code', label: 'Another' });
  assert.equal((await accounts.list()).length, 2);
});

test('binds Claude Code accounts to distinct config directories and rejects cross-directory snapshots', async (t) => {
  const { accounts, configure, root } = await fixture(t);
  const personalDir = join(root, 'claude-personal');
  const workDir = join(root, 'claude-work');
  await mkdir(join(personalDir, 'projects', 'repo'), { recursive: true });
  await mkdir(join(workDir, 'projects', 'repo'), { recursive: true });
  const personal = await accounts.addProvider({ provider: 'claude-code', label: 'Personal', claudeConfigDir: personalDir });
  const work = await accounts.addProvider({ provider: 'claude-code', label: 'Work', claudeConfigDir: `${workDir}/` });
  const unbound = await accounts.addProvider({ provider: 'claude-code', label: 'Unbound', claudeConfigDir: '' });
  await assert.rejects(accounts.addProvider({ provider: 'claude-code', label: 'Again', claudeConfigDir: personalDir }), /already uses this config directory/);
  for (const claudeConfigDir of ['relative/dir', 'line\nbreak', 42]) {
    await assert.rejects(accounts.addProvider({ provider: 'claude-code', label: 'Bad', claudeConfigDir }), /absolute or ~\/ path/);
  }
  await assert.rejects(accounts.addProvider({ provider: 'antigravity', label: 'Bad', claudeConfigDir: personalDir }), /absolute or ~\/ path/);
  const listed = await accounts.list();
  assert.equal(listed.find((item) => item.id === work.id).claudeConfigDir, workDir);
  assert.equal(listed.find((item) => item.id === unbound.id).claudeConfigDir, undefined);

  const transcript = (dir) => join(dir, 'projects', 'repo', 'session.jsonl');
  assert.deepEqual(await accounts.captureSnapshot(personal.id, { ...claudeQuota(10), transcript_path: transcript(personalDir) }), { id: personal.id, state: 'ok' });
  await assert.rejects(accounts.captureSnapshot(work.id, { ...claudeQuota(90), transcript_path: transcript(personalDir) }), /different Claude Code config directory/);
  // The env variable is checked when no transcript path identifies the directory.
  await assert.rejects(accounts.captureSnapshot(work.id, claudeQuota(90), { env: { CLAUDE_CONFIG_DIR: personalDir } }), /different Claude Code config directory/);
  // Claude Code's env scrub can remove CLAUDE_CONFIG_DIR, so an absent signal is accepted.
  assert.equal((await accounts.captureSnapshot(work.id, claudeQuota(30), { env: {} })).state, 'ok');
  assert.equal((await accounts.captureSnapshot(unbound.id, { ...claudeQuota(50), transcript_path: transcript(personalDir) })).state, 'ok');
  const profiles = await accounts.profiles();
  const read = async (id) => readSnapshotProfile(profiles.find((item) => item.id === id));
  assert.equal((await read(personal.id)).windows[0].usedPercent, 10);
  assert.equal((await read(work.id)).windows[0].usedPercent, 30);
  for (const secret of [personalDir, 'session.jsonl']) assert.equal((await readFile(profiles[0].snapshotFile, 'utf8')).includes(secret), false);

  await configure([{ id: 'g', label: 'G', provider: 'antigravity', snapshotFile: join(root, 'g.json'), claudeConfigDir: personalDir }]);
  await assert.rejects(accounts.profiles(), /Invalid usage profile configuration/);
  await configure([
    { id: 'a', label: 'A', provider: 'claude-code', snapshotFile: join(root, 'a.json'), claudeConfigDir: personalDir },
    { id: 'b', label: 'B', provider: 'claude-code', snapshotFile: join(root, 'b.json'), claudeConfigDir: `${personalDir}/.` },
  ]);
  await assert.rejects(accounts.profiles(), /Duplicate usage profile configuration/);
});

test('adds the signed-in default Claude Code account once and remembers removal', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-default-claude-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const defaultClaudeConfigDir = join(root, '.claude');
  let signedIn = false;
  let probes = 0;
  const accounts = createAccounts({
    profilesFile: join(root, 'config', 'profiles.json'), managedRoot: join(root, 'managed'), snapshotRoot: join(root, 'snapshots'),
    currentHome: join(root, 'codex'), defaultClaudeConfigDir,
    readClaudeAuth: async (dir) => { probes++; assert.equal(dir, defaultClaudeConfigDir); return { loggedIn: signedIn, authMethod: signedIn ? 'claude.ai' : 'none', subscriptionType: null, configDirectory: dir }; },
  });
  t.after(() => accounts.close());
  assert.equal(await accounts.ensureDefaultClaude(), null);
  await assert.rejects(accounts.ensureDefaultClaude({ force: true }), /not signed in/);
  signedIn = true;
  const [first, second] = await Promise.all([accounts.ensureDefaultClaude(), accounts.ensureDefaultClaude()]);
  assert.deepEqual(first, { id: 'claude_default', label: '', provider: 'claude-code' });
  assert.deepEqual(second, first);
  const listed = await accounts.list();
  assert.equal(listed.length, 1);
  assert.equal(listed[0].defaultClaude, true);
  assert.equal(listed[0].claudeConfigDir, defaultClaudeConfigDir);
  const probesBefore = probes;
  await accounts.ensureDefaultClaude();
  assert.equal(probes, probesBefore, 'an existing default account needs no CLI probe');
  await accounts.removeProfile('claude_default');
  assert.equal(await accounts.ensureDefaultClaude(), null);
  assert.deepEqual(await accounts.list(), []);
  assert.equal((await accounts.ensureDefaultClaude({ force: true })).id, 'claude_default');
  await accounts.removeProfile('claude_default');
  await assert.rejects(accounts.addProvider({ provider: 'claude-code', label: 'Manual default', claudeConfigDir: defaultClaudeConfigDir }).then(() => accounts.addProvider({ provider: 'claude-code', label: 'Again', claudeConfigDir: defaultClaudeConfigDir })), /already uses this config directory/);
  assert.equal((await accounts.ensureDefaultClaude()), null);
});

test('installs a collector into the bound settings file, keeps the previous status line, and restores it', async (t) => {
  const { accounts, root } = await fixture(t);
  const configDir = join(root, 'claude work');
  await mkdir(configDir);
  const settingsFile = join(configDir, 'settings.json');
  const previous = { type: 'command', command: '/bin/sh ~/.orca/statusline.sh', padding: 0 };
  await writeFile(settingsFile, JSON.stringify({ model: 'opus', statusLine: previous }), { mode: 0o644 });
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Work', claudeConfigDir: configDir });
  const command = `node collect --account ${added.id}`;
  assert.deepEqual(await accounts.collectorStatus({ ...added, claudeConfigDir: configDir }, command), { state: 'not-installed', settingsFile, chained: false, existing: true });

  assert.deepEqual(await accounts.installCollector(added.id, command), { id: added.id, state: 'installed' });
  const installed = JSON.parse(await readFile(settingsFile, 'utf8'));
  assert.equal(installed.model, 'opus');
  assert.deepEqual(installed.statusLine, { padding: 0, type: 'command', command });
  assert.equal((await stat(settingsFile)).mode & 0o777, 0o644);
  assert.deepEqual(JSON.parse(await readFile(`${settingsFile}.subset-backup`, 'utf8')).statusLine, previous);
  assert.equal(await accounts.chainedStatusLine(added.id), previous.command);
  assert.equal((await accounts.collectorStatus({ ...added, claudeConfigDir: configDir }, command)).state, 'installed');
  // Installing again does not chain the collector to itself.
  await accounts.installCollector(added.id, command);
  assert.equal(await accounts.chainedStatusLine(added.id), previous.command);

  // Another tool replacing the line is reported, and reinstalling keeps chaining that tool's line.
  await writeFile(settingsFile, JSON.stringify({ model: 'opus', statusLine: { type: 'command', command: 'other-tool' } }));
  assert.equal((await accounts.collectorStatus({ ...added, claudeConfigDir: configDir }, command)).state, 'replaced');
  await accounts.installCollector(added.id, command);
  assert.equal(await accounts.chainedStatusLine(added.id), 'other-tool');

  await accounts.uninstallCollector(added.id);
  assert.deepEqual(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine, { type: 'command', command: 'other-tool' });
  assert.equal(await accounts.chainedStatusLine(added.id), null);
});

test('installing without a previous status line removes the key on uninstall and account removal', async (t) => {
  const { accounts, root } = await fixture(t);
  const configDir = join(root, 'claude');
  await mkdir(configDir);
  const settingsFile = join(configDir, 'settings.json');
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Personal', claudeConfigDir: configDir });
  await accounts.installCollector(added.id, 'collect --account x');
  assert.equal(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine.command, 'collect --account x');
  await accounts.removeProfile(added.id);
  assert.deepEqual(JSON.parse(await readFile(settingsFile, 'utf8')), {});

  const unbound = await accounts.addProvider({ provider: 'claude-code', label: 'Unbound' });
  await assert.rejects(accounts.installCollector(unbound.id, 'c'), /Set a Claude Code config directory/);
  const missing = await accounts.addProvider({ provider: 'claude-code', label: 'Missing', claudeConfigDir: join(root, 'missing') });
  await assert.rejects(accounts.installCollector(missing.id, 'c'), /settings directory was not found/);
  const broken = join(root, 'broken');
  await mkdir(broken);
  await writeFile(join(broken, 'settings.json'), '{ not json');
  const brokenProfile = await accounts.addProvider({ provider: 'claude-code', label: 'Broken', claudeConfigDir: broken });
  await assert.rejects(accounts.installCollector(brokenProfile.id, 'c'), /not valid JSON/);
  assert.equal(await readFile(join(broken, 'settings.json'), 'utf8'), '{ not json');
});

test('records the outcome of each collector run for installed collectors', async (t) => {
  const { accounts, root } = await fixture(t);
  const configDir = join(root, 'claude');
  await mkdir(join(configDir, 'projects', 'p'), { recursive: true });
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Claude', claudeConfigDir: configDir });
  const profile = { ...added, claudeConfigDir: configDir };
  await accounts.installCollector(added.id, 'collect --account x');
  assert.equal((await accounts.collectorStatus(profile, 'collect --account x')).lastRun, null);
  await accounts.captureSnapshot(added.id, { session_id: 'startup' });
  assert.equal((await accounts.collectorStatus(profile, 'collect --account x')).lastRun.result, 'no-quota');
  await assert.rejects(accounts.captureSnapshot(added.id, { ...claudeQuota(), transcript_path: join(root, 'other', 'projects', 'p', 's.jsonl') }));
  assert.equal((await accounts.collectorStatus(profile, 'collect --account x')).lastRun.result, 'wrong-directory');
  await accounts.captureSnapshot(added.id, { ...claudeQuota(), transcript_path: join(configDir, 'projects', 'p', 's.jsonl') });
  const status = await accounts.collectorStatus(profile, 'collect --account x');
  assert.equal(status.lastRun.result, 'saved');
  assert.ok(Date.parse(status.installedAt) <= Date.now());
  await accounts.removeProfile(added.id);
  await assert.rejects(stat(join(root, 'collector-runs', `${added.id}.json`)), { code: 'ENOENT' });
});

test('keeps local sign-ins off until chosen and adds Factory Droid accounts per home and key', async (t) => {
  const { accounts, root } = await fixture(t);
  assert.deepEqual(await accounts.usagePreferences(), { localCredentials: false, localCredentialsChosen: false });
  assert.deepEqual(await accounts.setUsagePreferences({ localCredentials: false }), { localCredentials: false, localCredentialsChosen: true });
  assert.deepEqual(await accounts.setUsagePreferences({ localCredentials: true }), { localCredentials: true, localCredentialsChosen: true });
  await assert.rejects(accounts.setUsagePreferences({ localCredentials: 'yes' }), /Invalid settings/);
  await assert.rejects(accounts.setUsagePreferences({ localCredentials: true, extra: 1 }), /Invalid settings/);
  const work = await accounts.addProvider({ provider: 'factory-droid', label: 'Work', factoryHome: join(root, 'droid-work') });
  const keyed = await accounts.addProvider({ provider: 'factory-droid', label: 'Keyed', factoryHome: join(root, 'droid-work'), credentialEnv: 'FACTORY_KEY' });
  await assert.rejects(accounts.addProvider({ provider: 'factory-droid', label: 'Again', factoryHome: join(root, 'droid-work') }), /Duplicate/);
  await assert.rejects(accounts.addProvider({ provider: 'factory-droid', label: 'Bad', factoryHome: 'relative' }), /Factory home/);
  await assert.rejects(accounts.addProvider({ provider: 'factory-droid', label: 'Bad', credentialEnv: 'KEY=value' }), /Invalid usage account/);
  const listed = await accounts.list();
  assert.deepEqual(listed.map((item) => [item.id, item.factoryHome, item.apiKeyConfigured]), [[work.id, join(root, 'droid-work'), false], [keyed.id, join(root, 'droid-work'), true]]);
  assert.doesNotMatch(JSON.stringify(listed), /FACTORY_KEY/);
});

test('account names are optional, and legacy default names are dropped for the Default tag', async (t) => {
  const { accounts, configure, options, root } = await fixture(t);
  const unnamed = await accounts.addProvider({ provider: 'claude-code' });
  assert.equal(unnamed.label, '');
  await configure([
    { id: 'current', label: 'Current Codex account', codexHome: options.currentHome },
    { id: 'claude_default', label: 'Claude Code (default)', provider: 'claude-code', snapshotFile: join(root, 'd.json') },
    { id: 'kept', label: 'Current Codex account', codexHome: join(root, 'other') },
  ]);
  assert.deepEqual((await accounts.profiles()).map((profile) => profile.label), ['', '', 'Current Codex account']);
});

test('adds Amp, Devin, Pi, and OpenCode accounts with validated options only', async (t) => {
  const { accounts } = await fixture(t);
  const amp = await accounts.addProvider({ provider: 'amp' });
  await accounts.addProvider({ provider: 'amp', credentialEnv: 'AMP_WORK' });
  await assert.rejects(accounts.addProvider({ provider: 'amp' }), /Duplicate/);
  await accounts.addProvider({ provider: 'devin', label: 'Devin' });
  await accounts.addProvider({ provider: 'pi', login: 'chatgpt' });
  await accounts.addProvider({ provider: 'opencode', login: 'opencode-go' });
  await assert.rejects(accounts.addProvider({ provider: 'pi', login: 'opencode-go' }), /Choose which stored login/);
  await assert.rejects(accounts.addProvider({ provider: 'pi', login: 'chatgpt', credentialEnv: 'X' }), /Invalid usage account/);
  await assert.rejects(accounts.addProvider({ provider: 'amp', factoryHome: '/x' }), /Invalid usage account/);
  const listed = await accounts.list();
  assert.deepEqual(listed.map((item) => [item.provider, item.login ?? null, item.apiKeyConfigured ?? null]), [
    ['amp', null, false], ['amp', null, true], ['devin', null, false], ['pi', 'chatgpt', null], ['opencode', 'opencode-go', null],
  ]);
  assert.equal(listed[0].id, amp.id);
});

test('adds omp and Hermes stored logins, keeping separate omp entries apart', async (t) => {
  const { accounts } = await fixture(t);
  await accounts.addProvider({ provider: 'omp', login: 'chatgpt', entryId: '4' });
  await accounts.addProvider({ provider: 'omp', login: 'chatgpt', entryId: '7' });
  await assert.rejects(accounts.addProvider({ provider: 'omp', login: 'chatgpt', entryId: '7' }), /Duplicate/);
  await assert.rejects(accounts.addProvider({ provider: 'omp', login: 'chatgpt', entryId: '../x' }), /Choose which stored login/);
  await assert.rejects(accounts.addProvider({ provider: 'amp', entryId: '1' }), /Choose which stored login/);
  await accounts.addProvider({ provider: 'hermes', login: 'chatgpt' });
  assert.deepEqual((await accounts.list()).map((item) => [item.provider, item.entryId ?? null]), [['omp', '4'], ['omp', '7'], ['hermes', null]]);
});

test('renames an account and clears its name back to the email', async (t) => {
  const { accounts } = await fixture(t);
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Old' });
  assert.deepEqual(await accounts.renameProfile(added.id, ' Work '), { id: added.id, label: 'Work' });
  assert.equal((await accounts.list())[0].label, 'Work');
  await accounts.renameProfile(added.id, '');
  assert.equal((await accounts.list())[0].label, '');
  await assert.rejects(accounts.renameProfile(added.id, 'x'.repeat(81)), /Enter an account name/);
  await assert.rejects(accounts.renameProfile('missing', 'x'), /Account was not found/);
});

test('serializes preference writes so concurrent changes are all kept', async (t) => {
  const { accounts, root } = await fixture(t);
  const configDir = join(root, 'claude');
  await mkdir(configDir);
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Claude', claudeConfigDir: configDir });
  await Promise.all([accounts.setUsagePreferences({ localCredentials: true }), accounts.removeProfile(added.id), accounts.setUsagePreferences({ localCredentials: true })]);
  assert.deepEqual(await accounts.usagePreferences(), { localCredentials: true, localCredentialsChosen: true });
});

test('accounts sharing one settings file never swap collectors, and the next one inherits the original line', async (t) => {
  const { accounts, root } = await fixture(t);
  const settingsFile = join(root, 'gemini', 'settings.json');
  await mkdir(join(root, 'gemini'));
  const original = { type: 'command', command: 'original-line' };
  await writeFile(settingsFile, JSON.stringify({ statusLine: original }));
  const first = await accounts.addProvider({ provider: 'antigravity', label: 'One' });
  const second = await accounts.addProvider({ provider: 'antigravity', label: 'Two' });
  const commandFor = (id) => `'/data/bin/subset-usage-collect' --account '${id}'`;
  await accounts.installCollector(first.id, commandFor(first.id));
  assert.deepEqual(await accounts.collectorStatus({ ...second, provider: 'antigravity' }, commandFor(second.id)), { state: 'other-account', settingsFile, chained: false, otherAccount: first.id });
  await assert.rejects(accounts.installCollector(second.id, commandFor(second.id)), /Another account's collector/);
  assert.equal(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine.command, commandFor(first.id));
  // Removing the first account restores the original line; a stale collector of a removed account can be replaced.
  await accounts.removeProfile(first.id);
  assert.deepEqual(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine, original);
  await writeFile(settingsFile, JSON.stringify({ statusLine: { type: 'command', command: commandFor(first.id) } }));
  await accounts.installCollector(second.id, commandFor(second.id));
  assert.deepEqual(JSON.parse(await readFile(`${settingsFile}.subset-backup`, 'utf8')).statusLine, original);
  await accounts.uninstallCollector(second.id);
});

test('migrates installed collectors to the current command only while they are still installed', async (t) => {
  const { accounts, root } = await fixture(t);
  const configDir = join(root, 'claude');
  await mkdir(configDir);
  const settingsFile = join(configDir, 'settings.json');
  await writeFile(settingsFile, JSON.stringify({ statusLine: { type: 'command', command: 'previous', padding: 1 } }));
  const added = await accounts.addProvider({ provider: 'claude-code', label: 'Claude', claudeConfigDir: configDir });
  const oldCommand = `node '/old/apps/usage/server.mjs' collect --account '${added.id}'`;
  await accounts.installCollector(added.id, oldCommand);
  const shim = (id) => `'/data/bin/subset-usage-collect' --account '${id}'`;
  assert.deepEqual(await accounts.migrateCollectors(shim), [added.id]);
  assert.deepEqual(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine, { type: 'command', command: shim(added.id), padding: 1 });
  assert.equal(await accounts.chainedStatusLine(added.id), 'previous');
  assert.deepEqual(await accounts.migrateCollectors(shim), []);
  // A line another tool installed since is left alone.
  await writeFile(settingsFile, JSON.stringify({ statusLine: { type: 'command', command: 'other-tool' } }));
  assert.deepEqual(await accounts.migrateCollectors((id) => `new ${id}`), []);
  assert.equal(JSON.parse(await readFile(settingsFile, 'utf8')).statusLine.command, 'other-tool');
});
