import assert from 'node:assert/strict';
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { RESERVED_NAMES } from '../packages/subset-dev/src/commands.mjs';
import {
  appMetadataProblems,
  checkAppMetadata,
  escapingSymlinks,
  isRepoRelativePath,
  unexpectedArchiveMembers,
  hasHardenedRuntime,
  macosReleaseManifestProblems,
  parseArgs,
  parseReleaseTag,
  prereleaseProblems,
  readMacosReleaseManifests,
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

test('parses macOS beta and dev build tags', () => {
  assert.deepEqual(parseReleaseTag('macos/breaks/v0.1.1-beta.3'), { appId: 'breaks', version: '0.1.1', prerelease: { channel: 'beta', build: '3' } });
  assert.deepEqual(parseReleaseTag('macos/breaks/v0.1.1-dev.1'), { appId: 'breaks', version: '0.1.1', prerelease: { channel: 'dev', build: '1' } });
  assert.deepEqual(parseReleaseTag('macos/pdf-review/v2.0.0-beta.42').prerelease, { channel: 'beta', build: '42' });
  for (const tag of [
    'macos/breaks/v0.1.1-beta.0',
    'macos/breaks/v0.1.1-beta.01',
    'macos/breaks/v0.1.1-beta.',
    'macos/breaks/v0.1.1-beta.-1',
    'macos/breaks/v0.1.1-beta.1.2',
    'macos/breaks/v0.1.1-beta1',
    'macos/breaks/v0.1.1-rc.1',
    'macos/breaks/v0.1.1-beta.1x',
    'macos/breaks/v0.1-beta.1',
  ]) {
    assert.throws(() => parseReleaseTag(tag), /-beta\.<n>/, tag);
  }
});

test('names beta builds after the tag', () => {
  assert.equal(releaseVersion('0.1.1'), '0.1.1');
  assert.equal(releaseVersion('0.1.1', { channel: 'beta', build: '3' }), '0.1.1-beta.3');
  for (const tag of ['macos/breaks/v0.1.1-beta.3', 'macos/breaks/v0.1.1-dev.2']) {
    const { version, prerelease } = parseReleaseTag(tag);
    assert.equal(`macos/breaks/v${releaseVersion(version, prerelease)}`, tag);
  }
});

test('macOS release tags never match the npm publish trigger', () => {
  // publish-tag.yml listens for *-v*.*.*, and GitHub's * does not cross a slash.
  const npmTrigger = /^[^/]*-v[^/]*\.[^/]*\.[^/]*$/;
  assert.equal(npmTrigger.test('macos/breaks/v0.1.0'), false);
  assert.equal(npmTrigger.test('macos/pdf-review/v0.1.0'), false);
  assert.equal(npmTrigger.test('macos/breaks/v0.1.1-dev.1'), false);
  assert.equal(npmTrigger.test('macos/breaks/v0.1.1-beta.1'), false);
  assert.equal(npmTrigger.test('usage-v0.1.0'), true);
});

test('beta tags match the workflow trigger and the environment tag policy', () => {
  // GitHub's * does not cross a slash. The trigger is read from release-macos.yml; the macos-release environment's
  // tag rule (macos/*/v*) lives in the repository settings, not in a file.
  const workflow = readFileSync(new URL('../.github/workflows/release-macos.yml', import.meta.url), 'utf8');
  const trigger = /^\s+tags:\n\s+- '([^']+)'$/m.exec(workflow)?.[1];
  assert.equal(trigger, 'macos/*/v*.*.*');
  const glob = (pattern) => new RegExp(`^${pattern.replace(/[.]/g, '\\.').replace(/\*/g, '[^/]*')}$`);
  for (const tag of ['macos/breaks/v0.1.0', 'macos/breaks/v0.1.1-beta.1', 'macos/breaks/v0.1.1-dev.1', 'macos/pdf-review/v12.3.4-beta.27']) {
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
  assert.deepEqual(validateManifest({ project: 'Breaks.xcodeproj', scheme: 'BreaksMac', app: 'Breaks', team: 'SAZVPX4CAA', bundleId: 'dev.subset.breaks' }, 'breaks'), []);
  assert.deepEqual(validateManifest({ project: 'A.xcodeproj', scheme: 'A', app: 'A', bundleId: 'dev.subset.a' }, 'a'), []);
  const base = { project: 'A.xcodeproj', scheme: 'A', app: 'A', bundleId: 'dev.subset.a' };
  assert.deepEqual(validateManifest({ ...base, workspaces: ['@subset.dev/minutes-core', '@subset.dev/minutes'] }, 'a'), []);
  assert.deepEqual(validateManifest({ ...base, prepare: 'scripts/setup.sh' }, 'a'), []);
  for (const workspaces of [[], 'x', ['Bad Name'], [7]]) {
    assert.match(validateManifest({ ...base, workspaces }, 'a').join(), /"workspaces"/, String(workspaces));
  }
  for (const prepare of ['../x.sh', '/tmp/x.sh', 'scripts/setup', 'a b.sh', 'scripts/../../x.sh', './x.sh', 7]) {
    assert.match(validateManifest({ ...base, prepare }, 'a').join(), /"prepare"/, String(prepare));
  }
  assert.match(validateManifest({ ...base, project: undefined }, 'a').join(), /"project"/);
  assert.match(validateManifest({ ...base, project: '../other/A.xcodeproj' }, 'a').join(), /inside the app directory/);
  assert.match(validateManifest({ ...base, app: 'A/../B' }, 'a').join(), /plain app name/);
  assert.match(validateManifest({ ...base, team: 'nope' }, 'a').join(), /team ID/);
  assert.deepEqual(validateManifest(null, 'a'), ['native/a/macos-release.json must be an object']);
  assert.deepEqual(validateManifest([], 'a'), ['native/a/macos-release.json must be an object']);
});

