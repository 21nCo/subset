// subset update and subset uninstall (SET-231) with the tool stand-ins of install-stubs.mjs, so they run on Linux.
// Every refusal, failure and interruption is checked against the invariant: the installed app is the old copy,
// untouched (same inode and Info.plist), or the new verified one, never neither, and nothing staged is left behind.
import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, renameSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { setTimeout as sleep } from 'node:timers/promises';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { runInstall } from '../src/commands/install.mjs';
import { runList } from '../src/commands/list.mjs';
import { parseUninstallArgs, runUninstall } from '../src/commands/uninstall.mjs';
import { NPM_LATEST_URL, newerLauncher, parseUpdateArgs, runUpdate } from '../src/commands/update.mjs';
import { receiptFile } from '../src/macos/apps.mjs';
import { moveToTrash, prepareTrash, removeLeftCopies, renameIntoTrash, trashFolder, trashName } from '../src/macos/trash.mjs';
import { LockError, lockApp, lockKey, locksFolder } from '../src/macos/lock.mjs';
import { decideUpdate, recoverApps, swapApp, UPDATE_TOOLS } from '../src/macos/update.mjs';
import { makeApp, writeReceipt } from './helpers.mjs';
import { appFiles, attachedImages, makeImage, stubTools, stubToolsSkip } from './install-stubs.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const preload = new URL('./install-preload.mjs', import.meta.url).href;
const template = JSON.parse(readFileSync(new URL('../../catalog/feed/fixtures/catalog-valid-live-and-beta.json', import.meta.url), 'utf8'));
const LIVE_URL = template.apps[0].channels.live.url;
const BETA_URL = template.apps[0].channels.beta.url;
const NOW = Date.parse('2026-11-14T12:00:00Z');
const root = mkdtempSync(path.join(tmpdir(), 'subset-update-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
mkdirSync(path.join(root, 'tools'));
const tools = stubToolsSkip ? undefined : stubTools(path.join(root, 'tools'));
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const skip = stubToolsSkip;
const BUNDLE_ID = 'dev.subset.breaks';

let count = 0;
// A case folder: a home, stand-ins for /Applications and ~/Applications, a Trash, a temporary folder and a stub log.
function setup() {
  const base = path.join(root, `case-${(count += 1)}`);
  const c = {
    base,
    home: path.join(base, 'home'),
    system: path.join(base, 'Applications'),
    user: path.join(base, 'user-Applications'),
    trash: path.join(base, 'Trash'),
    tmp: path.join(base, 'tmp'),
    log: path.join(base, 'stub.log'),
    feedFile: path.join(base, 'catalog.json')
  };
  for (const dir of [c.home, c.system, c.user, c.trash, c.tmp]) mkdirSync(dir, { recursive: true });
  c.env = { SUBSET_CATALOG_URL: pathToFileURL(c.feedFile).href, SUBSET_APPLICATIONS_DIRS: `${c.system}${path.delimiter}${c.user}`, SUBSET_TRASH_DIR: c.trash };
  c.app = path.join(c.system, 'Breaks.app');
  return c;
}

// The case's feed: Breaks with the given live and beta channels ({ version, build?, image }), each with its image's
// SHA-256 (or `sha`); a channel left out is removed.
function feed(c, { live, beta }) {
  const doc = structuredClone(template);
  const channels = doc.apps[0].channels;
  for (const [name, channel] of [['live', live], ['beta', beta]]) {
    if (!channel) delete channels[name];
    else Object.assign(channels[name], { version: channel.version, sha256: channel.sha ?? sha256(channel.image) }, name === 'beta' ? { build: channel.build } : {});
  }
  writeFileSync(c.feedFile, JSON.stringify(doc));
}

const breaksImage = (options) => makeImage({ ...appFiles('Breaks.app', options), Applications: 'link' });

// The installed Breaks in the /Applications stand-in, with a file marking this copy, and its receipt when `channel`.
function installed(c, { version = '0.1.0', build = '1', channel, dir = c.system } = {}) {
  const bundle = makeApp(dir, 'Breaks', { bundleId: BUNDLE_ID, version, build });
  writeFileSync(path.join(bundle, 'Contents', 'old-copy'), version);
  if (channel) {
    writeReceipt(c.home, BUNDLE_ID, {
      schema: 'subset.receipt@1',
      channel,
      version,
      ...(channel === 'beta' ? { build: Number(build) } : {}),
      sha256: 'a'.repeat(64),
      installedAt: '2026-11-01T00:00:00Z',
      path: '/Applications/Breaks.app'
    });
  }
  return { bundle, ino: lstatSync(bundle).ino, plist: readFileSync(path.join(bundle, 'Contents', 'Info.plist')), receipt: channel ? readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8') : undefined };
}

// A fetch serving `images` ({ url: bytes }) and the npm registry's `latest` of subset.dev as `registry` (a version, or
// an HTTP status). `calls` lists the URLs asked for.
function fakeFetch(images, { registry } = {}) {
  const calls = [];
  const fetch = async (url) => {
    calls.push(String(url));
    if (String(url) === NPM_LATEST_URL) {
      if (typeof registry === 'number' || registry === undefined) return new Response('{}', { status: registry ?? 404 });
      return new Response(JSON.stringify({ name: 'subset.dev', version: registry }), { status: 200 });
    }
    const bytes = images[String(url)];
    return bytes ? new Response(bytes) : new Response('not found', { status: 404 });
  };
  return Object.assign(fetch, { calls });
}

// Runs a command in this process with the stand-in tools and `extraEnv` in the stand-ins' environment.
async function run(runner, c, args, { fetch = fakeFetch({}), platform = 'darwin', signals = new EventEmitter(), extraEnv = {}, ...rest } = {}) {
  let stdout = '';
  let stderr = '';
  const keys = ['TMPDIR', 'STUB_LOG', ...Object.keys(extraEnv)];
  const previous = Object.fromEntries(keys.map((key) => [key, process.env[key]]));
  Object.assign(process.env, { TMPDIR: c.tmp, STUB_LOG: c.log, ...extraEnv });
  try {
    const code = await runner(args, {
      env: c.env,
      platform,
      home: c.home,
      now: NOW,
      clock: () => NOW,
      fetch,
      tools,
      signals,
      stdout: { write: (text) => (stdout += text) },
      stderr: { write: (text) => (stderr += text) },
      ...rest
    });
    return { code, stdout, stderr };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}
const update = (c, args, options) => run(runUpdate, c, args, options);
const uninstall = (c, args, options) => run(runUninstall, c, args, options);

const steps = (c) => (existsSync(c.log) ? readFileSync(c.log, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line)) : []);
const plistVersion = (bundle) => /CFBundleShortVersionString<\/key>\s*<string>([^<]*)</.exec(readFileSync(path.join(bundle, 'Contents', 'Info.plist'), 'utf8'))[1];
const stillAttached = (c) => attachedImages(path.dirname(tools.hdiutil)).filter((image) => image.startsWith(`${c.tmp}${path.sep}`));

// The old copy is in place, untouched: the same inode and version, no staged copy or backup beside it, nothing in the
// Trash, the receipt as it was, the image detached and the private folder removed.
function assertOldUntouched(c, old) {
  assert.deepEqual(readdirSync(c.system), ['Breaks.app'], 'nothing staged or backed up beside the app');
  assert.equal(lstatSync(c.app).ino, old.ino, 'the same copy');
  assert.equal(readFileSync(path.join(c.app, 'Contents', 'old-copy'), 'utf8'), plistVersion(c.app));
  assert.deepEqual(readFileSync(path.join(c.app, 'Contents', 'Info.plist')), old.plist, 'the same Info.plist');
  assert.deepEqual(readdirSync(c.trash), [], 'nothing in the Trash');
  if (old.receipt === undefined) assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false, 'no receipt');
  else assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt, 'the receipt is unchanged');
  assert.deepEqual(stillAttached(c), [], 'the image is detached');
  assert.deepEqual(readdirSync(c.tmp), [], 'the private folder is removed');
}

// The new copy is in place with `version`, and the old one (with `oldVersion`) is the one copy in the Trash.
function assertUpdated(c, version, oldVersion) {
  assert.deepEqual(readdirSync(c.system), ['Breaks.app'], 'nothing staged or backed up beside the app');
  assert.equal(plistVersion(c.app), version);
  assert.equal(existsSync(path.join(c.app, 'Contents', 'old-copy')), false, 'the new copy');
  const trashed = readdirSync(c.trash);
  assert.equal(trashed.length, 1, 'one copy in the Trash');
  assert.match(trashed[0], /^Breaks \d{4}-\d{2}-\d{2} \d{2}\.\d{2}\.\d{2}\.app$/);
  assert.equal(readFileSync(path.join(c.trash, trashed[0], 'Contents', 'old-copy'), 'utf8'), oldVersion);
  assert.deepEqual(stillAttached(c), []);
  assert.deepEqual(readdirSync(c.tmp), []);
}

const receipt = (c) => JSON.parse(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'));

test('parses the apps, --beta and --quit, and refuses anything else', () => {
  assert.deepEqual(parseUpdateArgs([]), { apps: [], beta: false, quit: false });
  assert.deepEqual(parseUpdateArgs(['breaks', '--beta', 'timer', 'breaks', '--quit']), { apps: ['breaks', 'timer'], beta: true, quit: true });
  assert.match(parseUpdateArgs(['--force']).error, /does not take the option "--force"\. Usage: subset update \[<app>\.\.\.\] \[--beta\] \[--quit\]/);
  assert.deepEqual(parseUninstallArgs(['breaks', '--quit']), { app: 'breaks', quit: true });
  assert.match(parseUninstallArgs([]).error, /needs an app/);
  assert.match(parseUninstallArgs(['breaks', 'timer']).error, /takes one app/);
  assert.match(parseUninstallArgs(['breaks', '--purge']).error, /does not take the option "--purge"/);
});

test('version rules: newer, equal beta to live with a receipt, equal without one, builds with --beta, downgrades', () => {
  const app = { channels: { live: { version: '0.1.1' }, beta: { version: '0.1.1', build: 4 } } };
  const decide = (copy, beta = false) => decideUpdate({ build: '1', channel: null, ...copy }, app, beta).action;
  assert.equal(decide({ version: '0.1.0' }), 'update', 'a newer live version');
  assert.equal(decide({ version: '0.1.0', channel: 'beta', build: '9' }), 'update', 'a newer version from a beta');
  assert.equal(decide({ version: '0.1.1', channel: 'beta', build: '4' }), 'update', 'the same version: a beta (per its receipt) moves to live');
  assert.equal(decide({ version: '0.1.1', channel: 'live' }), 'current');
  assert.equal(decide({ version: '0.1.1', channel: null, build: '4' }), 'current', 'without a receipt an equal version is current');
  assert.equal(decide({ version: '0.2.0', channel: 'live' }), 'ahead', 'a downgrade');
  assert.equal(decide({ version: '0.1.10' }), 'ahead', 'versions compare as numbers');
  assert.equal(decide({ version: 'x' }), 'unknown');
  assert.equal(decide({ version: null }), 'unknown');
  assert.equal(decide({ version: '0.1.1', channel: 'beta', build: '3' }, true), 'update', 'a newer beta build');
  assert.equal(decide({ version: '0.1.1', channel: 'beta', build: '4' }, true), 'current');
  assert.equal(decide({ version: '0.1.1', channel: 'beta', build: '10' }, true), 'ahead', 'an older beta build is a downgrade');
  assert.equal(decide({ version: '0.1.1', channel: 'live' }, true), 'current', 'a live release is not older than its betas');
  assert.equal(decide({ version: '0.1.1', channel: null, build: '1' }, true), 'current');
  assert.equal(decideUpdate({ version: '0.1.0' }, { channels: { beta: app.channels.beta } }, false).action, 'no-release');
});

test('updates to a newer live version: the old copy goes to the Trash and the receipt is rewritten', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const fetch = fakeFetch({ [LIVE_URL]: image });
  const result = await update(c, ['breaks'], { fetch });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Updated Breaks 0.1.0 to 0.1.1 in ${c.app}\n`);
  assert.match(result.stderr, /^Downloading Breaks 0\.1\.1 from .*\nVerifying Breaks\.app\nMoved Breaks 0\.1\.0 to the Trash: .*Trash\/Breaks [\d-]+ [\d.]+\.app\n$/);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.deepEqual(receipt(c), { schema: 'subset.receipt@1', channel: 'live', version: '0.1.1', sha256: sha256(image), installedAt: '2026-11-14T12:00:00Z', path: '/Applications/Breaks.app' });
  // Running is checked before the download and again once the new copy is verified; a named app gives no npm hint.
  const log = steps(c).map((entry) => entry.step);
  assert.deepEqual([log[0], log.at(-3)], ['ps', 'ps']);
  assert.equal(log.indexOf('sw_vers') < log.lastIndexOf('ps'), true);
  assert.deepEqual(fetch.calls, [LIVE_URL]);
});

test('an installed beta moves to the live build of the same version when its receipt says beta', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1', build: '5' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { version: '0.1.1', build: '4', channel: 'beta' });
  const result = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Updated Breaks 0.1.1-beta.4 to 0.1.1 in ${c.app}\n`);
  assertUpdated(c, '0.1.1', '0.1.1');
  assert.equal(receipt(c).channel, 'live');
  assert.equal(Object.hasOwn(receipt(c), 'build'), false);
});

