import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { chmodSync, existsSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { MAX_FEED_BYTES, buildCatalogFeed, catalogFeedProblems, liveNpm, receiptProblems, recordedSources } from './catalog-feed.mjs';
import { readMacosReleaseManifests } from './release-macos.mjs';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixtures = path.join(root, 'packages/catalog/feed/fixtures');
const recordedFile = path.join(root, 'scripts/fixtures/catalog-feed/recorded.json');
const script = path.join(root, 'scripts/catalog-feed.mjs');
// The check:workspaces script builds packages/catalog before the tests run.
const { capabilities } = await import(new URL('packages/catalog/dist/index.js', `file://${root}/`).href);
const manifests = readMacosReleaseManifests(path.join(root, 'native'));
const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));
const releaseTargets = readJson(path.join(root, 'release-packages.json')).map((target) => ({ ...target, manifest: readJson(path.join(root, target.path, 'package.json')) }));
const recorded = readJson(recordedFile);
const generatedAt = new Date('2026-11-12T00:00:00.000Z');

const RELEASES_URL = 'https://api.github.com/repos/21nCo/subset/releases?per_page=100&page=1';
const DOWNLOAD = 'https://github.com/21nCo/subset/releases/download/';
const sha = (character) => character.repeat(64);

// A GitHub releases-list entry as the REST API returns it (only the fields the generator reads).
function release(tag, { draft = false, prerelease = true, files = ['dmg', 'zip', 'SHA256SUMS'], app = 'Record', digest } = {}) {
  const version = tag.slice(tag.lastIndexOf('/v') + 2);
  const names = { dmg: `${app}-${version}.dmg`, zip: `${app}-${version}.zip`, SHA256SUMS: 'SHA256SUMS' };
  return {
    tag_name: tag,
    draft,
    prerelease,
    html_url: `https://github.com/21nCo/subset/releases/tag/${tag}`,
    assets: files.map((file) => ({
      name: names[file],
      state: 'uploaded',
      ...(file === 'dmg' && digest !== undefined ? { digest } : {}),
      browser_download_url: `${DOWNLOAD}${tag}/${names[file]}`
    }))
  };
}

const sumsLine = (hash, file) => `${hash}  ${file}\n`;

// Builds a feed from the repository's catalog, manifests and packages, answering GitHub and npm from `responses`.
function build({ releases = [], files = {}, npm = {}, catalog = capabilities, targets = releaseTargets } = {}) {
  const sources = recordedSources({ github: { [RELEASES_URL]: releases, ...files }, npm });
  return buildCatalogFeed({ capabilities: catalog, manifests, releaseTargets: targets, generatedAt, ...sources });
}
const npmNone = Object.fromEntries(releaseTargets.map((target) => [target.name, null]));
const appIds = (feed) => feed.apps.map((app) => app.id);

test('every valid fixture is accepted and every invalid one is refused for its own reason', () => {
  const reasons = {
    'catalog-invalid-wrong-host': /url must match pattern/,
    'catalog-invalid-dot-segment': /url must match pattern/,
    'catalog-invalid-missing-sha256': /must have required property 'sha256'/,
    'catalog-invalid-unknown-field': /must NOT have additional properties \(homepage\)/,
    'catalog-invalid-oversize': /262145 bytes, more than 262144/,
    'catalog-invalid-wrong-schema': /\/schema must be equal to constant/,
    'catalog-invalid-duplicate-app': /app id "breaks" appears more than once/,
    'receipt-invalid-live-with-build': /\/build boolean schema is false/,
    'receipt-invalid-beta-without-build': /must have required property 'build'/,
    'receipt-invalid-unknown-field': /must NOT have additional properties \(bundleId\)/,
    'receipt-invalid-relative-path': /\/path must match pattern/,
    'receipt-invalid-other-applications-folder': /\/path must match pattern/,
    'receipt-invalid-parent-segment': /\/path must match pattern/
  };
  const names = readdirSync(fixtures).filter((name) => name.endsWith('.json')).map((name) => name.slice(0, -'.json'.length));
  // The contract both readers test against: these cases must stay.
  for (const required of ['catalog-valid-live-only', 'catalog-valid-live-and-beta', 'catalog-valid-tools-only', 'receipt-valid-live', 'receipt-valid-beta', ...Object.keys(reasons)]) {
    assert.ok(names.includes(required), `fixture ${required}.json is missing`);
  }
  for (const name of names) {
    const [kind, verdict] = name.split('-');
    assert.ok(['catalog', 'receipt'].includes(kind) && ['valid', 'invalid'].includes(verdict), `${name}.json is not named <catalog|receipt>-<valid|invalid>-<case>`);
    const problems = (kind === 'catalog' ? catalogFeedProblems : receiptProblems)(readFileSync(path.join(fixtures, `${name}.json`)));
    if (verdict === 'valid') assert.deepEqual(problems, [], `${name} should be valid`);
    else assert.match(problems.join('\n'), reasons[name] ?? /(?!)/, `${name} is refused for another reason: ${problems.join('; ')}`);
  }
});

