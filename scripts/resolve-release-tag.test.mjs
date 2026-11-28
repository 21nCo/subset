// Runs scripts/resolve-release-tag.mjs on a fixture repository (a copy of the script next to its own
// release-packages.json and package), so the tag classification is tested against exact package versions.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { copyFile, mkdir, mkdtemp, readFile, rm, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';

const script = fileURLToPath(new URL('./resolve-release-tag.mjs', import.meta.url));
const roots = [];

after(async () => {
  await Promise.all(roots.map((root) => rm(root, { recursive: true, force: true })));
});

async function resolve(tag, packageVersion) {
  const root = await mkdtemp(path.join(tmpdir(), 'subset-resolve-tag-'));
  roots.push(root);
  await mkdir(path.join(root, 'scripts'));
  await mkdir(path.join(root, 'pkg'));
  await copyFile(script, path.join(root, 'scripts', 'resolve-release-tag.mjs'));
  await writeFile(path.join(root, 'release-packages.json'), JSON.stringify([{ slug: 'demo', name: '@example/demo', path: 'pkg' }]));
  await writeFile(
    path.join(root, 'pkg', 'package.json'),
    JSON.stringify({ name: '@example/demo', version: packageVersion, private: false }),
  );
  const output = path.join(root, 'github-output');
  await writeFile(output, '');
  const result = spawnSync(process.execPath, [path.join(root, 'scripts', 'resolve-release-tag.mjs'), tag], {
    env: { ...process.env, GITHUB_OUTPUT: output },
    encoding: 'utf8',
  });
  const outputs = Object.fromEntries(
    (await readFile(output, 'utf8'))
      .split('\n')
      .filter(Boolean)
      .map((line) => [line.slice(0, line.indexOf('=')), line.slice(line.indexOf('=') + 1)]),
  );
  return { status: result.status, stderr: result.stderr, outputs };
}

test('a live tag publishes to latest', async () => {
  const { status, outputs } = await resolve('demo-v1.2.3', '1.2.3');
  assert.equal(status, 0);
  assert.equal(outputs.npm_tag, 'latest');
});

test('a beta tag publishes the package version with its suffix to beta', async () => {
  const { status, outputs } = await resolve('demo-v1.2.3-beta.4', '1.2.3');
  assert.equal(status, 0);
  assert.equal(outputs.npm_tag, 'beta');
  assert.equal(outputs.publish_version, '1.2.3-beta.4');
});

// The live tag ruleset leaves tags matching *-v*.*.*-beta.* to the beta rules, so such a tag must never reach latest,
// even when its version matches package.json exactly.
test('-beta. in build metadata is refused even when it matches package.json', async () => {
  const { status, stderr, outputs } = await resolve('demo-v1.2.3+build-beta.1', '1.2.3+build-beta.1');
  assert.equal(status, 1);
  assert.match(stderr, /looks like a beta/);
  assert.equal(outputs.npm_tag, undefined);
});

test('-beta. after another prerelease part is refused', async () => {
  const { status } = await resolve('demo-v1.2.3-rc.1-beta.2', '1.2.3-rc.1-beta.2');
  assert.equal(status, 1);
});
