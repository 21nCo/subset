import assert from 'node:assert/strict';
import { test } from 'node:test';
import { mkdtemp, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { normalizeClaudeAuthStatus, readClaudeAuthStatus, withClaudeAuth } from '../dist/claude.js';
import { createUsageStatus, isUsageStatus } from '../dist/index.js';

const account = (overrides = {}) => ({
  id: 'claude_default', label: 'Claude Code (default)', provider: 'claude-code', source: 'Claude Code status-line snapshot',
  plan: null, observedAt: null, state: 'unavailable', windows: [], resetCredits: null,
  errors: [{ code: 'snapshot_read_failed', message: 'Could not read the configured snapshot file.' }], ...overrides,
});

test('keeps only sign-in state, email, method, plan, and config directory from auth status', () => {
  const status = normalizeClaudeAuthStatus({ loggedIn: true, authMethod: 'claude.ai', subscriptionType: 'max', configDirectory: '/x/.claude', email: 'private@example.com', orgId: 'secret-org' });
  assert.deepEqual(status, { loggedIn: true, email: 'private@example.com', authMethod: 'claude.ai', subscriptionType: 'max', configDirectory: '/x/.claude' });
  assert.equal(normalizeClaudeAuthStatus({ loggedIn: true, email: 'not an email' }).email, null);
  assert.equal(normalizeClaudeAuthStatus({ loggedIn: false, email: 'stale@example.com' }).email, null);
  assert.equal(normalizeClaudeAuthStatus({ loggedIn: 'yes' }), null);
  assert.equal(normalizeClaudeAuthStatus([]), null);
  assert.equal(normalizeClaudeAuthStatus({ loggedIn: true, subscriptionType: '<script>' }).subscriptionType, null);
});

test('merges live sign-in state into snapshot accounts', () => {
  const awaiting = withClaudeAuth(account(), { loggedIn: true, authMethod: 'claude.ai', subscriptionType: 'team', configDirectory: null });
  assert.equal(awaiting.plan, 'team');
  assert.deepEqual(awaiting.errors.map((error) => error.code), ['claude_awaiting_snapshot']);
  const signedOut = withClaudeAuth(account(), { loggedIn: false, authMethod: 'none', subscriptionType: null, configDirectory: null });
  assert.equal(signedOut.state, 'unauthorized');
  assert.equal(signedOut.errors[0].code, 'claude_signed_out');
  const apiKey = withClaudeAuth(account(), { loggedIn: true, authMethod: 'api_key', subscriptionType: null, configDirectory: null });
  assert.equal(apiKey.state, 'unsupported');
  const observed = account({ observedAt: '2026-10-01T00:00:00.000Z', state: 'ok', plan: null, errors: [] });
  assert.deepEqual(withClaudeAuth(observed, { loggedIn: true, authMethod: 'claude.ai', subscriptionType: 'pro', configDirectory: null }), { ...observed, plan: 'pro' });
  assert.equal(withClaudeAuth(observed, null), observed);
  for (const item of [awaiting, signedOut, apiKey]) assert.equal(isUsageStatus(createUsageStatus([item])), true);
});

test('reads auth status through the CLI per config directory without token overrides', async (t) => {
  const root = await mkdtemp(join(tmpdir(), 'subset-claude-auth-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const binary = join(root, 'fake-claude');
  const log = join(root, 'env.log');
  await writeFile(binary, `#!/bin/sh
printf '%s|%s|%s\\n' "\${CLAUDE_CONFIG_DIR-unset}" "\${ANTHROPIC_API_KEY-unset}" "$*" >> '${log}'
printf '{"loggedIn":true,"authMethod":"claude.ai","subscriptionType":"max","configDirectory":"%s","email":"private@example.com"}\\n' "\${CLAUDE_CONFIG_DIR-/default}"
`, { mode: 0o700 });
  const defaultDir = join(root, 'default');
  const workDir = join(root, 'work');
  await mkdir(defaultDir);
  await mkdir(workDir);
  const previous = process.env.ANTHROPIC_API_KEY;
  process.env.ANTHROPIC_API_KEY = 'secret-key';
  t.after(() => { if (previous === undefined) delete process.env.ANTHROPIC_API_KEY; else process.env.ANTHROPIC_API_KEY = previous; });
  const work = await readClaudeAuthStatus(workDir, { claudeBinary: binary, builtInConfigDir: defaultDir });
  assert.deepEqual(work, { loggedIn: true, email: 'private@example.com', authMethod: 'claude.ai', subscriptionType: 'max', configDirectory: workDir });
  assert.equal(withClaudeAuth(account(), work).email, 'private@example.com');
  await readClaudeAuthStatus(defaultDir, { claudeBinary: binary, builtInConfigDir: defaultDir });
  // A host default taken from CLAUDE_CONFIG_DIR is not Claude Code's built-in directory, so it is passed explicitly.
  await readClaudeAuthStatus(workDir, { claudeBinary: binary });
  assert.equal(await readClaudeAuthStatus(join(root, 'missing'), { claudeBinary: binary }), null);
  assert.equal(await readClaudeAuthStatus(workDir, { claudeBinary: join(root, 'no-such-binary') }), null);
  assert.deepEqual((await readFile(log, 'utf8')).trim().split('\n'), [`${workDir}|unset|auth status --json`, 'unset|unset|auth status --json', `${workDir}|unset|auth status --json`]);
});
