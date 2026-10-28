import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { isLinkDetailsV1, LinkUrlError, parseLinkDetails } from '../dist/index.js';

const url = 'https://example.com/docs/page.html';
const fixture = (name) => readFileSync(new URL(`fixtures/${name}`, import.meta.url), 'utf8');
const parse = (html, options = {}) => {
  const details = parseLinkDetails(html, { url, contentType: 'text/html; charset=utf-8', ...options });
  assert.ok(isLinkDetailsV1(details), 'every parsed record passes the validator');
  return details;
};
const head = (...tags) => `<!doctype html><html><head>${tags.join('')}</head><body></body></html>`;
const meta = (attribute, key, content) => `<meta ${attribute}="${key}" content="${content}">`;

// Each row lists one field's sources from highest to lowest precedence. For every source, a document holding
// it and all lower sources yields that source's value.
const precedence = [
  {
    field: 'title',
    sources: [
      ['og:title', (v) => meta('property', 'og:title', v)],
      ['twitter:title', (v) => meta('name', 'twitter:title', v)],
      ['<title>', (v) => `<title>${v}</title>`]
    ]
  },
  {
    field: 'description',
    sources: [
      ['og:description', (v) => meta('property', 'og:description', v)],
      ['twitter:description', (v) => meta('name', 'twitter:description', v)],
      ['meta[name=description]', (v) => meta('name', 'description', v)]
    ]
  },
  {
    field: 'image',
    absolute: true,
    sources: [
      ['og:image:secure_url', (v) => meta('property', 'og:image:secure_url', v)],
      ['og:image', (v) => meta('property', 'og:image', v)],
      ['twitter:image', (v) => meta('name', 'twitter:image', v)]
    ]
  },
  {
    field: 'author',
    sources: [
      ['meta[name=author]', (v) => meta('name', 'author', v)],
      ['article:author', (v) => meta('property', 'article:author', v)]
    ]
  }
];

for (const { field, sources, absolute } of precedence) {
  sources.forEach(([source], index) => {
    test(`${field} comes from ${source} ahead of every lower source`, () => {
      const value = (name) => (absolute ? `https://img.example/${encodeURIComponent(name)}.png` : `From ${name}`);
      // Lower sources first in the document, so document order cannot explain the result.
      const tags = sources.slice(index).reverse().map(([name, tag]) => tag(value(name)));
      assert.equal(parse(head(...tags))[field], value(source));
    });
  });
  test(`${field} skips an empty higher source`, () => {
    const [[, highest], [second, next]] = sources;
    const value = absolute ? 'https://img.example/next.png' : 'Next';
    assert.equal(parse(head(highest('  '), next(value)))[field], value, `falls through to ${second}`);
  });
}

test('Open Graph and Twitter keys are read from either property or name', () => {
  const details = parse(head(meta('name', 'og:title', 'Named OG'), meta('property', 'twitter:description', 'Property Twitter')));
  assert.equal(details.title, 'Named OG');
  assert.equal(details.description, 'Property Twitter');
  // description and author are only names: a property with that key is not the description.
  assert.equal(parse(head(meta('property', 'description', 'Not this'))).description, undefined);
});

test('an og:image that is not http or https falls through to the next source', () => {
  const details = parse(head(meta('property', 'og:image:secure_url', 'javascript:alert(1)'), meta('property', 'og:image', 'data:image/png;base64,AA'), meta('name', 'twitter:image', '/t.png')));
  assert.equal(details.image, 'https://example.com/t.png');
});

test('fixture: multiple og:image tags use the first', () => {
  assert.equal(parse(fixture('multiple-og-image.html')).image, 'https://cdn.example.com/first.jpg');
});

test('canonical comes from link rel=canonical, resolved and canonicalized, http(s) only', () => {
  assert.equal(parse(head('<link rel="canonical" href="/Guide?utm_source=feed&id=7#intro">')).canonicalUrl, 'https://example.com/Guide?id=7');
  assert.equal(parse(head('<link rel="Canonical" href="HTTP://Example.COM:80">')).canonicalUrl, 'http://example.com/');
  assert.equal(parse(head('<link rel="canonical" href="ftp://example.com/a">')).canonicalUrl, undefined);
  assert.equal(parse(head('<link rel="canonical" href="ftp://example.com/a"><link rel="canonical" href="/b">')).canonicalUrl, 'https://example.com/b');
  assert.equal(parse(head('<link rel="alternate" href="/feed">')).canonicalUrl, undefined);
});