test('--beta updates to a newer beta build of the same version', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1', build: '4' });
  feed(c, { beta: { version: '0.1.1', build: 4, image } });
  installed(c, { version: '0.1.1', build: '3', channel: 'beta' });
  const result = await update(c, ['breaks', '--beta'], { fetch: fakeFetch({ [BETA_URL]: image }) });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Updated Breaks 0.1.1-beta.3 to 0.1.1-beta.4 in ${c.app}\n`);
  assert.deepEqual([receipt(c).channel, receipt(c).build], ['beta', 4]);
});

test('an equal version without a receipt is current: says so, downloads nothing and exits 0', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { version: '0.1.0' });
  const fetch = fakeFetch({});
  const result = await update(c, ['breaks'], { fetch });
  assert.deepEqual(result, { code: 0, stdout: 'Breaks 0.1.0 is up to date (/Applications).\n', stderr: '' });
  assert.deepEqual(fetch.calls, []);
  assertOldUntouched(c, old);
});

test('refuses a downgrade of a named app (exit 1) and only notes it when updating every app', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { version: '0.2.0', channel: 'live' });
  const fetch = fakeFetch({});
  const named = await update(c, ['breaks'], { fetch });
  assert.equal(named.code, 1);
  assert.equal(named.stderr, 'subset: Breaks in /Applications was not updated: 0.2.0 is newer than the live 0.1.0, and subset update does not downgrade.\n');
  const every = await update(c, [], { fetch });
  assert.equal(every.code, 0);
  assert.match(every.stderr, /^subset: note: Breaks in \/Applications was not updated: 0\.2\.0 is newer than the live 0\.1\.0/);
  assert.deepEqual(fetch.calls, [NPM_LATEST_URL]);
  assertOldUntouched(c, old);
});

test('a new copy that fails verification leaves the old app in place, untouched', { skip }, async () => {
  for (const [image, message] of [
    [breaksImage({ version: '0.1.1', signature: null }), /the signature check failed/],
    [breaksImage({ version: '0.1.1', signature: { valid: true, team: 'ABCDE12345', notarized: true } }), /the team check failed/],
    [breaksImage({ version: '0.1.1', bundleId: 'com.example.breaks' }), /the bundle ID check failed/],
    [breaksImage({ version: '0.1.0' }), /the version check failed/]
  ]) {
    const c = setup();
    feed(c, { live: { version: '0.1.1', image } });
    const old = installed(c, { channel: 'live' });
    const result = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
    assert.equal(result.code, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /subset: Breaks in \/Applications was not updated to 0\.1\.1: /);
    assert.match(result.stderr, message);
    assertOldUntouched(c, old);
  }
  const corrupted = setup();
  feed(corrupted, { live: { version: '0.1.1', image: breaksImage({ version: '0.1.1' }), sha: '0'.repeat(64) } });
  const old = installed(corrupted, {});
  const result = await update(corrupted, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: breaksImage({ version: '0.1.1' }) }) });
  assert.match(result.stderr, /the checksum step failed/);
  assertOldUntouched(corrupted, old);
});

// A process standing in for the app: it exits on SIGTERM unless `ignoreTerm`. Listed by the stand-in ps as running
// from inside the bundle.
const fakeApps = new Set();
after(() => {
  for (const child of fakeApps) child.kill('SIGKILL');
});
async function fakeApp(c, { ignoreTerm = false, executable = path.join(c.app, 'Contents', 'MacOS', 'Breaks') } = {}) {
  const child = spawn(process.execPath, ['-e', `${ignoreTerm ? "process.on('SIGTERM', () => {});" : ''} console.log('ready'); setInterval(() => {}, 1000);`], { stdio: ['ignore', 'pipe', 'ignore'] });
  // Killed when the tests end, whatever happened.
  fakeApps.add(child);
  child.once('exit', () => fakeApps.delete(child));
  await new Promise((resolve) => child.stdout.once('data', resolve));
  const file = path.join(c.base, 'ps.json');
  const table = existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : [];
  writeFileSync(file, JSON.stringify([...table, { pid: child.pid, path: executable }]));
  const exited = new Promise((resolve) => child.once('exit', (code, signal) => resolve(signal ?? code)));
  return { child, exited, env: { STUB_PS_FILE: file } };
}

test('a running app is not replaced without --quit: exit 1 naming it, before anything is downloaded', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.1', image: breaksImage({ version: '0.1.1' }) } });
  const old = installed(c, { channel: 'live' });
  const app = await fakeApp(c);
  try {
    const fetch = fakeFetch({});
    const result = await update(c, ['breaks'], { fetch, extraEnv: app.env });
    assert.equal(result.code, 1);
    assert.equal(result.stderr, `subset: Breaks in /Applications was not updated to 0.1.1: Breaks is running (pid ${app.child.pid}); quit it, or use subset update --quit to quit and reopen it.\n`);
    assert.deepEqual(fetch.calls, []);
    assertOldUntouched(c, old);
    // Whether it runs cannot be told: refused too.
    const unknown = await update(c, ['breaks'], { fetch, extraEnv: { STUB_PS_FAIL: '1' } });
    assert.match(unknown.stderr, /was not updated to 0\.1\.1: whether .*Breaks\.app is running cannot be told \(ps: ps: stub failure\)/);
    assertOldUntouched(c, old);
  } finally {
    app.child.kill('SIGKILL');
  }
});

test('--quit quits a running app with SIGTERM, updates it and reopens it with open -b', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  // A helper inside the bundle counts as the app too.
  const app = await fakeApp(c);
  const helper = await fakeApp(c, { executable: path.join(c.app, 'Contents', 'Library', 'LoginItems', 'Helper.app', 'Contents', 'MacOS', 'Helper') });
  const result = await update(c, ['breaks', '--quit'], { fetch: fakeFetch({ [LIVE_URL]: image }), extraEnv: helper.env });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(await app.exited, 'SIGTERM');
  assert.equal(await helper.exited, 'SIGTERM');
  assert.match(result.stderr, new RegExp(`Quitting Breaks \\(pid ${app.child.pid}, ${helper.child.pid}\\)`));
  assertUpdated(c, '0.1.1', '0.1.0');
  // Quit only once the new copy is verified, and reopened after the swap.
  const log = steps(c);
  const names = log.map((entry) => entry.step);
  assert.ok(names.indexOf('sw_vers') < names.indexOf('ps'), 'the first ps runs after the checks');
  assert.equal(names.at(-1), 'open');
  assert.deepEqual(log.at(-1).args, ['-b', BUNDLE_ID]);
});

test('--quit refuses when the app is still running after the wait, keeps the old copy and reopens it', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  const old = installed(c, { channel: 'live' });
  const app = await fakeApp(c, { ignoreTerm: true });
  try {
    const result = await update(c, ['breaks', '--quit'], { fetch: fakeFetch({ [LIVE_URL]: image }), extraEnv: { ...app.env, STUB_OPEN_FAIL: '1' }, quitTimeoutMs: 600 });
    assert.equal(result.code, 1);
    assert.match(result.stderr, new RegExp(`was not updated to 0\\.1\\.1: Breaks is still running 0\\.6 seconds after it was asked to quit \\(pid ${app.child.pid}\\)\\.`));
    assert.match(result.stderr, /subset: warning: Breaks could not be reopened \(open -b dev\.subset\.breaks: LSOpenURLsWithRole\(\) failed with error -10814\)/);
    assertOldUntouched(c, old);
    assert.equal(steps(c).at(-1).step, 'open');
  } finally {
    app.child.kill('SIGKILL');
  }
});

test('an app replaced by another install or update while this one ran is not replaced again', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const result = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }), extraEnv: { STUB_PS_REPLACE: c.app } });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /the install step failed: .*Breaks\.app was changed or removed while it was being updated/);
  // The replacement (a copy of the old app, with another inode) is in place, and nothing else is left.
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  assert.equal(plistVersion(c.app), '0.1.0');
  assert.deepEqual(readdirSync(c.trash), []);
  assert.equal(receipt(c).version, '0.1.0');
  assert.deepEqual(readdirSync(c.tmp), []);
});

test('updates every installed app with no apps named, and says when a newer subset.dev is on npm', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const result = await update(c, [], { fetch: fakeFetch({ [LIVE_URL]: image }, { registry: '0.3.0' }), launcherVersion: '0.2.0' });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Updated Breaks 0.1.0 to 0.1.1 in ${c.app}\nsubset.dev 0.3.0 is available (this is 0.2.0); update it with: npm install -g subset.dev@latest\n`);
  // Timer has no live release: a note, not a failure, when it is not installed nothing is said.
  assert.doesNotMatch(result.stderr, /Timer/);

  const none = setup();
  feed(none, { live: { version: '0.1.1', image } });
  const quiet = await update(none, [], { fetch: fakeFetch({}, { registry: '0.2.0' }), launcherVersion: '0.2.0' });
  assert.deepEqual(quiet, { code: 0, stdout: 'No Subset Mac apps are installed.\n', stderr: '' });
});

