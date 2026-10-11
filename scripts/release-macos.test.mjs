import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import {
  escapingSymlinks,
  hasHardenedRuntime,
  parseArgs,
  parseReleaseTag,
  prereleaseProblems,
  releaseVersion,
  selectAppSettings,
  unsafeOutDirReason,
  validateManifest,
} from './release-macos.mjs';

test('parses macOS release tags', () => {
  assert.deepEqual(parseReleaseTag('macos/breaks/v0.1.0'), { appId: 'breaks', version: '0.1.0' });
  assert.deepEqual(parseReleaseTag('macos/pdf-review/v12.3.4'), { appId: 'pdf-review', version: '12.3.4' });
  for (const tag of ['breaks-v0.1.0', 'macos/breaks/0.1.0', 'macos/Breaks/v0.1.0', 'macos/breaks/v0.1', 'macos/../v0.1.0', undefined]) {
    assert.throws(() => parseReleaseTag(tag), /macos\/<app-id>\/v<x\.y\.z>/, String(tag));
  }
});

test('parses macOS dev build tags', () => {
  assert.deepEqual(parseReleaseTag('macos/breaks/v0.1.1-dev.1'), { appId: 'breaks', version: '0.1.1', dev: '1' });
  assert.deepEqual(parseReleaseTag('macos/pdf-review/v2.0.0-dev.42'), { appId: 'pdf-review', version: '2.0.0', dev: '42' });
  for (const tag of [
    'macos/breaks/v0.1.1-dev.0',
    'macos/breaks/v0.1.1-dev.01',
    'macos/breaks/v0.1.1-dev.',
    'macos/breaks/v0.1.1-dev.-1',
    'macos/breaks/v0.1.1-dev.1.2',
    'macos/breaks/v0.1.1-dev1',
    'macos/breaks/v0.1.1-beta.1',
    'macos/breaks/v0.1.1-dev.1x',
    'macos/breaks/v0.1-dev.1',
  ]) {
    assert.throws(() => parseReleaseTag(tag), /-dev\.<n>/, tag);
  }
});

test('names dev builds after the dev tag', () => {
  assert.equal(releaseVersion('0.1.1'), '0.1.1');
  assert.equal(releaseVersion('0.1.1', '3'), '0.1.1-dev.3');
  const { version, dev } = parseReleaseTag('macos/breaks/v0.1.1-dev.3');
  assert.equal(`macos/breaks/v${releaseVersion(version, dev)}`, 'macos/breaks/v0.1.1-dev.3');
});

test('macOS release tags never match the npm publish trigger', () => {
  // publish-tag.yml listens for *-v*.*.*, and GitHub's * does not cross a slash.
  const npmTrigger = /^[^/]*-v[^/]*\.[^/]*\.[^/]*$/;
  assert.equal(npmTrigger.test('macos/breaks/v0.1.0'), false);
  assert.equal(npmTrigger.test('macos/pdf-review/v0.1.0'), false);
  assert.equal(npmTrigger.test('macos/breaks/v0.1.1-dev.1'), false);
  assert.equal(npmTrigger.test('usage-v0.1.0'), true);
});

test('dev tags match the workflow trigger and the environment tag policy', () => {
  // GitHub's * does not cross a slash. The trigger is read from release-macos.yml; the macos-release environment's
  // tag rule (macos/*/v*) lives in the repository settings, not in a file.
  const workflow = readFileSync(new URL('../.github/workflows/release-macos.yml', import.meta.url), 'utf8');
  const trigger = /^\s+tags:\n\s+- '([^']+)'$/m.exec(workflow)?.[1];
  assert.equal(trigger, 'macos/*/v*.*.*');
  const glob = (pattern) => new RegExp(`^${pattern.replace(/[.]/g, '\\.').replace(/\*/g, '[^/]*')}$`);
  for (const tag of ['macos/breaks/v0.1.0', 'macos/breaks/v0.1.1-dev.1', 'macos/pdf-review/v12.3.4-dev.27']) {
    assert.equal(glob(trigger).test(tag), true, tag);
    assert.equal(glob('macos/*/v*').test(tag), true, tag);
  }
});

