// SET-233: the CLI names itself after SUBSET_COMMAND (`subset usage`) when the `subset` launcher started it, and
// subset-usage otherwise. Only text changes: exit codes stay the same.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { fileURLToPath } from 'node:url';

const hostDirectory = fileURLToPath(new URL('..', import.meta.url));
// Values that do not match ^subset [a-z0-9-]+$, which the CLI ignores.
const INVALID = ['', 'subset', 'subset Usage', 'subset usage --help', 'subset usage\n', ' subset usage', 'subset  usage', 'npx subset.dev usage', 'subset-usage', 'subset us/age'];

async function sandbox(t) {
  const root = await mkdtemp(join(tmpdir(), 'subset-usage-name-'));
  t.after(() => rm(root, { recursive: true, force: true }));
  const env = { ...process.env, HOME: root, SUBSET_USAGE_DATA_DIR: join(root, 'data'), SUBSET_USAGE_PROFILES_FILE: join(root, 'profiles.json') };
  delete env.SUBSET_COMMAND;
  return (args, extra = {}) => spawnSync(process.execPath, ['src/server.mjs', ...args], { cwd: hostDirectory, env: { ...env, ...extra }, encoding: 'utf8', timeout: 15000 });
}

test('help names subset-usage when started directly and subset usage through subset', async (t) => {
  const run = await sandbox(t);
  const direct = run(['--help']);
  assert.equal(direct.status, 0);
  assert.match(direct.stdout, /^Usage: subset-usage \[serve\|status\|mcp\|collect\] \[options\]\n/);
  assert.doesNotMatch(direct.stdout, /subset usage/);

  const through = run(['status', '--help'], { SUBSET_COMMAND: 'subset usage' });
  assert.equal(through.status, 0);
  assert.match(through.stdout, /^Usage: subset usage \[serve\|status\|mcp\|collect\] \[options\]\n/);
  assert.doesNotMatch(through.stdout, /subset-usage/);
  // Only the name differs from the bin's help.
  assert.equal(through.stdout.replace('subset usage', 'subset-usage'), direct.stdout);

  for (const value of INVALID) assert.equal(run(['--help'], { SUBSET_COMMAND: value }).stdout, direct.stdout, JSON.stringify(value));
});

test('an unknown command or extra mcp arguments print the help naming the command, with exit 2', async (t) => {
  const run = await sandbox(t);
  const cases = [[{}, 'subset-usage'], [{ SUBSET_COMMAND: 'subset usage' }, 'subset usage'], ...INVALID.map((value) => [{ SUBSET_COMMAND: value }, 'subset-usage'])];
  for (const [env, name] of cases) {
    for (const args of [['frobnicate'], ['mcp', 'extra']]) {
      const result = run(args, env);
      assert.equal(result.status, 2, `${args.join(' ')} ${JSON.stringify(env.SUBSET_COMMAND)}`);
      assert.equal(result.stdout, '');
      assert.ok(result.stderr.startsWith(`Usage: ${name} [serve|status|mcp|collect] [options]\n`), `${JSON.stringify(env.SUBSET_COMMAND)}: ${result.stderr}`);
    }
  }
});