test('the subset.dev check: newer releases only, a release after its prerelease, and silence on any failure', async () => {
  const check = (registry, current) => newerLauncher({ fetch: fakeFetch({}, { registry }), current });
  assert.equal(await check('0.3.0', '0.2.0'), '0.3.0');
  assert.equal(await check('0.10.0', '0.9.0'), '0.10.0');
  assert.equal(await check('0.2.0', '0.2.0'), undefined);
  assert.equal(await check('0.1.9', '0.2.0'), undefined);
  assert.equal(await check('0.3.0', '0.3.0-beta.2'), '0.3.0');
  assert.equal(await check('0.2.0', '0.3.0-beta.2'), undefined);
  assert.equal(await check(503, '0.2.0'), undefined);
  assert.equal(await check('not a version', '0.2.0'), undefined);
  assert.equal(await newerLauncher({ fetch: async () => new Response('<html>'), current: '0.2.0' }), undefined);
  assert.equal(await newerLauncher({ fetch: async () => Promise.reject(new TypeError('fetch failed')), current: '0.2.0' }), undefined);
});

// cli.mjs gives the command no fetch: the subset.dev check must use the global one. The real command runs here with a
// global fetch that answers only the npm registry, on this platform (off macOS it still checks before refusing).
test('the real subset update with no apps says when a newer subset.dev is on npm, with the global fetch', async () => {
  const c = setup();
  writeFileSync(c.feedFile, JSON.stringify(template));
  const stub = `globalThis.fetch = async (url) => String(url) === ${JSON.stringify(NPM_LATEST_URL)} ? new Response('{"version":"99.0.0"}') : new Response('', { status: 404 });`;
  const env = { ...process.env, ...c.env, HOME: c.home, XDG_CACHE_HOME: path.join(c.home, '.cache') };
  const child = spawn(process.execPath, ['--import', `data:text/javascript,${encodeURIComponent(stub)}`, cli, 'update'], { env, stdio: ['ignore', 'pipe', 'pipe'] });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => (stdout += chunk));
  child.stderr.on('data', (chunk) => (stderr += chunk));
  const status = await new Promise((resolve) => child.on('close', resolve));
  const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.match(stdout, new RegExp(`subset\\.dev 99\\.0\\.0 is available \\(this is ${escapeRegExp(version)}\\); update it with: npm install -g subset\\.dev@latest\\n$`), stderr);
  assert.equal(status, process.platform === 'darwin' ? 0 : 1, stderr);
});

test('names an app that is not installed or unknown, a missing channel, and refuses off macOS', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.1', image: breaksImage() } });
  const missing = await update(c, ['breaks']);
  assert.deepEqual(missing, { code: 1, stdout: '', stderr: 'subset: Breaks is not installed; subset install breaks installs it.\n' });
  assert.equal((await update(c, ['nope'])).stderr, 'subset: there is no Subset Mac app "nope"; subset list shows them.\n');
  installed(c, { channel: 'live' });
  assert.equal((await update(c, ['breaks', '--beta'])).stderr, 'subset: Breaks has no beta release.\n');
  const linux = await update(c, ['breaks'], { platform: 'linux' });
  assert.deepEqual(linux, { code: 1, stdout: '', stderr: 'subset: Mac apps can be updated only on macOS.\n' });
  const usage = await update(c, ['--force']);
  assert.equal(usage.code, 2);
  assert.equal((await uninstall(c, ['breaks'], { platform: 'linux' })).stderr, 'subset: Mac apps can be uninstalled only on macOS.\n');
});

test('a Trash that cannot be used stops the update before anything is downloaded', { skip: skip || (process.getuid?.() === 0 && 'root ignores permissions') }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.1', image: breaksImage({ version: '0.1.1' }) } });
  const old = installed(c, { channel: 'live' });
  chmodSync(c.trash, 0o555);
  try {
    const fetch = fakeFetch({});
    const result = await update(c, ['breaks'], { fetch });
    assert.equal(result.code, 1);
    assert.match(result.stderr, /^subset: nothing was updated: the Trash .*Trash cannot be used \(EACCES\)\.\n$/);
    assert.deepEqual(fetch.calls, []);
    assertOldUntouched(c, old);
  } finally {
    chmodSync(c.trash, 0o755);
  }
});

test('trash: the Trash folder, its names, a taken name and a Trash on another volume (EXDEV)', { skip }, async () => {
  assert.equal(trashFolder({ env: {}, home: '/Users/a' }), '/Users/a/.Trash');
  assert.equal(trashFolder({ env: { SUBSET_TRASH_DIR: '/tmp/t' }, home: '/Users/a' }), '/tmp/t');
  assert.throws(() => trashFolder({ env: { SUBSET_TRASH_DIR: 'relative' }, home: '/Users/a' }), /must be an absolute folder/);
  const date = new Date(2026, 10, 14, 9, 5, 7);
  assert.equal(trashName('Breaks', date), 'Breaks 2026-11-14 09.05.07.app');
  assert.equal(trashName('Breaks', date, 3), 'Breaks 2026-11-14 09.05.07 3.app');

  const c = setup();
  // A missing Trash is created, private.
  const fresh = path.join(c.base, 'new-Trash');
  prepareTrash(fresh);
  assert.equal(statSync(fresh).mode & 0o777, 0o700);
  // A taken name: the next one.
  makeApp(path.join(c.trash), 'Breaks 2026-11-14 09.05.07', { bundleId: 'x' });
  const first = installed(c, {});
  assert.equal(renameIntoTrash(first.bundle, { trash: c.trash, appName: 'Breaks', now: date }), path.join(c.trash, 'Breaks 2026-11-14 09.05.07 2.app'));
  assert.equal(lstatSync(path.join(c.trash, 'Breaks 2026-11-14 09.05.07 2.app')).ino, first.ino, 'renamed, not copied');

  // Another volume: copied with ditto, then the original is removed.
  const exdev = () => {
    throw Object.assign(new Error('cross-device link'), { code: 'EXDEV' });
  };
  installed(c, {});
  const copied = await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools, rename: exdev });
  assert.equal(copied, path.join(c.trash, 'Breaks 2026-11-14 09.05.07 3.app'));
  assert.equal(existsSync(c.app), false, 'the original is removed after the copy');
  assert.equal(readFileSync(path.join(copied, 'Contents', 'old-copy'), 'utf8'), '0.1.0');

  // A failed copy is removed from the Trash, and the original stays.
  const old = installed(c, {});
  const failing = path.join(c.base, 'ditto-fails');
  writeFileSync(failing, '#!/bin/sh\nmkdir -p "$2/Contents" && echo partial > "$2/Contents/partial" && echo "ditto: No space left on device" >&2 && exit 1\n');
  chmodSync(failing, 0o755);
  const before = readdirSync(c.trash).sort();
  await assert.rejects(moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools: { ...tools, ditto: failing }, rename: exdev }), /ditto could not copy .* \(ditto: No space left on device\)/);
  assert.equal(lstatSync(c.app).ino, old.ino, 'the original stays');
  assert.deepEqual(readdirSync(c.trash).sort(), before, 'the incomplete copy is removed');
});

// A folder on another device than the case folders, for a real EXDEV, or undefined.
function otherVolume() {
  for (const candidate of ['/dev/shm']) {
    try {
      if (statSync(candidate).dev !== statSync(root).dev && statSync(candidate).isDirectory()) return mkdtempSync(path.join(candidate, 'subset-trash-'));
    } catch {
      // Not there.
    }
  }
  return undefined;
}

const other = skip ? undefined : otherVolume();
after(() => other && rmSync(other, { recursive: true, force: true }));
test('updates with the Trash on another volume: the old copy is copied there, then removed', { skip: skip || (!other && 'no folder on another volume') }, async () => {
  const c = setup();
  c.trash = other;
  c.env.SUBSET_TRASH_DIR = other;
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const result = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 0, result.stderr);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.ok(steps(c).some((entry) => entry.step === 'ditto' && entry.args[1].startsWith(other)), 'copied with ditto');
});

