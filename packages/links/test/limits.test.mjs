import assert from 'node:assert/strict';
import { test } from 'node:test';
import { MAX_DOCUMENT_BYTES, parseLinkDetails } from '../dist/index.js';

const url = 'https://example.com/';
const KB = 1024;

/** A realistic page: a head with metadata, then repeated article markup up to `size` characters. */
function page(size, { before = '', after = '' } = {}) {
  const head = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Big page</title>${before}</head><body>`;
  const block = '<div class="card" data-id="42"><a href="/item?id=42&amp;ref=x">Item &amp; more</a><p>Lorem ipsum dolor sit amet, <b>consectetur</b> adipiscing elit.</p><img src="/i.png" alt="x"></div>\n';
  const body = block.repeat(Math.ceil((size - head.length) / block.length));
  return `${head}${body.slice(0, size - head.length)}${after}</body></html>`;
}

test('fixture: a 3 MB document is parsed only up to its first 512 KB', () => {
  const late = '<meta property="og:title" content="Too late"><link rel="icon" href="/late.png">';
  const html = page(3 * KB * KB, { before: '<meta name="description" content="Early">' });
  // Insert the late tags just after the 512 KB boundary.
  const document = `${html.slice(0, MAX_DOCUMENT_BYTES + 10)}${late}${html.slice(MAX_DOCUMENT_BYTES + 10)}`;
  assert.ok(document.length > 3 * KB * KB);
  for (const input of [document, new TextEncoder().encode(document)]) {
    const details = parseLinkDetails(input, { url, contentType: 'text/html' });
    assert.equal(details.title, 'Big page');
    assert.equal(details.description, 'Early');
    assert.deepEqual(details.icons, [{ url: 'https://example.com/favicon.ico', rel: 'icon' }]);
  }
  // The same tags just inside the boundary are read.
  const inside = `${html.slice(0, MAX_DOCUMENT_BYTES - late.length - 10)}${late}${html.slice(MAX_DOCUMENT_BYTES)}`;
  assert.equal(parseLinkDetails(inside, { url }).title, 'Too late');
});

test('the 512 KB cut does not split a character', () => {
  // A 4-byte character straddling the cut is dropped from byte input; a surrogate pair from string input.
  const bytes = new TextEncoder().encode(`<title>${'a'.repeat(MAX_DOCUMENT_BYTES - 9)}😀😀</title>`);
  const title = parseLinkDetails(bytes, { url }).title;
  assert.ok(!title.includes('�'));
  const text = `<title>${'a'.repeat(MAX_DOCUMENT_BYTES - 8)}😀</title>`;
  assert.ok(!/[\uD800-\uDBFF]$/.test(parseLinkDetails(text, { url }).title));
});

test('a 512 KB document parses in under 100 ms', () => {
  parseLinkDetails(page(16 * KB), { url });
  const fill = (prefix, unit, suffix = '') => `${prefix}${unit.repeat(Math.ceil(MAX_DOCUMENT_BYTES / unit.length))}${suffix}`;
  const fixtures = {
    realistic: page(MAX_DOCUMENT_BYTES),
    'meta-heavy': fill('<head>', '<meta property="og:image" content="/x.png"><link rel="icon" href="/i.png">'),
    'entity-heavy': fill('<title>', '&amp;&#x41;&nbsp;&lt;', '</title>'),
    // htmlparser2's Parser is quadratic on this one (its element stack uses Array#unshift).
    'deeply nested': fill('', '<div><span><a href="x">'),
    'unterminated attribute': fill('<meta content="', 'x'),
    'open comment': fill('<!--', '-- <meta property="og:title" content="x"> '),
    whitespace: fill('<title>', ' \n\t', 'x</title>')
  };
  for (const [name, html] of Object.entries(fixtures)) {
    assert.ok(html.length >= MAX_DOCUMENT_BYTES * 0.95, `${name} is about 512 KB`);
    const started = performance.now();
    parseLinkDetails(html, { url });
    const elapsed = performance.now() - started;
    assert.ok(elapsed < 100, `${name} took ${elapsed.toFixed(1)} ms`);
  }
});

test('parse time grows linearly with document size', () => {
  const time = (html) => {
    let best = Infinity;
    for (let run = 0; run < 3; run++) {
      const started = performance.now();
      parseLinkDetails(html, { url });
      best = Math.min(best, performance.now() - started);
    }
    return best;
  };
  const small = time(page(MAX_DOCUMENT_BYTES / 8));
  const large = time(page(MAX_DOCUMENT_BYTES));
  // Eight times the input; a quadratic step would take about 64 times as long. Allow generous noise.
  assert.ok(large < Math.max(small, 1) * 24, `64 KB took ${small.toFixed(1)} ms, 512 KB took ${large.toFixed(1)} ms`);
});