// What scripts/check-workspaces.mjs runs over every native/<app-id>/macos-release.json.
const systemRelease = {
  appId: 'system',
  manifest: {
    project: 'System.xcodeproj',
    scheme: 'SubsetSystem',
    app: 'Subset System',
    bundleId: 'dev.subset.system',
    helpers: [{ command: 'system', path: 'Contents/Helpers/subset-system', kind: 'native' }],
  },
};
const timerRelease = {
  appId: 'timer',
  manifest: {
    project: 'Timer.xcodeproj',
    scheme: 'Timer',
    app: 'Timer',
    bundleId: 'dev.subset.timer',
    helpers: [{ command: 'timer', path: 'Contents/Resources/timer-cli/dist/cli.mjs', kind: 'node' }],
  },
};
const withHelper = (release, helper) => ({ ...release, manifest: { ...release.manifest, helpers: [{ ...release.manifest.helpers[0], ...helper }] } });
const releaseProblems = (...entries) => macosReleaseManifestProblems(entries, RESERVED_NAMES).join('\n');

test('check-workspaces accepts declared bundle IDs and helpers', () => {
  const breaks = { appId: 'breaks', manifest: { project: 'Breaks.xcodeproj', scheme: 'BreaksMac', app: 'Breaks', bundleId: 'dev.subset.breaks' } };
  assert.deepEqual(macosReleaseManifestProblems([systemRelease, timerRelease, breaks], RESERVED_NAMES), []);
});

test('check-workspaces refuses a missing or malformed bundleId', () => {
  const { bundleId, ...withoutBundleId } = systemRelease.manifest;
  assert.match(releaseProblems({ appId: 'system', manifest: withoutBundleId }), /^native\/system\/macos-release\.json: "bundleId" must be/);
  for (const bad of ['', 'subset', 'dev.subset.', 'dev..subset', 'dev.subset system', 'dev/subset.system', 7]) {
    assert.match(releaseProblems({ ...systemRelease, manifest: { ...systemRelease.manifest, bundleId: bad } }), /"bundleId" must be/, String(bad));
  }
});

