// subset <tool> runs the command bundled in an installed Subset Mac app (SET-232). The launcher runs as its own process
// with install-preload.mjs, which makes it report darwin and runs stand-ins for plutil and codesign. Apps are folders
// standing in for /Applications and ~/Applications (SUBSET_APPLICATIONS_DIRS). The codesign stand-in judges the file
// it is given by `<file>.signature.json` beside it ({ valid, team }; none means unsigned) and logs each call.
import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, beforeEach, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { findAppHelper, helperDeclarationProblems } from '../src/helpers.mjs';
import { readMacosReleaseManifests } from '../../../scripts/release-macos.mjs';
import { resolveTool, TOOLS } from '../src/tools.mjs';
import { makeApp, stubPlutil } from './helpers.mjs';

const skip = process.platform === 'win32' && 'the stand-ins are shebang scripts, which Windows cannot run';
const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const preload = fileURLToPath(new URL('./install-preload.mjs', import.meta.url));
// Without links in it (macOS's temporary folder is under /var, a link to /private/var), as the launcher resolves them.
const root = realpathSync(mkdtempSync(path.join(tmpdir(), 'subset-helpers-test-')));
after(() => rmSync(root, { recursive: true, force: true }));

const stubs = path.join(root, 'stubs');
mkdirSync(stubs);
const log = path.join(root, 'calls.log');
const codesign = path.join(stubs, 'codesign');
writeFileSync(
  codesign,
  `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
const target = args.at(-1);
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify({ tool: 'codesign', args }) + '\\n');
let signature;
try { signature = JSON.parse(fs.readFileSync(target + '.signature.json', 'utf8')); } catch {}
if (args.length === 3 && args[0] === '--verify' && args[1] === '--strict') {
  if (!signature) { console.error(target + ': code object is not signed at all'); process.exit(1); }
  if (signature.valid === false) { console.error(target + ': invalid signature (code or signature have been modified)'); process.exit(1); }
} else if (args.length === 3 && args[0] === '-d' && args[1] === '--verbose=2') {
  if (!signature) { console.error(target + ': code object is not signed at all'); process.exit(1); }
  console.error('Executable=' + target + '\\nTeamIdentifier=' + (signature.team || 'not set'));
} else { console.error('stub codesign: unexpected arguments'); process.exit(64); }
`
);
chmodSync(codesign, 0o755);
const plutil = stubPlutil(stubs);
const stubMap = JSON.stringify({ '/usr/bin/codesign': codesign, '/usr/bin/plutil': plutil });

// An npm that logs its arguments and fails, as when the registry cannot be reached: no test here should reach the npm
// package unless it asks for it.
mkdirSync(path.join(root, 'npm'));
writeFileSync(
  path.join(root, 'npm', 'npm-cli.js'),
  `require('node:fs').appendFileSync(${JSON.stringify(log)}, JSON.stringify({ tool: 'npm', args: process.argv.slice(2) }) + '\\n'); process.exit(7);`
);

const SUBSET = { valid: true, team: 'SAZVPX4CAA' };
// A native helper: prints its arguments, SUBSET_COMMAND and process ID as JSON and exits with HELPER_EXIT. With
// HELPER_WAIT it prints `ready <pid>`, then reports each signal it gets and exits 0 a moment after the first; with
// HELPER_DIE it prints `ready <pid>` and waits to be killed.
const NATIVE = `#!/usr/bin/env node
if (process.env.HELPER_WAIT) {
  for (const s of ['SIGTERM', 'SIGHUP', 'SIGINT']) process.on(s, () => { process.stdout.write(' ' + s); setTimeout(() => process.exit(0), 300); });
  process.stdout.write('ready ' + process.pid);
  setTimeout(() => process.exit(9), 5000);
} else if (process.env.HELPER_DIE) {
  process.stdout.write('ready ' + process.pid);
  setTimeout(() => process.exit(9), 5000);
} else {
  process.stdout.write(JSON.stringify({ args: process.argv.slice(2), command: process.env.SUBSET_COMMAND, pid: process.pid }));
  process.exit(Number(process.env.HELPER_EXIT ?? 0));
}
`;
// A node helper (an app's embedded cli.mjs): the same report, from the process that loaded it.
const NODE = `process.stdout.write(JSON.stringify({ args: process.argv.slice(2), command: process.env.SUBSET_COMMAND, pid: process.pid, file: process.argv[1] }));
process.exitCode = Number(process.env.HELPER_EXIT ?? 0);
`;