test('a receipt path is an app directly in /Applications or a user\'s ~/Applications', () => {
  const live = readJson(path.join(fixtures, 'receipt-valid-live.json'));
  const problems = (appPath) => receiptProblems(JSON.stringify({ ...live, path: appPath }));
  for (const accepted of ['/Applications/Breaks.app', '/Users/alex/Applications/Breaks.app', '/Applications/Screen Shot.app']) assert.deepEqual(problems(accepted), [], accepted);
  const refused = [
    '/tmp/x/Applications/Breaks.app',
    '/Volumes/USB/Applications/Breaks.app',
    '/Users/alex/Desktop/Applications/Breaks.app',
    '/Users/./Applications/Breaks.app',
    '/Applications/./Breaks.app',
    '/Applications/.Breaks.app',
    '/Applications/Utilities/Breaks.app',
    'Applications/Breaks.app',
    '/Applications/Bre\naks.app',
    '/Applications/Bre\u0000aks.app',
    '/Users/al\u007fex/Applications/Breaks.app'
  ];
  for (const appPath of refused) assert.match(problems(appPath).join(), /\/path must match pattern/, JSON.stringify(appPath));
});

test('the size limit is 256 KiB of the document as read, whatever it holds', () => {
  const oversize = readFileSync(path.join(fixtures, 'catalog-invalid-oversize.json'));
  assert.equal(oversize.byteLength, MAX_FEED_BYTES + 1);
  // The oversize fixture is otherwise a valid feed, so only its size refuses it.
  assert.deepEqual(catalogFeedProblems(JSON.stringify(JSON.parse(oversize))), []);
  const atLimit = oversize.toString('utf8').replace(/ \}\n$/, '}\n');
  assert.equal(Buffer.byteLength(atLimit), MAX_FEED_BYTES);
  assert.deepEqual(catalogFeedProblems(atLimit), []);
  // Bytes, not characters: multibyte text over the limit is refused even when it has fewer characters than that.
  const liveOnly = readJson(path.join(fixtures, 'catalog-valid-live-only.json'));
  const compact = JSON.stringify({ ...liveOnly, apps: [{ ...liveOnly.apps[0], summary: 'é'.repeat(400) }] });
  const wide = `${compact.slice(0, -1)}${' '.repeat(MAX_FEED_BYTES - compact.length)}}`;
  assert.ok(wide.length <= MAX_FEED_BYTES && Buffer.byteLength(wide) > MAX_FEED_BYTES);
  assert.match(catalogFeedProblems(wide).join(), /more than 262144/);
});

test('download and release page URLs must stay on 21nCo/subset releases', () => {
  const liveOnly = readJson(path.join(fixtures, 'catalog-valid-live-only.json'));
  const withLive = (live) => JSON.stringify({ ...liveOnly, apps: [{ ...liveOnly.apps[0], channels: { live: { ...liveOnly.apps[0].channels.live, ...live } } }] });
  const refused = [
    'http://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg',
    'https://github.com.evil.example/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg',
    'https://github.com/21nCo/subset-fork/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg',
    'https://github.com/21nCo/subset/releases/download/macos/breaks/./v0.1.0/Breaks-0.1.0.dmg',
    'https://github.com/21nCo/subset/releases/download/%2e%2e/%2e%2e/x/Breaks-0.1.0.dmg',
    'https://github.com/21nCo/subset/releases/download/macos\\..\\..\\x/Breaks-0.1.0.dmg',
    'https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg?x=1.dmg',
    'https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.zip'
  ];
  for (const url of refused) assert.match(catalogFeedProblems(withLive({ url })).join(), /url must match pattern/, url);
  assert.match(catalogFeedProblems(withLive({ releaseUrl: 'https://github.com/21nCo/subset/releases/tag/../../../evil' })).join(), /releaseUrl must match pattern/);
  assert.match(catalogFeedProblems(withLive({ releaseUrl: 'https://example.com/releases/tag/macos/breaks/v0.1.0' })).join(), /releaseUrl must match pattern/);
});

