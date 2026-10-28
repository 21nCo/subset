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

// Node only: inside workerd the clock stands still while code runs, so a busy read cannot be timed there.
test('timeout is judged by the clock between yields, so reads that each take a while stop on time', async () => {
  for (const operation of [lib.fetchLinkDetails, lib.fetchResource]) {
    let pulls = 0;
    // Every read is ready at once but takes 10 ms of synchronous work.
    const stream = new ReadableStream(
      {
        pull(controller) {
          pulls++;
          const until = performance.now() + 10;
          while (performance.now() < until);
          controller.enqueue(new Uint8Array(1));
        }
      },
      { highWaterMark: 0 }
    );
    const fetch = async () => new Response(stream, { headers: { 'content-type': 'text/html' } });
    await assert.rejects(operation('https://example.com/', { fetch, timeoutMs: 50 }), { code: 'timeout' });
    assert.ok(pulls <= 8, `read ${pulls} chunks of 10 ms each within a 50 ms limit`);
  }
});
