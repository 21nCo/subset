import assert from 'node:assert/strict';
import test from 'node:test';
import { parseArgs, parseReleaseTag, validateManifest } from './release-macos.mjs';

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