let apps;
let userApps;
beforeEach(() => {
  rmSync(log, { force: true });
  apps = mkdtempSync(path.join(root, 'Applications-'));
  userApps = mkdtempSync(path.join(root, 'user-Applications-'));
});

/** Writes `<dir>/<appName>.app` for a tool's app with its helper (unless `helper` is null), signed as `signature`. */
function installApp(dir, name, { helper = name === 'timer' || name === 'minutes' ? NODE : NATIVE, signature = SUBSET, appSignature = SUBSET, bundleId } = {}) {
  const app = TOOLS[name].app;
  const bundle = makeApp(dir, app.appName, { bundleId: bundleId ?? app.bundleId, version: '1.0.0', build: '1' });
  writeFileSync(`${bundle}.signature.json`, JSON.stringify(appSignature));
  if (helper === null) return bundle;
  const file = path.join(bundle, app.helper);
  mkdirSync(path.dirname(file), { recursive: true });
  writeFileSync(file, helper);
  chmodSync(file, 0o755);
  if (signature) writeFileSync(`${file}.signature.json`, JSON.stringify(signature));
  return bundle;
}

const environment = (extra) => ({
  ...process.env,
  HOME: root,
  SUBSET_APPLICATIONS_DIRS: `${apps}${path.delimiter}${userApps}`,
  STUB_TOOL_MAP: stubMap,
  npm_execpath: path.join(root, 'npm', 'npx-cli.js'),
  ...extra
});
const subset = (args, extra = {}) => spawnSync(process.execPath, ['--import', preload, cli, ...args], { encoding: 'utf8', env: environment(extra) });
// The calls of a tool since the test began.
const calls = (tool) =>
  (existsSync(log) ? readFileSync(log, 'utf8') : '')
    .split('\n')
    .filter(Boolean)
    .map((line) => JSON.parse(line))
    .filter((entry) => entry.tool === tool)
    .map((entry) => entry.args);

test('runs an installed app\'s native helper with the arguments unchanged, after checking its signature and team', { skip }, () => {
  const bundle = installApp(apps, 'system');
  const result = subset(['system', 'status', '--json', 'two words', '--help']);
  assert.equal(result.status, 0, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.args, ['status', '--json', 'two words', '--help']);
  assert.equal(report.command, 'subset system');
  const helper = path.join(bundle, 'Contents', 'Helpers', 'subset-system');
  assert.deepEqual(calls('codesign'), [['--verify', '--strict', helper], ['-d', '--verbose=2', helper]]);
  assert.deepEqual(calls('npm'), []);
});

test("exits with the native helper's exit code", { skip }, () => {
  installApp(apps, 'point-in-time');
  for (const code of [0, 1, 3, 130]) assert.equal(subset(['point-in-time', 'status'], { HELPER_EXIT: String(code) }).status, code);
});

test('loads a node helper into its own process, as it loads an npm tool, without asking npm', { skip }, () => {
  const bundle = installApp(apps, 'timer');
  const result = subset(['timer', 'list', '--json'], { HELPER_EXIT: '4' });
  assert.equal(result.status, 4, result.stderr);
  const report = JSON.parse(result.stdout);
  assert.deepEqual(report.args, ['list', '--json']);
  assert.equal(report.command, 'subset timer');
  assert.equal(report.file, path.join(bundle, 'Contents', 'Resources', 'timer-cli', 'dist', 'cli.mjs'));
  // A node helper has no signature of its own: the app's signature seals it.
  assert.deepEqual(calls('codesign'), [['--verify', '--strict', bundle], ['-d', '--verbose=2', bundle]]);
  assert.deepEqual(calls('npm'), []);
});

