import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { findNpmCli } from '../src/npm.mjs';
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

test('finds the npm to run without a shell', () => {
  const only = (...files) => (file) => files.includes(file);
  // The npm that launched the command, from npx-cli.js or npm-cli.js.
  assert.equal(
    findNpmCli({ env: { npm_execpath: '/n/lib/node_modules/npm/bin/npx-cli.js' }, platform: 'darwin', exists: only('/n/lib/node_modules/npm/bin/npm-cli.js') }),
    '/n/lib/node_modules/npm/bin/npm-cli.js'
  );
  // Not launched by npm on macOS and Linux: the caller runs npm from PATH.
  assert.equal(findNpmCli({ env: { npm_execpath: '/x/yarn.js' }, platform: 'linux', exists: () => true }), undefined);
  // On Windows, the first PATH folder with npm.cmd and its npm-cli.js, then the npm installed with Node.js.
  const execPath = 'C:\\Program Files\\nodejs\\node.exe';
  const roaming = 'C:\\Users\\a\\AppData\\Roaming\\npm';
  const bundled = 'C:\\Program Files\\nodejs\\node_modules\\npm\\bin\\npm-cli.js';
  const env = { PATH: `C:\\Windows;${roaming};C:\\Program Files\\nodejs` };
  assert.equal(
    findNpmCli({ env, platform: 'win32', execPath, exists: only(`${roaming}\\npm.cmd`, `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }),
    `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`
  );
  assert.equal(findNpmCli({ env, platform: 'win32', execPath, exists: only(`${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }), bundled);
  assert.equal(findNpmCli({ env, platform: 'win32', execPath, exists: () => false }), undefined);
});

test('passes a hangup on to npm as SIGTERM, which npm forwards to the tool', { skip: process.platform === 'win32' }, async () => {
  // The stand-in npm reports the signal it gets, then exits.
  const signalNpmDir = mkdtempSync(path.join(tmpdir(), 'subset-dev-signal-'));
  after(() => rmSync(signalNpmDir, { recursive: true, force: true }));
  writeFileSync(
    path.join(signalNpmDir, 'npm-cli.js'),
    "for (const s of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(s, () => { process.stdout.write(s); process.exit(0); }); process.stdout.write('ready'); setInterval(() => {}, 1000);"
  );
  const child = spawn(process.execPath, [cli, 'usage'], { env: { ...process.env, npm_execpath: path.join(signalNpmDir, 'npm-cli.js') } });
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    stdout += chunk;
    if (stdout === 'ready') child.kill('SIGHUP');
  });
  const [code] = await once(child, 'exit');
  assert.equal(stdout, 'readySIGTERM');
  assert.equal(code, 0);
});