test('check-workspaces refuses a helper command declared twice', () => {
  assert.match(releaseProblems(systemRelease, withHelper(timerRelease, { command: 'system' })), /native\/timer\/macos-release\.json: command "system" is already declared by native\/system\/macos-release\.json/);
  const twice = { ...systemRelease, manifest: { ...systemRelease.manifest, helpers: [...systemRelease.manifest.helpers, { command: 'system', path: 'Contents/Helpers/other', kind: 'native' }] } };
  assert.match(releaseProblems(twice), /command "system" is already declared by native\/system/);
  assert.match(releaseProblems(systemRelease, { ...timerRelease, manifest: { ...timerRelease.manifest, bundleId: 'dev.subset.system' } }), /bundleId "dev\.subset\.system" is already declared/);
});

test('check-workspaces refuses a helper command that is a subset command', () => {
  for (const verb of ['install', 'uninstall', 'update', 'list', 'help', 'version']) {
    assert.match(releaseProblems(withHelper(systemRelease, { command: verb })), new RegExp(`helper command "${verb}" is a reserved subset command`), verb);
  }
  for (const bad of ['System', '-x', 'a b', '', 7]) assert.match(releaseProblems(withHelper(systemRelease, { command: bad })), /"command" must be a tool ID/, String(bad));
});

test('check-workspaces refuses an unknown helper kind', () => {
  for (const kind of ['python', 'Native', '', undefined]) assert.match(releaseProblems(withHelper(systemRelease, { kind })), /"kind" must be one of native, node/, String(kind));
  assert.match(releaseProblems(withHelper(systemRelease, { args: ['--x'] })), /unknown key "args"/);
  for (const helpers of [[], {}, 'Contents/Helpers/subset-system', [null]]) {
    assert.match(releaseProblems({ ...systemRelease, manifest: { ...systemRelease.manifest, helpers } }), /"helpers"/, JSON.stringify(helpers));
  }
});