test('icons come from rel icon, shortcut icon and apple-touch-icon, in that order', () => {
  const details = parse(head(
    '<link rel="apple-touch-icon" sizes="180x180" href="/apple.png">',
    '<link rel="shortcut icon" href="/shortcut.ico">',
    '<link rel="icon" type="image/png" sizes="32x32" href="/icon.png">'
  ));
  assert.deepEqual(details.icons, [
    { url: 'https://example.com/icon.png', rel: 'icon', sizes: '32x32', type: 'image/png' },
    { url: 'https://example.com/shortcut.ico', rel: 'shortcut icon' },
    { url: 'https://example.com/apple.png', rel: 'apple-touch-icon', sizes: '180x180' }
  ]);
});

test('icons fall back to /favicon.ico at the site root', () => {
  assert.deepEqual(parse(head('<title>No icons</title>')).icons, [{ url: 'https://example.com/favicon.ico', rel: 'icon' }]);
  assert.deepEqual(parse(head('<link rel="icon" href="data:,">')).icons, [{ url: 'https://example.com/favicon.ico', rel: 'icon' }]);
});

test('fixture: relative icons resolve against the document URL, deduplicated, http(s) only', () => {
  // The fixture declares <base href>; resolution uses the document URL, as SET-171 specifies.
  assert.deepEqual(parse(fixture('relative-icons.html')).icons, [
    { url: 'https://example.com/docs/favicon-32.png', rel: 'icon', sizes: '32x32', type: 'image/png' },
    { url: 'https://static.example.org/f16.png', rel: 'icon', sizes: '16x16', type: 'image/png' },
    { url: 'https://example.com/favicon.ico', rel: 'shortcut icon' },
    { url: 'https://example.com/touch/apple-180.png', rel: 'apple-touch-icon', sizes: '180x180' }
  ]);
});

test('at most 16 icons are kept, after ordering', () => {
  const apple = Array.from({ length: 20 }, (_, i) => `<link rel="apple-touch-icon" href="/a${i}.png">`);
  const icons = Array.from({ length: 10 }, (_, i) => `<link rel="icon" href="/i${i}.png">`);
  const details = parse(head(...apple, ...icons));
  assert.equal(details.icons.length, 16);
  assert.deepEqual(details.icons.slice(0, 10).map((icon) => icon.rel), Array(10).fill('icon'));
  assert.equal(details.icons[10].url, 'https://example.com/a0.png');
});

test('site name, language, type, published time come from their single sources', () => {
  const details = parse(`<html lang=" pt-BR "><head>${meta('property', 'og:site_name', 'Exemplo')}${meta('property', 'og:type', 'article')}${meta('property', 'article:published_time', '2024-03-05T10:20:30+05:30')}</head></html>`);
  assert.equal(details.siteName, 'Exemplo');
  assert.equal(details.language, 'pt-BR');
  assert.equal(details.type, 'article');
  assert.equal(details.publishedTime, '2024-03-05T10:20:30+05:30');
});

test('published time accepts ISO 8601 dates and date-times only', () => {
  const published = (value) => parse(head(meta('property', 'article:published_time', value))).publishedTime;
  for (const value of ['2024-03-05', '2024-03-05T10:20Z', '2024-03-05T10:20:30.123Z', '2024-02-29T00:00:00-08:00']) assert.equal(published(value), value);
  for (const value of ['March 5, 2024', '2024-02-30', '2023-02-29T00:00Z', '2024-03-05T25:00Z', '1709600000', '2024-3-5', '2024-03-05 10:20']) {
    assert.equal(published(value), undefined, value);
  }
});

test('a language that is not a language tag is dropped', () => {
  assert.equal(parse('<html lang="en us"><title>x</title></html>').language, undefined);
  assert.equal(parse('<html><title>x</title></html>').language, undefined);
});

test('entities are decoded and whitespace is collapsed', () => {
  const details = parse(head('<title>\n  Fish &amp; Chips &mdash;\t&#x1F41F;&nbsp;\n</title>', meta('name', 'description', '  a&lt;b&gt;c   &quot;d&quot;\n\n e ')));
  assert.equal(details.title, 'Fish & Chips — 🐟');
  assert.equal(details.description, 'a<b>c "d" e');
});

test('title and description are capped by characters, not code units', () => {
  const emoji = '😀'.repeat(600);
  const details = parse(head(`<title>${emoji}</title>`, meta('name', 'description', 'd'.repeat(2500))));
  assert.equal([...details.title].length, 500);
  assert.equal(details.title, '😀'.repeat(500));
  assert.equal(details.description.length, 2000);
});

test('only the first <title> counts, and an SVG title is not the document title', () => {
  assert.equal(parse('<body><svg><title>Icon</title></svg><title>Page</title></body>').title, 'Page');
  assert.equal(parse(head('<title> </title>', '<title>Second</title>')).title, undefined);
});