test('a version given runs the npm package, never the installed app', { skip }, () => {
  installApp(apps, 'timer');
  for (const version of ['beta', 'latest', '0.2.0']) {
    rmSync(log, { force: true });
    const result = subset([`timer@${version}`, 'list']);
    assert.equal(result.status, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, new RegExp(`npm could not fetch @subset\\.dev/timer@${version.replaceAll('.', '\\.')}`));
    assert.deepEqual(calls('npm')[0], ['exec', '--yes', `--package=@subset.dev/timer@${version}`, '--', 'node', '-p', 'process.env.PATH']);
    assert.deepEqual(calls('codesign'), []);
  }
  // An app-only tool has no npm versions.
  rmSync(log, { force: true });
  const appOnly = subset(['system@beta', 'status']);
  assert.equal(appOnly.status, 2);
  assert.match(appOnly.stderr, /^subset: system comes with the Subset System app and has no npm versions\. Run "subset system" instead\.$/m);
  assert.deepEqual(calls('npm'), []);
});

test('without the app, an app-only tool says how to install it, and a tool with a package runs the package', { skip }, () => {
  // A folder of that name with another bundle ID is not the app.
  installApp(apps, 'system', { bundleId: 'com.example.other' });
  const system = subset(['system', 'status']);
  assert.equal(system.status, 1);
  assert.equal(system.stderr, 'subset: system comes with the Subset System app. Install it with: subset install system\n');
  assert.equal(subset(['point-in-time']).stderr, 'subset: point-in-time comes with the pointInTime app. Install it with: subset install point-in-time\n');
  assert.deepEqual(calls('npm'), []);

  const timer = subset(['timer', 'list']);
  assert.match(timer.stderr, /npm could not fetch @subset\.dev\/timer@latest/);
  assert.deepEqual(calls('npm')[0], ['exec', '--yes', '--package=@subset.dev/timer@latest', '--', 'node', '-p', 'process.env.PATH']);
});

test('an installed app without the helper (an older version) is updated, or the npm package runs', { skip }, () => {
  const bundle = installApp(apps, 'system', { helper: null });
  const system = subset(['system', 'status']);
  assert.equal(system.status, 1);
  assert.equal(system.stderr, `subset: ${bundle} has no Contents/Helpers/subset-system. Update it with: subset update system\n`);
  installApp(apps, 'minutes', { helper: null });
  assert.match(subset(['minutes']).stderr, /npm could not fetch @subset\.dev\/minutes@latest/);
  assert.equal(calls('npm').length > 0, true);
});

