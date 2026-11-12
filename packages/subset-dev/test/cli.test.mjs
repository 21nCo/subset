import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { findToolBin } from '../src/bin.mjs';
import { findNpmCli } from '../src/npm.mjs';
import { npmLocateArgs, resolveTool, TOOLS } from '../src/tools.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

// A stand-in npm and an installed @subset.dev/usage. The npm records its arguments in FAKE_NPM_LOG, prints a PATH
// whose node_modules/.bin folder holds the tool, and exits with FAKE_NPM_EXIT. The tool prints its arguments as JSON
// and exits with TOOL_EXIT; with TOOL_WAIT it prints `ready <pid>`, then reports each signal it gets.
const root = mkdtempSync(path.join(tmpdir(), 'subset-dev-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
const npmLog = path.join(root, 'npm-args.json');
const modules = path.join(root, 'prefix', 'node_modules');
mkdirSync(path.join(modules, '.bin'), { recursive: true });
mkdirSync(path.join(modules, '@subset.dev', 'usage'), { recursive: true });
writeFileSync(path.join(modules, '@subset.dev', 'usage', 'package.json'), JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'cli.mjs' } }));
writeFileSync(
  path.join(modules, '@subset.dev', 'usage', 'cli.mjs'),
  `if (process.env.TOOL_WAIT) {
     // Reports every signal it gets, and exits 0 a moment after the first.
     for (const s of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
       process.on(s, () => {
         process.stdout.write(' ' + s);
         setTimeout(() => process.exit(0), 200);
       });
     }
     process.stdout.write('ready ' + process.pid);
     setTimeout(() => process.exit(9), 5000);
   } else {
     if (process.env.TOOL_PRINT_PATH) process.stdout.write(process.env.PATH);
     else process.stdout.write(JSON.stringify(process.argv.slice(2)));
     process.exitCode = Number(process.env.TOOL_EXIT ?? 0);
   }`
);
mkdirSync(path.join(root, 'npm'));
writeFileSync(
  path.join(root, 'npm', 'npm-cli.js'),
  `require('node:fs').writeFileSync(${JSON.stringify(npmLog)}, JSON.stringify(process.argv.slice(2)));
   process.stdout.write('some npm output\\n' + ${JSON.stringify(`/elsewhere/node_modules/.bin${path.delimiter}${path.join(modules, '.bin')}${path.delimiter}/usr/bin`)} + '\\n');
   process.exit(Number(process.env.FAKE_NPM_EXIT ?? 0));`
);
const env = { ...process.env, npm_execpath: path.join(root, 'npm', 'npx-cli.js') };

const subset = (args, extra = {}) => spawnSync(process.execPath, [cli, ...args], { encoding: 'utf8', env: { ...env, ...extra } });

