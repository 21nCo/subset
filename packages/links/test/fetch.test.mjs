import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
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

function busy(ms) {
  const until = performance.now() + ms;
  while (performance.now() < until);
}

/** A body that records whether it was cancelled. `next` returns each chunk or undefined to close. */
function trackedBody(next) {
  const state = { pulls: 0, cancelled: false };
  state.stream = new ReadableStream(
    {
      async pull(controller) {
        const chunk = await next(state.pulls++);
        if (chunk === undefined) controller.close();
        else controller.enqueue(new TextEncoder().encode(chunk));
      },
      cancel() {
        state.cancelled = true;
      }
    },
    { highWaterMark: 0 }
  );
  return state;
}

// Node only, as above: each step finishes in time to be awaited but completes after the limit.
test('work that finishes after the limit ends with timeout, its response or body cancelled', async () => {
  const operations = [
    ['fetchLinkDetails', lib.fetchLinkDetails, 'application/pdf'],
    ['fetchResource', lib.fetchResource, 'image/png']
  ];
  for (const [name, operation, type] of operations) {
    // A response that arrives after the limit, for a type whose body is never read.
    const late = trackedBody(() => 'x');
    const lateFetch = async () => {
      await null;
      busy(120);
      return new Response(late.stream, { headers: { 'content-type': type } });
    };
    await assert.rejects(operation('https://example.com/file', { fetch: lateFetch, timeoutMs: 50 }), { code: 'timeout' }, `${name} late response`);
    await new Promise((resolve) => setTimeout(resolve, 0));
    assert.equal(late.cancelled, true, `${name} late response cancelled`);

    // A resolution that arrives after the limit: the hop is never requested.
    let requests = 0;
    const resolveHost = async () => {
      await null;
      busy(120);
      return ['93.184.216.34'];
    };
    const countingFetch = async () => {
      requests++;
      return new Response('', { headers: { 'content-type': type } });
    };
    await assert.rejects(operation('https://example.com/', { fetch: countingFetch, resolveHost, timeoutMs: 50 }), { code: 'timeout' }, `${name} late resolution`);
    assert.equal(requests, 0, `${name} requests after a late resolution`);

    // The last read, the end of the body, arrives after the limit.
    const ending = trackedBody(async (pull) => {
      if (pull === 0) return '<title>Late</title>';
      busy(120);
      return undefined;
    });
    const endingFetch = async () => new Response(ending.stream, { headers: { 'content-type': name === 'fetchResource' ? type : 'text/html' } });
    await assert.rejects(operation('https://example.com/', { fetch: endingFetch, timeoutMs: 50 }), { code: 'timeout' }, `${name} late end of body`);

    // The read that fills maxBytes arrives after the limit.
    const filling = trackedBody(async () => {
      busy(120);
      return 'abcd';
    });
    const fillingFetch = async () => new Response(filling.stream, { headers: { 'content-type': name === 'fetchResource' ? type : 'text/html' } });
    await assert.rejects(operation('https://example.com/', { fetch: fillingFetch, timeoutMs: 50, maxBytes: 4 }), { code: 'timeout' }, `${name} late limit read`);
    assert.equal(filling.cancelled, true, `${name} body cancelled after a late limit read`);
  }
});

// Node only: a child process with Node's default handling, where an unhandled rejection exits with 1.
test('a request, resolution or read that fails after the limit leaves no unhandled rejection', () => {
  const script = `
    import * as lib from ${JSON.stringify(new URL('../dist/index.js', import.meta.url).href)};
    const busy = (ms) => { const until = performance.now() + ms; while (performance.now() < until); };
    const expectTimeout = async (label, promise) => {
      try { await promise; } catch (error) { if (error.code === 'timeout') return; throw new Error(label + ': ' + error.code); }
      throw new Error(label + ': resolved');
    };
    for (const operation of [lib.fetchLinkDetails, lib.fetchResource]) {
      // A body read whose pull is busy past the limit and then errors.
      const body = () => new ReadableStream({ pull(controller) { busy(100); controller.error(new Error('body reset')); } }, { highWaterMark: 0 });
      await expectTimeout('body', operation('https://example.com/', { fetch: async () => new Response(body(), { headers: { 'content-type': 'text/html' } }), timeoutMs: 50 }));
      // A request that fails after the limit.
      const fetch = async () => { await null; busy(100); throw new Error('connection reset'); };
      await expectTimeout('request', operation('https://example.com/', { fetch, timeoutMs: 50 }));
      // A resolution that fails after the limit.
      const resolveHost = async () => { await null; busy(100); throw new Error('resolver down'); };
      await expectTimeout('resolution', operation('https://example.com/', { fetch, resolveHost, timeoutMs: 50 }));
    }
    // Let any late settlement surface before exiting.
    await new Promise((resolve) => setTimeout(resolve, 200));
    console.log('ok');
  `;
  const result = spawnSync(process.execPath, ['--input-type=module', '-e', script], { encoding: 'utf8', timeout: 20_000 });
  assert.equal(result.stderr, '');
  assert.equal(result.stdout.trim(), 'ok');
  assert.equal(result.status, 0);
});