test('refuses a helper that is not signed by the Subset team, an invalid or missing signature, or a file outside the app', { skip }, () => {
  const cases = [
    ['another team', 'system', { signature: { valid: true, team: 'ABCDE12345' } }, /Contents\/Helpers\/subset-system: it is not signed by the Subset team SAZVPX4CAA \(TeamIdentifier: ABCDE12345\)/],
    ['an ad-hoc signature', 'system', { signature: { valid: true } }, /it is not signed by the Subset team SAZVPX4CAA \(TeamIdentifier: not set\)/],
    ['an invalid signature', 'point-in-time', { signature: { valid: false, team: 'SAZVPX4CAA' } }, /its code signature is not valid \(codesign: .*modified\)/],
    ['no signature', 'system', { signature: null }, /its code signature is not valid \(codesign: .*not signed at all\)/],
    ['a node helper in an app of another team', 'timer', { appSignature: { valid: true, team: 'ABCDE12345' } }, /the app: it is not signed by the Subset team SAZVPX4CAA \(TeamIdentifier: ABCDE12345\)/]
  ];
  for (const [label, name, options, message] of cases) {
    rmSync(log, { force: true });
    const bundle = installApp(apps, name, options);
    const result = subset([name, 'status']);
    assert.equal(result.status, 1, label);
    assert.equal(result.stdout, '', `${label}: the helper did not run`);
    assert.ok(result.stderr.startsWith(`subset: ${bundle} was not run: `), `${label}: ${result.stderr}`);
    assert.match(result.stderr, message, label);
    // A refused app does not fall back to the npm package.
    assert.deepEqual(calls('npm'), [], label);
    rmSync(bundle, { recursive: true });
  }

  // A helper linked to a file outside the app.
  rmSync(log, { force: true });
  const bundle = installApp(apps, 'system');
  const outside = path.join(root, 'outside-helper');
  writeFileSync(outside, NATIVE);
  chmodSync(outside, 0o755);
  writeFileSync(`${outside}.signature.json`, JSON.stringify(SUBSET));
  const file = path.join(bundle, 'Contents', 'Helpers', 'subset-system');
  rmSync(file);
  symlinkSync(outside, file);
  const result = subset(['system', 'status']);
  assert.equal(result.status, 1);
  assert.equal(result.stderr, `subset: ${bundle} was not run: its Contents/Helpers/subset-system is not a file inside the app.\n`);
  assert.deepEqual(calls('codesign'), []);
});

test('runs the app in /Applications before the one in ~/Applications', { skip }, async () => {
  installApp(userApps, 'system');
  const first = installApp(apps, 'system');
  const found = await findAppHelper(TOOLS.system.app, { env: environment(), home: root, tools: { codesign, plutil } });
  assert.deepEqual(found, { status: 'found', bundle: first, file: path.join(first, 'Contents', 'Helpers', 'subset-system'), kind: 'native' });
  rmSync(first, { recursive: true });
  assert.equal((await findAppHelper(TOOLS.system.app, { env: environment(), home: root, tools: { codesign, plutil } })).bundle, path.join(userApps, 'Subset System.app'));
});

// Starts the launcher on a waiting native helper, in its own process group, and sends `signal` once the helper is
// running: to the launcher, or with `group` to the launcher's process group (as Ctrl-C at a terminal does).
async function signalLauncher(signal, { group = false, die = false } = {}) {
  const child = spawn(process.execPath, ['--import', preload, cli, 'system', 'watch'], { env: environment(die ? { HELPER_DIE: '1' } : { HELPER_WAIT: '1' }), detached: true });
  let stdout = '';
  child.stdout.setEncoding('utf8');
  child.stdout.on('data', (chunk) => {
    const first = stdout === '';
    stdout += chunk;
    if (first) process.kill(group ? -child.pid : child.pid, signal);
  });
  const [code, endSignal] = await once(child, 'exit');
  const [, pid, ...signals] = stdout.split(' ');
  return { ownProcess: Number(pid) !== child.pid, signals, code, endSignal };
}

test('passes each signal on to a native helper exactly once, whether sent to the launcher or to its group', { skip }, async () => {
  installApp(apps, 'system');
  for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
    for (const group of [false, true]) {
      assert.deepEqual(await signalLauncher(signal, { group }), { ownProcess: true, signals: [signal], code: 0, endSignal: null }, `${signal}${group ? ' to the group' : ''}`);
    }
  }
});

test('ends by the signal that ended the native helper', { skip }, async () => {
  installApp(apps, 'system');
  for (const signal of ['SIGTERM', 'SIGHUP', 'SIGINT']) {
    assert.deepEqual(await signalLauncher(signal, { die: true }), { ownProcess: true, signals: [], code: null, endSignal: signal }, signal);
  }
});

