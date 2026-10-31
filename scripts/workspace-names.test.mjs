import assert from 'node:assert/strict';
import test from 'node:test';
import { publishedManifestProblems, workspaceManifestProblems } from './workspace-names.mjs';

test('rejects a workspace outside the @subset.dev scope, private or not', () => {
  for (const kind of ['packages', 'apps']) {
    assert.deepEqual(workspaceManifestProblems(kind, { name: '@subset/x', private: true }), ['@subset/x must be named @subset.dev/<name>']);
  }
  assert.equal(workspaceManifestProblems('packages', { name: 'x', private: true }).length, 1);
  assert.equal(workspaceManifestProblems('packages', { name: '@subset.dev/X', private: true }).length, 1);
  assert.equal(workspaceManifestProblems('packages', { private: true }).length, 1);
});

test('accepts @subset.dev names for private packages, published packages and app hosts', () => {
  assert.deepEqual(workspaceManifestProblems('packages', { name: '@subset.dev/usage-core', private: true }), []);
  assert.deepEqual(workspaceManifestProblems('packages', { name: '@subset.dev/usage', private: false }), []);
  assert.deepEqual(workspaceManifestProblems('apps', { name: '@subset.dev/usage-web', private: true }), []);
});

test('requires a declared privacy and private app hosts', () => {
  assert.deepEqual(workspaceManifestProblems('apps', { name: '@subset.dev/x', private: false }), ['@subset.dev/x is an app host and must remain private']);
  assert.deepEqual(workspaceManifestProblems('packages', { name: '@subset.dev/x' }), ['@subset.dev/x must declare whether it is private']);
});

const published = (overrides = {}) => ({
  name: '@subset.dev/link-capture',
  private: false,
  version: '0.1.0',
  license: 'MIT',
  repository: { type: 'git', url: 'git+https://github.com/21nCo/subset.git', directory: 'packages/link-capture' },
  publishConfig: { access: 'public' },
  files: ['dist'],
  exports: { '.': './dist/index.js' },
  dependencies: { '@extfn/core': '0.1.0', '@subset.dev/links': '^0.1.0' },
  peerDependencies: { svelte: '^5.57.1' },
  ...overrides
});
const workspaces = new Map([
  ['@subset.dev/links', { name: '@subset.dev/links', private: false, version: '0.1.0' }],
  ['@subset.dev/usage-core', { name: '@subset.dev/usage-core', private: true, version: '0.0.0' }]
]);

test('accepts a published library that depends on another published workspace by its caret version', () => {
  assert.deepEqual(publishedManifestProblems(published(), 'packages/link-capture', workspaces), []);
  // A CLI declares bin instead of exports and bundles its private workspaces as devDependencies.
  const cli = published({ exports: undefined, bin: { x: 'dist/cli.mjs' }, dependencies: {}, devDependencies: { '@subset.dev/usage-core': '*' } });
  assert.deepEqual(publishedManifestProblems(cli, 'packages/link-capture', workspaces), []);
});

test('refuses a published workspace dependency that npm could not resolve after publication', () => {
  for (const version of ['*', '0.1.0', '^0.0.9', 'workspace:*']) {
    assert.deepEqual(publishedManifestProblems(published({ dependencies: { '@subset.dev/links': version } }), 'packages/link-capture', workspaces), [
      `@subset.dev/link-capture must depend on @subset.dev/links as ^0.1.0 (found ${version})`
    ]);
  }
  for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    assert.deepEqual(publishedManifestProblems(published({ dependencies: {}, peerDependencies: {}, [field]: { '@subset.dev/usage-core': '*' } }), 'packages/link-capture', workspaces), [
      '@subset.dev/link-capture cannot depend at runtime on private workspace @subset.dev/usage-core; bundle it instead'
    ]);
  }
  assert.deepEqual(publishedManifestProblems(published({ dependencies: { '@extfn/core': '^0.1.0' } }), 'packages/link-capture', workspaces), [
    '@subset.dev/link-capture must pin @extfn/core to an exact version (found ^0.1.0)'
  ]);
});

test('requires the publication metadata npm shows and installs from', () => {
  const problems = (overrides) => publishedManifestProblems(published(overrides), 'packages/link-capture', workspaces);
  assert.deepEqual(problems({ private: true }), ['@subset.dev/link-capture must set "private": false']);
  assert.deepEqual(problems({ license: undefined }), ['@subset.dev/link-capture must declare a license']);
  assert.deepEqual(problems({ publishConfig: undefined }), ['@subset.dev/link-capture must set publishConfig.access to public']);
  assert.deepEqual(problems({ files: [] }), ['@subset.dev/link-capture must list its published files']);
  assert.deepEqual(problems({ exports: undefined }), ['@subset.dev/link-capture must declare exports or bin']);
  const repository = '@subset.dev/link-capture must name its repository git+https://github.com/21nCo/subset.git and directory packages/link-capture';
  assert.deepEqual(problems({ repository: undefined }), [repository]);
  assert.deepEqual(problems({ repository: { type: 'git', url: 'git+https://github.com/21nCo/subset.git', directory: 'packages/links' } }), [repository]);
});