test('check-workspaces refuses a helper path outside the app\'s Contents folder', () => {
  for (const bad of [
    '/Applications/Subset System.app/Contents/Helpers/subset-system',
    '/usr/local/bin/subset-system',
    '../subset-system',
    'Contents/../../subset-system',
    'Contents/Helpers/../../../x',
    'Contents/./Helpers/subset-system',
    './Contents/Helpers/subset-system',
    'Helpers/subset-system',
    'Contents',
    'Contents/',
    'Contents//Helpers/subset-system',
    'Contents/Helpers/subset system',
  ]) {
    assert.match(releaseProblems(withHelper(systemRelease, { path: bad })), /"path" must be a relative path inside the app's Contents\/ folder/, bad);
  }
  assert.match(releaseProblems(withHelper(timerRelease, { path: 'Contents/Resources/timer-cli/dist/cli.js' })), /node helper must be an \.mjs ES module/);
});

test('every committed macos-release.json passes check-workspaces', () => {
  const entries = readMacosReleaseManifests(fileURLToPath(new URL('../native/', import.meta.url)));
  assert.ok(entries.length > 0);
  assert.deepEqual(macosReleaseManifestProblems(entries, RESERVED_NAMES), []);
  const commands = Object.fromEntries(entries.flatMap(({ manifest }) => (manifest.helpers ?? []).map(({ command, path: helperPath, kind }) => [command, `${kind} ${helperPath}`])));
  assert.deepEqual(commands, {
    minutes: 'node Contents/Resources/minutes-cli/dist/cli.mjs',
    'point-in-time': 'native Contents/Helpers/point-in-time',
    system: 'native Contents/Helpers/subset-system',
    timer: 'node Contents/Resources/timer-cli/dist/cli.mjs',
  });
});

test('check-workspaces reads the manifest of an app folder whose name contains "?" or "#"', (t) => {
  const nativeDirectory = mkdtempSync(path.join(tmpdir(), 'native-'));
  t.after(() => rmSync(nativeDirectory, { recursive: true, force: true }));
  const write = (appId, manifest) => {
    mkdirSync(path.join(nativeDirectory, appId));
    writeFileSync(path.join(nativeDirectory, appId, 'macos-release.json'), JSON.stringify(manifest));
  };
  const { bundleId, ...withoutBundleId } = systemRelease.manifest;
  write('a?b', withoutBundleId);
  write('c#d', { ...timerRelease.manifest, bundleId: 'not a bundle id' });
  write('system', systemRelease.manifest);
  mkdirSync(path.join(nativeDirectory, 'no-release'));
  const entries = readMacosReleaseManifests(nativeDirectory);
  assert.deepEqual(entries.map(({ appId }) => appId).sort(), ['a?b', 'c#d', 'system']);
  const problems = macosReleaseManifestProblems(entries, RESERVED_NAMES).join('\n');
  assert.match(problems, /^native\/a\?b\/macos-release\.json: "bundleId" must be/m);
  assert.match(problems, /^native\/c#d\/macos-release\.json: "bundleId" must be/m);
  assert.doesNotMatch(problems, /native\/system\//);
});

// A fixture Subset System.app and a stand-in for plutil: it answers `plutil -extract CFBundleIdentifier raw -expect
// string -o - <plist>` with the fixture Info.plist's text (the bundle ID, as plutil prints it) and fails otherwise.
function fixtureApp(t, { bundleId = 'dev.subset.system' } = {}) {
  const root = mkdtempSync(path.join(tmpdir(), 'release-app-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const app = path.join(root, 'Subset System.app');
  mkdirSync(path.join(app, 'Contents', 'Helpers'), { recursive: true });
  mkdirSync(path.join(app, 'Contents', 'Resources', 'timer-cli', 'dist'), { recursive: true });
  if (bundleId !== null) writeFileSync(path.join(app, 'Contents', 'Info.plist'), `${bundleId}\n`);
  writeFileSync(path.join(app, 'Contents', 'Helpers', 'subset-system'), '#!/bin/sh\n', { mode: 0o755 });
  writeFileSync(path.join(app, 'Contents', 'Resources', 'timer-cli', 'dist', 'cli.mjs'), 'export {};\n', { mode: 0o644 });
  const plutil = path.join(root, 'plutil');
  writeFileSync(
    plutil,
    `#!/bin/sh
[ "$*" = "-extract CFBundleIdentifier raw -expect string -o - $8" ] || { echo "unexpected arguments: $*" >&2; exit 64; }
[ -f "$8" ] || { echo "$8: file does not exist or is not readable" >&2; exit 1; }
cat "$8"
`,
    { mode: 0o755 }
  );
  return { root, app, plutil };
}
const manifestWith = (helpers) => ({ ...systemRelease.manifest, helpers });
const nodeHelper = { command: 'timer', path: 'Contents/Resources/timer-cli/dist/cli.mjs', kind: 'node' };

test('a release passes when the app has the declared bundle ID and helpers', (t) => {
  const { app, plutil } = fixtureApp(t);
  const manifest = manifestWith([...systemRelease.manifest.helpers, nodeHelper]);
  assert.deepEqual(appMetadataProblems(app, manifest, { plutil }), []);
  assert.doesNotThrow(() => checkAppMetadata(app, 'system', manifest, { plutil }));
  // An app that bundles no command needs only the bundle ID.
  assert.deepEqual(appMetadataProblems(app, { ...systemRelease.manifest, helpers: undefined }, { plutil }), []);
});

test('a release fails when the app has another bundle ID', (t) => {
  const { app, plutil } = fixtureApp(t, { bundleId: 'dev.subset.other' });
  assert.throws(
    () => checkAppMetadata(app, 'system', systemRelease.manifest, { plutil }),
    (error) => error.message === 'Subset System.app does not match native/system/macos-release.json: CFBundleIdentifier is "dev.subset.other", but "bundleId" is "dev.subset.system"'
  );
});

test('a release fails when the bundle ID cannot be read', (t) => {
  const { app, plutil } = fixtureApp(t, { bundleId: null });
  assert.match(appMetadataProblems(app, systemRelease.manifest, { plutil }).join(), /could not read CFBundleIdentifier from Contents\/Info\.plist: .*does not exist/);
  const { app: other } = fixtureApp(t);
  assert.match(appMetadataProblems(other, systemRelease.manifest, { plutil: path.join(other, 'no-such-plutil') }).join(), /could not read CFBundleIdentifier/);
});

test('a release fails when a declared helper is missing or unusable', (t) => {
  const { root, app, plutil } = fixtureApp(t);
  const missing = { command: 'point-in-time', path: 'Contents/Helpers/point-in-time', kind: 'native' };
  assert.throws(
    () => checkAppMetadata(app, 'system', manifestWith([...systemRelease.manifest.helpers, missing]), { plutil }),
    /^Error: Subset System\.app does not match native\/system\/macos-release\.json: helper "point-in-time" at Contents\/Helpers\/point-in-time is missing from the app$/
  );
  // A native helper must be executable; a node helper is a module that Node.js reads.
  chmodSync(path.join(app, 'Contents', 'Helpers', 'subset-system'), 0o644);
  assert.deepEqual(appMetadataProblems(app, manifestWith([...systemRelease.manifest.helpers, nodeHelper]), { plutil }), [
    'helper "system" at Contents/Helpers/subset-system is not executable (mode 644)',
  ]);
  assert.deepEqual(appMetadataProblems(app, manifestWith([{ ...nodeHelper, kind: 'native' }]), { plutil }), [
    'helper "timer" at Contents/Resources/timer-cli/dist/cli.mjs is not executable (mode 644)',
  ]);
  // A folder, or a link out of the app, is not a bundled helper.
  assert.deepEqual(appMetadataProblems(app, manifestWith([{ command: 'x', path: 'Contents/Helpers', kind: 'native' }]), { plutil }), ['helper "x" at Contents/Helpers is not a file']);
  writeFileSync(path.join(root, 'outside'), '#!/bin/sh\n', { mode: 0o755 });
  symlinkSync('../../../outside', path.join(app, 'Contents', 'Helpers', 'linked'));
  assert.deepEqual(appMetadataProblems(app, manifestWith([{ command: 'x', path: 'Contents/Helpers/linked', kind: 'native' }]), { plutil }), [
    'helper "x" at Contents/Helpers/linked resolves outside the app',
  ]);
  // A link that stays inside the app is followed (ditto keeps the links an embedded runtime has).
  symlinkSync('subset-system', path.join(app, 'Contents', 'Helpers', 'alias'));
  chmodSync(path.join(app, 'Contents', 'Helpers', 'subset-system'), 0o755);
  assert.deepEqual(appMetadataProblems(app, manifestWith([{ command: 'x', path: 'Contents/Helpers/alias', kind: 'native' }]), { plutil }), []);
});

test('reads the bundle ID from a real Info.plist with plutil', { skip: process.platform !== 'darwin' && 'plutil is a macOS tool' }, (t) => {
  const { app } = fixtureApp(t);
  const plist = (value) =>
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict><key>CFBundleIdentifier</key>${value}</dict></plist>\n`;
  writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist('<string>dev.subset.system</string>'));
  assert.deepEqual(appMetadataProblems(app, systemRelease.manifest), []);
  writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist('<string>dev.subset.system.debug</string>'));
  assert.deepEqual(appMetadataProblems(app, systemRelease.manifest), ['CFBundleIdentifier is "dev.subset.system.debug", but "bundleId" is "dev.subset.system"']);
  writeFileSync(path.join(app, 'Contents', 'Info.plist'), plist('<dict/>'));
  assert.match(appMetadataProblems(app, systemRelease.manifest).join(), /could not read CFBundleIdentifier/);
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
  assert.deepEqual(parseArgs(['breaks', '--beta', '7']).prerelease, { channel: 'beta', build: '7' });
  assert.deepEqual(parseArgs(['breaks', '--dev', '7']).prerelease, { channel: 'dev', build: '7' });
  for (const build of ['0', '01', '-1', '1.2', 'x', '1234567890']) {
    assert.throws(() => parseArgs(['breaks', '--beta', build]), /positive integer/, build);
    assert.throws(() => parseArgs(['breaks', '--dev', build]), /positive integer/, build);
  }
  assert.throws(() => parseArgs(['breaks', '--beta', '1', '--dev', '1']), /cannot be combined/);
  assert.throws(() => parseArgs([]), /Usage/);
  assert.throws(() => parseArgs(['breaks', 'extra']), /Usage/);
  assert.throws(() => parseArgs(['../x']), /Invalid app id/);
  assert.throws(() => parseArgs(['breaks', '--version', 'latest']), /x\.y\.z/);
  assert.throws(() => parseArgs(['breaks', '--version']), /needs a value/);
  assert.throws(() => parseArgs(['breaks', '--team', 'abc']), /team ID/);
  assert.throws(() => parseArgs(['breaks', '--sign']), /Unknown option/);
  assert.deepEqual(parseArgs(['minutes', '--archive-only', '--archive-out', 'a.tgz', '--beta', '2']), {
    appId: 'minutes',
    skipNotarize: false,
    archiveOnly: true,
    archiveOut: 'a.tgz',
    prerelease: { channel: 'beta', build: '2' },
  });
  assert.equal(parseArgs(['minutes', '--from-archive', 'a.tgz', '--version', '0.1.0']).fromArchive, 'a.tgz');
  assert.throws(() => parseArgs(['minutes', '--archive-only']), /needs --archive-out/);
  assert.throws(() => parseArgs(['minutes', '--archive-out', 'a.tgz']), /needs --archive-only/);
  assert.throws(() => parseArgs(['minutes', '--from-archive', 'a.tgz']), /needs --version/);
  assert.throws(() => parseArgs(['minutes', '--archive-only', '--archive-out', 'a', '--from-archive', 'b', '--version', '0.1.0']), /cannot be combined/);
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

test('detects symlinks that escape an archive', () => {
  const root = mkdtempSync(path.join(tmpdir(), 'prepared-'));
  try {
    writeFileSync(path.join(root, 'secret'), 'outside');
    const framework = path.join(root, 'x.xcframework');
    mkdirSync(path.join(framework, 'Versions', 'A', 'b'), { recursive: true });
    symlinkSync('A', path.join(framework, 'Versions', 'Current'));
    assert.deepEqual(escapingSymlinks(framework), []);
    // Both resolve to the existing root/secret only when the links are followed: as text, 's/../secret' looks like
    // x.xcframework/secret. A lexical check would accept them.
    symlinkSync('.', path.join(framework, 's'));
    symlinkSync('s/../secret', path.join(framework, 'chained'));
    symlinkSync('../..', path.join(framework, 'Versions', 'A', 'b', 'up'));
    symlinkSync('Versions/A/b/up/../../secret', path.join(framework, 'chained2'));
    symlinkSync('../../../etc', path.join(framework, 'Versions', 'evil'));
    symlinkSync(path.join(framework, 'Versions', 'A'), path.join(framework, 'absolute-inside'));
    symlinkSync('missing', path.join(framework, 'dangling'));
    assert.deepEqual(escapingSymlinks(framework).sort(), ['Versions/evil', 'absolute-inside', 'chained', 'chained2', 'dangling'].sort());
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('accepts only plain repository-relative paths', () => {
  for (const ok of ['packages/minutes-cli/app-runtime', 'native/dictate/.build/whisper.xcframework', 'a']) assert.equal(isRepoRelativePath(ok), true, ok);
  for (const bad of ['.', './.', '', 'a/./b', 'a//b', 'a/', '../a', 'a/../b', '/abs', 'a b', 7]) assert.equal(isRepoRelativePath(bad), false, String(bad));
});

test('flags archive members outside the allowed roots', () => {
  const roots = ['Minutes.xcarchive'];
  const ok = [
    'Minutes.xcarchive/',
    'Minutes.xcarchive/Info.plist',
    'Minutes.xcarchive/Products/Applications/Minutes.app/Contents/Resources/minutes-cli/node_modules/@scope/pkg+1~x/a file.js',
  ];
  assert.deepEqual(unexpectedArchiveMembers(ok, roots), []);
  const bad = [
    'scripts/release-macos.mjs',
    '../evil',
    '/etc/passwd',
    'Minutes.xcarchive/../../../x',
    'Minutes.xcarchive-other/x',
    'Other.xcarchive/x',
    './x',
    'Minutes.xcarchive/a\\..\\b',
    'Minutes.xcarchive/line\nbreak',
    'Minutes.xcarchive/c1\u009bx',
  ];
  assert.deepEqual(unexpectedArchiveMembers(bad, roots), bad);
});
