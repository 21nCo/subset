import assert from 'node:assert/strict';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';

const root = new URL('../', import.meta.url);
const readJson = (path) => JSON.parse(readFileSync(new URL(path, root), 'utf8'));
const rootManifest = readJson('package.json');

assert.deepEqual(rootManifest.workspaces, ['packages/*', 'apps/*']);

const names = new Set();
const workspaces = [];
for (const kind of ['packages', 'apps']) {
  for (const entry of readdirSync(new URL(`${kind}/`, root), { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const manifest = readJson(join(kind, entry.name, 'package.json'));
    assert.equal(typeof manifest.private, 'boolean', `${manifest.name} must declare whether it is private`);
    if (kind === 'apps') {
      assert.match(manifest.name, /^@subset\/[a-z0-9-]+$/);
      assert.equal(manifest.private, true, `${manifest.name} is an app host and must remain private`);
    } else if (manifest.private) {
      assert.match(manifest.name, /^@(subset|subset\.dev)\/[a-z0-9-]+$/);
    } else {
      assert.match(manifest.name, /^@subset\.dev\/[a-z0-9-]+$/, `${manifest.name} must use the @subset.dev npm scope to publish`);
    }
    assert.equal(names.has(manifest.name), false, `Duplicate workspace ${manifest.name}`);
    names.add(manifest.name);
    workspaces.push(manifest);

    for (const [dependency, version] of Object.entries({ ...manifest.dependencies, ...manifest.devDependencies })) {
      assert.equal(String(version).includes('superfunctions-dev'), false, `${manifest.name} depends on a sibling checkout path`);
    }
  }
}

for (const manifest of workspaces) {
  for (const [dependency, version] of Object.entries({ ...manifest.dependencies, ...manifest.devDependencies })) {
    if (names.has(dependency)) assert.equal(version, '*', `${manifest.name} must use an npm workspace dependency for ${dependency}`);
  }
}

// Publishable packages are listed for the tag workflow, bundle private workspaces instead of
// depending on them at runtime, and declare which files they ship.
const releaseTargets = readJson('release-packages.json');
const publicPackages = workspaces.filter((manifest) => manifest.private === false);
for (const manifest of publicPackages) {
  const target = releaseTargets.find((entry) => entry.name === manifest.name);
  assert.ok(target, `${manifest.name} is public but missing from release-packages.json`);
  assert.equal(readJson(join(target.path, 'package.json')).name, manifest.name, `release-packages.json points ${target.slug} at the wrong path`);
  assert.ok(Array.isArray(manifest.files) && manifest.files.length, `${manifest.name} must list its published files`);
  // Any installed dependency field counts. A workspace dependency is pinned to "*", which npm would
  // publish unchanged, so public packages bundle workspaces instead of depending on them.
  for (const dependency of Object.keys({ ...manifest.dependencies, ...manifest.optionalDependencies, ...manifest.peerDependencies })) {
    assert.ok(!names.has(dependency), `${manifest.name} cannot depend at runtime on workspace ${dependency}; bundle it instead`);
  }
  // External runtime dependencies of a published package are pinned, so a release installs what was tested.
  for (const [dependency, version] of Object.entries({ ...manifest.dependencies, ...manifest.optionalDependencies })) {
    assert.match(String(version), /^\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?$/, `${manifest.name} must pin ${dependency} to an exact version (found ${version})`);
  }
}

// Native targets reuse capability packages (for example by running their CLI); they do not carry a
// second Node.js implementation with its own manifest or lockfile.
const nativeRoot = new URL('native/', root);
const skipped = new Set(['node_modules', 'build', 'DerivedData', '.build']);
// Documented exceptions, relative to native/. The Screenshot share Worker is a self-hosted Cloudflare Worker
// kept out of the workspaces until a deployment is authorized (see its README); it is not a bot or app runtime.
const allowedNodeProjects = new Set(['screenshot/share-worker/']);
function findNodeManifests(directory) {
  const found = [];
  for (const entry of readdirSync(directory, { withFileTypes: true })) {
    if (skipped.has(entry.name) || entry.name.endsWith('.xcodeproj')) continue;
    // Encode the name: a "#" or "?" in a folder name would otherwise end the URL path.
    const child = new URL(`${encodeURIComponent(entry.name)}${entry.isDirectory() ? '/' : ''}`, directory);
    if (entry.isDirectory() && allowedNodeProjects.has(decodeURIComponent(child.pathname.slice(nativeRoot.pathname.length)))) continue;
    if (entry.isDirectory()) found.push(...findNodeManifests(child));
    else if (['package.json', 'package-lock.json', 'pnpm-lock.yaml', 'yarn.lock'].includes(entry.name)) found.push(decodeURIComponent(child.pathname));
  }
  return found;
}
if (existsSync(nativeRoot)) {
  assert.deepEqual(findNodeManifests(nativeRoot), [], 'Native targets must not contain their own Node.js package; use a packages/ workspace');
}

// The Minutes macOS app decodes the CLI's NDJSON contract; its supported version must match the package's.
const minutesContract = readFileSync(new URL('packages/minutes/src/contract.ts', root), 'utf8').match(/MINUTES_CONTRACT_VERSION = (\d+) as const/);
const minutesSwift = readFileSync(new URL('native/minutes/MacApp/MinutesCLI.swift', root), 'utf8').match(/supportedContractVersion = (\d+)/);
assert.ok(minutesContract && minutesSwift, 'Could not find the Minutes contract version in TypeScript and Swift');
assert.equal(minutesSwift[1], minutesContract[1], 'native/minutes supports a different Minutes contract version than @subset/minutes');
for (const target of releaseTargets) {
  assert.match(target.slug, /^[a-z0-9][a-z0-9-]*$/);
  assert.equal(releaseTargets.filter((entry) => entry.slug === target.slug).length, 1, `Release slug ${target.slug} is listed more than once`);
  assert.ok(publicPackages.some((manifest) => manifest.name === target.name), `${target.name} in release-packages.json is not a public workspace`);
}

assert.equal(names.has('@subset/catalog'), true);
assert.equal(names.has('@subset/directory'), true);
assert.equal(names.has('@subset/mgraph-contracts'), true);
assert.equal(names.has('@subset/mgraph-store'), true);
assert.equal(names.has('@subset/minutes'), true);
console.log(`Validated ${names.size} Subset workspaces.`);
