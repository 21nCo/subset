import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { afterEach, describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { transformWithEsbuild } from 'vite';
import { captureLink, createCapturePopupController } from '../dist/index.js';
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

  it('refuses a save when storage is full and removes nothing, so every saved capture is kept', async () => {
    const NO_ROOM = { ok: false, error: 'There is no room on this device to save the link.' };
    const full = { error: undefined };
    const { browser, local, calls } = createFakeBrowser({ storage: { before: (op) => { if (op === 'set' && full.error) throw full.error; } } });
    const target = createLocalTarget(browser, fakeLocks());
    await target.save(link('a'), { notes: 'kept' });
    const before = structuredClone(Object.fromEntries(local));
    // Every set fails, as Chromium and Firefox report a full storage: refused, never rejected, nothing removed.
    for (const error of [new Error('QUOTA_BYTES quota exceeded'), Object.assign(new Error('full'), { name: 'QuotaExceededError' })]) {
      full.error = error;
      const from = calls.length;
      assert.deepEqual(await target.save(link('a'), { notes: 'replacement' }), NO_ROOM);
      assert.deepEqual(await target.save(link('b'), {}), NO_ROOM);
      assert.deepEqual(Object.fromEntries(local), before);
      assert.deepEqual(calls.slice(from).map(([op]) => op).filter((op) => op === 'storage.local.remove'), []);
    }
  });

  it('at the quota refuses both a link saved again and a 101st link, keeping all 100', async () => {
    const quota = { quotaBytes: Infinity };
    const { browser, local, calls } = createFakeBrowser({ storage: quota });
    const target = createLocalTarget(browser, fakeLocks());
    for (let n = 0; n < 100; n++) await target.save(link(n), { notes: 'x'.repeat(100) });
    const before = structuredClone(Object.fromEntries(local));
    // Room for less than one more entry, though removing the entry each save replaces would make room.
    quota.quotaBytes = JSON.stringify(before).length + 100;
    const from = calls.length;
    assert.deepEqual(await target.save(link(0), { notes: 'y' }), { ok: false, error: 'There is no room on this device to save the link.' });
    assert.deepEqual(await target.save(link(100), {}), { ok: false, error: 'There is no room on this device to save the link.' });
    assert.deepEqual(Object.fromEntries(local), before);
    assert.equal(calls.slice(from).filter(([op]) => op === 'storage.local.remove').length, 0);
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

  const NOT_REMOVED = 'Links replaced on this device could not be removed from its storage.';
  const REFUSED = { ok: false, error: `The link was not saved. ${NOT_REMOVED}` };
  const ops = (calls, from = 0) => calls.slice(from).map(([op]) => op).filter((op) => op.startsWith('storage.local.'));

  /** Saves link a 12 times through `targets` in turn while every removal fails: 1 kept entry and 10 replaced ones. */
  async function failRemovals(targets, failing) {
    failing.remove = true;
    const results = [];
    for (let n = 0; n < 12; n++) results.push(await targets[n % targets.length].save(link('a'), { notes: `edit ${n}` }));
    return results;
  }

  for (const instances of [1, 2]) {
    it(`bounds the replaced entries a failing removal leaves; status() and save() agree (${instances} instance${instances > 1 ? 's' : ''})`, async () => {
      const failing = {};
      const { browser, local, calls } = createFakeBrowser({ storage: { before: (op) => { if (failing[op]) throw new Error(`${op} failed`); } } });
      const locks = fakeLocks();
      const targets = Array.from({ length: instances }, () => createLocalTarget(browser, locks));
      failing.remove = true;
      const results = [];
      for (let n = 0; n < 11; n++) {
        results.push(await targets[n % instances].save(link('a'), { notes: `edit ${n}` }));
        assert.ok(local.size <= 11);
        // n replaced entries are left: below the bound a save still works, so status() is connected on every instance.
        const expected = n < 10 ? { state: 'connected' } : { state: 'error', message: NOT_REMOVED };
        for (const target of targets) assert.deepEqual(await target.status(), expected, `after ${n} left`);
      }
      // Each write is committed (ok).
      assert.deepEqual(results, [{ ok: true, existing: false }, ...Array(10).fill({ ok: true, existing: true })]);
      assert.equal(local.size, 11);
      // At the bound: refused, nothing written, whichever instance saves.
      const before = structuredClone(Object.fromEntries(local));
      const from = calls.length;
      for (const target of targets) {
        assert.deepEqual(await target.save(link('a'), { notes: 'refused' }), REFUSED);
        assert.deepEqual(await target.save(link('b'), {}), REFUSED);
      }
      assert.deepEqual(Object.fromEntries(local), before);
      assert.equal(ops(calls, from).filter((op) => op === 'storage.local.set').length, 0);
      assert.equal(stored(local).filter(({ notes }) => notes === 'edit 10').length, 1);
      // Once removal works, status() on the instance that did not save last frees them: one entry per link.
      failing.remove = false;
      assert.deepEqual(await targets.at(-1).status(), { state: 'connected' });
      assert.deepEqual(stored(local), [{ link: 'https://example.com/a', notes: 'edit 10' }]);
      for (const target of targets) assert.deepEqual(await target.status(), { state: 'connected' });
    });
  }

  it('stays connected after one failed removal: the popup reaches editing and saves', async () => {
    const failing = {};
    const { browser, local } = createFakeBrowser({ storage: { before: (op) => { if (failing[op]) throw new Error(`${op} failed`); } } });
    const locks = fakeLocks();
    const [popupTarget, background] = [createLocalTarget(browser, locks), createLocalTarget(browser, locks)];
    await background.save(link('a'), { notes: 'one' });
    failing.remove = true;
    assert.deepEqual(await background.save(link('a'), { notes: 'two' }), { ok: true, existing: true });
    assert.deepEqual(await popupTarget.status(), { state: 'connected' });
    const controller = createCapturePopupController({ target: popupTarget, capture: async () => link('b') });
    await controller.start();
    assert.equal(controller.state.name, 'editing');
    await controller.save();
    assert.equal(controller.state.name, 'saved');
    failing.remove = false;
    assert.deepEqual(await background.status(), { state: 'connected' });
    assert.deepEqual(storedLinks(local), ['https://example.com/b', 'https://example.com/a']);
    assert.equal(stored(local).find((entry) => entry.link.endsWith('/a')).notes, 'two');
  });

  it('a removal that failed past the 100-link cap leaves the target connected, and status() frees it later', async () => {
    const failing = {};
    const { browser, local } = createFakeBrowser({ storage: { before: (op) => { if (failing[op]) throw new Error(`${op} failed`); } } });
    const target = createLocalTarget(browser, fakeLocks());
    for (let n = 0; n < 100; n++) await target.save(link(n), {});
    failing.remove = true;
    assert.deepEqual(await target.save(link(100), {}), { ok: true, existing: false });
    assert.equal(storedLinks(local).length, 101);
    assert.deepEqual(await target.status(), { state: 'connected' });
    failing.remove = false;
    assert.deepEqual(await target.status(), { state: 'connected' });
    assert.deepEqual(storedLinks(local), Array.from({ length: 100 }, (_, i) => `https://example.com/${100 - i}`));
  });

  it('once removal works again, frees the replaced entries before writing into a full storage', async () => {
    const failing = {};
    const quota = { quotaBytes: Infinity, before: (op) => { if (failing[op]) throw new Error(`${op} failed`); } };
    const { browser, local } = createFakeBrowser({ storage: quota });
    const locks = fakeLocks();
    const [popup, background] = [createLocalTarget(browser, locks), createLocalTarget(browser, locks)];
    await background.save(link('b'), { notes: 'b' });
    assert.deepEqual((await failRemovals([popup, background], failing)).at(-1), REFUSED);
    // Full: the next entry fits only once the 10 replaced copies of a are gone.
    quota.quotaBytes = JSON.stringify(Object.fromEntries(local)).length + 10;
    failing.remove = false;
    assert.deepEqual(await popup.save(link('a'), { notes: 'after recovery' }), { ok: true, existing: true });
    assert.deepEqual(stored(local).sort((x, y) => (x.link < y.link ? -1 : 1)), [
      { link: 'https://example.com/a', notes: 'after recovery' },
      { link: 'https://example.com/b', notes: 'b' }
    ]);
    assert.deepEqual(await background.status(), { state: 'connected' });
  });

  it('frees only replaced entries: never the newest of a link, nor the one this save replaces, even when the write then fails', async () => {
    const quota = {};
    const { browser, local, calls } = createFakeBrowser({ storage: quota });
    const entry = (time, name, notes) => [`reference:capture:${time.toString(36).padStart(12, '0')}:${name}`, { capture: link(name.slice(0, 1)), notes }];
    const seeded = [entry(1, 'a1', 'old a'), entry(2, 'a2', 'old a 2'), entry(3, 'b3', 'only b'), entry(4, 'a4', 'newest a')];
    for (const [key, value] of seeded) local.set(key, value);
    const kept = Object.fromEntries([seeded[2], seeded[3]]);
    quota.quotaBytes = JSON.stringify(kept).length + 10;
    const from = calls.length;
    assert.deepEqual(await createLocalTarget(browser, fakeLocks()).save(link('a'), { notes: 'replacement' }), {
      ok: false,
      error: 'There is no room on this device to save the link.'
    });
    assert.deepEqual(Object.fromEntries(local), kept);
    assert.deepEqual(calls.slice(from).filter(([op]) => op === 'storage.local.remove').map(([, keys]) => keys), [[seeded[1][0], seeded[0][0]]]);
  });

  /** Replaces `globalThis.navigator` for one test. */
  function setNavigator(value) {
    const descriptor = Object.getOwnPropertyDescriptor(globalThis, 'navigator');
    Object.defineProperty(globalThis, 'navigator', { value, configurable: true, writable: true });
    restore.push(() => (descriptor ? Object.defineProperty(globalThis, 'navigator', descriptor) : delete globalThis.navigator));
  }

  it('holds one exclusive navigator.locks lock by default: a second instance waits for it before touching storage', async () => {
    const requests = [];
    const held = fakeLocks();
    setNavigator({ locks: { request: (name, options, callback) => (requests.push([name, options]), held.request(name, callback)) } });
    const { browser, calls } = createFakeBrowser();
    let release;
    const holder = held.request('link-capture:reference-local', () => new Promise((resolve) => (release = resolve)));
    const first = createLocalTarget(browser).save(link('a'), {});
    const second = createLocalTarget(browser).save(link('b'), {});
    await new Promise((resolve) => setTimeout(resolve, 10));
    assert.deepEqual(calls.filter(([op]) => op.startsWith('storage.')), []);
    release();
    await holder;
    assert.deepEqual(await Promise.all([first, second]), [{ ok: true, existing: false }, { ok: true, existing: false }]);
    assert.deepEqual(requests, [
      ['link-capture:reference-local', { mode: 'exclusive' }],
      ['link-capture:reference-local', { mode: 'exclusive' }]
    ]);
  });

  it('without Web Locks reports an error and refuses every save without touching storage', async () => {
    const NO_LOCKS = 'This browser has no Web Locks (navigator.locks), so links cannot be saved on this device.';
    setNavigator({});
    freezeClockAndReverseUuids();
    const { browser, local, calls } = createFakeBrowser();
    local.set('reference:capture:kept', { capture: link('kept') });
    const before = structuredClone(Object.fromEntries(local));
    // Explicitly without a lock manager, and through the default where navigator.locks is absent.
    for (const make of [() => createLocalTarget(browser, undefined), () => createLocalTarget(browser)]) {
      const [background, popup] = [make(), make()];
      assert.deepEqual(await background.status(), { state: 'error', message: NO_LOCKS });
      const results = await Promise.all([background.save(link('a'), { notes: 'earlier' }), popup.save(link('a'), { notes: 'later' })]);
      assert.deepEqual(results, [{ ok: false, error: NO_LOCKS }, { ok: false, error: NO_LOCKS }]);
    }
    assert.deepEqual(Object.fromEntries(local), before);
    assert.deepEqual(calls.filter(([op]) => op.startsWith('storage.')), []);
    assert.deepEqual(await createLocalTarget(browser, fakeLocks()).status(), { state: 'connected' });
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