test('uninstall moves every copy to the Trash and deletes the receipt; the app data stays', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  const user = installed(c, { version: '0.1.1', dir: c.user });
  const data = path.join(c.home, 'Library', 'Application Support', 'Breaks');
  mkdirSync(data, { recursive: true });
  writeFileSync(path.join(data, 'history.json'), '[]');
  const result = await uninstall(c, ['breaks']);
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stdout, /^Moved Breaks 0\.1\.0 \(\/Applications\) to the Trash: .*\nMoved Breaks 0\.1\.1 \(~\/Applications\) to the Trash: .*\n$/);
  assert.deepEqual([readdirSync(c.system), readdirSync(c.user)], [[], []]);
  const trashed = readdirSync(c.trash).sort();
  assert.equal(trashed.length, 2);
  assert.deepEqual(trashed.map((name) => lstatSync(path.join(c.trash, name)).ino).sort(), [old.ino, user.ino].sort(), 'renamed into the Trash');
  assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false, 'the receipt is deleted');
  assert.equal(readFileSync(path.join(data, 'history.json'), 'utf8'), '[]', 'the app data stays');
  assert.equal(steps(c).filter((entry) => entry.step === 'ps').length, 4, 'each copy checked before any is moved, and again just before it is moved');

  const again = await uninstall(c, ['breaks']);
  assert.deepEqual(again, { code: 1, stdout: '', stderr: 'subset: Breaks is not installed in /Applications or ~/Applications.\n' });
  assert.equal((await uninstall(c, ['nope'])).stderr, 'subset: there is no Subset Mac app "nope"; subset list shows them.\n');
});

test('uninstall refuses a running app without --quit, and quits it with --quit', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  const app = await fakeApp(c);
  try {
    const refused = await uninstall(c, ['breaks'], { extraEnv: app.env });
    assert.equal(refused.code, 1);
    assert.equal(refused.stderr, `subset: Breaks was not uninstalled: Breaks is running from ${c.app} (pid ${app.child.pid}); quit it, or use subset uninstall breaks --quit.\n`);
    assertOldUntouched(c, old);
    const quit = await uninstall(c, ['breaks', '--quit'], { extraEnv: app.env });
    assert.equal(quit.code, 0, quit.stderr);
    assert.equal(await app.exited, 'SIGTERM');
    assert.deepEqual(readdirSync(c.system), []);
    assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false);
    assert.equal(steps(c).some((entry) => entry.step === 'open'), false, 'an uninstalled app is not reopened');
  } finally {
    app.child.kill('SIGKILL');
  }
});

// Runs the real command in its own process with the stand-in tools (install-preload.mjs); the fetch serves $FAKE_IMAGE.
function spawnCommand(c, image, args, extraEnv = {}, { group = false } = {}) {
  const imageFile = path.join(c.base, `image-${Math.random().toString(16).slice(2)}.dmg`);
  writeFileSync(imageFile, image);
  const map = Object.fromEntries(Object.entries(UPDATE_TOOLS).map(([key, file]) => [file, tools[key]]));
  const env = { ...process.env, ...c.env, HOME: c.home, TMPDIR: c.tmp, STUB_LOG: c.log, STUB_TOOL_MAP: JSON.stringify(map), FAKE_IMAGE: imageFile, XDG_CACHE_HOME: '', ...extraEnv };
  const child = spawn(process.execPath, ['--import', preload, cli, ...args], { env, stdio: ['ignore', 'pipe', 'pipe'], detached: group });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => (stdout += chunk));
  child.stderr.on('data', (chunk) => (stderr += chunk));
  return new Promise((resolve) => child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr })));
}

// Every point where a signal can arrive before the swap: the running check, the download, each tool of the install, and
// the running check after verification (the last ps).
const boundaries = ['ps', 'download', 'hdiutil-attach', 'ditto', 'find-chflags', 'find-chmod', 'codesign-verify', 'codesign-display', 'spctl', 'plutil', 'sw_vers'];
for (const boundary of boundaries) {
  test(`SIGTERM at ${boundary} leaves the old app in place, untouched`, { skip }, async () => {
    const c = setup();
    const image = breaksImage({ version: '0.1.1' });
    feed(c, { live: { version: '0.1.1', image } });
    const old = installed(c, { channel: 'live' });
    const result = await spawnCommand(c, image, ['update', 'breaks'], { STUB_SIGNAL_AT: boundary });
    assert.equal(result.status, 143, result.stderr);
    assert.match(result.stderr, /subset: Breaks in \/Applications was not updated to 0\.1\.1: interrupted by SIGTERM\./);
    assert.equal(result.stdout, '');
    assertOldUntouched(c, old);
  });
}

test('a SIGINT to the process group at the last running check, with --quit, keeps the old app before quitting it', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  const old = installed(c, { channel: 'live' });
  const env = { STUB_SIGNAL_AT: 'ps', STUB_SIGNAL: 'SIGINT', STUB_SIGNAL_GROUP: '1', STUB_LINGER_MS: '50' };
  const app = await fakeApp(c);
  try {
    // --quit skips the check before the download, so the one ps is the check after verification.
    const result = await spawnCommand(c, image, ['update', 'breaks', '--quit'], { ...env, ...app.env }, { group: true });
    assert.equal(result.status, 130, result.stderr);
    assertOldUntouched(c, old);
    assert.equal(steps(c).some((entry) => entry.step === 'open'), false, 'not quit, so not reopened');
    assert.equal(app.child.exitCode, null, 'still running');
  } finally {
    app.child.kill('SIGKILL');
  }
});

test('a SIGINT to the process group after the swap, while the image is detached, keeps the new app and its receipt', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const env = { STUB_SIGNAL_AT: 'hdiutil-detach', STUB_SIGNAL: 'SIGINT', STUB_SIGNAL_GROUP: '1', STUB_LINGER_MS: '50' };
  const result = await spawnCommand(c, image, ['update', 'breaks'], env, { group: true });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `Updated Breaks 0.1.0 to 0.1.1 in ${c.app}\n`);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.equal(receipt(c).version, '0.1.1');
});

// While a spawned command holds the app's lock (it waits at its first ps), another subset install, update or uninstall
// of the app refuses, naming that command's pid.
const BUSY = /another subset \(pid \d+\) is installing, updating or uninstalling Breaks; run this again once it has finished \(if no subset runs, remove .*\.lock\)\.\n$/;

test('one subset at a time per app: while an update runs, another update, an install and an uninstall refuse; list works', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  const old = installed(c, { channel: 'live' });
  const gate = psGate(c);
  const first = spawnCommand(c, image, ['update', 'breaks'], gate.env);
  let result;
  try {
    await gate.held(first);
    const fetch = fakeFetch({ [LIVE_URL]: image });
    const again = await update(c, ['breaks'], { fetch });
    assert.equal(again.code, 1);
    assert.match(again.stderr, /^subset: Breaks was not updated: another subset/);
    assert.match(again.stderr, BUSY);
    const removed = await uninstall(c, ['breaks']);
    assert.equal(removed.code, 1);
    assert.match(removed.stderr, /^subset: Breaks was not uninstalled: another subset/);
    const install = await run(runInstall, c, ['breaks', '--user'], { fetch });
    assert.equal(install.code, 1);
    assert.match(install.stderr, /^subset: Breaks 0\.1\.1 was not installed: another subset/);
    assert.deepEqual(fetch.calls, [], 'nothing downloaded');
    assert.deepEqual([readdirSync(c.user), readdirSync(c.trash)], [[], []]);
    assert.equal(lstatSync(c.app).ino, old.ino);
    assert.equal((await run(runList, c, [], { plutil: tools.plutil })).code, 0, 'list takes no lock');
  } finally {
    gate.release();
    result = await first;
  }
  assert.equal(result.status, 0, result.stderr);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.equal(receipt(c).version, '0.1.1');
  assert.deepEqual(readdirSync(locksFolder(c.home)), [], 'every lock is released');
});

test('an install while an uninstall runs refuses: the uninstall then removes the receipt, which no install wrote meanwhile', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { version: '0.1.0', image } });
  installed(c, { channel: 'live' });
  const gate = psGate(c);
  const first = spawnCommand(c, image, ['uninstall', 'breaks'], gate.env);
  let result;
  try {
    await gate.held(first);
    const install = await run(runInstall, c, ['breaks', '--user'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
    assert.equal(install.code, 1);
    assert.match(install.stderr, BUSY);
    assert.deepEqual(readdirSync(c.user), []);
  } finally {
    gate.release();
    result = await first;
  }
  assert.equal(result.status, 0, result.stderr);
  assert.deepEqual([readdirSync(c.system), readdirSync(c.trash).length], [[], 1]);
  assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false);
});

test('a copy replaced between reading its version and identifying it is not updated (no downgrade of the replacement)', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.2.0' });
  feed(c, { live: { version: '0.2.0', image } });
  installed(c, { channel: 'live' });
  // While its 0.1.0 Info.plist is read, a concurrent update puts 0.3.0 in its place.
  const fetch = fakeFetch({ [LIVE_URL]: image });
  const result = await update(c, ['breaks'], { fetch, extraEnv: { STUB_PLUTIL_REPLACE: c.app, STUB_PLUTIL_REPLACE_VERSION: '0.3.0' } });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /Breaks in \/Applications was not updated: .*Breaks\.app was replaced while its version was read .*; run subset update again\./);
  assert.equal(plistVersion(c.app), '0.3.0', 'the replacement stays');
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  assert.deepEqual(readdirSync(c.trash), []);
  assert.deepEqual(fetch.calls, [], 'nothing downloaded');
});

test('swap: an installed copy removed before the swap is reported, and the staged copy stays where it was', { skip }, () => {
  const c = setup();
  const staged = makeApp(c.system, '.Breaks.app.subset-install-0', { bundleId: BUNDLE_ID, version: '0.1.1' });
  const identity = lstatSync(staged);
  assert.throws(() => swapApp({ staged, target: c.app, identity, receipt: null, trash: c.trash, appName: 'Breaks', warn: () => {} }), /Breaks\.app was changed or removed while it was being updated/);
  assert.deepEqual(readdirSync(c.system), ['.Breaks.app.subset-install-0.app']);
});

