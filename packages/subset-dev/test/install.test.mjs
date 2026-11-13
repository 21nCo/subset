import assert from 'node:assert/strict';
import { execFileSync, spawn } from 'node:child_process';
import { createHash } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { chmodSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseInstallArgs, runInstall } from '../src/commands/install.mjs';
import { validateReceipt } from '../src/feed.mjs';
import { receiptFile } from '../src/macos/apps.mjs';
import { INSTALL_TOOLS } from '../src/macos/install.mjs';
import { compareVersions } from '../src/macos/verify.mjs';
import { makeApp } from './helpers.mjs';
import { appFiles, attachedImages, makeImage, makeImageWithModes, stubTools, stubToolsSkip } from './install-stubs.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const preload = new URL('./install-preload.mjs', import.meta.url).href;
const template = JSON.parse(readFileSync(new URL('../../catalog/feed/fixtures/catalog-valid-live-and-beta.json', import.meta.url), 'utf8'));
const LIVE_URL = template.apps[0].channels.live.url;
const BETA_URL = template.apps[0].channels.beta.url;
const NOW = Date.parse('2026-11-13T12:00:00Z');
const root = mkdtempSync(path.join(tmpdir(), 'subset-install-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
mkdirSync(path.join(root, 'tools'));
const tools = stubToolsSkip ? undefined : stubTools(path.join(root, 'tools'));
const sha256 = (bytes) => createHash('sha256').update(bytes).digest('hex');
const skip = stubToolsSkip;

let count = 0;
// A case folder: a home, two folders standing in for /Applications and ~/Applications, a temporary folder, a stub log
// and the feed (written by `feed`).
function setup() {
  const base = path.join(root, `case-${(count += 1)}`);
  const c = { base, home: path.join(base, 'home'), system: path.join(base, 'Applications'), user: path.join(base, 'user-Applications'), tmp: path.join(base, 'tmp'), log: path.join(base, 'stub.log') };
  for (const dir of [c.home, c.system, c.user, c.tmp]) mkdirSync(dir, { recursive: true });
  c.feedFile = path.join(base, 'catalog.json');
  c.env = { SUBSET_CATALOG_URL: pathToFileURL(c.feedFile).href, SUBSET_APPLICATIONS_DIRS: `${c.system}${path.delimiter}${c.user}` };
  return c;
}

// Writes the case's feed: the fixture's Breaks with each channel's sha256 that of the given image (or `sha`), and
// `change` applied to the app.
function feed(c, { live, beta, change = () => {} }) {
  const doc = structuredClone(template);
  const breaks = doc.apps[0];
  if (live) breaks.channels.live.sha256 = live.sha ?? sha256(live.image);
  else delete breaks.channels.live;
  if (beta) breaks.channels.beta.sha256 = beta.sha ?? sha256(beta.image);
  else delete breaks.channels.beta;
  change(breaks);
  writeFileSync(c.feedFile, JSON.stringify(doc));
}

// A fetch serving `images` ({ url: bytes }); `calls` lists the URLs asked for.
function fakeFetch(images, { status = 200, redirect } = {}) {
  const calls = [];
  const fetch = async (url, init) => {
    calls.push(String(url));
    assert.equal(init.redirect, 'manual');
    if (redirect && String(url) !== redirect) return new Response(null, { status: 302, headers: { location: redirect } });
    const bytes = images[String(url)] ?? images[LIVE_URL];
    return new Response(status === 200 ? bytes : 'not found', { status });
  };
  return Object.assign(fetch, { calls });
}

// Runs `subset install` in this process with the stand-in tools; returns { code, stdout, stderr }.
async function install(c, args, { fetch, platform = 'darwin', signals = new EventEmitter(), toolSet = tools } = {}) {
  let stdout = '';
  let stderr = '';
  const previous = { TMPDIR: process.env.TMPDIR, STUB_LOG: process.env.STUB_LOG };
  process.env.TMPDIR = c.tmp;
  process.env.STUB_LOG = c.log;
  try {
    const code = await runInstall(args, {
      env: c.env,
      platform,
      home: c.home,
      now: NOW,
      fetch,
      tools: toolSet,
      signals,
      stdout: { write: (text) => (stdout += text) },
      stderr: { write: (text) => (stderr += text) }
    });
    return { code, stdout, stderr };
  } finally {
    for (const [key, value] of Object.entries(previous)) {
      if (value === undefined) delete process.env[key];
      else process.env[key] = value;
    }
  }
}

const steps = (c) => (existsSync(c.log) ? readFileSync(c.log, 'utf8').trim().split('\n').filter(Boolean).map((line) => JSON.parse(line)) : []);
const receipt = (c) => receiptFile(c.home, 'dev.subset.breaks');

// No image downloaded into the case's temporary folder is still attached to the stand-in hdiutil.
const assertDetached = (c) => assert.deepEqual(stillAttached(c), [], 'the image is detached');
const stillAttached = (c) => (tools ? attachedImages(path.dirname(tools.hdiutil)).filter((image) => image.startsWith(`${c.tmp}${path.sep}`)) : []);

// Nothing was installed: the destination holds only what it held before and there is no receipt. The image is
// detached and the private folder is gone.
function assertNothingInstalled(c, dir = c.system, before = []) {
  assert.deepEqual(readdirSync(dir).sort(), before, `${dir} is unchanged`);
  assert.equal(existsSync(receipt(c)), false, 'no receipt');
  assertDetached(c);
  assert.deepEqual(readdirSync(c.tmp), [], 'the private folder is removed');
}

const breaksImage = (options) => makeImage({ ...appFiles('Breaks.app', options), Applications: 'link' });

test('parses the app, --beta, --user and --dir, and refuses anything else', () => {
  assert.deepEqual(parseInstallArgs(['breaks']), { app: 'breaks', beta: false, user: false, dir: undefined });
  assert.deepEqual(parseInstallArgs(['--beta', 'breaks', '--dir', '/tmp/x']), { app: 'breaks', beta: true, user: false, dir: '/tmp/x' });
  assert.deepEqual(parseInstallArgs(['breaks', '--user']), { app: 'breaks', beta: false, user: true, dir: undefined });
  assert.match(parseInstallArgs([]).error, /needs an app/);
  assert.match(parseInstallArgs(['breaks', 'timer']).error, /takes one app/);
  assert.match(parseInstallArgs(['breaks', '--sudo']).error, /does not take the option "--sudo"/);
  assert.match(parseInstallArgs(['breaks', '--dir']).error, /--dir needs a folder/);
  assert.match(parseInstallArgs(['breaks', '--user', '--dir', '/tmp']).error, /cannot be used together/);
  assert.ok(compareVersions('0.1.10', '0.1.9') > 0 && compareVersions('1.0.0', '1.0.0') === 0 && compareVersions('0.9.9', '1.0.0') < 0);
});

test('exits 2 for a usage error and 1 off macOS, touching nothing', { skip }, async () => {
  const c = setup();
  const fetch = fakeFetch({});
  const usage = await install(c, ['breaks', '--force'], { fetch });
  assert.equal(usage.code, 2);
  assert.match(usage.stderr, /Usage: subset install <app> \[--beta\] \[--user\] \[--dir <folder>\]/);
  const linux = await install(c, ['breaks'], { fetch, platform: 'linux' });
  assert.deepEqual(linux, { code: 1, stdout: '', stderr: 'subset: Mac apps can be installed only on macOS.\n' });
  assert.deepEqual(fetch.calls, []);
});

test('installs the live app in the /Applications stand-in with its receipt', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image }, beta: { image } });
  const fetch = fakeFetch({ [LIVE_URL]: image });
  const result = await install(c, ['breaks'], { fetch });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Installed Breaks 0.1.0 in ${path.join(c.system, 'Breaks.app')}\n`);
  assert.deepEqual(fetch.calls, [LIVE_URL]);
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  // The image's permissions, not the staging folder's 0700.
  assert.equal(statSync(path.join(c.system, 'Breaks.app')).mode & 0o777, 0o755 & ~process.umask());
  const written = JSON.parse(readFileSync(receipt(c), 'utf8'));
  assert.deepEqual(written, { schema: 'subset.receipt@1', channel: 'live', version: '0.1.0', sha256: sha256(image), installedAt: '2026-11-13T12:00:00Z', path: '/Applications/Breaks.app' });
  assert.deepEqual(validateReceipt(written), []);
  assert.deepEqual(readdirSync(c.tmp), []);
  // The tools ran in order, on the staged copy, with the image attached read-only and hidden in the private folder,
  // and the image was detached by its device, then checked to be gone.
  const log = steps(c);
  assert.deepEqual(log.map((entry) => entry.step), ['hdiutil-attach', 'ditto', 'codesign-verify', 'codesign-display', 'spctl', 'sw_vers', 'hdiutil-detach', 'hdiutil-info']);
  assert.match(log[0].args[5], new RegExp(`^${c.tmp}/subset-install-[^/]+/mnt$`));
  assert.match(log[6].args[1], /^\/dev\/disk\d+$/);
  assertDetached(c);
  const staged = log[2].args[3];
  assert.match(path.basename(staged), /^\.Breaks\.app\.subset-install-[0-9a-f]{12}$/);
  assert.equal(path.dirname(staged), c.system);
  assert.equal(log[1].args[1], staged);
});

test('installs a beta, checking its build, with a beta receipt', { skip }, async () => {
  const c = setup();
  const image = breaksImage({ version: '0.1.1', build: '4' });
  feed(c, { live: { image: breaksImage() }, beta: { image } });
  const result = await install(c, ['breaks', '--beta'], { fetch: fakeFetch({ [BETA_URL]: image }) });
  assert.equal(result.code, 0, result.stderr);
  assert.equal(result.stdout, `Installed Breaks 0.1.1-beta.4 in ${path.join(c.system, 'Breaks.app')}\n`);
  assert.equal(JSON.parse(readFileSync(receipt(c), 'utf8')).build, 4);

  const wrongBuild = setup();
  feed(wrongBuild, { beta: { image: breaksImage({ version: '0.1.1', build: '3' }) } });
  const refused = await install(wrongBuild, ['breaks', '--beta'], { fetch: fakeFetch({ [BETA_URL]: breaksImage({ version: '0.1.1', build: '3' }) }) });
  assert.equal(refused.code, 1);
  assert.match(refused.stderr, /the version check failed: its build is "3", not 4/);
  assertNothingInstalled(wrongBuild);
});

test('--user, an unwritable /Applications and --dir choose the destination; --dir elsewhere gets no receipt', { skip }, async () => {
  const image = breaksImage();
  const fetch = () => fakeFetch({ [LIVE_URL]: image });
  const user = setup();
  feed(user, { live: { image } });
  assert.equal((await install(user, ['breaks', '--user'], { fetch: fetch() })).code, 0);
  assert.deepEqual([readdirSync(user.system), readdirSync(user.user)], [[], ['Breaks.app']]);
  // The test's home is not /Users/<user>, so subset.receipt@1 cannot name its ~/Applications: no receipt is written.
  assert.equal(existsSync(receipt(user)), false);

  if (process.getuid?.() !== 0) {
    const locked = setup();
    feed(locked, { live: { image } });
    rmSync(locked.user, { recursive: true });
    chmodSync(locked.system, 0o555);
    try {
      const result = await install(locked, ['breaks'], { fetch: fetch() });
      assert.equal(result.code, 0, result.stderr);
      assert.deepEqual(readdirSync(locked.user), ['Breaks.app'], '~/Applications is created');
    } finally {
      chmodSync(locked.system, 0o755);
    }
  }

  const elsewhere = setup();
  feed(elsewhere, { live: { image } });
  const dir = path.join(elsewhere.base, 'elsewhere');
  mkdirSync(dir);
  assert.equal((await install(elsewhere, ['breaks', '--dir', dir], { fetch: fetch() })).code, 0);
  assert.deepEqual(readdirSync(dir), ['Breaks.app']);
  assert.equal(existsSync(receipt(elsewhere)), false);
  // --dir naming the /Applications stand-in is that folder, with its receipt.
  const named = setup();
  feed(named, { live: { image } });
  assert.equal((await install(named, ['breaks', '--dir', named.system], { fetch: fetch() })).code, 0);
  assert.equal(JSON.parse(readFileSync(receipt(named), 'utf8')).path, '/Applications/Breaks.app');
  const missing = await install(named, ['breaks', '--dir', path.join(named.base, 'nope')], { fetch: fetch() });
  assert.equal(missing.code, 1);
  assert.match(missing.stderr, /the destination step failed: .*nope is not a folder/);
});

// Each in-scope failure: exit 1, a message naming the failed check, and no app, staged copy or receipt left behind.
const refusals = [
  ['a corrupted download', { sha: '0'.repeat(64) }, {}, /the checksum step failed: the download's SHA-256 is [0-9a-f]{64}, not 0{64} as the feed lists/],
  ['an HTTP error', {}, { status: 404 }, /the download step failed: HTTP 404/],
  ['a redirect to http:', {}, { redirect: 'http://example.com/Breaks.dmg' }, /the download step failed: redirected to a URL that is not https: \(http:\)/],
  ['an image that cannot be attached', { image: Buffer.from('not an image') }, {}, /the image step failed: hdiutil could not attach the image \(hdiutil: attach failed - image not recognized\)/, 0],
  ['an image with no app', { image: makeImage({ 'README.txt': 'hi' }) }, {}, /the image step failed: the image holds 0 apps at its root, not exactly one \(Breaks\.app\)/],
  ['an image with two apps', { image: makeImage({ ...appFiles('Breaks.app'), ...appFiles('Other.app') }) }, {}, /the image step failed: the image holds 2 apps/],
  ['an app with another name', { image: makeImage(appFiles('Breaks 2.app')) }, {}, /the image step failed: the image holds "Breaks 2\.app", not Breaks\.app/],
  ['an image with two volumes', { image: makeImage(appFiles('Breaks.app'), appFiles('Breaks.app')) }, {}, /the image step failed: the image mounted 2 volumes, not one/],
  ['an unsigned app', { image: breaksImage({ signature: null }) }, {}, /the signature check failed: the code signature is not valid \(codesign: .*not signed at all\)/],
  ['a broken signature', { image: breaksImage({ signature: { valid: false, team: 'SAZVPX4CAA', notarized: true } }) }, {}, /the signature check failed/],
  ['an ad-hoc signed app', { image: breaksImage({ signature: { valid: true, team: null, notarized: false } }) }, {}, /the team check failed: it is not signed by the Subset team SAZVPX4CAA \(TeamIdentifier: not set\)/],
  ['an app signed by another team', { image: breaksImage({ signature: { valid: true, team: 'ABCDE12345', notarized: true } }) }, {}, /the team check failed: .*\(TeamIdentifier: ABCDE12345\)/],
  ['an app that is not notarized', { image: breaksImage({ signature: { valid: true, team: 'SAZVPX4CAA', notarized: false } }) }, {}, /the notarization check failed: .*source=Unnotarized Developer ID/],
  ['another bundle ID', { image: breaksImage({ bundleId: 'com.example.breaks' }) }, {}, /the bundle ID check failed: its bundle ID is "com\.example\.breaks", not dev\.subset\.breaks/],
  ['another version', { image: breaksImage({ version: '0.0.9' }) }, {}, /the version check failed: its version is "0\.0\.9", not 0\.1\.0/],
  ['a newer macOS than this Mac', { image: breaksImage({ minimumSystem: '16.0' }) }, {}, /the macOS version check failed: it needs macOS 16\.0 or later, and this Mac runs 15\.1/]
];

for (const [name, image, fetchOptions, message, detaches = 1] of refusals) {
  test(`refuses ${name}`, { skip }, async () => {
    const c = setup();
    const bytes = image.image ?? breaksImage();
    feed(c, { live: { image: bytes, sha: image.sha } });
    const result = await install(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: bytes }, fetchOptions) });
    assert.equal(result.code, 1);
    assert.equal(result.stdout, '');
    assert.match(result.stderr, /subset: Breaks 0\.1\.0 was not installed: /);
    assert.match(result.stderr, message);
    assertNothingInstalled(c);
    const log = steps(c).map((entry) => entry.step);
    assert.doesNotMatch(result.stderr, /warning/);
    if (log.includes('hdiutil-attach')) assert.equal(log.filter((step) => step === 'hdiutil-detach').length, detaches, 'the attached image is detached once');
  });
}

test('refuses a feed whose download URL is off the allowlist, before downloading anything', { skip }, async () => {
  const c = setup();
  feed(c, { live: { image: breaksImage() }, change: (app) => (app.channels.live.url = 'https://example.com/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg') });
  const fetch = fakeFetch({});
  const result = await install(c, ['breaks'], { fetch });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /is not a valid subset\.catalog@1 feed, so it is not used:\n {2}\/apps\/0\/channels\/live\/url: does not match/);
  assert.deepEqual(fetch.calls, []);
  assertNothingInstalled(c);
});

test('refuses an app that is already there, or a downgrade, before downloading', { skip }, async () => {
  const there = setup();
  feed(there, { live: { image: breaksImage() } });
  makeApp(there.system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
  const fetch = fakeFetch({});
  const exists = await install(there, ['breaks'], { fetch });
  assert.equal(exists.code, 1);
  assert.match(exists.stderr, /Breaks\.app already exists; use subset update to change its version\./);

  const newer = setup();
  feed(newer, { live: { image: breaksImage() } });
  makeApp(newer.user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.2.0', build: '9' });
  const downgrade = await install(newer, ['breaks'], { fetch });
  assert.equal(downgrade.code, 1);
  assert.equal(downgrade.stderr, 'subset: Breaks 0.1.0 was not installed: 0.2.0 is installed in ~/Applications, and subset install does not downgrade.\n');
  assert.deepEqual(readdirSync(newer.system), []);

  const beta = setup();
  feed(beta, { beta: { image: breaksImage() } });
  makeApp(beta.user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.1', build: '5' });
  const olderBuild = await install(beta, ['breaks', '--beta'], { fetch });
  assert.match(olderBuild.stderr, /0\.1\.1 \(build 5\) is installed in ~\/Applications, and subset install does not downgrade/);
  assert.deepEqual(fetch.calls, []);
});

test('names unknown apps and missing channels', { skip }, async () => {
  const c = setup();
  feed(c, { beta: { image: breaksImage() } });
  const fetch = fakeFetch({});
  assert.match((await install(c, ['nope'], { fetch })).stderr, /there is no Subset Mac app "nope"; subset list shows them/);
  assert.match((await install(c, ['breaks'], { fetch })).stderr, /Breaks has no live release yet; try subset install breaks --beta/);
  // A new home, so the catalog cached for the first feed is not used.
  const liveOnly = setup();
  feed(liveOnly, { live: { image: breaksImage() } });
  assert.match((await install(liveOnly, ['breaks', '--beta'], { fetch })).stderr, /Breaks has no beta\./);
});

test('a receipt that cannot be written leaves no app', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image } });
  // The receipts folder is a file.
  mkdirSync(path.join(c.home, 'Library', 'Application Support', 'Subset'), { recursive: true });
  writeFileSync(path.join(c.home, 'Library', 'Application Support', 'Subset', 'receipts'), '');
  const result = await install(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /the receipt step failed: the receipt .* cannot be written/);
  assert.deepEqual(readdirSync(c.system), []);
  assert.deepEqual(readdirSync(c.tmp), []);
});

// ditto keeps the image's permissions: a refused app whose folders are read-only is still removed.
test('a refused app with read-only folders is removed', { skip: skip || (process.getuid?.() === 0 && 'root ignores permissions') }, async () => {
  const c = setup();
  const files = { ...appFiles('Breaks.app', { signature: { valid: true, team: 'ABCDE12345', notarized: true } }), 'Breaks.app/Contents/Resources/en.lproj/x.strings': 'x' };
  const image = makeImageWithModes(files, { 'Breaks.app': 0o555, 'Breaks.app/Contents': 0o555, 'Breaks.app/Contents/Resources': 0o555, 'Breaks.app/Contents/Resources/en.lproj': 0o555 });
  feed(c, { live: { image } });
  const result = await install(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 1);
  assert.match(result.stderr, /the team check failed/);
  assert.doesNotMatch(result.stderr, /warning/);
  assertNothingInstalled(c);
});

test('installing next to a copy in the other folder says that the receipt now describes the new copy', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image } });
  makeApp(c.user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
  const result = await install(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }) });
  assert.equal(result.code, 0, result.stderr);
  assert.match(result.stderr, /subset: note: Breaks 0\.1\.0 is also installed in ~\/Applications; the receipt now describes the copy in \/Applications\.\n/);
  assert.equal(JSON.parse(readFileSync(receipt(c), 'utf8')).path, '/Applications/Breaks.app');
});

test('a signal before the rename stops the install and leaves nothing (in process)', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image } });
  const signals = new EventEmitter();
  const fetch = async () => {
    signals.emit('SIGINT');
    return new Response(image);
  };
  const result = await install(c, ['breaks'], { fetch, signals });
  assert.equal(result.code, 130);
  assert.match(result.stderr, /Breaks 0\.1\.0 was not installed: interrupted by SIGINT\./);
  assertNothingInstalled(c);
  assert.equal(signals.listenerCount('SIGINT'), 0, 'the handlers are removed');
});

// Runs the real command in its own process with the stand-in tools (install-preload.mjs).
// With `group`, it leads its own process group, as a command started at a terminal does.
function spawnInstall(c, image, extraEnv = {}, args = ['breaks', '--dir', c.system], { group = false } = {}) {
  const imageFile = path.join(c.base, `image-${Math.random().toString(16).slice(2)}.dmg`);
  writeFileSync(imageFile, image);
  const map = Object.fromEntries(Object.entries(INSTALL_TOOLS).map(([key, file]) => [file, tools[key]]));
  const env = { ...process.env, ...c.env, HOME: c.home, TMPDIR: c.tmp, STUB_LOG: c.log, STUB_TOOL_MAP: JSON.stringify(map), FAKE_IMAGE: imageFile, XDG_CACHE_HOME: '', ...extraEnv };
  const child = spawn(process.execPath, ['--import', preload, cli, 'install', ...args], { env, stdio: ['ignore', 'pipe', 'pipe'], detached: group });
  let stdout = '';
  let stderr = '';
  child.stdout.on('data', (chunk) => (stdout += chunk));
  child.stderr.on('data', (chunk) => (stderr += chunk));
  return new Promise((resolve) => child.on('close', (status, signal) => resolve({ status, signal, stdout, stderr })));
}

// Every point between two steps where a signal can arrive before the rename: during the download (between its chunks),
// and while each tool runs, including plutil reading the staged copy's Info.plist.
const boundaries = ['download', 'hdiutil-attach', 'ditto', 'codesign-verify', 'codesign-display', 'spctl', 'plutil', 'sw_vers'];
for (const boundary of boundaries) {
  for (const signal of boundary === 'ditto' ? ['SIGTERM', 'SIGINT', 'SIGHUP'] : ['SIGTERM']) {
    test(`${signal} at ${boundary} leaves the destination unchanged and no receipt`, { skip }, async () => {
      const c = setup();
      const image = breaksImage();
      feed(c, { live: { image } });
      makeApp(c.system, 'Other', { bundleId: 'com.example.other', version: '1.0.0', build: '1' });
      const result = await spawnInstall(c, image, { STUB_SIGNAL_AT: boundary, STUB_SIGNAL: signal }, ['breaks']);
      assert.equal(result.status, { SIGTERM: 143, SIGINT: 130, SIGHUP: 129 }[signal], result.stderr);
      assert.match(result.stderr, new RegExp(`was not installed: interrupted by ${signal}\\.`));
      assert.equal(result.stdout, '');
      assertNothingInstalled(c, c.system, ['Other.app']);
    });
  }
}

// Ctrl-C at a terminal signals the whole foreground process group. The tools run in their own group, so only subset
// gets it: each stand-in signals the group and then does its work, which it would not live to do if it were in it.
for (const boundary of boundaries) {
  test(`a SIGINT to the process group at ${boundary} leaves the destination unchanged and no receipt`, { skip }, async () => {
    const c = setup();
    const image = breaksImage();
    feed(c, { live: { image } });
    const env = { STUB_SIGNAL_AT: boundary, STUB_SIGNAL: 'SIGINT', STUB_SIGNAL_GROUP: '1', STUB_LINGER_MS: '50' };
    const result = await spawnInstall(c, image, env, ['breaks'], { group: true });
    assert.equal(result.status, 130, result.stderr);
    assert.match(result.stderr, /was not installed: interrupted by SIGINT\./);
    assert.doesNotMatch(result.stderr, /warning/);
    assertNothingInstalled(c);
  });
}

test('a SIGINT to the process group after the rename, while the image is detached, keeps the app and its receipt', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image } });
  const env = { STUB_SIGNAL_AT: 'hdiutil-detach', STUB_SIGNAL: 'SIGINT', STUB_SIGNAL_GROUP: '1', STUB_LINGER_MS: '50' };
  const result = await spawnInstall(c, image, env, ['breaks'], { group: true });
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, `Installed Breaks 0.1.0 in ${path.join(c.system, 'Breaks.app')}\n`);
  assert.doesNotMatch(result.stderr, /warning/);
  assert.deepEqual(readdirSync(c.system), ['Breaks.app']);
  assert.equal(JSON.parse(readFileSync(receipt(c), 'utf8')).path, '/Applications/Breaks.app');
  assertDetached(c);
  assert.deepEqual(readdirSync(c.tmp), [], 'the private folder is removed');
});

// A tool that takes a while to stop: it keeps working after the signal (ditto copying, hdiutil mounting the image).
// The cleanup waits for it to exit, so what it did afterwards is cleaned up too.
for (const boundary of ['hdiutil-attach', 'ditto']) {
  test(`a tool still working at ${boundary} after SIGTERM is waited for before the cleanup`, { skip }, async () => {
    const c = setup();
    const image = breaksImage();
    feed(c, { live: { image } });
    const result = await spawnInstall(c, image, { STUB_SIGNAL_AT: boundary, STUB_LINGER_MS: '700' }, ['breaks']);
    assert.equal(result.status, 143, result.stderr);
    assert.doesNotMatch(result.stderr, /warning/);
    assertNothingInstalled(c);
  });
}

test('two installs of the same app into one --dir at once: exactly one succeeds', { skip }, async () => {
  const c = setup();
  const image = breaksImage();
  feed(c, { live: { image } });
  const barrier = path.join(c.base, 'barrier');
  mkdirSync(barrier);
  // Both reach the last check before the rename together, so they race for it.
  const env = { STUB_BARRIER_DIR: barrier, STUB_BARRIER_COUNT: '2' };
  const results = await Promise.all([spawnInstall(c, image, env), spawnInstall(c, image, env)]);
  assert.deepEqual(results.map((result) => result.status).sort(), [0, 1], results.map((result) => result.stderr).join('\n'));
  const loser = results.find((result) => result.status === 1);
  assert.match(loser.stderr, /the install step failed: .*Breaks\.app already exists; use subset update to change its version/);
  assert.deepEqual(readdirSync(c.system), ['Breaks.app'], 'one app and no staged copy');
  assert.deepEqual(readdirSync(c.tmp), []);
});

// On macOS, with the real hdiutil, codesign and spctl: an ad-hoc signed app in a real disk image is refused at the team
// check (the macOS CI job also installs the real Breaks 0.1.0, .github/workflows/verify.yml).
test('with the real tools, refuses an ad-hoc signed app at the team check', { skip: process.platform !== 'darwin' && 'needs macOS' }, async () => {
  const c = setup();
  const source = path.join(c.base, 'source');
  const bundle = path.join(source, 'Breaks.app');
  mkdirSync(path.join(bundle, 'Contents', 'MacOS'), { recursive: true });
  copyFileSync('/usr/bin/true', path.join(bundle, 'Contents', 'MacOS', 'Breaks'));
  writeFileSync(
    path.join(bundle, 'Contents', 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.subset.breaks</string>
<key>CFBundleExecutable</key><string>Breaks</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
</dict></plist>
`
  );
  execFileSync('/usr/bin/codesign', ['--sign', '-', '--force', bundle]);
  const dmg = path.join(c.base, 'adhoc.dmg');
  execFileSync('/usr/bin/hdiutil', ['create', '-quiet', '-fs', 'HFS+', '-volname', 'Breaks', '-srcfolder', source, '-format', 'UDZO', dmg]);
  const image = readFileSync(dmg);
  feed(c, { live: { image } });
  const result = await install(c, ['breaks'], { fetch: fakeFetch({ [LIVE_URL]: image }), toolSet: INSTALL_TOOLS });
  assert.equal(result.code, 1, result.stderr);
  assert.match(result.stderr, /the team check failed: it is not signed by the Subset team SAZVPX4CAA \(TeamIdentifier: not set\)/);
  assert.deepEqual(readdirSync(c.system), []);
  assert.equal(existsSync(receipt(c)), false);
  assert.deepEqual(readdirSync(c.tmp), []);
  assert.equal(execFileSync('/usr/bin/hdiutil', ['info'], { encoding: 'utf8' }).includes(c.tmp), false, 'the image is detached');
});
