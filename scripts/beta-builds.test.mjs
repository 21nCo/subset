import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { currentBeta, marketingVersion, nextBuildNumber, optedOut, planTarget } from './beta-builds.mjs';
import { betaVerdict, isNewerBeta } from './npm-beta-guard.mjs';

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
  // The highest number counts, not how many tags there are, so a deleted tag's number is never reused.
  assert.equal(nextBuildNumber(['macos/breaks/v0.1.1-dev.1', 'macos/breaks/v0.1.1-beta.4'], 'macos/breaks/v', '0.1.1'), 5);
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

test('orders beta versions', () => {
  assert.equal(isNewerBeta('0.2.0-beta.2', '0.2.0-beta.1'), true);
  assert.equal(isNewerBeta('0.2.0-beta.10', '0.2.0-beta.9'), true);
  assert.equal(isNewerBeta('0.2.1-beta.1', '0.2.0-beta.7'), true);
  assert.equal(isNewerBeta('0.2.0-beta.1', '0.2.0-beta.2'), false);
  assert.equal(isNewerBeta('0.2.0-beta.1', '0.2.0-beta.1'), false);
  assert.equal(isNewerBeta('0.2.0-beta.1', '0.1.9-next.3'), true);
  assert.equal(isNewerBeta('0.2.0-beta.1', undefined), true);
  assert.throws(() => isNewerBeta('0.2.0', '0.2.0-beta.1'), /not an x\.y\.z-beta\.n/);
});

test('publishes a beta only before its release and never behind a newer beta', () => {
  const packument = { 'dist-tags': { latest: '0.1.0' }, versions: { '0.1.0': {} } };
  assert.deepEqual(betaVerdict(packument, '0.2.0', '0.2.0-beta.1'), { publish: true });
  assert.match(betaVerdict(null, '0.2.0', '0.2.0-beta.1').error, /no live release/);
  assert.match(betaVerdict({ 'dist-tags': {}, versions: {} }, '0.2.0', '0.2.0-beta.1').error, /no live release/);
  assert.match(betaVerdict(packument, '0.1.0', '0.1.0-beta.1').error, /already released/);
  const ahead = { ...packument, 'dist-tags': { latest: '0.1.0', beta: '0.2.0-beta.2' } };
  assert.equal(betaVerdict(ahead, '0.2.0', '0.2.0-beta.1').publish, false);
  assert.equal(betaVerdict(ahead, '0.2.0', '0.2.0-beta.3').publish, true);
  // A rerun of the beta the channel already points at publishes again (npm then refuses the duplicate version).
  assert.equal(betaVerdict(ahead, '0.2.0', '0.2.0-beta.2').publish, true);
});

test('a named, unchanged target reuses only a published beta of its current version', () => {
  const target = { prefix: 'macos/breaks/v', version: '0.1.1', tags: ['macos/breaks/v0.1.1-beta.3'], forced: true };
  assert.deepEqual(planTarget({ ...target, changed: false, reusable: 'macos/breaks/v0.1.1-beta.3' }),
    { skip: 'unchanged since macos/breaks/v0.1.1-beta.3, which is published', reuse: 'macos/breaks/v0.1.1-beta.3' });
  // Without a published beta to reuse (a failed build, a legacy dev build), a named target is built.
  assert.deepEqual(planTarget({ ...target, changed: false }), { tag: 'macos/breaks/v0.1.1-beta.4' });
  assert.deepEqual(planTarget({ ...target, changed: true, reusable: 'macos/breaks/v0.1.1-beta.3' }), { tag: 'macos/breaks/v0.1.1-beta.4' });
  assert.equal(currentBeta('macos/breaks/v0.1.1-beta.3', 'macos/breaks/v', '0.1.1'), 'macos/breaks/v0.1.1-beta.3');
  assert.equal(currentBeta('macos/breaks/v0.1.1-dev.2', 'macos/breaks/v', '0.1.1'), undefined);
  assert.equal(currentBeta('macos/breaks/v0.1.0-beta.9', 'macos/breaks/v', '0.1.1'), undefined);
  assert.equal(currentBeta(undefined, 'usage-v', '0.2.0'), undefined);
});

// Runs the planner on this checkout. Without --skip-unchanged it reads only git and the repository, never the network.
function plan(...args) {
  const { GITHUB_OUTPUT: _output, ...env } = process.env;
  const script = fileURLToPath(new URL('./beta-builds.mjs', import.meta.url));
  return JSON.parse(execFileSync(process.execPath, [script, ...args], { encoding: 'utf8', env }));
}

test('keeps System out of beta builds until SET-59, and only System', () => {
  assert.equal(optedOut('macos/system'), 'kept out of beta builds until SET-59');
  for (const name of ['macos/breaks', 'macos/systems', 'system', 'npm/usage']) assert.equal(optedOut(name), undefined);

  const optOut = { name: 'macos/system', reason: 'kept out of beta builds until SET-59' };
  // Named, even with --skip-unchanged, it is skipped rather than rejected as unknown.
  assert.deepEqual(plan('--only', 'macos/system'), { builds: [], skipped: [optOut] });
  assert.deepEqual(plan('--only', 'macos/system', '--skip-unchanged'), { builds: [], skipped: [optOut] });
  // Never tagged, so its inputs count as changed, yet a run for every changed target leaves it out.
  const all = plan();
  assert.equal(all.builds.some((build) => build.name === 'macos/system'), false);
  assert.deepEqual(all.skipped.filter((entry) => entry.reason === optOut.reason), [optOut]);
  // Other apps are planned as before: a named app gets a beta or its own reason, never the opt-out.
  const breaks = plan('--only', 'macos/breaks');
  assert.equal(breaks.builds.length + breaks.skipped.length, 1);
  assert.equal(breaks.skipped.some((entry) => entry.reason === optOut.reason), false);
});
