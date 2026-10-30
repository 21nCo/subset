// parseImport and renderNetscape on their own: one fixture per exporter, the limits and malformed files.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import { BookmarkError, MAX_IMPORT_BYTES, MAX_IMPORT_ITEMS, normalizeTagName, parseImport, renderNetscape } from '../dist/index.js';

export const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url));
const throwsWith = (fn, code) => assert.throws(fn, (error) => error instanceof BookmarkError && error.code === code);
/** The fields a test states, in a stable shape. */
const brief = ({ url, title, notes, tags, unread, archived }) => ({ url, title, notes, tags, unread, archived });
const link = (url, fields = {}) => ({ url, title: null, notes: null, tags: [], unread: false, archived: false, ...fields });

test('Chrome: folders become tags, the bookmarks bar does not, and entities are decoded', () => {
  const { items, warnings } = parseImport(fixture('chrome.html'), 'netscape-html');
  assert.deepEqual(items.map(brief), [
    link('https://developer.mozilla.org/en-US/', { title: 'MDN Web Docs' }),
    link('https://nodejs.org/en/docs?utm_source=chrome&v=22', { title: 'Node.js & npm <docs>', tags: ['Dev-Tools'] }),
    link('https://doc.rust-lang.org/book/', { title: 'The Rust Programming Language', tags: ['Dev-Tools', 'Rust-Go'] }),
    // Only Safari's top-level Favorites folder is its toolbar; a user's folder of that name in Chrome is a tag.
    link('https://news.ycombinator.com/', { title: 'Hacker News', tags: ['Favorites'] }),
    link('javascript:void(document.title)', { title: 'Bookmarklet' }),
    link('https://example.com/', { tags: ['Other-bookmarks'] }),
    link('chrome://settings/', { title: 'Settings', tags: ['Other-bookmarks'] })
  ]);
  assert.equal(items[0].addedAt, 1_700_000_100_000);
  assert.deepEqual(warnings, []);
});

test('Firefox: TAGS and folders combine, a <DD> after a link is its notes, one after a folder is not', () => {
  const { items } = parseImport(fixture('firefox.html'), 'netscape-html');
  assert.deepEqual(items.map(brief), [
    link('https://support.mozilla.org/products/firefox', { title: 'Get Help', tags: ['Mozilla-Firefox'] }),
    link('https://www.example.org/article', {
      title: 'An article',
      notes: 'Saved for the weekend.\nSecond line > first.',
      tags: ['reading', 'long-read']
    }),
    link('place:parent=menu________&queryType=1&sort=12', { title: 'Recent Tags' }),
    link('https://www.mozilla.org/en-US/firefox/', { title: 'Firefox' }),
    link('https://WWW.Example.org/article?utm_campaign=x#comments', { title: 'Duplicate of the article', tags: ['Other-Bookmarks', 'Reading', 'notes'] })
  ]);
});

test('Safari: no top-level list, and the unmarked Favorites folder is the toolbar', () => {
  const { items } = parseImport(fixture('safari.html'), 'netscape-html');
  assert.deepEqual(items.map(brief), [
    link('https://www.apple.com/', { title: 'Apple' }),
    link('https://www.bbc.co.uk/news', { title: 'BBC News', tags: ['News'] }),
    link('https://www.wikipedia.org/', { title: 'Wikipedia', tags: ['Bookmarks-Menu'] }),
    link('https://www.example.net/long-read', { title: 'A Long Read', tags: ['Reading-List'] })
  ]);
  assert.equal(items[0].addedAt, null);
});

test('a top-level Favorites folder is a tag outside Safari, which alone writes folders outside a <DL>', () => {
  const firefox = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
    '<TITLE>Bookmarks</TITLE>',
    '<H1>Bookmarks Menu</H1>',
    '<DL><p>',
    '    <DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000100">Favorites</H3>',
    '    <DL><p>',
    '        <DT><A HREF="https://firefox.example/" ADD_DATE="1700000001">Firefox favorite</A>',
    '    </DL><p>',
    '</DL>'
  ].join('\n');
  const raindrop = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
    '<TITLE>Raindrop.io Bookmarks</TITLE>',
    '<H1>Raindrop.io Bookmarks</H1>',
    '<DL><p>',
    '<DT><H3 ADD_DATE="1700000000" LAST_MODIFIED="1700000000">Favourites bar</H3>',
    '<DL><p>',
    '<DT><A HREF="https://raindrop.example/" ADD_DATE="1700000100" TAGS="ui">Raindrop favourite</A>',
    '</DL><p>',
    '</DL><p>'
  ].join('\n');
  assert.deepEqual(parseImport(firefox, 'netscape-html').items.map(brief), [
    link('https://firefox.example/', { title: 'Firefox favorite', tags: ['Favorites'] })
  ]);
  assert.deepEqual(parseImport(raindrop, 'netscape-html').items.map(brief), [
    link('https://raindrop.example/', { title: 'Raindrop favourite', tags: ['Favourites-bar', 'ui'] })
  ]);
});

