import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { afterEach, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { transformWithEsbuild } from 'vite';
import { captureLink } from '../dist/index.js';
import { createFakeBrowser } from './fake-browser.mjs';

// The reference host's target is extension source, built only by Vite; it imports types alone, so stripping them is enough.
const path = fileURLToPath(new URL('../extension/src/local-target.ts', import.meta.url));
const { code } = await transformWithEsbuild(readFileSync(path, 'utf8'), path, { format: 'esm' });
const { createLocalTarget } = await import(`data:text/javascript,${encodeURIComponent(code)}`);

const link = (n) => captureLink(`https://example.com/${n}`, `Page ${n}`);

/** One origin's Web Locks: an exclusive request waits for the one before it. */
function fakeLocks() {
  const queues = new Map();
  return {
    request(name, callback) {
      const result = (queues.get(name) ?? Promise.resolve()).then(() => callback());
      queues.set(name, result.catch(() => undefined));
      return result;
    }
  };
}

function storedLinks(local) {
  return [...local.entries()]
    .filter(([key]) => key.startsWith('reference:capture:'))
    .sort(([a], [b]) => (a < b ? 1 : -1))
    .map(([, value]) => value.capture.canonicalUrl);
}

const stored = (local) => [...local.values()].map((value) => ({ link: value.capture.canonicalUrl, notes: value.notes }));

const restore = [];
afterEach(() => restore.splice(0).forEach((undo) => undo()));
/** A frozen clock, and UUIDs that sort each one before the last: neither can order the saves. */
function freezeClockAndReverseUuids(at = 1_000) {
  const { now } = performance;
  const { randomUUID } = crypto;
  let n = 0xffff;
  performance.now = () => at;
  crypto.randomUUID = () => `${(n--).toString(16).padStart(8, '0')}-0000-4000-8000-000000000000`;
  restore.push(() => Object.assign(performance, { now }), () => Object.assign(crypto, { randomUUID }));
  return (value) => (at = value);
}

describe('the reference local target', () => {
  it('keeps the later of two same-link saves from two instances with a tied clock and reversed UUIDs', async () => {
    freezeClockAndReverseUuids();
    const { browser, local } = createFakeBrowser();
    const locks = fakeLocks();
    const background = createLocalTarget(browser, locks);
    const popup = createLocalTarget(browser, locks);
    const results = await Promise.all([background.save(link('a'), { notes: 'earlier edit' }), popup.save(link('a'), { notes: 'later edit' })]);
    assert.deepEqual(results, [{ ok: true, existing: false }, { ok: true, existing: true }]);
    assert.deepEqual(stored(local), [{ link: 'https://example.com/a', notes: 'later edit' }]);
  });

  it('keeps the later save when a new instance reads an earlier clock', async () => {
    const setClock = freezeClockAndReverseUuids(5_000);
    const { browser, local } = createFakeBrowser();
    const locks = fakeLocks();
    await createLocalTarget(browser, locks).save(link('a'), { notes: 'first' });
    setClock(1_000);
    assert.deepEqual(await createLocalTarget(browser, locks).save(link('a'), { notes: 'second' }), { ok: true, existing: true });
    assert.deepEqual(stored(local), [{ link: 'https://example.com/a', notes: 'second' }]);
  });

  it('orders overlapping saves by the lock even when storage calls interleave', async () => {
    freezeClockAndReverseUuids();
    const delays = { get: 5, set: 1, remove: 3 };
    const { browser, local } = createFakeBrowser({ storage: { before: (op) => new Promise((resolve) => setTimeout(resolve, delays[op])) } });
    const locks = fakeLocks();
    const [one, two, three] = [0, 1, 2].map(() => createLocalTarget(browser, locks));
    await Promise.all([one.save(link('a'), { notes: 'a1' }), two.save(link('b'), { notes: 'b' }), three.save(link('a'), { notes: 'a2' })]);
    assert.deepEqual(stored(local).sort((x, y) => (x.link < y.link ? -1 : 1)), [
      { link: 'https://example.com/a', notes: 'a2' },
      { link: 'https://example.com/b', notes: 'b' }
    ]);
  });

  it('reports a link saved again as existing and keeps only its newest entry', async () => {
    const { browser, local } = createFakeBrowser();
    const target = createLocalTarget(browser, fakeLocks());
    assert.deepEqual(await target.save(link('a'), { tags: ['old'] }), { ok: true, existing: false });
    assert.deepEqual(await target.save(link('a'), { tags: ['new'] }), { ok: true, existing: true });
    assert.deepEqual(storedLinks(local), ['https://example.com/a']);
    assert.deepEqual(await target.suggestTags(''), ['new']);
  });

  it('keeps the 100 newest links, also when saves overlap at the limit', async () => {
    const { browser, local } = createFakeBrowser();
    const locks = fakeLocks();
    const target = createLocalTarget(browser, locks);
    for (let n = 0; n < 99; n++) await target.save(link(n), {});
    await Promise.all([0, 1, 2, 3].map((n) => createLocalTarget(browser, locks).save(link(`late-${n}`), {})));
    const links = new Set(storedLinks(local));
    const kept = (name) => links.has(`https://example.com/${name}`);
    assert.equal(links.size, 100);
    assert.deepEqual(['late-0', 'late-1', 'late-2', 'late-3', '0', '2', '3'].map(kept), [true, true, true, true, false, false, true]);
  });

  it('frees the room of the entry a save replaces when storage is full, and keeps it when the save still does not fit', async () => {
    const quota = { quotaBytes: Infinity };
    const { browser, local } = createFakeBrowser({ storage: quota });
    const target = createLocalTarget(browser, fakeLocks());
    await target.save(link('a'), { notes: 'x'.repeat(1_000) });
    await target.save(link('b'), {});
    quota.quotaBytes = JSON.stringify(Object.fromEntries(local)).length + 200;
    // Fits only once a's old entry is gone.
    assert.deepEqual(await target.save(link('a'), { notes: 'y'.repeat(900) }), { ok: true, existing: true });
    assert.deepEqual(stored(local).map(({ link: url, notes }) => [url, notes?.[0]]).sort(), [['https://example.com/a', 'y'], ['https://example.com/b', undefined]]);

    // Too large even after freeing a's entry: a is written back, nothing is lost.
    const before = structuredClone(Object.fromEntries(local));
    const result = await target.save(link('a'), { notes: 'z'.repeat(10_000) });
    assert.deepEqual(result, { ok: false, error: 'There is no room on this device to save the link.' });
    assert.deepEqual(Object.fromEntries(local), before);
    // A capture too large for an empty slot frees nothing it does not replace.
    assert.deepEqual(await target.save(link('c'), { notes: 'z'.repeat(10_000) }), { ok: false, error: 'There is no room on this device to save the link.' });
    assert.deepEqual(Object.fromEntries(local), before);
  });

  it('tells a failure before the write (not saved) from one after it (saved)', async () => {
    const fail = {};
    const { browser, local } = createFakeBrowser({ storage: { before: (op) => { if (fail[op]) throw new Error(`${op} failed`); } } });
    const target = createLocalTarget(browser, fakeLocks());
    await target.save(link('a'), { notes: 'one' });
    fail.set = true;
    assert.deepEqual(await target.save(link('a'), { notes: 'two' }), { ok: false, error: 'The link was not saved: set failed' });
    assert.deepEqual(stored(local), [{ link: 'https://example.com/a', notes: 'one' }]);
    fail.set = false;
    fail.remove = true;
    // Written, then clean-up failed: saved, and the next save clears the stale entry.
    assert.deepEqual(await target.save(link('a'), { notes: 'three' }), { ok: true, existing: true });
    fail.remove = false;
    await target.save(link('b'), {});
    assert.deepEqual(stored(local).filter((entry) => entry.link.endsWith('/a')), [{ link: 'https://example.com/a', notes: 'three' }]);
  });

  it('suggests at most eight saved tags by prefix, ignoring case', async () => {
    const { browser } = createFakeBrowser();
    const target = createLocalTarget(browser, fakeLocks());
    await target.save(link('a'), { tags: ['Reading', 'rust'] });
    await target.save(link('b'), { tags: ['research', ...Array.from({ length: 10 }, (_, n) => `re${n}`)] });
    assert.deepEqual((await target.suggestTags('RE')).length, 8);
    assert.deepEqual((await target.suggestTags('rea')).sort(), ['Reading']);
  });
});
