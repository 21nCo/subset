import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { describe, it } from 'node:test';
import { fileURLToPath } from 'node:url';
import { transformWithEsbuild } from 'vite';
import { captureLink } from '../dist/index.js';
import { createFakeBrowser } from './fake-browser.mjs';

// The reference host's target is extension source, built only by Vite; it imports types alone, so stripping them is enough.
const path = fileURLToPath(new URL('../extension/src/local-target.ts', import.meta.url));
const { code } = await transformWithEsbuild(readFileSync(path, 'utf8'), path, { format: 'esm' });
const { createLocalTarget } = await import(`data:text/javascript,${encodeURIComponent(code)}`);

const link = (n) => captureLink(`https://example.com/${n}`, `Page ${n}`);

function storedLinks(local) {
  return [...local.entries()]
    .filter(([key]) => key.startsWith('reference:capture:'))
    .sort(([a], [b]) => (a < b ? 1 : -1))
    .map(([, value]) => value.capture.canonicalUrl);
}

describe('the reference local target', () => {
  it('keeps both of two overlapping saves of different links, as from the popup and the background', async () => {
    const { browser, local } = createFakeBrowser();
    // Two instances, as the popup and the background each create their own.
    const popup = createLocalTarget(browser);
    const background = createLocalTarget(browser);
    const results = await Promise.all([popup.save(link('a'), { notes: 'from the popup' }), background.save(link('b'), {})]);
    assert.deepEqual(results, [{ ok: true, existing: false }, { ok: true, existing: false }]);
    assert.deepEqual(storedLinks(local).sort(), ['https://example.com/a', 'https://example.com/b']);
  });

  it('reports a link saved again as existing and keeps only its newest entry', async () => {
    const { browser, local } = createFakeBrowser();
    const target = createLocalTarget(browser);
    assert.deepEqual(await target.save(link('a'), { tags: ['old'] }), { ok: true, existing: false });
    assert.deepEqual(await target.save(link('a'), { tags: ['new'] }), { ok: true, existing: true });
    assert.deepEqual(storedLinks(local), ['https://example.com/a']);
    assert.deepEqual(await target.suggestTags(''), ['new']);
  });

  it('keeps the 100 newest links, also when saves overlap at the limit', async () => {
    const { browser, local } = createFakeBrowser();
    const target = createLocalTarget(browser);
    for (let n = 0; n < 99; n++) await target.save(link(n), {});
    await Promise.all([0, 1, 2, 3].map((n) => createLocalTarget(browser).save(link(`late-${n}`), {})));
    const links = storedLinks(local);
    assert.equal(links.length, 100);
    for (let n = 0; n < 4; n++) assert.ok(links.includes(`https://example.com/late-${n}`), `late-${n}`);
    assert.ok(!links.includes('https://example.com/0') && !links.includes('https://example.com/2'));
    assert.ok(links.includes('https://example.com/3'));
  });

  it('suggests saved tags by prefix, ignoring case', async () => {
    const { browser } = createFakeBrowser();
    const target = createLocalTarget(browser);
    await target.save(link('a'), { tags: ['Reading', 'rust'] });
    await target.save(link('b'), { tags: ['research'] });
    assert.deepEqual((await target.suggestTags('RE')).sort(), ['Reading', 'research']);
  });
});