test('resolves a tool to its package at latest, a dist-tag or an exact version', () => {
  assert.deepEqual(resolveTool('usage'), { name: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', version: 'latest', spec: '@subset.dev/usage@latest' });
  assert.equal(resolveTool('timer@beta').spec, '@subset.dev/timer@beta');
  assert.equal(resolveTool('minutes@0.1.0').spec, '@subset.dev/minutes@0.1.0');
  assert.equal(resolveTool('usage@0.2.0-beta.3').spec, '@subset.dev/usage@0.2.0-beta.3');
});

test('refuses unknown tools, and versions that are not a published dist-tag or exact version', () => {
  for (const argument of ['nope', 'Usage', '__proto__', 'toString', '@subset.dev/usage', '-x', '']) {
    assert.match(resolveTool(argument).error, /^Unknown tool/, argument);
  }
  for (const argument of ['usage@', 'usage@x', 'usage@v1', 'usage@other', 'usage@^0.2.0', 'usage@>=0', 'usage@file:../x', 'usage@git+https://x', 'usage@--registry=x', 'usage@0.2']) {
    assert.match(resolveTool(argument).error, /is not latest, beta, next or an exact version/, argument);
  }
});

test('asks npm for the tool, then runs its bin with the arguments unchanged', () => {
  const result = subset(['usage', 'status', '--help', 'two words', '%PATH%', 'trailing\\']);
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual(JSON.parse(result.stdout), ['status', '--help', 'two words', '%PATH%', 'trailing\\']);
  assert.deepEqual(JSON.parse(readFileSync(npmLog, 'utf8')), npmLocateArgs(resolveTool('usage')));
  assert.deepEqual(npmLocateArgs(resolveTool('usage')), ['exec', '--yes', '--package=@subset.dev/usage@latest', '--', 'node', '-p', 'process.env.PATH']);
});

test('runs the tool with the PATH npm reported', () => {
  const result = subset(['usage'], { TOOL_PRINT_PATH: '1' });
  assert.equal(result.stdout, `/elsewhere/node_modules/.bin${path.delimiter}${path.join(modules, '.bin')}${path.delimiter}/usr/bin`);
});

test("exits with the tool's exit code, and fails when npm or the tool's bin does", () => {
  assert.equal(subset(['usage'], { TOOL_EXIT: '3' }).status, 3);
  const npmFailed = subset(['usage'], { FAKE_NPM_EXIT: '7' });
  assert.equal(npmFailed.status, 1);
  assert.match(npmFailed.stderr, /npm could not fetch @subset\.dev\/usage@latest/);
  // The fake prefix holds usage 0.2.0 only.
  assert.match(subset(['usage@0.1.0']).stderr, /its subset-usage command was not found/);
  assert.match(subset(['timer']).stderr, /its subset-timer command was not found/);
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
  rmSync(npmLog, { force: true });
  const result = subset(['nope']);
  assert.equal(result.status, 2);
  assert.equal(result.stdout, '');
  assert.match(result.stderr, /Unknown tool "nope"/);
  assert.throws(() => readFileSync(npmLog), { code: 'ENOENT' });
});

test("finds a tool's bin in the first node_modules/.bin folder that holds its package", () => {
  const files = {
    '/a/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.1.0', bin: { 'subset-usage': 'dist/cli.mjs' } }),
    '/b/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'dist/cli.mjs' } }),
    '/c/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.3.0', bin: { 'subset-usage': '../../../escape.mjs' } }),
    '/d/node_modules/@subset.dev/usage/package.json': JSON.stringify({ name: '@subset.dev/usage', version: '0.4.0', bin: { 'subset-usage': '..cli.mjs' } }),
    '/e/node_modules/@subset.dev/usage/package.json': 'null'
  };
  const readFile = (file) => {
    if (!(file in files)) throw Object.assign(new Error('missing'), { code: 'ENOENT' });
    return files[file];
  };
  const find = (pathValue, argument) => findToolBin(pathValue, resolveTool(argument), { platform: 'linux', readFile });
  const pathValue = '/usr/bin:/x/node_modules/.bin:/a/node_modules/.bin:/b/node_modules/.bin';
  assert.equal(find(pathValue, 'usage'), '/a/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(find(pathValue, 'usage@0.2.0'), '/b/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(find(pathValue, 'usage@0.9.0'), undefined);
  // A bin that points outside its package is ignored.
  assert.equal(find('/c/node_modules/.bin', 'usage'), undefined);
  // A file whose name starts with `..` is still inside the package; a package.json that is not an object is skipped.
  assert.equal(find('/d/node_modules/.bin', 'usage'), '/d/node_modules/@subset.dev/usage/..cli.mjs');
  assert.equal(find('/e/node_modules/.bin:/b/node_modules/.bin', 'usage'), '/b/node_modules/@subset.dev/usage/dist/cli.mjs');
  assert.equal(
    findToolBin('C:\\p\\node_modules\\.bin;C:\\Windows', resolveTool('usage'), {
      platform: 'win32',
      readFile: (file) => {
        assert.equal(file, 'C:\\p\\node_modules\\@subset.dev\\usage\\package.json');
        return JSON.stringify({ name: '@subset.dev/usage', version: '0.2.0', bin: { 'subset-usage': 'dist/cli.mjs' } });
      }
    }),
    'C:\\p\\node_modules\\@subset.dev\\usage\\dist\\cli.mjs'
  );
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
  const winEnv = { PATH: `C:\\Windows;${roaming};C:\\Program Files\\nodejs` };
  assert.equal(
    findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: only(`${roaming}\\npm.cmd`, `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }),
    `${roaming}\\node_modules\\npm\\bin\\npm-cli.js`
  );
  assert.equal(findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: only(`${roaming}\\node_modules\\npm\\bin\\npm-cli.js`, bundled) }), bundled);
  assert.equal(findNpmCli({ env: winEnv, platform: 'win32', execPath, exists: () => false }), undefined);
});

// Starts the launcher on the waiting tool, in its own process group, and sends `signal` once the tool is running: to
// the launcher's process, or with `group` to its whole process group, as a terminal does for Ctrl-C or a hangup.
// Resolves with the tool's process ID, the signals it reported and how the launcher ended.
async function signalLauncher(signal, { group = false } = {}) {
  const child = spawn(process.execPath, [cli, 'usage'], { env: { ...env, TOOL_WAIT: '1' }, detached: true });
  let stdout = '';
  child.stdout.on('data', (chunk) => {
    const first = !stdout;
    stdout += chunk;
    if (first) process.kill(group ? -child.pid : child.pid, signal);
  });
  const [code, endSignal] = await once(child, 'close');
  const [, pid, ...signals] = stdout.split(' ');
  return { sameProcess: Number(pid) === child.pid, signals, code, endSignal };
}

test('runs the tool in its own process, so each signal reaches the tool exactly once', { skip: process.platform === 'win32' }, async () => {
  for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
    for (const group of [false, true]) {
      assert.deepEqual(await signalLauncher(signal, { group }), { sameProcess: true, signals: [signal], code: 0, endSignal: null }, `${signal}${group ? ' to the group' : ''}`);
    }
  }
});
