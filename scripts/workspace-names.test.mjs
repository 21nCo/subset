import assert from 'node:assert/strict';
import test from 'node:test';
import { workspaceManifestProblems } from './workspace-names.mjs';

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
