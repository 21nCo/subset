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

/** The fastest of three parses in milliseconds, so one run preempted by a busy host does not count. */
function bestTime(html) {
  let best = Infinity;
  for (let run = 0; run < 3; run++) {
    const started = performance.now();
    parseLinkDetails(html, { url });
    best = Math.min(best, performance.now() - started);
  }
  return best;
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

test('a string is cut at 512 KB of UTF-8, the same place as its bytes', () => {
  // 262,144 two-byte characters fill the limit in about half as many UTF-16 code units.
  const late = '<meta property="og:title" content="Too late"><link rel="icon" href="/late.png">';
  const html = `<title>Early</title><!--${'é'.repeat(MAX_DOCUMENT_BYTES / 2)}-->${late}${'x'.repeat(3 * KB * KB)}`;
  assert.ok(html.indexOf(late) < MAX_DOCUMENT_BYTES);
  const fromString = parseLinkDetails(html, { url });
  assert.equal(fromString.title, 'Early');
  assert.deepEqual(fromString.icons, [{ url: 'https://example.com/favicon.ico', rel: 'icon' }]);
  assert.deepEqual(parseLinkDetails(new TextEncoder().encode(html), { url }), fromString);
});

test('the 512 KB cut does not split a character', () => {
  // A comment of multi-byte filler, then `<title>X ` and 4-byte emoji, the first ending exactly at the limit or
  // straddling it. The title is collapsed and short, so the cut shows in it for both input forms.
  const prefix = '<!--';
  const suffix = '--><title>X ';
  for (const [filler, fillerBytes] of [['é', 2], ['\uD800', 3]]) {
    for (const [emojiStart, title] of [[MAX_DOCUMENT_BYTES - 4, 'X 😀'], [MAX_DOCUMENT_BYTES - 2, 'X']]) {
      const bytes = emojiStart - prefix.length - suffix.length;
      const html = `${prefix}${filler.repeat(Math.floor(bytes / fillerBytes))}${'a'.repeat(bytes % fillerBytes)}${suffix}😀😀`;
      assert.equal(parseLinkDetails(html, { url }).title, title, `string, ${fillerBytes}-byte filler`);
      assert.equal(parseLinkDetails(new TextEncoder().encode(html), { url }).title, title, `bytes, ${fillerBytes}-byte filler`);
    }
  }
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
    const elapsed = bestTime(html);
    assert.ok(elapsed < 100, `${name} took ${elapsed.toFixed(1)} ms`);
  }
});

test('parse time grows linearly with document size', () => {
  const small = bestTime(page(MAX_DOCUMENT_BYTES / 8));
  const large = bestTime(page(MAX_DOCUMENT_BYTES));
  // Eight times the input; a quadratic step would take about 64 times as long. Allow generous noise.
  assert.ok(large < Math.max(small, 1) * 24, `64 KB took ${small.toFixed(1)} ms, 512 KB took ${large.toFixed(1)} ms`);
});