test('trash on another volume: the copy in the Trash and the removal concern the app copied, not a new one put at its path', { skip }, async () => {
  const c = setup();
  const date = new Date(2026, 10, 14, 9, 5, 7);
  const exdev = () => {
    throw Object.assign(new Error('cross-device link'), { code: 'EXDEV' });
  };
  const script = (name, body) => {
    const file = path.join(c.base, name);
    writeFileSync(file, `#!/bin/sh\n${body}\n`);
    chmodSync(file, 0o755);
    return { ...tools, ditto: file };
  };
  // While the copy runs, a concurrent install or update puts a new Breaks.app at the path.
  const newCopy = `mkdir -p "${c.app}/Contents" && echo new > "${c.app}/Contents/new-copy"`;
  const old = installed(c, {});
  const copied = await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools: script('ditto-replaced', `${newCopy} && cp -R "$1/." "$2"`), rename: exdev });
  assert.equal(readFileSync(path.join(copied, 'Contents', 'old-copy'), 'utf8'), '0.1.0', 'the old copy is in the Trash');
  assert.equal(readFileSync(path.join(c.app, 'Contents', 'new-copy'), 'utf8'), 'new\n', 'the new copy stays');
  assert.notEqual(lstatSync(c.app).ino, old.ino);
  assert.deepEqual(readdirSync(c.system), ['Breaks.app'], 'nothing set aside is left');

  // The copy fails, and the app cannot be renamed back because a new one took its place: the message says where it is.
  rmSync(c.app, { recursive: true });
  rmSync(c.trash, { recursive: true });
  mkdirSync(c.trash);
  installed(c, {});
  const failed = await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools: script('ditto-replaced-fails', `${newCopy} && echo "ditto: No space left on device" >&2 && exit 1`), rename: exdev }).catch((error) => error);
  assert.match(failed.message, /ditto could not copy .*, and it could not be renamed back \(\w+\): it is at .*\/\.Breaks\.app\.subset-trash-\d+-[0-9a-f]{12}$/);
  assert.equal(readFileSync(path.join(failed.left, 'Contents', 'old-copy'), 'utf8'), '0.1.0', 'the old copy is kept, set aside');
  assert.deepEqual(readdirSync(c.trash), []);

  // An interrupted copy: the incomplete copy is removed from the Trash and the app is renamed back, the same copy.
  rmSync(c.system, { recursive: true });
  mkdirSync(c.system);
  const before = installed(c, {});
  const controller = new AbortController();
  const interrupted = moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools: script('ditto-slow', 'mkdir -p "$2/Contents" && echo partial > "$2/Contents/partial" && sleep 30'), rename: exdev, signal: controller.signal });
  setTimeout(() => controller.abort(new Error('stopped')), 300);
  await assert.rejects(interrupted, /stopped/);
  assert.equal(lstatSync(c.app).ino, before.ino, 'the app is back, untouched');
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  assert.deepEqual(readdirSync(c.trash), [], 'the incomplete copy is removed');
});

// A pid that no process has any more.
function deadPid() {
  return spawnSync(process.execPath, ['-e', '']).pid;
}

test('an app an interrupted update left under a hidden name is put back by update and install, and named by list', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  // A SIGKILL between the two renames of a swap: the old copy under its backup name, from a subset no longer running.
  const backup = path.join(c.system, `.Breaks.app.subset-update-${deadPid()}-0123456789ab`);
  renameSync(c.app, backup);

  const listed = await run(runList, c, [], { plutil: tools.plutil });
  assert.equal(listed.code, 0);
  assert.match(listed.stderr, new RegExp(`subset: note: Breaks is missing from /Applications, and an interrupted subset update or uninstall left it at ${backup.replaceAll('.', '\\.')}; subset update breaks puts it back\\.`));
  assert.equal(existsSync(backup), true, 'list changes nothing');

  const updated = await update(c, ['breaks']);
  assert.equal(updated.code, 0, updated.stderr);
  assert.match(updated.stderr, new RegExp(`^subset: note: Breaks was put back at ${c.app.replaceAll('.', '\\.')}: an interrupted subset update or uninstall had left it at ${backup.replaceAll('.', '\\.')}\\.\n`));
  assert.equal(updated.stdout, 'Breaks 0.1.0 is up to date (/Applications).\n');
  assertOldUntouched(c, old);

  renameSync(c.app, backup);
  const install = await run(runInstall, c, ['breaks']);
  assert.equal(install.code, 1);
  assert.match(install.stderr, /note: Breaks was put back at .*\nsubset: Breaks 0\.1\.0 was not installed: .*Breaks\.app already exists; use subset update/);
  assertOldUntouched(c, old);
});

test('recovery leaves a copy alone while the subset that set it aside runs, and when there are several', { skip }, async () => {
  const c = setup();
  const app = { id: 'breaks', name: 'Breaks', appName: 'Breaks' };
  const folders = [{ label: '/Applications', dir: c.system }];
  installed(c, {});
  const busy = path.join(c.system, '.Breaks.app.subset-trash-4242-0123456789ab');
  renameSync(c.app, busy);
  assert.deepEqual(recoverApps([app], folders, { running: (pid) => pid === 4242 }), [
    `Breaks is missing from /Applications, and an interrupted subset update or uninstall left it at ${busy}; subset (pid 4242) is still updating or uninstalling it.`
  ]);
  const second = path.join(c.system, '.Breaks.app.subset-update-4243-0123456789ab');
  mkdirSync(second);
  const notes = recoverApps([app], folders, { running: () => false });
  assert.equal(notes.length, 1);
  assert.match(notes[0], new RegExp(`; rename the copy to keep to ${c.app.replaceAll('.', '\\.')}\\.$`));
  assert.deepEqual(readdirSync(c.system).sort(), [path.basename(busy), path.basename(second)].sort(), 'nothing is renamed');
  // With Breaks.app in place, a copy an interrupted update or uninstall left beside it is no longer the installed one: it
  // is renamed to a name that is never put back (subset list only names it), so a later uninstall cannot revive it.
  rmSync(c.system, { recursive: true });
  mkdirSync(c.system);
  installed(c, { version: '0.2.0' });
  const stale = path.join(c.system, '.Breaks.app.subset-update-4244-0123456789ab');
  makeApp(c.system, '.Breaks.app.subset-update-4244-0123456789ab', { bundleId: BUNDLE_ID, version: '0.1.0' });
  renameSync(`${stale}.app`, stale);
  const listed = recoverApps([app], folders, { restore: false, running: () => false });
  assert.match(listed[0], /^a previous copy of Breaks that subset did not move to the Trash is at .*\.Breaks\.app\.subset-update-4244-0123456789ab; /);
  assert.equal(existsSync(stale), true, 'list renames nothing');
  const demoted = recoverApps([app], folders, { running: () => false });
  const [old] = readdirSync(c.system).filter((name) => name !== 'Breaks.app');
  assert.match(old, /^\.Breaks\.app\.subset-old-\d+-[0-9a-f]{12}$/);
  assert.equal(demoted[0], `a previous copy of Breaks that subset did not move to the Trash is at ${path.join(c.system, old)}; it is not used any more and can be moved to the Trash.`);
  rmSync(c.app, { recursive: true });
  assert.deepEqual(recoverApps([app], folders, { running: () => false }), [demoted[0]], 'an old copy is never put back');
  assert.equal(existsSync(c.app), false);
  // A staged (unverified) copy alone is never put back.
  rmSync(c.system, { recursive: true });
  mkdirSync(c.system);
  mkdirSync(path.join(c.system, '.Breaks.app.subset-install-0123456789ab'));
  assert.deepEqual(recoverApps([app], folders, { running: () => false }), []);
});

// The `n` names the Trash gives Breaks at `date` taken (by files, which rename(2) does not replace), so that the next
// rename of a Breaks copy into the Trash at that time fails.
function fillTrash(c, date, n = 100) {
  for (let index = 1; index <= n; index += 1) writeFileSync(path.join(c.trash, trashName('Breaks', date, index)), '');
}

const leftovers = (c) => readdirSync(c.system).filter((name) => name.startsWith('.Breaks.app.'));

test('an old copy an update could not move to the Trash is never put back: not after an uninstall, not by an install', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  fillTrash(c, new Date(NOW));
  const updated = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(updated.code, 0, updated.stderr);
  assert.match(updated.stderr, /subset: warning: the previous copy could not be moved to the Trash \(.*\); it is at .*\/\.Breaks\.app\.subset-old-\d+-[0-9a-f]{12}\n/);
  assert.equal(plistVersion(c.app), '0.1.1');
  const [old] = leftovers(c);
  assert.match(old, /^\.Breaks\.app\.subset-old-/);

  const later = () => NOW + 60_000;
  const removed = await uninstall(c, ['breaks'], { clock: later });
  assert.equal(removed.code, 0, removed.stderr);
  assert.match(removed.stderr, /note: a previous copy of Breaks that subset did not move to the Trash is at .*subset-old-/);
  assert.equal(existsSync(c.app), false);
  assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false);

  // The next install installs the release; the old 0.1.0 stays hidden, named.
  const install = await run(runInstall, c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }), clock: later });
  assert.equal(install.code, 0, install.stderr);
  assert.doesNotMatch(install.stderr, /put back/);
  assert.match(install.stderr, /note: a previous copy of Breaks .* is at .*subset-old-/);
  assert.equal(plistVersion(c.app), '0.1.1');
  assert.equal(existsSync(path.join(c.app, 'Contents', 'old-copy')), false, 'not the old copy');
  assert.deepEqual(leftovers(c), [old]);
});

