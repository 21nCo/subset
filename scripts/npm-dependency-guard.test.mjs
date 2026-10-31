import assert from 'node:assert/strict';
import test from 'node:test';
import { missingDependencies, satisfiesCaret } from './npm-dependency-guard.mjs';

test('reads ^x.y.z ranges as npm does, without prereleases', () => {
  const cases = {
    '^0.1.0': { '0.1.0': true, '0.1.7': true, '0.2.0': false, '0.0.9': false, '1.1.0': false, '0.1.1-beta.1': false },
    '^1.2.3': { '1.2.3': true, '1.3.0': true, '1.2.2': false, '2.0.0': false, '1.10.0': true },
    '^0.0.3': { '0.0.3': true, '0.0.4': false, '0.1.3': false }
  };
  for (const [range, versions] of Object.entries(cases)) {
    for (const [version, expected] of Object.entries(versions)) assert.equal(satisfiesCaret(version, range), expected, `${version} ${range}`);
  }
  for (const range of ['*', '0.1.0', '~0.1.0', '>=0.1.0']) assert.throws(() => satisfiesCaret('0.1.0', range), /is not a \^x\.y\.z range/);
});

test('refuses a package whose @subset.dev dependency npm cannot install', () => {
  const manifest = { name: '@subset.dev/link-capture', dependencies: { '@extfn/core': '0.1.0', '@subset.dev/links': '^0.1.0' } };
  const packument = (...versions) => ({ versions: Object.fromEntries(versions.map((version) => [version, {}])) });
  const missing = ['@subset.dev/links@^0.1.0 is not on npm; publish it first'];
  assert.deepEqual(missingDependencies(manifest, new Map([['@subset.dev/links', null]])), missing);
  assert.deepEqual(missingDependencies(manifest, new Map([['@subset.dev/links', packument('0.1.0-beta.1', '0.2.0')]])), missing);
  assert.deepEqual(missingDependencies(manifest, new Map([['@subset.dev/links', packument('0.1.0')]])), []);
  // Packages outside the scope come from the registry as usual and are not checked.
  assert.deepEqual(missingDependencies({ dependencies: { htmlparser2: '12.0.0' } }, new Map()), []);
});