test('linkding: TOREAD, the archived marker tag and [linkding-notes]', () => {
  const { items } = parseImport(fixture('linkding.html'), 'netscape-html');
  assert.deepEqual(items.map(brief), [
    link('https://github.com/sissbruecker/linkding', {
      title: 'linkding',
      notes: 'Self-hosted bookmark manager\n\nTry the "bundles" feature',
      tags: ['self-hosted', 'bookmarks'],
      unread: true
    }),
    link('https://www.djangoproject.com/', { title: 'Django', tags: ['python'], archived: true }),
    link('https://news.ycombinator.com/item?id=1', { title: 'Ask HN: Untitled thread', notes: 'Only a note' })
  ]);
});

test('Raindrop: collections become tags along with TAGS', () => {
  const { items } = parseImport(fixture('raindrop.html'), 'netscape-html');
  assert.deepEqual(items.map(brief), [
    link('https://www.figma.com/', {
      title: 'Figma: the collaborative interface design tool',
      notes: 'Design and prototype in the browser',
      tags: ['Design', 'ui', 'tools']
    }),
    link('https://fonts.google.com/?query=inter', { title: 'Google Fonts', tags: ['Design', 'Type-&-Fonts', 'fonts'] }),
    link('https://example.com/raindrop?ref=feed', { tags: ['Unsorted'] })
  ]);
});

test('Pocket CSV: quoted fields, | tags, status=archive, and a title that is only the URL is none', () => {
  const { items, warnings } = parseImport(fixture('pocket.csv'), 'pocket-csv');
  assert.deepEqual(items.map(brief), [
    link('https://example.com/nothing?utm_medium=social', { title: 'How to Do Nothing', tags: ['books', 'long-form'] }),
    link('https://example.org/q', { title: 'Quotes, "commas" and line breaks', archived: true }),
    link('https://example.net/untitled', { tags: ['reading'] }),
    link('ftp://example.com/file.txt', { title: 'Not a web link' })
  ]);
  assert.equal(items[0].addedAt, 1_700_000_000_000);
  assert.deepEqual(warnings, []);
  // Columns are found by name, so their order does not matter; a short row is read and reported.
  const reordered = parseImport('url,status,title\nhttps://a.example/,archive,A\nhttps://b.example/\n', 'pocket-csv');
  assert.deepEqual(reordered.items.map(brief), [link('https://a.example/', { title: 'A', archived: true }), link('https://b.example/')]);
  assert.deepEqual(reordered.warnings, [{ item: 2, message: 'The row has 1 fields where the header has 3' }]);
});

test('a file that is not of the kind, or an unknown kind, is invalid input', () => {
  throwsWith(() => parseImport('<html><body><a href="https://example.com/">x</a></body></html>', 'netscape-html'), 'invalid-input');
  throwsWith(() => parseImport('name,link\nx,https://example.com/\n', 'pocket-csv'), 'invalid-input');
  throwsWith(() => parseImport('', 'pocket-csv'), 'invalid-input');
  throwsWith(() => parseImport('<!DOCTYPE NETSCAPE-Bookmark-file-1>', 'json'), 'invalid-input');
  throwsWith(() => parseImport(42, 'netscape-html'), 'invalid-input');
});

test('files over 20 MB fail with too-large, counting UTF-8 bytes', () => {
  const doctype = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n';
  const atLimit = doctype + ' '.repeat(MAX_IMPORT_BYTES - doctype.length);
  assert.deepEqual(parseImport(atLimit, 'netscape-html').items, []);
  assert.deepEqual(parseImport(new TextEncoder().encode(atLimit), 'netscape-html').items, []);
  throwsWith(() => parseImport(`${atLimit} `, 'netscape-html'), 'too-large');
  throwsWith(() => parseImport(new Uint8Array(MAX_IMPORT_BYTES + 1), 'netscape-html'), 'too-large');
  throwsWith(() => parseImport(new ArrayBuffer(MAX_IMPORT_BYTES + 1), 'pocket-csv'), 'too-large');
  // Fewer characters than the limit, but two bytes each.
  throwsWith(() => parseImport(doctype + 'é'.repeat(MAX_IMPORT_BYTES / 2), 'netscape-html'), 'too-large');
});