test('a running app started again between the checks and the move is not uninstalled; a new copy keeps its receipt', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  // ps is asked twice: the first check says nothing runs, the second (just before the move) finds the app.
  const psFile = path.join(c.base, 'ps.json');
  const fakePs = path.join(c.base, 'ps-twice');
  writeFileSync(fakePs, `#!/bin/sh\nif [ -f "${psFile}.seen" ]; then echo "  ${process.ppid} ${c.app}/Contents/MacOS/Breaks"; else touch "${psFile}.seen"; fi\n`);
  chmodSync(fakePs, 0o755);
  const refused = await uninstall(c, ['breaks'], { tools: { ...tools, ps: fakePs } });
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /Breaks was not uninstalled: Breaks is running from .*Breaks\.app again \(pid \d+\)/);
  assert.equal(lstatSync(c.app).ino, old.ino);
  assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);

  // A new Breaks.app put in place while the old one went to the Trash keeps the receipt.
  const putNew = path.join(c.base, 'ps-new');
  writeFileSync(putNew, `#!/bin/sh\nif [ -f "${psFile}.new" ]; then mkdir -p "${c.user}/Breaks.app/Contents"; else touch "${psFile}.new"; fi\n`);
  chmodSync(putNew, 0o755);
  const kept = await uninstall(c, ['breaks'], { tools: { ...tools, ps: putNew } });
  assert.equal(kept.code, 0, kept.stderr);
  assert.match(kept.stderr, /note: .*user-Applications\/Breaks\.app was installed again while Breaks was uninstalled, so its receipt stays\./);
  assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);
});

// The stand-in tools for a spawned command, with `overrides` ({ ditto, find, ... }: wrapper scripts) in place of some.
function toolMap(c, overrides) {
  const map = Object.fromEntries(Object.entries(UPDATE_TOOLS).map(([key, file]) => [file, overrides[key] ?? tools[key]]));
  return JSON.stringify(map);
}
const wrapper = (c, name, body) => {
  const file = path.join(c.base, name);
  writeFileSync(file, `#!/bin/sh\n${body}\n`);
  chmodSync(file, 0o755);
  return file;
};

// A case whose Trash is on another volume (the rename into it fails with a real EXDEV).
function setupOtherVolume() {
  const c = setup();
  c.trash = mkdtempSync(path.join(other, 'case-'));
  c.env.SUBSET_TRASH_DIR = c.trash;
  return c;
}

const otherSkip = skip || (!other && 'no folder on another volume');
test('trash on another volume, SIGKILL while the uninstalled copy is removed: the partly removed copy is never put back', { skip: otherSkip }, async () => {
  const c = setupOtherVolume();
  const image = breaksImage();
  feed(c, { live: { version: '0.1.0', image } });
  installed(c, { channel: 'live' });
  // The copy in the Trash succeeded; its removal (find runs first) removes part of it, then the uninstall is killed.
  const find = wrapper(c, 'find-killed', `case "$2" in *.subset-*) rm -f "$2/Contents/Info.plist"; kill -KILL $PPID; sleep 5;; esac\nexec "${tools.find}" "$@"`);
  const killed = await spawnCommand(c, image, ['uninstall', 'breaks'], { STUB_TOOL_MAP: toolMap(c, { find }) });
  assert.equal(killed.signal, 'SIGKILL', killed.stderr);
  assert.equal(existsSync(c.app), false);
  const [partial] = leftovers(c);
  assert.match(partial, /^\.Breaks\.app\.subset-old-\d+-[0-9a-f]{12}$/, 'renamed out of the names put back before its removal');
  const [trashed] = readdirSync(c.trash);
  assert.equal(readFileSync(path.join(c.trash, trashed, 'Contents', 'old-copy'), 'utf8'), '0.1.0', 'the complete copy is in the Trash');

  const install = await run(runInstall, c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(install.code, 0, install.stderr);
  assert.doesNotMatch(install.stderr, /put back/);
  assert.equal(existsSync(path.join(c.app, 'Contents', 'old-copy')), false, 'the release is installed, not the partly removed copy');
  assert.deepEqual(leftovers(c), [partial]);
});

test('trash on another volume, SIGKILL while an update copies the old copy to the Trash: the old copy is never put back', { skip: otherSkip }, async () => {
  const c = setupOtherVolume();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const ditto = wrapper(c, 'ditto-killed', `case "$2" in "${c.trash}"/*) mkdir -p "$2/Contents"; kill -KILL $PPID; sleep 5;; esac\nexec "${tools.ditto}" "$@"`);
  const killed = await spawnCommand(c, image, ['update', 'breaks'], { STUB_TOOL_MAP: toolMap(c, { ditto }) });
  assert.equal(killed.signal, 'SIGKILL', killed.stderr);
  assert.equal(plistVersion(c.app), '0.1.1', 'the new copy is in place');
  const [old] = leftovers(c);
  assert.match(old, /^\.Breaks\.app\.subset-old-\d+-[0-9a-f]{12}$/);
  const [orphan] = readdirSync(c.trash);
  assert.match(orphan, /^\.Breaks\.app\.subset-copy-\d+-[0-9a-f]{12}$/, 'the killed copy is left in the Trash');

  const removed = await uninstall(c, ['breaks'], { clock: () => NOW + 60_000 });
  assert.equal(removed.code, 0, removed.stderr);
  assert.match(removed.stderr, new RegExp(`note: an incomplete copy of Breaks that an interrupted subset left in the Trash was removed \\(${escapeRegExp(path.join(c.trash, orphan))}\\)\\.`));
  assert.equal(readdirSync(c.trash).length, 1, 'only the uninstalled copy is in the Trash');
  assert.match(readdirSync(c.trash)[0], /^Breaks \d{4}-/);
  const install = await run(runInstall, c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }), clock: () => NOW + 120_000 });
  assert.equal(install.code, 0, install.stderr);
  assert.doesNotMatch(install.stderr, /put back/);
  assert.equal(existsSync(path.join(c.app, 'Contents', 'old-copy')), false, 'not the old 0.1.0');
  assert.deepEqual(leftovers(c), [old]);
});

test('trash on another volume, a SIGTERM while uninstall copies to the Trash: the app is back, the Trash empty, the receipt kept', { skip: otherSkip }, async () => {
  const c = setupOtherVolume();
  const image = breaksImage();
  feed(c, { live: { version: '0.1.0', image } });
  const old = installed(c, { channel: 'live' });
  const result = await spawnCommand(c, image, ['uninstall', 'breaks'], { STUB_SIGNAL_AT: 'ditto' });
  assert.equal(result.status, 143, result.stderr);
  assert.match(result.stderr, /subset: Breaks was not uninstalled: interrupted by SIGTERM\./);
  assert.equal(lstatSync(c.app).ino, old.ino, 'the same copy, renamed back');
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  assert.deepEqual(readdirSync(c.trash), []);
  assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);
});

// A stand-in ps for a spawned command that, once called, waits until release(): the command holds the app's lock
// meanwhile. held(child) waits until it is waiting (and fails if the command ends first).
function psGate(c) {
  const dir = mkdtempSync(path.join(c.base, 'gate-'));
  const ps = wrapper(c, `ps-${path.basename(dir)}`, `touch "${dir}/held"\nwhile [ ! -f "${dir}/go" ]; do sleep 0.05; done\nexec "${tools.ps}" "$@"`);
  return {
    env: { STUB_TOOL_MAP: toolMap(c, { ps }) },
    async held(child) {
      let ended;
      child.then((result) => (ended = result));
      while (!existsSync(path.join(dir, 'held'))) {
        if (ended) assert.fail(`the command ended before it was held: ${ended.stderr}`);
        await sleep(20);
      }
    },
    release: () => writeFileSync(path.join(dir, 'go'), '')
  };
}

const exdev = () => {
  throw Object.assign(new Error('cross-device link'), { code: 'EXDEV' });
};

for (const outcome of ['fails', 'succeeds', 'is aborted']) {
  test(`trash: a copy to another volume that ${outcome} never replaces or removes what a same-volume move put in the Trash meanwhile`, { skip }, async () => {
    const c = setup();
    const date = new Date(2026, 10, 14, 9, 5, 7);
    const first = path.join(c.trash, trashName('Breaks', date));
    const old = installed(c, {});
    // While the copy of /Applications/Breaks.app runs, another Breaks (in ~/Applications) is renamed into the Trash under
    // the first name, as a same-volume move at the same second does.
    const other = makeApp(c.user, 'Breaks', { bundleId: BUNDLE_ID, version: '0.2.0' });
    writeFileSync(path.join(other, 'Contents', 'other-copy'), 'B');
    const moveOther = `"${process.execPath}" -e "require('node:fs').renameSync(process.argv[1], process.argv[2])" "${other}" "${first}"`;
    const body = { fails: 'exit 1', succeeds: 'cp -R "$1/." "$2"', 'is aborted': 'sleep 30' }[outcome];
    const ditto = wrapper(c, 'ditto-meanwhile', `mkdir -p "$2/Contents" && echo partial > "$2/Contents/partial" && ${moveOther} && ${body}`);
    const controller = new AbortController();
    const moving = moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools: { ...tools, ditto }, rename: exdev, signal: controller.signal });
    if (outcome === 'is aborted') {
      while (!existsSync(first)) await sleep(20);
      controller.abort(new Error('stopped'));
    }
    const result = await moving.catch((error) => error);
    assert.equal(readFileSync(path.join(first, 'Contents', 'other-copy'), 'utf8'), 'B', 'the other copy stays in the Trash');
    assert.equal(plistVersion(first), '0.2.0');
    if (outcome === 'succeeds') {
      assert.equal(result, path.join(c.trash, trashName('Breaks', date, 2)));
      assert.equal(readFileSync(path.join(result, 'Contents', 'old-copy'), 'utf8'), '0.1.0');
      assert.equal(existsSync(path.join(result, 'Contents', 'other-copy')), false);
      assert.deepEqual(readdirSync(c.system), []);
    } else {
      assert.ok(result instanceof Error);
      assert.equal(lstatSync(c.app).ino, old.ino, 'the app is back, the same copy');
      assert.deepEqual(readdirSync(c.trash), [path.basename(first)], 'only the incomplete copy is removed');
    }
  });
}

test('trash: an empty folder already at a Trash name stays; the app goes to the next name, on either volume', { skip }, async () => {
  const c = setup();
  const date = new Date(2026, 10, 14, 9, 5, 7);
  const empty = path.join(c.trash, trashName('Breaks', date));
  mkdirSync(empty);
  const same = installed(c, {});
  assert.equal(await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date }), path.join(c.trash, trashName('Breaks', date, 2)));
  assert.equal(lstatSync(path.join(c.trash, trashName('Breaks', date, 2))).ino, same.ino);
  installed(c, {});
  const copied = await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', now: date, tools, rename: exdev });
  assert.equal(copied, path.join(c.trash, trashName('Breaks', date, 3)));
  assert.deepEqual(readdirSync(empty), [], 'the empty folder is still there');
  assert.equal(readdirSync(c.trash).length, 3);
});