test('flags pre-release catalog surfaces', () => {
  const live = {
    version: '0.1.0',
    url: 'https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg',
    releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0',
  };
  assert.deepEqual(prereleaseProblems(live), []);
  assert.deepEqual(prereleaseProblems({ ...live, version: '0.1.1-dev.2' }), ['version "0.1.1-dev.2" is not a plain x.y.z release']);
  assert.match(prereleaseProblems({ ...live, version: '1.0.0-beta' }).join(), /plain x\.y\.z/);
  assert.deepEqual(
    prereleaseProblems({
      ...live,
      url: 'https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.1-dev.2/Breaks-0.1.1-dev.2.dmg',
    }),
    ['url links a pre-release']
  );
  assert.deepEqual(prereleaseProblems({ ...live, releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.1-dev.2' }), [
    'releaseUrl links a pre-release',
  ]);
  assert.deepEqual(prereleaseProblems({ ...live, releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos%2Fbreaks%2Fv0.1.1%2Ddev.2' }), [
    'releaseUrl links a pre-release',
  ]);
  assert.deepEqual(prereleaseProblems({ ...live, url: 'https://example.com/Breaks-0.1.0-dev.dmg' }), ['url links a pre-release']);
  assert.deepEqual(prereleaseProblems({ ...live, url: 'https://example.com/v1.0.0-rc1/App.dmg' }), ['url links a pre-release']);
  // Only pre-release versions count: build counts, dates, and other words in a link are fine.
  for (const url of ['https://example.com/App-1.0.0-2.dmg', 'https://example.com/2025.01.15-assets/App.dmg', 'https://example.com/my-dev.tools/App.dmg']) {
    assert.deepEqual(prereleaseProblems({ ...live, url }), [], url);
  }
  assert.match(prereleaseProblems({ ...live, version: '01.2.3' }).join(), /plain x\.y\.z/);
  // A long digit run is checked in linear time.
  const started = performance.now();
  prereleaseProblems({ ...live, url: `https://example.com/1.1.${'1'.repeat(200000)}` });
  assert.ok(performance.now() - started < 1000);
});

test('validates release manifests', () => {
  assert.deepEqual(validateManifest({ project: 'Breaks.xcodeproj', scheme: 'BreaksMac', app: 'Breaks', team: 'SAZVPX4CAA' }, 'breaks'), []);
  assert.deepEqual(validateManifest({ project: 'A.xcodeproj', scheme: 'A', app: 'A' }, 'a'), []);
  const base = { project: 'A.xcodeproj', scheme: 'A', app: 'A' };
  assert.deepEqual(validateManifest({ ...base, workspaces: ['@subset/minutes', '@subset.dev/minutes'], prepared: ['packages/minutes-cli/app-runtime'] }, 'a'), []);
  assert.deepEqual(validateManifest({ ...base, prepare: 'scripts/setup.sh', prepared: ['native/a/.build/x.xcframework'] }, 'a'), []);
  for (const workspaces of [[], 'x', ['Bad Name'], [7]]) {
    assert.match(validateManifest({ ...base, workspaces, prepared: ['x'] }, 'a').join(), /"workspaces"/, String(workspaces));
  }
  for (const prepare of ['../x.sh', '/tmp/x.sh', 'scripts/setup', 'a b.sh', 'scripts/../../x.sh', 7]) {
    assert.match(validateManifest({ ...base, prepare, prepared: ['x'] }, 'a').join(), /"prepare"/, String(prepare));
  }
  for (const prepared of [['../x'], ['/abs'], 'x', [7]]) {
    assert.match(validateManifest({ ...base, prepare: 'p.sh', prepared }, 'a').join(), /"prepared"/, JSON.stringify(prepared));
  }
  // Anything built or fetched must be declared, or the signing job couldn't receive it.
  assert.match(validateManifest({ ...base, prepare: 'p.sh' }, 'a').join(), /"prepared" must list/);
  assert.match(validateManifest({ ...base, workspaces: ['@subset/minutes'] }, 'a').join(), /"prepared" must list/);
  assert.match(validateManifest({ scheme: 'A', app: 'A' }, 'a').join(), /"project"/);
  assert.match(validateManifest({ project: '../other/A.xcodeproj', scheme: 'A', app: 'A' }, 'a').join(), /inside the app directory/);
  assert.match(validateManifest({ project: 'A.xcodeproj', scheme: 'A', app: 'A/../B' }, 'a').join(), /plain app name/);
  assert.match(validateManifest({ project: 'A.xcodeproj', scheme: 'A', app: 'A', team: 'nope' }, 'a').join(), /team ID/);
  assert.deepEqual(validateManifest(null, 'a'), ['native/a/macos-release.json must be an object']);
});

test('parses arguments', () => {
  assert.deepEqual(parseArgs(['breaks']), { appId: 'breaks', skipNotarize: false });
  assert.deepEqual(parseArgs(['breaks', '--version', '0.2.0', '--notary-profile', 'subset-notary', '--out', 'x']), {
    appId: 'breaks',
    skipNotarize: false,
    version: '0.2.0',
    notaryProfile: 'subset-notary',
    out: 'x',
  });
  assert.equal(parseArgs(['breaks', '--skip-notarize']).skipNotarize, true);
  assert.equal(parseArgs(['breaks', '--dev', '7']).dev, '7');
  for (const dev of ['0', '01', '-1', '1.2', 'x', '1234567890']) assert.throws(() => parseArgs(['breaks', '--dev', dev]), /positive integer/, dev);
  assert.throws(() => parseArgs([]), /Usage/);
  assert.throws(() => parseArgs(['breaks', 'extra']), /Usage/);
  assert.throws(() => parseArgs(['../x']), /Invalid app id/);
  assert.throws(() => parseArgs(['breaks', '--version', 'latest']), /x\.y\.z/);
  assert.throws(() => parseArgs(['breaks', '--version']), /needs a value/);
  assert.throws(() => parseArgs(['breaks', '--team', 'abc']), /team ID/);
  assert.throws(() => parseArgs(['breaks', '--sign']), /Unknown option/);
  assert.equal(parseArgs(['minutes', '--prepare-only']).prepareOnly, true);
  assert.equal(parseArgs(['minutes', '--prepare-only', '--prepared-archive', 'x.tgz']).preparedArchive, 'x.tgz');
  assert.equal(parseArgs(['minutes', '--no-prepare']).noPrepare, true);
  assert.throws(() => parseArgs(['minutes', '--prepare-only', '--no-prepare']), /cannot be combined/);
  assert.throws(() => parseArgs(['minutes', '--prepared-archive', 'x.tgz']), /needs --prepare-only/);
  assert.equal(parseArgs(['minutes', '--no-prepare', '--prepared-from', 'd']).preparedFrom, 'd');
  assert.throws(() => parseArgs(['minutes', '--prepared-from', 'd']), /needs --no-prepare/);
});

test('detects the hardened runtime among other CodeDirectory flags', () => {
  assert.equal(hasHardenedRuntime('CodeDirectory v=20500 size=1021 flags=0x10000(runtime) hashes=21+7'), true);
  assert.equal(hasHardenedRuntime('flags=0x12000(library-validation,runtime) hashes=1'), true);
  assert.equal(hasHardenedRuntime('flags=0x2000(library-validation) hashes=1'), false);
  assert.equal(hasHardenedRuntime('flags=0x0(none)'), false);
  assert.equal(hasHardenedRuntime('no flags here'), false);
});

test('selects the build settings of the manifest app', () => {
  const settings = [
    { buildSettings: { WRAPPER_EXTENSION: 'appex', FULL_PRODUCT_NAME: 'Widget.appex' } },
    { buildSettings: { WRAPPER_EXTENSION: 'app', FULL_PRODUCT_NAME: 'Helper.app', MARKETING_VERSION: '9.9.9' } },
    { buildSettings: { WRAPPER_EXTENSION: 'app', FULL_PRODUCT_NAME: 'Record.app', MARKETING_VERSION: '0.1.0' } },
  ];
  assert.equal(selectAppSettings(settings, 'Record')?.MARKETING_VERSION, '0.1.0');
  assert.equal(selectAppSettings(settings, 'Missing'), undefined);
});

test('refuses output folders whose release files would be risky to clear', () => {
  const repo = '/work/subset';
  assert.match(unsafeOutDirReason('/', repo, '/Users/me'), /root/);
  assert.match(unsafeOutDirReason('/Users/me', repo, '/Users/me'), /home/);
  assert.match(unsafeOutDirReason('/work/subset', repo, '/Users/me'), /repository/);
  assert.match(unsafeOutDirReason('/work', repo, '/Users/me'), /repository/);
  assert.equal(unsafeOutDirReason('/work/subset/dist/macos/record/0.1.0', repo, '/Users/me'), null);
  assert.equal(unsafeOutDirReason('/Users/me/Downloads', repo, '/Users/me'), null);
});

test('detects symlinks that escape a prepared input', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'prepared-'));
  try {
    const framework = path.join(root, 'x.xcframework');
    mkdirSync(path.join(framework, 'Versions', 'A'), { recursive: true });
    symlinkSync('A', path.join(framework, 'Versions', 'Current'));
    assert.deepEqual(escapingSymlinks(framework), []);
    symlinkSync('../../../etc', path.join(framework, 'Versions', 'evil'));
    symlinkSync('/etc/passwd', path.join(framework, 'abs'));
    assert.deepEqual(escapingSymlinks(framework).sort(), ['Versions/evil', 'abs']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});