test('more than 50,000 bookmarks fail with too-large', () => {
  const netscape = (count) => `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${'<DT><A HREF="https://example.com/">x</A>\n'.repeat(count)}</DL><p>\n`;
  const pocket = (count) => `title,url\n${'x,https://example.com/\n'.repeat(count)}`;
  assert.equal(parseImport(netscape(MAX_IMPORT_ITEMS), 'netscape-html').items.length, MAX_IMPORT_ITEMS);
  assert.equal(parseImport(pocket(MAX_IMPORT_ITEMS), 'pocket-csv').items.length, MAX_IMPORT_ITEMS);
  throwsWith(() => parseImport(netscape(MAX_IMPORT_ITEMS + 1), 'netscape-html'), 'too-large');
  throwsWith(() => parseImport(pocket(MAX_IMPORT_ITEMS + 1), 'pocket-csv'), 'too-large');
});

test('malformed markup is read in linear time', () => {
  // A tail of tags that never close: a backtracking tokenizer rescans the rest of the file from each one.
  const file = `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DT><A HREF="https://example.com/">ok</A>\n${'<a '.repeat(300_000)}`;
  const started = performance.now();
  const { items } = parseImport(file, 'netscape-html');
  assert.ok(performance.now() - started < 2000, `took ${Math.round(performance.now() - started)} ms`);
  // The unclosed tail is one link with no URL, which an import skips.
  assert.deepEqual(items.map((item) => item.url), ['https://example.com/', '']);
});

test('ADD_DATE in seconds, milliseconds or microseconds is read as epoch milliseconds', () => {
  const dates = ['1700000000', '1700000000123', '1700000000123456', 'yesterday', ''].map(
    (date) => parseImport(`<!DOCTYPE NETSCAPE-Bookmark-file-1><DT><A HREF="https://example.com/" ADD_DATE="${date}">x</A>`, 'netscape-html').items[0].addedAt
  );
  assert.deepEqual(dates, [1_700_000_000_000, 1_700_000_000_123, 1_700_000_000_123, null, null]);
});

test('renderNetscape escapes markup and parses back to the same items', () => {
  const bookmarks = [
    {
      url: 'https://example.com/?a=1&b="2"',
      title: '<script>alert("x")</script> & \'quotes\'',
      notes: 'Line one\nLine <two> & three',
      tags: ['a&b', 'Rust'],
      unread: true,
      archived: true,
      createdAt: 1_700_000_000_999,
      updatedAt: 1_700_000_100_000
    },
    { url: 'https://example.org/', title: null, notes: null, tags: [], unread: false, archived: false, createdAt: 1_700_000_200_000, updatedAt: 1_700_000_200_000 }
  ];
  const html = renderNetscape(bookmarks);
  assert.ok(!html.includes('<script>'));
  assert.match(html, /ADD_DATE="1700000000" LAST_MODIFIED="1700000100" TOREAD="1" TAGS="a&amp;b,Rust,linkding:bookmarks.archived"/);
  const { items } = parseImport(html, 'netscape-html');
  assert.deepEqual(
    items.map((item) => ({ ...brief(item), addedAt: item.addedAt })),
    bookmarks.map(({ url, title, notes, tags, unread, archived, createdAt }) => ({ url, title, notes, tags, unread, archived, addedAt: Math.floor(createdAt / 1000) * 1000 }))
  );
});

test('renderNetscape keeps notes with linkding markers, titles with spacing and the archived marker apart', () => {
  const bookmarks = [
    {
      url: 'https://lossless.example/',
      title: ' Two  spaces,\ta tab,\nline\u00a0break and no-break space ',
      notes: 'see [linkding-notes]x[/linkding-notes] here\n[/linkding-notes] and &#91; stays',
      tags: ['linkding'],
      unread: false,
      archived: false,
      createdAt: 1_700_000_000_000,
      updatedAt: 1_700_000_000_000
    }
  ];
  const html = renderNetscape(bookmarks);
  assert.ok(!html.includes('[linkding-notes]'));
  const { items } = parseImport(html, 'netscape-html');
  assert.deepEqual(items.map(brief), bookmarks.map(({ url, title, notes, tags, unread, archived }) => ({ url, title, notes, tags, unread, archived })));
  // A tag of that name cannot be saved, so a bookmark tagged with the marker is never exported as archived.
  throwsWith(() => normalizeTagName('Linkding:Bookmarks.Archived'), 'invalid-input');
});

test('Netscape titles read like a browser: markup whitespace collapses, encoded whitespace stays', () => {
  const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF="https://a.example/">\n  Wrapped\n  title&nbsp;&nbsp;here&#10;</A>\n</DL><p>';
  assert.equal(parseImport(html, 'netscape-html').items[0].title, 'Wrapped title\u00a0\u00a0here\n');
});