test('trash: a copy replaced since it was checked is put back and refused, on either volume', { skip }, async () => {
  const c = setup();
  installed(c, {});
  const checked = lstatSync(c.app);
  for (const [index, rename] of [renameSync, exdev].entries()) {
    // What is at the path is moved away (not removed, so that no inode is reused) and another copy put in its place.
    renameSync(c.app, path.join(c.base, `away-${index}.app`));
    const replacement = installed(c, { version: '0.3.0' });
    const error = await moveToTrash(c.app, { trash: c.trash, appName: 'Breaks', identity: checked, tools, rename }).catch((caught) => caught);
    assert.match(error.message, /Breaks\.app was replaced since it was checked .*, so it was left in place$/);
    assert.equal(lstatSync(c.app).ino, replacement.ino, 'the replacement is back in place');
    assert.deepEqual([readdirSync(c.system), readdirSync(c.trash)], [['Breaks.app'], []]);
  }
});

test('uninstall moves only the copy it checked: one replaced while its version is read, or before its move, stays with the receipt', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  const read = await uninstall(c, ['breaks'], { extraEnv: { STUB_PLUTIL_REPLACE: c.app, STUB_PLUTIL_REPLACE_VERSION: '0.3.0' } });
  assert.equal(read.code, 1);
  assert.match(read.stderr, /^subset: Breaks was not uninstalled: .*Breaks\.app was replaced while its version was read .*; run subset uninstall breaks again\.\n$/);
  assert.equal(plistVersion(c.app), '0.3.0', 'the replacement stays');
  assert.deepEqual(readdirSync(c.trash), []);
  assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);

  // Replaced after the last running check (the second ps), just before the move.
  const seen = path.join(c.base, 'ps-seen');
  const ps = wrapper(c, 'ps-replace', `if [ -f "${seen}" ]; then mv "${c.app}" "${c.base}/checked.app" && mkdir -p "${c.app}/Contents" && echo new > "${c.app}/Contents/new-copy"; else touch "${seen}"; fi\nexec "${tools.ps}" "$@"`);
  const moved = await uninstall(c, ['breaks'], { tools: { ...tools, ps } });
  assert.equal(moved.code, 1);
  assert.match(moved.stderr, /^subset: Breaks was not uninstalled: .*Breaks\.app was replaced since it was checked .*, so it was left in place\.\n$/);
  assert.equal(readFileSync(path.join(c.app, 'Contents', 'new-copy'), 'utf8'), 'new\n');
  assert.deepEqual([readdirSync(c.system), readdirSync(c.trash)], [['Breaks.app'], []]);
  assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);
});

test('locks: a live holder refuses another command, which changes nothing; a dead holder\'s lock is removed', { skip }, async () => {
  const c = setup();
  const app = { name: 'Breaks', bundleId: BUNDLE_ID };
  const release = lockApp(app, { home: c.home });
  assert.throws(() => lockApp(app, { home: c.home }), /another subset \(pid \d+\) is installing, updating or uninstalling Breaks/, 'held in this process');
  release();
  // A subset that runs (this test's parent) holds the lock, with its update's backup set aside and Breaks.app missing.
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  installed(c, { channel: 'live' });
  const live = path.join(locksFolder(c.home), `${lockKey(BUNDLE_ID)}.${process.ppid}.0123456789ab.lock`);
  writeFileSync(live, '');
  const backup = path.join(c.system, `.Breaks.app.subset-update-${process.ppid}-0123456789ab`);
  renameSync(c.app, backup);
  for (const [runner, args] of [[runInstall, ['breaks']], [runUpdate, ['breaks']], [runUninstall, ['breaks']]]) {
    const result = await run(runner, c, args);
    assert.equal(result.code, 1);
    assert.match(result.stderr, new RegExp(`another subset \\(pid ${process.ppid}\\)`));
    assert.deepEqual(readdirSync(c.system), [path.basename(backup)], 'neither put back nor renamed');
  }
  // Once that subset is gone, its lock is removed and the backup put back.
  const dead = path.join(locksFolder(c.home), `${lockKey(BUNDLE_ID)}.${deadPid()}.0123456789ab.lock`);
  renameSync(live, dead);
  const dying = path.join(c.system, `.Breaks.app.subset-update-${deadPid()}-0123456789ab`);
  renameSync(backup, dying);
  const updated = await update(c, ['breaks']);
  assert.equal(updated.code, 0, updated.stderr);
  assert.match(updated.stderr, /note: Breaks was put back/);
  assert.deepEqual(readdirSync(locksFolder(c.home)), []);
});

test('an update killed between its swap and renaming its backup: the next uninstall takes over its lock, and no install revives the backup', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  // What a SIGKILL right after step 2 leaves: the new 0.1.1 in place, the old 0.1.0 under the backup name, and the lock.
  const pid = deadPid();
  installed(c, { channel: 'live' });
  renameSync(c.app, path.join(c.system, `.Breaks.app.subset-update-${pid}-0123456789ab`));
  makeApp(c.system, 'Breaks', { bundleId: BUNDLE_ID, version: '0.1.1' });
  mkdirSync(locksFolder(c.home), { recursive: true });
  writeFileSync(path.join(locksFolder(c.home), `${lockKey(BUNDLE_ID)}.${pid}.0123456789ab.lock`), '');
  const removed = await uninstall(c, ['breaks']);
  assert.equal(removed.code, 0, removed.stderr);
  assert.match(removed.stderr, /note: a previous copy of Breaks that subset did not move to the Trash is at .*subset-old-/);
  const install = await run(runInstall, c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }), clock: () => NOW + 60_000 });
  assert.equal(install.code, 0, install.stderr);
  assert.doesNotMatch(install.stderr, /put back/);
  assert.equal(existsSync(path.join(c.app, 'Contents', 'old-copy')), false, 'the release, not the old 0.1.0');
});

test('swap: the receipt is written only while the new copy is still in place', { skip }, () => {
  const c = setup();
  installed(c, {});
  const checked = lstatSync(c.app);
  const staged = makeApp(c.system, '.Breaks.app.subset-install-0', { bundleId: BUNDLE_ID, version: '0.1.1' });
  const file = receiptFile(c.home, BUNDLE_ID);
  const elsewhere = path.join(c.base, 'moved-away.app');
  // Something moves the new copy away while the receipt is made.
  const receiptDoc = { file, document: () => (renameSync(c.app, elsewhere), { schema: 'subset.receipt@1' }) };
  const warnings = [];
  swapApp({ staged, target: c.app, identity: checked, receipt: receiptDoc, trash: c.trash, appName: 'Breaks', warn: (line) => warnings.push(line), now: new Date(NOW) });
  assert.equal(existsSync(file), false, 'no receipt for a copy that is not there');
  assert.match(warnings.join('\n'), /the receipt .* was not written: .*Breaks\.app was replaced or removed after the update/);
  assert.deepEqual(readdirSync(path.dirname(file)), [], 'no temporary file is left');
});

test('uninstall --quit quits an app started after the first check, at the check just before the move', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  installed(c, { channel: 'live' });
  const app = await fakeApp(c);
  try {
    const seen = path.join(c.base, 'ps-late-seen');
    const ps = wrapper(c, 'ps-late', `if [ -f "${seen}" ]; then exec "${tools.ps}" "$@"; fi\ntouch "${seen}"`);
    const result = await uninstall(c, ['breaks', '--quit'], { tools: { ...tools, ps }, extraEnv: app.env });
    assert.equal(result.code, 0, result.stderr);
    assert.equal(result.stderr, `Quitting Breaks (pid ${app.child.pid})\n`);
    assert.equal(await app.exited, 'SIGTERM');
    assert.deepEqual(readdirSync(c.system), []);
  } finally {
    app.child.kill('SIGKILL');
  }
});

test('uninstall exits 1 naming the receipt when it cannot be removed; the app stays in the Trash', { skip: skip || (process.getuid?.() === 0 && 'root ignores permissions') }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  installed(c, { channel: 'live' });
  const receipts = path.dirname(receiptFile(c.home, BUNDLE_ID));
  chmodSync(receipts, 0o500);
  try {
    const result = await uninstall(c, ['breaks']);
    assert.equal(result.code, 1);
    assert.match(result.stderr, new RegExp(`^subset: Breaks was moved to the Trash, but its receipt ${escapeRegExp(receiptFile(c.home, BUNDLE_ID))} could not be removed \\(EACCES\\); remove it by hand\\.\\n$`));
    assert.deepEqual([readdirSync(c.system), readdirSync(c.trash).length], [[], 1]);
  } finally {
    chmodSync(receipts, 0o755);
  }
});

test('trash on another volume, SIGKILL while uninstall copies to the Trash: the app is put back and the incomplete copy removed', { skip: otherSkip }, async () => {
  const c = setupOtherVolume();
  const image = breaksImage();
  feed(c, { live: { version: '0.1.0', image } });
  const old = installed(c, { channel: 'live' });
  const ditto = wrapper(c, 'ditto-killed', `case "$2" in "${c.trash}"/*) mkdir -p "$2/Contents" && echo partial > "$2/Contents/partial"; kill -KILL $PPID; sleep 5;; esac\nexec "${tools.ditto}" "$@"`);
  const killed = await spawnCommand(c, image, ['uninstall', 'breaks'], { STUB_TOOL_MAP: toolMap(c, { ditto }) });
  assert.equal(killed.signal, 'SIGKILL', killed.stderr);
  const [aside] = leftovers(c);
  assert.match(aside, /^\.Breaks\.app\.subset-trash-\d+-[0-9a-f]{12}$/, 'the app is set aside, whole');
  const [orphan] = readdirSync(c.trash);
  assert.match(orphan, /^\.Breaks\.app\.subset-copy-\d+-[0-9a-f]{12}$/);
  // Something else in the Trash, and a copy of a subset that still runs (this test's parent), are never touched.
  const live = path.join(c.trash, `.Breaks.app.subset-copy-${process.ppid}-0123456789ab`);
  mkdirSync(live);
  makeApp(c.trash, 'Other', { bundleId: 'dev.example.other', version: '1.0' });
  const list = await run(runList, c, [], { plutil: tools.plutil });
  assert.match(list.stderr, /subset update breaks puts it back/);

  const removed = await uninstall(c, ['breaks'], { clock: () => NOW + 60_000 });
  assert.equal(removed.code, 0, removed.stderr);
  assert.match(removed.stderr, /note: Breaks was put back at /);
  assert.match(removed.stderr, new RegExp(`note: an incomplete copy of Breaks that an interrupted subset left in the Trash was removed \\(${escapeRegExp(path.join(c.trash, orphan))}\\)\\.`));
  const trashed = readdirSync(c.trash).sort();
  assert.equal(trashed.length, 3, trashed.join(', '));
  assert.ok(trashed.includes(path.basename(live)) && trashed.includes('Other.app'), 'the other entries stay');
  const moved = trashed.find((name) => name.startsWith('Breaks '));
  assert.equal(readFileSync(path.join(c.trash, moved, 'Contents', 'old-copy'), 'utf8'), '0.1.0', 'the whole app reached the Trash');
  assert.deepEqual(readFileSync(path.join(c.trash, moved, 'Contents', 'Info.plist')), old.plist);
  assert.deepEqual(readdirSync(c.system), []);
  assert.equal(existsSync(receiptFile(c.home, BUNDLE_ID)), false);
});

