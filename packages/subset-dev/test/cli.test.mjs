import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { npmExecArgs, resolveTool, TOOLS } from '../src/tools.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

// A stand-in npm that prints the arguments it was given and exits with FAKE_NPM_EXIT.
const fakeNpmDir = mkdtempSync(path.join(tmpdir(), 'subset-dev-test-'));
after(() => rmSync(fakeNpmDir, { recursive: true, force: true }));
writeFileSync(
  path.join(fakeNpmDir, 'npm-cli.js'),
  'process.stdout.write(JSON.stringify(process.argv.slice(2))); process.exit(Number(process.env.FAKE_NPM_EXIT ?? 0));'
);

function subset(args, env = {}) {
  return spawnSync(process.execPath, [cli, ...args], {
    encoding: 'utf8',
    env: { ...process.env, npm_execpath: path.join(fakeNpmDir, 'npx-cli.js'), ...env }
  });
}

test('resolves a tool to its package at latest, a dist-tag or an exact version', () => {
  assert.deepEqual(resolveTool('usage'), { name: 'usage', spec: '@subset.dev/usage@latest', bin: 'subset-usage' });
  assert.equal(resolveTool('timer@beta').spec, '@subset.dev/timer@beta');
  assert.equal(resolveTool('minutes@0.1.0').spec, '@subset.dev/minutes@0.1.0');
  assert.equal(resolveTool('usage@0.2.0-beta.3').spec, '@subset.dev/usage@0.2.0-beta.3');
});

test('refuses unknown tools and version specs that are not a dist-tag or exact version', () => {
  for (const argument of ['nope', 'Usage', '__proto__', 'toString', '@subset.dev/usage', '-x', '']) {
    assert.match(resolveTool(argument).error, /^Unknown tool/, argument);
  }
  for (const argument of ['usage@', 'usage@^0.2.0', 'usage@>=0', 'usage@file:../x', 'usage@git+https://x', 'usage@--registry=x', 'usage@0.2']) {
    assert.match(resolveTool(argument).error, /is not a dist-tag or exact version/, argument);
  }
});

test('runs the tool bin from its package and passes the arguments after it unchanged', () => {
  assert.deepEqual(npmExecArgs(resolveTool('usage'), ['status', '--json']), [
    'exec', '--yes', '--package=@subset.dev/usage@latest', '--', 'subset-usage', 'status', '--json'
  ]);
  const result = subset(['usage', 'status', '--help', 'two words']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['exec', '--yes', '--package=@subset.dev/usage@latest', '--', 'subset-usage', 'status', '--help', 'two words']);
});

test("exits with the tool's exit code", () => {
  assert.equal(subset(['timer'], { FAKE_NPM_EXIT: '3' }).status, 3);
});

test('prints help listing every tool, and its version', () => {
  for (const args of [[], ['--help'], ['-h'], ['help']]) {
    const result = subset(args);
    assert.equal(result.status, 0);
    for (const [name, tool] of Object.entries(TOOLS)) assert.match(result.stdout, new RegExp(`^  ${name}\\s.*\\(${tool.package}\\)$`, 'm'));
  }
  assert.equal(subset(['--version']).stdout.trim(), version);
});

test('fails with exit code 2 and starts nothing for an unknown tool', () => {
  const result = subset(['nope']);
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /Unknown tool "nope"/);
});
