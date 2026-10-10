import assert from 'node:assert/strict';
import test from 'node:test';
import { hasHardenedRuntime, parseArgs, parseReleaseTag, selectAppSettings, unsafeOutDirReason, validateManifest } from './release-macos.mjs';

test('parses macOS release tags', () => {
  assert.deepEqual(parseReleaseTag('macos/breaks/v0.1.0'), { appId: 'breaks', version: '0.1.0' });
  assert.deepEqual(parseReleaseTag('macos/pdf-review/v12.3.4'), { appId: 'pdf-review', version: '12.3.4' });
  for (const tag of ['breaks-v0.1.0', 'macos/breaks/0.1.0', 'macos/Breaks/v0.1.0', 'macos/breaks/v0.1', 'macos/../v0.1.0', undefined]) {
    assert.throws(() => parseReleaseTag(tag), /macos\/<app-id>\/v<x\.y\.z>/, String(tag));
  }
});

test('macOS release tags never match the npm publish trigger', () => {
  // publish-tag.yml listens for *-v*.*.*, and GitHub's * does not cross a slash.
  const npmTrigger = /^[^/]*-v[^/]*\.[^/]*\.[^/]*$/;
  assert.equal(npmTrigger.test('macos/breaks/v0.1.0'), false);
  assert.equal(npmTrigger.test('macos/pdf-review/v0.1.0'), false);
  assert.equal(npmTrigger.test('usage-v0.1.0'), true);
});

test('validates release manifests', () => {
  assert.deepEqual(validateManifest({ project: 'Breaks.xcodeproj', scheme: 'BreaksMac', app: 'Breaks', team: 'SAZVPX4CAA' }, 'breaks'), []);
  assert.deepEqual(validateManifest({ project: 'A.xcodeproj', scheme: 'A', app: 'A' }, 'a'), []);
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
  assert.throws(() => parseArgs([]), /Usage/);
  assert.throws(() => parseArgs(['breaks', 'extra']), /Usage/);
  assert.throws(() => parseArgs(['../x']), /Invalid app id/);
  assert.throws(() => parseArgs(['breaks', '--version', 'latest']), /x\.y\.z/);
  assert.throws(() => parseArgs(['breaks', '--version']), /needs a value/);
  assert.throws(() => parseArgs(['breaks', '--team', 'abc']), /team ID/);
  assert.throws(() => parseArgs(['breaks', '--sign']), /Unknown option/);
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