test('markup inside script and comments is ignored', () => {
  const details = parse(head(`<script>var s = '<meta property="og:title" content="Script">';</script>`, '<!-- <meta property="og:title" content="Comment"> -->', '<title>Real</title>'));
  assert.equal(details.title, 'Real');
});

test('fixture: missing head', () => {
  assert.deepEqual(parse(fixture('missing-head.html')), {
    version: 1,
    url,
    title: 'Une page sans head',
    description: 'Pas de <head> explicite.',
    siteName: 'Exemple',
    language: 'fr-CA',
    icons: [{ url: 'https://example.com/icon.svg', rel: 'icon', type: 'image/svg+xml' }],
    contentType: 'text/html'
  });
});

test('fixture: malformed HTML recovers the way a browser tokenizer does', () => {
  // `<head` without `>` swallows the next tag as attributes, as in a browser, so og:title is lost; the
  // unterminated og:type tag likewise swallows the icon link. Script and comment markup stays inert.
  assert.deepEqual(parse(fixture('malformed.html')), {
    version: 1,
    url,
    title: 'Never & closed',
    description: 'Bare-value',
    siteName: 'Site © 2024 ☃',
    language: 'en',
    type: 'video.other',
    icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }],
    contentType: 'text/html'
  });
});

test('non-UTF-8 charset declared in a meta tag decodes byte input', () => {
  // "Привет, мир" and "Café" in windows-1251, which has no ASCII-incompatible bytes in the markup.
  const cyrillic = [0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2, 0x2c, 0x20, 0xec, 0xe8, 0xf0];
  const bytes = (charsetTag) => Uint8Array.from([
    ...Buffer.from(`<html><head>${charsetTag}<title>`, 'latin1'),
    ...cyrillic,
    ...Buffer.from('</title></head></html>', 'latin1')
  ]);
  assert.equal(parse(bytes('<meta charset="windows-1251">'), { contentType: 'text/html' }).title, 'Привет, мир');
  assert.equal(parse(bytes('<meta http-equiv="Content-Type" content="text/html; charset=cp1251">'), { contentType: 'text/html' }).title, 'Привет, мир');
  // The Content-Type charset wins over the meta tag, and a BOM wins over both.
  assert.equal(parse(bytes('<meta charset="utf-8">'), { contentType: 'text/html; charset="windows-1251"' }).title, 'Привет, мир');
  const latin1 = Uint8Array.from([...Buffer.from('<meta charset=iso-8859-1><title>Caf', 'latin1'), 0xe9, ...Buffer.from('</title>', 'latin1')]);
  assert.equal(parse(latin1.buffer, { contentType: 'text/html' }).title, 'Café');
  const bom = Uint8Array.from([0xef, 0xbb, 0xbf, ...Buffer.from('<meta charset="windows-1251"><title>Café</title>', 'utf8')]);
  assert.equal(parse(bom, { contentType: 'text/html; charset=windows-1251' }).title, 'Café');
  // An unknown label and no declaration both fall back to UTF-8; a meta UTF-16 label means UTF-8.
  assert.equal(parse(Buffer.from('<meta charset="no-such-charset"><title>Café</title>'), { contentType: 'text/html' }).title, 'Café');
  assert.equal(parse(Buffer.from('<title>Café</title>'), { contentType: 'text/html' }).title, 'Café');
  assert.equal(parse(Buffer.from('<meta charset="utf-16"><title>Café</title>'), { contentType: 'text/html' }).title, 'Café');
});

test('a non-HTML content type yields only the URL, content type and fallback icon', () => {
  assert.deepEqual(parse('<title>Not parsed</title>', { contentType: 'Application/PDF' }), {
    version: 1,
    url,
    icons: [{ url: 'https://example.com/favicon.ico', rel: 'icon' }],
    contentType: 'application/pdf'
  });
  assert.equal(parse('<title>XHTML</title>', { contentType: 'application/xhtml+xml' }).title, 'XHTML');
  assert.equal(parseLinkDetails('<title>Default</title>', { url }).contentType, 'text/html');
  assert.equal(parseLinkDetails('<title>Bad header</title>', { url, contentType: 'garbage' }).title, 'Bad header');
});

test('the document URL must be absolute http or https', () => {
  for (const bad of ['/relative', 'file:///tmp/a.html', 'not a url']) {
    assert.throws(() => parseLinkDetails('<title>x</title>', { url: bad }), LinkUrlError);
  }
  assert.equal(parseLinkDetails('<title>x</title>', { url: new URL('HTTPS://Example.com') }).url, 'https://example.com/');
  assert.throws(() => parseLinkDetails(42, { url }), TypeError);
});

test('the record is JSON-serializable and round-trips through the validator', () => {
  const details = parse(fixture('missing-head.html'));
  assert.ok(isLinkDetailsV1(JSON.parse(JSON.stringify(details))));
});