test('trash: removeLeftCopies removes only the app\'s copies of a subset that no longer runs, and names one it cannot remove', { skip }, async () => {
  const c = setup();
  const app = { name: 'Breaks', appName: 'Breaks' };
  const dead = deadPid();
  const orphan = path.join(c.trash, `.Breaks.app.subset-copy-${dead}-0123456789ab`);
  makeApp(orphan, 'Breaks', { bundleId: BUNDLE_ID, version: '0.1.0' });
  const kept = [`.Breaks.app.subset-copy-${process.pid}-0123456789ab`, `.Breaks.app.subset-copy-${process.ppid}-0123456789ab`, `.Timer.app.subset-copy-${dead}-0123456789ab`, `.Breaks.app.subset-trash-${dead}-0123456789ab`, 'Breaks 2026-11-14 12.00.00.app'];
  for (const name of kept) mkdirSync(path.join(c.trash, name));
  writeFileSync(path.join(c.trash, `.Breaks.app.subset-copy-${dead}-ba9876543210`), 'a file, not a copy');
  kept.push(`.Breaks.app.subset-copy-${dead}-ba9876543210`);
  const reused = path.join(c.trash, `.Breaks.app.subset-copy-${process.ppid}-0123456789ab`);
  const notes = await removeLeftCopies(app, c.trash, { tools });
  assert.deepEqual(notes.sort(), [`an incomplete copy of Breaks is in the Trash at ${reused}, left by a subset (pid ${process.ppid}) that seems to run still; remove it by hand once no subset runs.`, `an incomplete copy of Breaks that an interrupted subset left in the Trash was removed (${orphan}).`].sort());
  assert.deepEqual(readdirSync(c.trash).sort(), [...kept].sort());
  assert.deepEqual(await removeLeftCopies(app, path.join(c.base, 'no-trash'), { tools }), [], 'no Trash, nothing to do');
  if (process.getuid?.() !== 0) {
    const stuck = path.join(c.trash, `.Breaks.app.subset-copy-${dead}-00000000000a`);
    mkdirSync(path.join(stuck, 'Contents'), { recursive: true });
    chmodSync(c.trash, 0o555);
    try {
      const note = (await removeLeftCopies(app, c.trash, { tools })).find((text) => text.includes(stuck));
      assert.match(note, new RegExp(`left an incomplete copy of Breaks in the Trash at ${escapeRegExp(stuck)}, and it could not be removed \\(E[A-Z]+\\); remove it by hand\\.$`));
    } finally {
      chmodSync(c.trash, 0o755);
    }
  }
});

for (const length of [250, 255]) {
  test(`locks: the lock file name is bounded for any catalog bundle ID: one of ${length} characters installs, updates and uninstalls`, { skip }, async () => {
    const c = setup();
    // At 250 characters the receipt's name (`<bundleId>.json`) fits in 255 bytes; at 255 it cannot exist, which the update
    // warns about (receipts are advisory) and the uninstall takes as no receipt. The install is into a --dir folder,
    // which gets no receipt.
    const bundleId = `dev.subset.${'b'.repeat(length - 11)}`;
    const doc = structuredClone(template);
    doc.apps[0].bundleId = bundleId;
    const live = breaksImage({ bundleId });
    const next = breaksImage({ bundleId, version: '0.1.1' });
    const write = (version, image) => {
      Object.assign(doc.apps[0].channels.live, { version, sha256: sha256(image) });
      delete doc.apps[0].channels.beta;
      writeFileSync(c.feedFile, JSON.stringify(doc));
    };
    write('0.1.0', live);
    const elsewhere = path.join(c.base, 'elsewhere');
    mkdirSync(elsewhere);
    const installs = await run(runInstall, c, ['breaks', '--dir', elsewhere], { fetch: fakeFetch({ [LIVE_URL]: live }) });
    assert.equal(installs.code, 0, installs.stderr);
    assert.equal(plistVersion(path.join(elsewhere, 'Breaks.app')), '0.1.0');
    makeApp(c.system, 'Breaks', { bundleId, version: '0.1.0', build: '1' });
    write('0.1.1', next);
    const updates = await update(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: next }), now: NOW + 600_000, clock: () => NOW + 600_000 });
    assert.equal(updates.code, 0, updates.stderr);
    assert.equal(plistVersion(c.app), '0.1.1');
    if (length === 250) {
      assert.doesNotMatch(updates.stderr, /warning/);
      assert.equal(JSON.parse(readFileSync(receiptFile(c.home, bundleId), 'utf8')).version, '0.1.1', 'the receipt is written');
    } else assert.match(updates.stderr, /warning: the receipt .* cannot be written \(ENAMETOOLONG\); the app is updated without one/);
    const removed = await uninstall(c, ['breaks'], { now: NOW + 600_000, clock: () => NOW + 660_000 });
    assert.equal(removed.code, 0, removed.stderr);
    assert.doesNotMatch(removed.stderr, /receipt/);
    assert.deepEqual(readdirSync(c.system), []);
    assert.equal(readdirSync(c.trash).length, 2);
    if (length === 250) assert.equal(existsSync(receiptFile(c.home, bundleId)), false);
    assert.deepEqual(readdirSync(path.dirname(receiptFile(c.home, bundleId))), [], 'no receipt or temporary file is left');
    // Contention still holds for it, and the lock names stay short.
    const release = lockApp({ name: 'Breaks', bundleId }, { home: c.home });
    try {
      assert.ok(readdirSync(locksFolder(c.home)).every((name) => Buffer.byteLength(name) < 100));
      assert.throws(() => lockApp({ name: 'Breaks', bundleId }, { home: c.home }), /another subset \(pid \d+\)/);
      lockApp({ name: 'Breaks', bundleId: `${bundleId.slice(0, -1)}c` }, { home: c.home })();
    } finally {
      release();
    }
    assert.deepEqual(readdirSync(locksFolder(c.home)), []);
  });
}

test('locks: a dead holder\'s lock that cannot be removed refuses only that app, naming it; the others update and every lock is released', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  // A lock rmSync cannot remove (a folder), of a Timer subset that no longer runs.
  const stuck = path.join(locksFolder(c.home), `${lockKey('dev.subset.timer')}.${deadPid()}.0123456789ab.lock`);
  mkdirSync(path.join(stuck, 'inside'), { recursive: true });
  assert.throws(() => lockApp({ name: 'Timer', bundleId: 'dev.subset.timer' }, { home: c.home }), (error) => error instanceof LockError && error.message.includes(`the lock ${stuck} of a subset`) && /remove it by hand$/.test(error.message));
  assert.deepEqual(readdirSync(locksFolder(c.home)), [path.basename(stuck)], 'its own claim is released');

  const result = await update(c, [], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.stderr, new RegExp(`subset: Timer was not updated: the lock ${escapeRegExp(stuck)} of a subset \\(pid \\d+\\) that no longer runs cannot be removed \\([A-Z_]+\\); remove it by hand\\.`));
  assert.match(result.stdout, /^Updated Breaks 0\.1\.0 to 0\.1\.1 in /m);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.deepEqual(readdirSync(locksFolder(c.home)), [path.basename(stuck)], 'every lock taken is released');
  const timer = await uninstall(c, ['timer']);
  assert.equal(timer.code, 1);
  assert.match(timer.stderr, /subset: Timer was not uninstalled: the lock .* cannot be removed/);
});

test('uninstall --quit quits nothing when the copy was replaced after its processes were listed (by path)', { skip }, async () => {
  const c = setup();
  feed(c, { live: { version: '0.1.0', image: breaksImage() } });
  const old = installed(c, { channel: 'live' });
  const app = await fakeApp(c);
  try {
    // Another program replaces the bundle right after ps lists the processes running from its path.
    const elsewhere = path.join(c.base, 'Breaks-old.app');
    const replace = `"${process.execPath}" -e "const fs = require('node:fs'); fs.renameSync(process.argv[1], process.argv[2]); fs.mkdirSync(process.argv[1] + '/Contents', { recursive: true })" "${c.app}" "${elsewhere}"`;
    const ps = wrapper(c, 'ps-replace', `"${tools.ps}" "$@"\nstatus=$?\n[ -e "${elsewhere}" ] || ${replace}\nexit $status`);
    const result = await uninstall(c, ['breaks', '--quit'], { tools: { ...tools, ps }, extraEnv: app.env });
    assert.equal(result.code, 1, result.stderr);
    assert.equal(result.stderr, `subset: Breaks was not uninstalled: ${c.app} was replaced since it was checked (by another program?), so it was not quit or moved.\n`);
    assert.equal(app.child.exitCode, null, 'not sent SIGTERM');
    assert.equal(app.child.signalCode, null);
    assert.equal(lstatSync(elsewhere).ino, old.ino);
    assert.deepEqual(readdirSync(c.trash), []);
    assert.equal(readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8'), old.receipt);
  } finally {
    app.child.kill('SIGKILL');
  }
});