test('Breaks gets a live entry with the catalog sha256 and the newest complete beta, from recorded responses', async () => {
  const feed = await buildCatalogFeed({ capabilities, manifests, releaseTargets, generatedAt, ...recordedSources(recorded) });
  assert.deepEqual(catalogFeedProblems(JSON.stringify(feed)), []);
  assert.equal(feed.generatedAt, '2026-11-12T00:00:00Z');
  const catalogBreaks = capabilities.find((listing) => listing.id === 'breaks').availableSurfaces.find((surface) => surface.surface === 'macos');
  const breaks = feed.apps.find((app) => app.id === 'breaks');
  assert.deepEqual(breaks.channels.live, { version: catalogBreaks.version, url: catalogBreaks.url, sha256: catalogBreaks.sha256, releaseUrl: catalogBreaks.releaseUrl });
  assert.equal(breaks.bundleId, 'dev.subset.breaks');
  // beta.4 is newer than beta.3 and the -dev builds of 0.1.1; its checksum is the DMG line of its SHA256SUMS.
  assert.deepEqual(breaks.channels.beta, {
    version: '0.1.1',
    build: 4,
    url: `${DOWNLOAD}macos/breaks/v0.1.1-beta.4/Breaks-0.1.1-beta.4.dmg`,
    sha256: '6d37efbe0af41ce3b1acbdff2b70990988be4318799e40f99dcedf417c612f4d',
    releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.1-beta.4'
  });
  const timer = feed.apps.find((app) => app.id === 'timer');
  assert.deepEqual({ build: timer.channels.beta.build, live: timer.channels.live }, { build: 2, live: undefined });
  assert.deepEqual(timer.helpers, [{ command: 'timer', path: 'Contents/Resources/timer-cli/dist/cli.mjs', kind: 'node' }]);
  // Apps with only -dev builds (record, launcher, clipboard, dictate) are left out.
  assert.deepEqual(appIds(feed).sort(), ['breaks', 'hop', 'minutes', 'screenshot', 'timer']);
  // Tools: usage is published with both tags; minutes and timer are not on npm; the launcher is not a tool.
  assert.deepEqual(feed.tools, [{ id: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', distTags: { latest: '0.2.0', beta: '0.2.0-beta.2' } }]);
});

test('a beta pre-release gets a beta entry with build n', async () => {
  const feed = await build({
    releases: [release('macos/record/v0.2.0-beta.7')],
    files: { [`${DOWNLOAD}macos/record/v0.2.0-beta.7/SHA256SUMS`]: sumsLine(sha('a'), 'Record-0.2.0-beta.7.dmg') + sumsLine(sha('b'), 'Record-0.2.0-beta.7.zip') },
    npm: npmNone
  });
  const record = feed.apps.find((app) => app.id === 'record');
  assert.deepEqual(record.channels, {
    beta: { version: '0.2.0', build: 7, url: `${DOWNLOAD}macos/record/v0.2.0-beta.7/Record-0.2.0-beta.7.dmg`, sha256: sha('a'), releaseUrl: 'https://github.com/21nCo/subset/releases/tag/macos/record/v0.2.0-beta.7' }
  });
  assert.equal(record.bundleId, 'dev.subset.record');
});

test('a draft, a -dev build, and a release without a DMG, SHA256SUMS or its line give no beta', async () => {
  const sums = (tag, file) => ({ [`${DOWNLOAD}${tag}/SHA256SUMS`]: sumsLine(sha('c'), file) });
  const uploading = release('macos/record/v0.2.0-beta.1');
  uploading.assets[0].state = 'starter';
  const cases = {
    draft: { releases: [release('macos/record/v0.2.0-beta.1', { draft: true })], files: sums('macos/record/v0.2.0-beta.1', 'Record-0.2.0-beta.1.dmg') },
    'not a pre-release': { releases: [release('macos/record/v0.2.0-beta.1', { prerelease: false })], files: sums('macos/record/v0.2.0-beta.1', 'Record-0.2.0-beta.1.dmg') },
    dev: { releases: [release('macos/record/v0.2.0-dev.3')], files: sums('macos/record/v0.2.0-dev.3', 'Record-0.2.0-dev.3.dmg') },
    'no SHA256SUMS': { releases: [release('macos/record/v0.2.0-beta.1', { files: ['dmg', 'zip'] })] },
    'no DMG': { releases: [release('macos/record/v0.2.0-beta.1', { files: ['zip', 'SHA256SUMS'] })], files: sums('macos/record/v0.2.0-beta.1', 'Record-0.2.0-beta.1.dmg') },
    'no DMG line': { releases: [release('macos/record/v0.2.0-beta.1')], files: sums('macos/record/v0.2.0-beta.1', 'Record-0.2.0-beta.1.zip') },
    'DMG still uploading': { releases: [uploading], files: sums('macos/record/v0.2.0-beta.1', 'Record-0.2.0-beta.1.dmg') },
    'DMG of another app': { releases: [release('macos/record/v0.2.0-beta.1', { app: 'Recorder' })], files: sums('macos/record/v0.2.0-beta.1', 'Recorder-0.2.0-beta.1.dmg') }
  };
  for (const [label, responses] of Object.entries(cases)) {
    // An unrecorded request fails the build, so a case that is skipped before fetching its SHA256SUMS needs none.
    const feed = await build({ ...responses, npm: npmNone });
    assert.ok(!appIds(feed).includes('record'), `${label}: record should have no entry`);
  }
});

test('an incomplete newest beta falls back to the newest complete one, by version then build', async () => {
  const feed = await build({
    releases: [
      release('macos/record/v0.3.0-beta.1', { files: ['dmg', 'zip'] }),
      release('macos/record/v0.10.0-beta.1', { draft: true }),
      release('macos/record/v0.2.0-beta.9'),
      release('macos/record/v0.2.0-beta.10'),
      release('macos/record/v0.2.0-dev.11'),
      release('macos/record/v0.2.0-beta.12')
    ],
    files: {
      [`${DOWNLOAD}macos/record/v0.2.0-beta.12/SHA256SUMS`]: sumsLine(sha('9'), 'Record-0.2.0-beta.12.zip'),
      [`${DOWNLOAD}macos/record/v0.2.0-beta.10/SHA256SUMS`]: sumsLine(sha('d'), 'Record-0.2.0-beta.10.dmg')
    },
    npm: npmNone
  });
  assert.deepEqual(feed.apps.find((app) => app.id === 'record').channels.beta.build, 10);
});

test('GitHub data that disagrees with itself or leaves 21nCo/subset stops the build', async () => {
  const tag = 'macos/record/v0.2.0-beta.1';
  const files = { [`${DOWNLOAD}${tag}/SHA256SUMS`]: sumsLine(sha('e'), 'Record-0.2.0-beta.1.dmg') };
  await assert.rejects(build({ releases: [release(tag, { digest: `sha256:${sha('f')}` })], files, npm: npmNone }), /digest of Record-0\.2\.0-beta\.1\.dmg .* disagrees with SHA256SUMS/);
  assert.ok(appIds(await build({ releases: [release(tag, { digest: `sha256:${sha('e')}` })], files, npm: npmNone })).includes('record'));
  const moved = release(tag);
  moved.assets[0].browser_download_url = `https://example.com/${tag}/Record-0.2.0-beta.1.dmg`;
  await assert.rejects(build({ releases: [moved], files, npm: npmNone }), /somewhere other than https:\/\/github\.com\/21nCo\/subset\/releases\/download\//);
  const twoSums = { [`${DOWNLOAD}${tag}/SHA256SUMS`]: sumsLine(sha('e'), 'Record-0.2.0-beta.1.dmg') + sumsLine(sha('1'), 'Record-0.2.0-beta.1.dmg') };
  await assert.rejects(build({ releases: [release(tag)], files: twoSums, npm: npmNone }), /different checksums/);
});

test('the catalog live entry must be a checksummed 21nCo/subset download', async () => {
  const withBreaks = (surface) => capabilities.map((listing) => (listing.id === 'breaks' ? { ...listing, availableSurfaces: [{ ...listing.availableSurfaces[0], ...surface }] } : listing));
  await assert.rejects(build({ catalog: withBreaks({ url: 'https://example.com/Breaks-0.1.0.dmg' }), npm: npmNone }), /not under https:\/\/github\.com\/21nCo\/subset\/releases\/download\//);
  await assert.rejects(build({ catalog: withBreaks({ sha256: undefined }), npm: npmNone }), /no sha256/);
  const planned = [{ id: 'mystery', name: 'Mystery', summary: 'Not built yet.', state: 'available', proposedSurfaces: ['macos'], availableSurfaces: [capabilities.find((l) => l.id === 'breaks').availableSurfaces[0]] }];
  await assert.rejects(build({ catalog: planned, npm: npmNone }), /no native\/mystery\/macos-release\.json/);
});

test('npm tools carry their latest and beta dist-tags; unpublished packages and the launcher are left out', async () => {
  const feed = await build({
    npm: { ...npmNone, '@subset.dev/usage': { latest: '0.2.0', beta: '0.2.1-beta.1', next: '0.3.0-rc.1' }, '@subset.dev/timer': { beta: '0.1.0-beta.3' } }
  });
  assert.deepEqual(feed.tools, [
    { id: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', distTags: { latest: '0.2.0', beta: '0.2.1-beta.1' } },
    { id: 'timer', package: '@subset.dev/timer', bin: 'subset-timer', distTags: { beta: '0.1.0-beta.3' } }
  ]);
  // A bin that is not subset-<slug> is a mistake in release-packages.json, not a tool to guess at.
  const odd = [{ slug: 'odd', path: 'packages/odd', name: '@subset.dev/odd', manifest: { name: '@subset.dev/odd', bin: { odd: 'cli.mjs' } } }];
  await assert.rejects(build({ targets: odd, npm: {} }), /exactly one bin, subset-odd/);
});

test('a dist-tag whose version the schema does not allow is left out, and a tool with none left is not listed', async () => {
  const feed = await build({
    npm: { ...npmNone, '@subset.dev/usage': { latest: '0.3.0-beta.1', beta: '0.3.0-beta.1' }, '@subset.dev/timer': { latest: '1.0', beta: '0.1.0-rc.1', next: '0.2.0' } }
  });
  assert.deepEqual(feed.tools, [{ id: 'usage', package: '@subset.dev/usage', bin: 'subset-usage', distTags: { beta: '0.3.0-beta.1' } }]);
  assert.deepEqual(catalogFeedProblems(JSON.stringify(feed)), []);
});

// An npm executable that answers each `npm <args>` from NPM_STUB ({ "<args>": { status, stdout } }) and logs its calls.
function stubNpm(t, answers) {
  const directory = mkdtempSync(path.join(tmpdir(), 'catalog-feed-npm-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  const command = path.join(directory, 'npm');
  const log = path.join(directory, 'calls.log');
  writeFileSync(
    command,
    `#!${process.execPath}
const fs = require('node:fs');
const args = process.argv.slice(2).join(' ');
fs.appendFileSync(${JSON.stringify(log)}, args + '\\n');
const answer = ${JSON.stringify(answers)}[args] ?? { status: 99, stdout: '' };
process.stdout.write(answer.stdout);
process.exitCode = answer.status;
`
  );
  chmodSync(command, 0o755);
  const calls = () => (existsSync(log) ? readFileSync(log, 'utf8').trim().split('\n') : []);
  return { npm: liveNpm({ command }), calls };
}

test('the live npm source runs npm view, asks for the beta when a package has no latest, and fails on anything unreadable', async (t) => {
  const json = (value) => `${JSON.stringify(value, null, 2)}\n`;
  const view = (spec) => `view ${spec} dist-tags --json`;
  const { npm, calls } = stubNpm(t, {
    [view('@subset.dev/usage')]: { status: 0, stdout: json({ latest: '0.2.0', beta: '0.2.1-beta.1' }) },
    [view('@subset.dev/timer')]: { status: 0, stdout: '' },
    [view('@subset.dev/timer@beta')]: { status: 0, stdout: json({ beta: '0.1.0-beta.3' }) },
    [view('@subset.dev/minutes')]: { status: 1, stdout: json({ error: { code: 'E404', summary: 'Not Found - GET https://registry.npmjs.org/@subset.dev%2fminutes - Not found' } }) },
    [view('@subset.dev/next-only')]: { status: 0, stdout: '' },
    [view('@subset.dev/next-only@beta')]: { status: 1, stdout: json({ error: { code: 'E404', summary: 'No match found for version beta' } }) },
    [view('@subset.dev/offline')]: { status: 1, stdout: '' },
    [view('@subset.dev/forbidden')]: { status: 1, stdout: json({ error: { code: 'E403', summary: '403 Forbidden' } }) },
    [view('@subset.dev/garbled')]: { status: 0, stdout: 'latest: 0.2.0\n' }
  });
  assert.deepEqual(await npm.distTags('@subset.dev/usage'), { latest: '0.2.0', beta: '0.2.1-beta.1' });
  // npm view prints nothing for a package with only a beta; its @beta answer carries the package's dist-tags.
  assert.deepEqual(await npm.distTags('@subset.dev/timer'), { beta: '0.1.0-beta.3' });
  assert.equal(await npm.distTags('@subset.dev/minutes'), null);
  assert.deepEqual(await npm.distTags('@subset.dev/next-only'), {});
  await assert.rejects(npm.distTags('@subset.dev/offline'), /npm view @subset\.dev\/offline dist-tags --json failed \(exit 1\): no JSON answer/);
  await assert.rejects(npm.distTags('@subset.dev/forbidden'), /failed \(exit 1\): 403 Forbidden/);
  await assert.rejects(npm.distTags('@subset.dev/garbled'), /failed \(exit 0\): no JSON answer/);
  assert.deepEqual(calls(), [
    view('@subset.dev/usage'),
    view('@subset.dev/timer'),
    view('@subset.dev/timer@beta'),
    view('@subset.dev/minutes'),
    view('@subset.dev/next-only'),
    view('@subset.dev/next-only@beta'),
    view('@subset.dev/offline'),
    view('@subset.dev/forbidden'),
    view('@subset.dev/garbled')
  ]);
  await assert.rejects(liveNpm({ command: path.join(tmpdir(), 'catalog-feed-no-such-npm') }).distTags('@subset.dev/usage'), /did not finish/);

  // Through the generator: the beta-only tool is listed, the unpublished one left out, and an npm failure stops the build.
  const targets = releaseTargets.filter((target) => ['usage', 'timer', 'minutes'].includes(target.slug));
  assert.equal(targets.length, 3);
  const feed = await buildCatalogFeed({ capabilities: [], manifests, releaseTargets: targets, generatedAt, github: recordedSources({ github: { [RELEASES_URL]: [] } }).github, npm });
  assert.deepEqual(
    feed.tools.map(({ id, distTags }) => ({ id, distTags })),
    [
      { id: 'usage', distTags: { latest: '0.2.0', beta: '0.2.1-beta.1' } },
      { id: 'timer', distTags: { beta: '0.1.0-beta.3' } }
    ]
  );
  const offline = [{ ...targets[0], name: '@subset.dev/offline', manifest: { ...targets[0].manifest, name: '@subset.dev/offline' } }];
  await assert.rejects(buildCatalogFeed({ capabilities: [], manifests, releaseTargets: offline, generatedAt, github: recordedSources({ github: { [RELEASES_URL]: [] } }).github, npm }), /no JSON answer/);
});

test('node scripts/catalog-feed.mjs --out writes a valid feed from recorded responses offline', () => {
  const directory = mkdtempSync(path.join(tmpdir(), 'catalog-feed-'));
  try {
    const out = path.join(directory, 'v1.json');
    const run = spawnSync(process.execPath, [script, '--recorded', recordedFile, '--out', out], { encoding: 'utf8', env: { ...process.env, GITHUB_TOKEN: '' } });
    assert.equal(run.status, 0, run.stderr);
    assert.match(run.stderr, /Wrote subset\.catalog@1 with 5 apps and 1 tools/);
    const text = readFileSync(out, 'utf8');
    assert.deepEqual(catalogFeedProblems(text), []);
    assert.deepEqual(JSON.parse(text).apps.map((app) => app.id), ['screenshot', 'breaks', 'minutes', 'hop', 'timer']);

    // A request the recording does not hold fails rather than reaching the network, and writes nothing.
    const partial = path.join(directory, 'partial.json');
    const missing = structuredClone(recorded);
    delete missing.github[`${DOWNLOAD}macos/timer/v0.1.0-beta.2/SHA256SUMS`];
    writeFileSync(partial, JSON.stringify(missing));
    const failed = spawnSync(process.execPath, [script, '--recorded', partial, '--out', path.join(directory, 'none.json')], { encoding: 'utf8' });
    assert.equal(failed.status, 1);
    assert.match(failed.stderr, /No recorded GitHub response for .*timer\/v0\.1\.0-beta\.2\/SHA256SUMS/);
    assert.equal(existsSync(path.join(directory, 'none.json')), false);
    assert.deepEqual(readdirSync(directory).sort(), ['partial.json', 'v1.json']);
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