test('resolves an explicit version, an app-only tool and a tool with both', () => {
  assert.equal(resolveTool('timer').explicit, false);
  assert.equal(resolveTool('timer@latest').explicit, true);
  assert.deepEqual(resolveTool('system'), { name: 'system', app: TOOLS.system.app, explicit: false });
  assert.equal(resolveTool('usage').app, undefined);
  assert.match(resolveTool('point-in-time@0.1.0').error, /has no npm versions/);
});

// The check npm run check (scripts/check-workspaces.mjs) runs on the launcher's tools and the apps' declarations.
test('the launcher tools and the helper declarations must agree', () => {
  const native = fileURLToPath(new URL('../../../native/', import.meta.url));
  assert.deepEqual(helperDeclarationProblems(TOOLS, readMacosReleaseManifests(native)), []);

  const manifest = (app, bundleId, helpers) => ({ app, bundleId, helpers });
  const tools = {
    system: { app: { id: 'system', appName: 'Subset System', bundleId: 'dev.subset.system', helper: 'Contents/Helpers/subset-system', kind: 'native' } },
    usage: { package: '@subset.dev/usage', bin: 'subset-usage' }
  };
  const system = { appId: 'system', manifest: manifest('Subset System', 'dev.subset.system', [{ command: 'system', path: 'Contents/Helpers/subset-system', kind: 'native' }]) };
  assert.deepEqual(helperDeclarationProblems(tools, [system]), []);

  // A declared helper the launcher does not run.
  const extra = { appId: 'record', manifest: manifest('Record', 'dev.subset.record', [{ command: 'record', path: 'Contents/Helpers/record', kind: 'native' }]) };
  assert.deepEqual(helperDeclarationProblems(tools, [system, extra]), [
    'native/record/macos-release.json declares the helper record, which is not a subset.dev launcher tool with an app in packages/subset-dev/src/tools.mjs'
  ]);
  // A launcher helper no app declares.
  assert.deepEqual(helperDeclarationProblems(tools, [{ appId: 'system', manifest: manifest('Subset System', 'dev.subset.system') }]), [
    'subset system runs a helper of the Subset System app, but no native/*/macos-release.json declares the helper system'
  ]);
  // A launcher helper that differs from the declaration.
  const moved = { appId: 'system', manifest: manifest('Subset System', 'dev.subset.system', [{ command: 'system', path: 'Contents/MacOS/subset-system', kind: 'native' }]) };
  assert.deepEqual(helperDeclarationProblems(tools, [moved]), ['subset system has app.helper "Contents/Helpers/subset-system", but native/system/macos-release.json declares "Contents/MacOS/subset-system"']);
  // A tool with neither a package nor an app.
  assert.deepEqual(helperDeclarationProblems({ ...tools, nothing: {} }, [system]), ['subset nothing has neither an npm package nor an app']);
});

// On macOS, with the real codesign and plutil: a helper ad-hoc signed (as a local build is) is refused at the team
// check and does not run.
test('with the real codesign, refuses an ad-hoc signed native helper at the team check', { skip: process.platform !== 'darwin' && 'needs macOS' }, () => {
  const bundle = makeApp(apps, 'Subset System', { bundleId: 'dev.subset.system', version: '1.0.0', build: '1' });
  const helper = path.join(bundle, 'Contents', 'Helpers', 'subset-system');
  mkdirSync(path.dirname(helper), { recursive: true });
  copyFileSync('/usr/bin/true', helper);
  execFileSync('/usr/bin/codesign', ['--sign', '-', '--force', helper]);
  execFileSync('/usr/bin/codesign', ['--verify', '--strict', helper]);
  const result = spawnSync(process.execPath, [cli, 'system', 'status'], {
    encoding: 'utf8',
    env: { ...process.env, HOME: root, SUBSET_APPLICATIONS_DIRS: `${apps}${path.delimiter}${userApps}` }
  });
  assert.equal(result.status, 1);
  assert.equal(result.stderr, `subset: ${bundle} was not run: Contents/Helpers/subset-system: it is not signed by the Subset team SAZVPX4CAA (TeamIdentifier: not set).\n`);
});
