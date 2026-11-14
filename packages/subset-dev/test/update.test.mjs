// subset update and subset uninstall (SET-231) with the tool stand-ins of install-stubs.mjs, so they run on Linux.
// Every refusal, failure and interruption is checked against the invariant: the installed app is the old copy,
// untouched (same inode and Info.plist), or the new verified one, never neither, and nothing staged is left behind.
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { chmodSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseUninstallArgs, runUninstall } from '../src/commands/uninstall.mjs';
import { NPM_LATEST_URL, newerLauncher, parseUpdateArgs, runUpdate } from '../src/commands/update.mjs';
import { receiptFile } from '../src/macos/apps.mjs';
import { moveToTrash, prepareTrash, renameIntoTrash, trashFolder, trashName } from '../src/macos/trash.mjs';
import { decideUpdate, UPDATE_TOOLS } from '../src/macos/update.mjs';
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
  return { bundle, ino: lstatSync(bundle).ino, receipt: channel ? readFileSync(receiptFile(c.home, BUNDLE_ID), 'utf8') : undefined };
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
async function fakeApp(c, { ignoreTerm = false, executable = path.join(c.app, 'Contents', 'MacOS', 'Breaks') } = {}) {
  const child = spawn(process.execPath, ['-e', `${ignoreTerm ? "process.on('SIGTERM', () => {});" : ''} console.log('ready'); setInterval(() => {}, 1000);`], { stdio: ['ignore', 'pipe', 'ignore'] });
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
  assert.equal(steps(c).filter((entry) => entry.step === 'ps').length, 2, 'each copy checked');

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

test('two updates of the same app at once: one updates it, the other refuses, and one old copy is in the Trash', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const barrier = path.join(c.base, 'barrier');
  mkdirSync(barrier);
  // Both reach the last check before the swap together, so they race for it.
  const env = { STUB_BARRIER_DIR: barrier, STUB_BARRIER_COUNT: '2' };
  const results = await Promise.all([spawnCommand(c, image, ['update', 'breaks'], env), spawnCommand(c, image, ['update', 'breaks'], env)]);
  assert.deepEqual(results.map((result) => result.status).sort(), [0, 1], results.map((result) => result.stderr).join('\n'));
  assert.match(results.find((result) => result.status === 1).stderr, /was changed or removed while it was being updated/);
  assertUpdated(c, '0.1.1', '0.1.0');
  assert.equal(receipt(c).version, '0.1.1');
});

test('an install and an update of the same app at once: the install refuses, the update succeeds', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1' });
  feed(c, { live: { version: '0.1.1', image } });
  installed(c, { channel: 'live' });
  const [updated, install] = await Promise.all([spawnCommand(c, image, ['update', 'breaks']), spawnCommand(c, image, ['install', 'breaks', '--dir', c.system])]);
  assert.equal(updated.status, 0, updated.stderr);
  assert.equal(install.status, 1, install.stderr);
  assert.match(install.stderr, /already exists; use subset update to change its version/);
  assertUpdated(c, '0.1.1', '0.1.0');
});
