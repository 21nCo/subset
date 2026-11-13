import assert from 'node:assert/strict';
import { existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { ApplicationsFoldersError, applicationsFolders, detectApps, PLUTIL, receiptFile } from '../src/macos/apps.mjs';
import { linkApp, makeApp, stubPlutil, writeReceipt } from './helpers.mjs';

const root = mkdtempSync(path.join(tmpdir(), 'subset-apps-test-'));
after(() => rmSync(root, { recursive: true, force: true }));
const stub = stubPlutil(root);
// Every detection test runs with the plutil stand-in, and on macOS also with the real plutil.
const plutils = [['stub plutil', stub], ...(process.platform === 'darwin' ? [['real plutil', PLUTIL]] : [])];

const BREAKS = { id: 'breaks', appName: 'Breaks', bundleId: 'dev.subset.breaks' };
const TIMER = { id: 'timer', appName: 'Timer', bundleId: 'dev.subset.timer' };
const SYSTEM = { id: 'system', appName: 'Subset System', bundleId: 'dev.subset.system' };
const SHA = '5ce3e8c78fcb273a738cdc72eec829716b5da3e945ad5ce45fe26f10d4fbd92e';

let count = 0;
// A home folder and two folders standing in for /Applications and ~/Applications.
function setup() {
  const base = path.join(root, `case-${(count += 1)}`);
  const home = path.join(base, 'home');
  const system = path.join(base, 'Applications');
  const user = path.join(base, 'user-Applications');
  for (const dir of [home, system, user]) mkdirSync(dir, { recursive: true });
  const folders = applicationsFolders({ env: { SUBSET_APPLICATIONS_DIRS: `${system}${path.delimiter}${user}` }, home });
  return { home, system, user, folders };
}

test('looks in /Applications and ~/Applications, or in the two folders of SUBSET_APPLICATIONS_DIRS', () => {
  assert.deepEqual(applicationsFolders({ env: {}, home: '/Users/alex' }), [
    { label: '/Applications', path: '/Applications', dir: '/Applications' },
    { label: '~/Applications', path: '/Users/alex/Applications', dir: '/Users/alex/Applications' }
  ]);
  assert.deepEqual(applicationsFolders({ env: { SUBSET_APPLICATIONS_DIRS: `/a${path.delimiter}/b` }, home: '/Users/alex' }).map((folder) => [folder.path, folder.dir]), [
    ['/Applications', '/a'],
    ['/Users/alex/Applications', '/b']
  ]);
  for (const value of ['/a', `/a${path.delimiter}/b${path.delimiter}/c`, `a${path.delimiter}/b`]) {
    assert.throws(() => applicationsFolders({ env: { SUBSET_APPLICATIONS_DIRS: value }, home: '/Users/alex' }), ApplicationsFoldersError, value);
  }
  assert.equal(receiptFile('/Users/alex', 'dev.subset.breaks'), '/Users/alex/Library/Application Support/Subset/receipts/dev.subset.breaks.json');
});

for (const [label, plutil] of plutils) {
  test(`finds an app by its bundle ID in either folder, with its version and build (${label})`, async () => {
    const { home, system, user, folders } = setup();
    makeApp(user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
    makeApp(system, 'Subset System', { bundleId: 'dev.subset.system', version: '1.2.3', build: '45' });
    const [breaks, timer, system_] = await detectApps([BREAKS, TIMER, SYSTEM], { folders, home, plutil });
    assert.deepEqual(breaks, [{ path: path.join(user, 'Breaks.app'), folder: '~/Applications', version: '0.1.0', build: '1', channel: null }]);
    assert.deepEqual(timer, []);
    assert.deepEqual(system_, [{ path: path.join(system, 'Subset System.app'), folder: '/Applications', version: '1.2.3', build: '45', channel: null }]);
  });

  test(`ignores a same-named app with another bundle ID or none, and reports both copies of one installed twice (${label})`, async () => {
    const { home, system, user, folders } = setup();
    makeApp(system, 'Breaks', { bundleId: 'com.example.breaks', version: '9.0.0', build: '9' });
    makeApp(user, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
    makeApp(system, 'Timer', { version: '0.1.0', build: '1' });
    makeApp(user, 'Timer', { bundleId: 'dev.subset.timer.other', version: '0.1.0', build: '1' });
    const [breaks, timer] = await detectApps([BREAKS, TIMER], { folders, home, plutil });
    assert.deepEqual(breaks.map((copy) => copy.folder), ['~/Applications']);
    assert.deepEqual(timer, []);
    makeApp(system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.1', build: '4' });
    const [both] = await detectApps([BREAKS], { folders, home, plutil });
    assert.deepEqual(both.map((copy) => [copy.folder, copy.version]), [['/Applications', '0.1.1'], ['~/Applications', '0.1.0']]);
  });

  test(`detects only a plain .app folder at the top level: no link, subfolder, file or unreadable Info.plist (${label})`, async () => {
    const { home, system, user, folders } = setup();
    const elsewhere = makeApp(path.join(root, `elsewhere-${count}`), 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
    linkApp(system, 'Breaks', elsewhere);
    makeApp(path.join(user, 'Subset'), 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
    writeFileSync(path.join(user, 'Timer.app'), 'not a bundle');
    const system_ = makeApp(system, 'Subset System', { bundleId: 'dev.subset.system', version: '1.0.0', build: '1' });
    writeFileSync(path.join(system_, 'Contents', 'Info.plist'), 'garbage');
    assert.deepEqual(await detectApps([BREAKS, TIMER, SYSTEM], { folders, home, plutil }), [[], [], []]);
  });

  test(`shows the channel of a receipt that describes the installed copy (${label})`, async () => {
    const { home, system, user, folders } = setup();
    makeApp(system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
    writeReceipt(home, 'dev.subset.breaks', { schema: 'subset.receipt@1', channel: 'live', version: '0.1.0', sha256: SHA, installedAt: '2026-11-12T09:30:00Z', path: '/Applications/Breaks.app' });
    makeApp(user, 'Timer', { bundleId: 'dev.subset.timer', version: '0.1.0', build: '2' });
    // A beta receipt for the stand-in ~/Applications: <home>/Applications. The home of a test is not under /Users, so
    // the receipt schema refuses it, as it would any receipt outside the two folders.
    writeReceipt(home, 'dev.subset.timer', { schema: 'subset.receipt@1', channel: 'beta', version: '0.1.0', build: 2, sha256: SHA, installedAt: '2026-11-12T09:30:00Z', path: path.join(home, 'Applications', 'Timer.app') });
    const [breaks, timer] = await detectApps([BREAKS, TIMER], { folders, home, plutil });
    assert.equal(breaks[0].channel, 'live');
    assert.equal(timer[0].channel, null);
    // With ~/Applications named as a home under /Users would name it, the same kind of receipt is accepted.
    writeReceipt(home, 'dev.subset.timer', { schema: 'subset.receipt@1', channel: 'beta', version: '0.1.0', build: 2, sha256: SHA, installedAt: '2026-11-12T09:30:00Z', path: '/Users/alex/Applications/Timer.app' });
    const asAlex = folders.map((folder, index) => (index === 1 ? { ...folder, path: '/Users/alex/Applications' } : folder));
    const [[beta]] = await detectApps([TIMER], { folders: asAlex, home, plutil });
    assert.equal(beta.channel, 'beta');
  });

  test(`ignores a receipt for another copy, version or build, and an invalid or unreadable one (${label})`, async () => {
    const { home, system, folders } = setup();
    makeApp(system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.1', build: '4' });
    const live = { schema: 'subset.receipt@1', channel: 'live', version: '0.1.1', sha256: SHA, installedAt: '2026-11-12T09:30:00Z', path: '/Applications/Breaks.app' };
    const beta = { ...live, channel: 'beta', build: 4 };
    const channel = async (receipt) => {
      writeReceipt(home, 'dev.subset.breaks', receipt);
      const [[copy]] = await detectApps([BREAKS], { folders, home, plutil });
      assert.ok(copy, 'the app itself is still detected');
      return copy.channel;
    };
    assert.equal(await channel(live), 'live');
    assert.equal(await channel(beta), 'beta');
    assert.equal(await channel({ ...beta, build: 3 }), null, 'another build');
    assert.equal(await channel({ ...live, version: '0.1.0' }), null, 'another version');
    assert.equal(await channel({ ...live, path: '/Users/alex/Applications/Breaks.app' }), null, 'another copy');
    assert.equal(await channel({ ...live, extra: true }), null, 'not subset.receipt@1');
    assert.equal(await channel({ ...live, build: 4 }), null, 'a live receipt with a build');
    assert.equal(await channel('{'), null, 'not JSON');
    assert.equal(await channel(`${JSON.stringify(live)}${' '.repeat(70 * 1024)}`), null, 'larger than 64 KiB');
    rmSync(receiptFile(home, 'dev.subset.breaks'));
    const [[copy]] = await detectApps([BREAKS], { folders, home, plutil });
    assert.equal(copy.channel, null, 'no receipt');
  });
}

test('an app whose Info.plist plutil cannot convert, or a missing plutil, is not detected', async () => {
  const { home, system, folders } = setup();
  makeApp(system, 'Breaks', { bundleId: 'dev.subset.breaks', version: '0.1.0', build: '1' });
  assert.deepEqual(await detectApps([BREAKS], { folders, home, plutil: path.join(root, 'no-such-plutil') }), [[]]);
  const failing = path.join(root, 'failing-plutil');
  writeFileSync(failing, '#!/bin/sh\necho "[1,2]"\n', { mode: 0o755 });
  assert.deepEqual(await detectApps([BREAKS], { folders, home, plutil: failing }), [[]]);
  assert.ok(existsSync(path.join(system, 'Breaks.app')));
});
