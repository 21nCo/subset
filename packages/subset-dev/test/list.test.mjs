import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { listDocument, listText, parseListArgs, runList } from '../src/commands/list.mjs';
import { cacheFile } from '../src/feed.mjs';
import { PLUTIL } from '../src/macos/apps.mjs';
import { makeApp, stubPlutil, writeReceipt } from './helpers.mjs';

const cli = fileURLToPath(new URL('../src/cli.mjs', import.meta.url));
const fixturesDir = new URL('../../catalog/feed/fixtures/', import.meta.url);
const fixtures = readdirSync(fixturesDir).filter((name) => /^catalog-.*\.json$/.test(name)).sort();
const fixtureUrl = (name) => new URL(name, fixturesDir).href;
const root = mkdtempSync(path.join(tmpdir(), 'subset-list-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
const stub = stubPlutil(root);
const SHA = '5ce3e8c78fcb273a738cdc72eec829716b5da3e945ad5ce45fe26f10d4fbd92e';
const NOW = Date.parse('2026-11-13T12:00:00Z');

let count = 0;
// A home and two empty folders standing in for /Applications and ~/Applications.
function setup() {
  const base = path.join(root, `case-${(count += 1)}`);
  const home = path.join(base, 'home');
  const system = path.join(base, 'Applications');
  const user = path.join(base, 'user-Applications');
  for (const dir of [home, system, user]) mkdirSync(dir, { recursive: true });
  return { home, system, user, dirs: `${system}${path.delimiter}${user}` };
}

// Runs `subset list` in this process with an injected platform and plutil; returns { code, stdout, stderr }.
async function list(args, { env, platform = 'darwin', home, now = NOW, plutil = stub }) {
  let stdout = '';
  let stderr = '';
  const code = await runList(args, {
    env,
    platform,
    home,
    now,
    plutil,
    stdout: { write: (text) => (stdout += text) },
    stderr: { write: (text) => (stderr += text) }
  });
  return { code, stdout, stderr };
}

// Runs the real command, without network: every test names its feed with SUBSET_CATALOG_URL.
const subset = (args, env) => spawnSync(process.execPath, [cli, 'list', ...args], { encoding: 'utf8', env: { ...process.env, ...env } });

test('takes --beta, --json and --refresh, and nothing else', () => {
  assert.deepEqual(parseListArgs([]), { beta: false, json: false, refresh: false });
  assert.deepEqual(parseListArgs(['--json', '--beta', '--refresh', '--beta']), { beta: true, json: true, refresh: true });
  assert.match(parseListArgs(['--all']).error, /does not take the option "--all"/);
  assert.match(parseListArgs(['breaks']).error, /does not take the argument "breaks"/);
  assert.match(parseListArgs(['--', 'x']).error, /does not take the option "--"/);
});

test('lists installed apps, live versions and tools; --beta adds the beta column', async () => {
  const { home, system, user, dirs } = setup();
  makeApp(user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
  // A same-named app that is not Subset's Timer.
  makeApp(system, 'Timer', { bundleId: 'com.example.timer', version: '3.0.0', build: '7' });
  const env = { SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-and-beta.json'), SUBSET_APPLICATIONS_DIRS: dirs };
  const plain = await list([], { env, home });
  assert.equal(plain.code, 0);
  assert.equal(plain.stderr, '');
  assert.equal(
    plain.stdout,
    `APP     INSTALLED               LIVE
breaks  0.1.0 (~/Applications)  0.1.0
timer   -                       -

TOOL   LIVE
usage  0.2.0
`
  );
  const beta = await list(['--beta'], { env, home });
  assert.equal(
    beta.stdout,
    `APP     INSTALLED               LIVE   BETA
breaks  0.1.0 (~/Applications)  0.1.0  0.1.1-beta.4
timer   -                       -      0.1.0-beta.2

TOOL   LIVE   BETA
usage  0.2.0  0.2.1-beta.1
`
  );
});

test('shows the channel from a matching receipt', async () => {
  const { home, system, dirs } = setup();
  makeApp(system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.1', build: '4' });
  writeReceipt(home, 'dev.subset.breaks', { schema: 'subset.receipt@1', channel: 'beta', version: '0.1.1', build: 4, sha256: SHA, installedAt: '2026-11-12T09:30:00Z', path: '/Applications/Breaks.app' });
  const env = { SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-only.json'), SUBSET_APPLICATIONS_DIRS: dirs };
  const { stdout } = await list([], { env, home });
  assert.equal(stdout, 'APP     INSTALLED                           LIVE\nbreaks  0.1.1-beta.4 (beta, /Applications)  0.1.0\n');
  const { stdout: json } = await list(['--json'], { env, home });
  assert.deepEqual(JSON.parse(json).apps[0].installed, [{ path: path.join(system, 'Breaks.app'), folder: '/Applications', version: '0.1.1', build: '4', channel: 'beta' }]);
});

test('--json prints the subset.list@1 document', async () => {
  const { home, user, dirs } = setup();
  makeApp(user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
  const url = fixtureUrl('catalog-valid-live-and-beta.json');
  const { code, stdout, stderr } = await list(['--json'], { env: { SUBSET_CATALOG_URL: url, SUBSET_APPLICATIONS_DIRS: dirs }, home });
  assert.equal(code, 0);
  assert.equal(stderr, '');
  assert.deepEqual(JSON.parse(stdout), {
    schema: 'subset.list@1',
    catalog: { url, generatedAt: '2026-11-12T00:00:00Z', fetchedAt: '2026-11-13T12:00:00.000Z', cached: false },
    platform: 'darwin',
    appDetection: 'supported',
    apps: [
      {
        id: 'breaks',
        name: 'Breaks',
        appName: 'Breaks',
        bundleId: 'dev.subset.breaks',
        installed: [{ path: path.join(user, 'Breaks.app'), folder: '~/Applications', version: '0.1.0', build: '1', channel: null }],
        live: { version: '0.1.0' },
        beta: { version: '0.1.1', build: 4, label: '0.1.1-beta.4' }
      },
      { id: 'timer', name: 'Timer', appName: 'Timer', bundleId: 'dev.subset.timer', installed: [], live: null, beta: { version: '0.1.0', build: 2, label: '0.1.0-beta.2' } }
    ],
    tools: [{ id: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', live: '0.2.0', beta: '0.2.1-beta.1' }]
  });
  // --beta changes only the text: the document always has both channels.
  assert.equal((await list(['--json', '--beta'], { env: { SUBSET_CATALOG_URL: url, SUBSET_APPLICATIONS_DIRS: dirs }, home, now: NOW + 1000 })).stdout.replace('"cached": true', '"cached": false'), stdout);
});

test('on Linux and Windows, lists the apps with their installation unsupported, and the tools', async () => {
  // Windows is only rendered here: its cache path would not be a path on the test's own platform.
  const catalog = { url: 'https://x.test/', fetchedAt: NOW, cached: false, feed: JSON.parse(readFileSync(new URL('catalog-valid-live-only.json', fixturesDir), 'utf8')) };
  const windows = listDocument(catalog, null, 'win32');
  assert.deepEqual([windows.platform, windows.appDetection, windows.apps[0].installed], ['win32', 'unsupported', null]);
  assert.equal(listText(windows, { beta: true }), 'APP     INSTALLED    LIVE   BETA\nbreaks  unsupported  0.1.0  -\n\nMac apps can be installed only on macOS.\n');
  for (const platform of ['linux']) {
    const { home } = setup();
    const env = { SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-and-beta.json'), SUBSET_APPLICATIONS_DIRS: 'not checked' };
    const text = await list([], { env, home, platform, plutil: path.join(root, 'never-run') });
    assert.equal(text.code, 0);
    assert.equal(
      text.stdout,
      `APP     INSTALLED    LIVE
breaks  unsupported  0.1.0
timer   unsupported  -

TOOL   LIVE
usage  0.2.0

Mac apps can be installed only on macOS.
`
    );
    const document = JSON.parse((await list(['--json'], { env, home, platform })).stdout);
    assert.equal(document.platform, platform);
    assert.equal(document.appDetection, 'unsupported');
    assert.deepEqual(document.apps.map((app) => app.installed), [null, null]);
  }
});

test('lists every valid catalog fixture in text and --json, and refuses every invalid one with a message', () => {
  for (const name of fixtures) {
    const { home, dirs } = setup();
    const env = { HOME: home, SUBSET_CATALOG_URL: fixtureUrl(name), SUBSET_APPLICATIONS_DIRS: dirs, XDG_CACHE_HOME: '' };
    const text = subset([], env);
    const json = subset(['--json'], env);
    if (name.startsWith('catalog-valid-')) {
      const feed = JSON.parse(readFileSync(new URL(name, fixturesDir), 'utf8'));
      assert.equal(text.status, 0, `${name}: ${text.stderr}`);
      assert.equal(text.stderr, '', name);
      for (const app of feed.apps) assert.match(text.stdout, new RegExp(`^${app.id}  `, 'm'), name);
      for (const tool of feed.tools) assert.match(text.stdout, new RegExp(`^${tool.id}  +${tool.distTags.latest ?? '-'}$`, 'm'), name);
      assert.equal(json.status, 0, name);
      const document = JSON.parse(json.stdout);
      assert.deepEqual(document.apps.map((app) => app.id), feed.apps.map((app) => app.id), name);
      assert.deepEqual(document.tools.map((tool) => tool.id), feed.tools.map((tool) => tool.id), name);
      assert.equal(document.appDetection, process.platform === 'darwin' ? 'supported' : 'unsupported');
      if (process.platform === 'darwin') assert.ok(document.apps.every((app) => Array.isArray(app.installed) && app.installed.length === 0));
    } else {
      for (const result of [text, json]) {
        assert.equal(result.status, 1, name);
        assert.equal(result.stdout, '', name);
        assert.match(result.stderr, /^subset: the catalog at file:.* is not a valid subset\.catalog@1 feed, so it is not used:\n {2}\S/, name);
      }
    }
  }
});

test('the command uses a stale cache with a warning on stderr when the feed cannot be fetched, and fails after 7 days', () => {
  const { home, dirs } = setup();
  const feedFile = path.join(home, 'feed.json');
  writeFileSync(feedFile, readFileSync(new URL('catalog-valid-live-only.json', fixturesDir)));
  const env = { HOME: home, SUBSET_CATALOG_URL: pathToFileURL(feedFile).href, SUBSET_APPLICATIONS_DIRS: dirs, XDG_CACHE_HOME: '' };
  assert.equal(subset(['--json'], env).status, 0);
  rmSync(feedFile);
  const cache = cacheFile({ platform: process.platform, env: {}, home });
  const age = (ms) => {
    const entry = JSON.parse(readFileSync(cache, 'utf8'));
    writeFileSync(cache, JSON.stringify({ ...entry, fetchedAt: new Date(Date.now() - ms).toISOString() }));
  };
  // Fresh: no fetch is tried, so no warning.
  const fresh = subset([], env);
  assert.equal(fresh.status, 0);
  assert.equal(fresh.stderr, '');
  age(2 * 24 * 3600 * 1000);
  const stale = subset(['--json'], env);
  assert.equal(stale.status, 0);
  assert.match(stale.stderr, /^subset: could not fetch the catalog from file:.*\(ENOENT\); using the copy cached 2 days ago\.\n$/);
  assert.equal(JSON.parse(stale.stdout).catalog.cached, true);
  age(8 * 24 * 3600 * 1000);
  const old = subset([], env);
  assert.equal(old.status, 1);
  assert.equal(old.stdout, '');
  assert.match(old.stderr, /the cached copy is 8 days old, more than 7 days\.\n$/);
});

test('refuses an http: catalog URL and a bad SUBSET_APPLICATIONS_DIRS with exit code 1, and an unknown option with 2', async () => {
  const { home, dirs } = setup();
  const http = subset([], { HOME: home, SUBSET_CATALOG_URL: 'http://subset.21n.dev/catalog/v1.json' });
  assert.equal(http.status, 1);
  assert.match(http.stderr, /must be an https: or file: URL, not http:/);
  const folders = await list([], { env: { SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-only.json'), SUBSET_APPLICATIONS_DIRS: '/only-one' }, home });
  assert.equal(folders.code, 1);
  assert.match(folders.stderr, /SUBSET_APPLICATIONS_DIRS must be two absolute folders/);
  const unknown = subset(['--all'], { HOME: home, SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-only.json'), SUBSET_APPLICATIONS_DIRS: dirs });
  assert.equal(unknown.status, 2);
  assert.equal(unknown.stdout, '');
  assert.match(unknown.stderr, /^subset: subset list does not take the option "--all"/);
});

test('says so when the catalog lists nothing', () => {
  const document = listDocument({ url: 'https://x.test/', fetchedAt: NOW, cached: false, feed: { generatedAt: '2026-11-12T00:00:00Z', apps: [], tools: [] } }, [], 'darwin');
  assert.equal(listText(document, { beta: false }), 'The catalog lists no apps or tools.\n');
});

test('detects a real app bundle with the real plutil through the command', { skip: process.platform !== 'darwin' && 'macOS only' }, () => {
  const { home, user, dirs } = setup();
  makeApp(user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1', extra: '\t<key>LSMinimumSystemVersion</key>\n\t<string>15.0</string>\n\t<key>LSUIElement</key>\n\t<true/>\n' });
  const env = { HOME: home, SUBSET_CATALOG_URL: fixtureUrl('catalog-valid-live-only.json'), SUBSET_APPLICATIONS_DIRS: dirs };
  const result = subset([], env);
  assert.equal(result.status, 0, result.stderr);
  assert.equal(result.stdout, 'APP     INSTALLED               LIVE\nbreaks  0.1.0 (~/Applications)  0.1.0\n');
  assert.equal(PLUTIL, '/usr/bin/plutil');
});
