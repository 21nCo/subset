import assert from 'node:assert/strict';
import test from 'node:test';
import { marketingVersion, nextBuildNumber, planTarget } from './beta-builds.mjs';

test('reads the one MARKETING_VERSION of a project', () => {
  assert.equal(marketingVersion('MARKETING_VERSION = 0.1.1;\n\t\tMARKETING_VERSION = 0.1.1;'), '0.1.1');
  assert.equal(marketingVersion('MARKETING_VERSION = "1.0.0";'), '1.0.0');
  assert.throws(() => marketingVersion('CURRENT_PROJECT_VERSION = 1;'), /found none/);
  assert.throws(() => marketingVersion('MARKETING_VERSION = 1.0.0; MARKETING_VERSION = 1.1.0;'), /found 1\.0\.0, 1\.1\.0/);
  assert.throws(() => marketingVersion('MARKETING_VERSION = 1.0;'), /not x\.y\.z/);
});

test('numbers beta builds after every earlier test build of the version', () => {
  const tags = ['macos/breaks/v0.1.0', 'macos/breaks/v0.1.1-dev.1', 'macos/breaks/v0.1.1-dev.2', 'macos/breaks/v0.1.2-beta.9'];
  assert.equal(nextBuildNumber(tags, 'macos/breaks/v', '0.1.1'), 3);
  assert.equal(nextBuildNumber([...tags, 'macos/breaks/v0.1.1-beta.3'], 'macos/breaks/v', '0.1.1'), 4);
  assert.equal(nextBuildNumber(tags, 'macos/breaks/v', '0.2.0'), 1);
  // Other apps, look-alike versions, and malformed numbers don't count.
  assert.equal(nextBuildNumber(['macos/breaks-pro/v0.1.1-beta.5', 'macos/breaks/v10.1.1-beta.5', 'macos/breaks/v0.1.1-beta.07'], 'macos/breaks/v', '0.1.1'), 1);
  assert.equal(nextBuildNumber(['usage-v0.1.0', 'usage-v0.2.0-beta.2'], 'usage-v', '0.2.0'), 3);
});

test('plans a beta only for a changed, unreleased version', () => {
  const target = { prefix: 'macos/breaks/v', version: '0.1.1', tags: ['macos/breaks/v0.1.0', 'macos/breaks/v0.1.1-dev.2'] };
  assert.deepEqual(planTarget({ ...target, changed: true }), { tag: 'macos/breaks/v0.1.1-beta.3' });
  assert.deepEqual(planTarget({ ...target, changed: null }), { tag: 'macos/breaks/v0.1.1-beta.3' });
  assert.match(planTarget({ ...target, changed: false }).skip, /unchanged/);
  assert.deepEqual(planTarget({ ...target, changed: false, forced: true }), { tag: 'macos/breaks/v0.1.1-beta.3' });
  assert.match(planTarget({ ...target, version: '0.1.0', changed: true }).skip, /already released/);
  assert.match(planTarget({ ...target, version: '0.1.0', changed: false, forced: true }).skip, /already released/);
});
