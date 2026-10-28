import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import * as lib from '../dist/index.js';
import { cases } from './fetch-cases.mjs';

for (const { name, run } of cases) test(name, () => run(lib));

test('the default user agent names the package version', () => {
  const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));
  assert.equal(lib.DEFAULT_USER_AGENT, `SubsetLinks/${version} (+https://subset.dev)`);
});
