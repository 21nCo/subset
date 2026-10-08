import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
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
      assert.match(manifest.name, /^@(subset|sub-set)\/[a-z0-9-]+$/);
    } else {
      assert.match(manifest.name, /^@sub-set\/[a-z0-9-]+$/, `${manifest.name} must use the @sub-set npm scope to publish`);
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
  for (const dependency of Object.keys(manifest.dependencies ?? {})) {
    const workspace = workspaces.find((item) => item.name === dependency);
    assert.ok(!workspace || workspace.private === false, `${manifest.name} cannot depend at runtime on private ${dependency}; bundle it instead`);
  }
}
for (const target of releaseTargets) {
  assert.match(target.slug, /^[a-z0-9][a-z0-9-]*$/);
  assert.ok(publicPackages.some((manifest) => manifest.name === target.name), `${target.name} in release-packages.json is not a public workspace`);
}

assert.equal(names.has('@subset/catalog'), true);
assert.equal(names.has('@subset/directory'), true);
console.log(`Validated ${names.size} Subset workspaces.`);
