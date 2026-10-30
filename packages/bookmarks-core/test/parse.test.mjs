// parseImport and renderNetscape on their own: one fixture per exporter, the limits and malformed files.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { test } from 'node:test';
import {
  BookmarkError,
  MAX_EXPORT_LENGTH,
  MAX_FOLDER_TAG_REFERENCES,
  MAX_IMPORT_BYTES,
  MAX_IMPORT_ITEMS,
  normalizeTagName,
  parseImport,
  renderNetscape
} from '../dist/index.js';
import { decodeEntities } from '../dist/netscape.js';

export const fixture = (name) => readFileSync(new URL(`./fixtures/${name}`, import.meta.url));
const throwsWith = (fn, code) => assert.throws(fn, (error) => error instanceof BookmarkError && error.code === code);
/** The fields a test states, in a stable shape. */
const brief = ({ url, title, notes, tags, unread, archived }) => ({ url, title, notes, tags, unread, archived });
const link = (url, fields = {}) => ({ url, title: null, notes: null, tags: [], unread: false, archived: false, ...fields });

/** The markup of the first `<DD>` in an export, up to the next entry or the end of the list. */
const ddText = (html) => /<DD>([\s\S]*?)\n(?=<DT>|<\/DL>)/.exec(html)[1];

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

test("Safari's Favorites folder in another language is the toolbar at the top level and a tag when nested", () => {
  for (const name of ['Favoriten', 'Favoris', 'お気に入り', '个人收藏', 'Избранное']) {
    const html = [
      '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
      `<DT><H3 FOLDED>${name}</H3>`,
      '<DL><p>',
      '<DT><A HREF="https://bar.example/">Bar</A>',
      '<DT><H3 FOLDED>Mine</H3>',
      '<DL><p>',
      `<DT><H3 FOLDED>${name}</H3>`,
      '<DL><p>',
      '<DT><A HREF="https://nested.example/">Nested</A>',
      '</DL><p>',
      '</DL><p>',
      '</DL><p>'
    ].join('\n');
    assert.deepEqual(
      parseImport(html, 'netscape-html').items.map(brief),
      [link('https://bar.example/', { title: 'Bar' }), link('https://nested.example/', { title: 'Nested', tags: ['Mine', name] })],
      name
    );
  }
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
  // Text after linkding's notes part is kept as a further paragraph.
  const trailing = parseImport(
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DT><A HREF="https://a.example/">a</A>\n<DD>Before [linkding-notes]inside[/linkding-notes] after &amp; more',
    'netscape-html'
  );
  assert.equal(trailing.items[0].notes, 'Before\n\ninside\n\nafter & more');
});

test('comments are not text in titles, notes or folder names', () => {
  const html = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
    '<DL><p>',
    '<DT><H3>Fold<!-- <DT><A HREF="https://hidden.example/">no</A> -->er</H3>',
    '<DL><p>',
    '<DT><A HREF="https://a.example/">Hello<!-- hidden --> world</A>',
    '<DD>Note <!-- secret -->kept',
    '</DL><p>',
    '<DT><A HREF="https://b.example/">B</A>',
    '<DD>Open <!-- comment to the end',
    '<DT><A HREF="https://never.example/">never</A>'
  ].join('\n');
  assert.deepEqual(parseImport(html, 'netscape-html').items.map(brief), [
    link('https://a.example/', { title: 'Hello world', notes: 'Note kept', tags: ['Folder'] }),
    link('https://b.example/', { title: 'B', notes: 'Open' })
  ]);
});

test('a link inside a note is note text, not a bookmark', () => {
  const html = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
    '<DL><p>',
    '<DT><A HREF="https://a.example/">A</A>',
    '<DD>See <a href="https://f.example/">this</a> page<br>and <A HREF="https://g.example/">that',
    '<DT><A HREF="https://b.example/">B</A>',
    '</DL><p>'
  ].join('\n');
  assert.deepEqual(parseImport(html, 'netscape-html').items.map(brief), [
    link('https://a.example/', { title: 'A', notes: 'See this page\nand that' }),
    link('https://b.example/', { title: 'B' })
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
    link('https://example.com/nothing?utm_medium=social', { title: 'How to Do Nothing', tags: ['books', 'long-form'], unread: true }),
    link('https://example.org/q', { title: 'Quotes, "commas" and line breaks', archived: true }),
    link('https://example.net/untitled', { tags: ['reading'], unread: true }),
    link('ftp://example.com/file.txt', { title: 'Not a web link', unread: true })
  ]);
  assert.equal(items[0].addedAt, 1_700_000_000_000);
  assert.deepEqual(warnings, []);
  // Columns are found by name, so their order does not matter; a short row is read and reported.
  const reordered = parseImport('url,status,title\nhttps://a.example/,archive,A\nhttps://b.example/\nhttps://c.example/,UNREAD,C\n', 'pocket-csv');
  assert.deepEqual(reordered.items.map(brief), [
    link('https://a.example/', { title: 'A', archived: true }),
    link('https://b.example/'),
    link('https://c.example/', { title: 'C', unread: true })
  ]);
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

test('tag names are made in linear time from TAGS, encoded folder whitespace and Pocket tags', () => {
  // A long inner run of whitespace: a trim that retries from each of its characters takes quadratic time.
  const spaces = 200_000;
  const timed = (file, kind) => {
    const started = performance.now();
    const { items } = parseImport(file, kind);
    const ms = performance.now() - started;
    assert.ok(ms < 2000, `${kind} took ${Math.round(ms)} ms`);
    return items[0].tags;
  };
  const doctype = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n';
  assert.deepEqual(timed(`${doctype}<DT><A HREF="https://a.example/" TAGS="a${' '.repeat(spaces)}b">x</A>\n`, 'netscape-html'), ['a-b']);
  const folder = `<DT><H3>a${'&nbsp;'.repeat(spaces)}b</H3>\n<DL><p>\n<DT><A HREF="https://a.example/">x</A>\n</DL><p>\n`;
  assert.deepEqual(timed(`${doctype}<DL><p>\n${folder}</DL><p>\n`, 'netscape-html'), ['a-b']);
  assert.deepEqual(timed(`title,url,tags\nx,https://a.example/,a${' '.repeat(spaces)}b|${' '.repeat(spaces)}c \n`, 'pocket-csv'), ['a-b', 'c']);
});

test('every distinct enclosing folder is a tag, and a file whose folders give too many tags fails', () => {
  const nest = (names) => names.map((name) => `<DT><H3>${name}</H3>\n<DL><p>\n`).join('');
  // Nested folders of one name are one tag, also in another spelling, and a link's own TAGS repeat neither.
  const same = parseImport(
    `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${nest(['Folder', 'FOLDER', 'Other', 'folder'])}<DT><A HREF="https://a.example/" TAGS="folder,x,X">a</A>\n</DL><p>\n</DL><p>\n<DT><A HREF="https://b.example/">b</A>`,
    'netscape-html'
  );
  assert.deepEqual(same.items.map((item) => item.tags), [['Folder', 'Other', 'x'], ['Folder']]);
  assert.deepEqual(same.warnings, []);

  // Deep nesting loses no folder.
  const deep = Array.from({ length: 100 }, (_, at) => `d${at}`);
  const nested = parseImport(`<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${nest(deep)}<DT><A HREF="https://deep.example/">d</A>\n`, 'netscape-html');
  assert.deepEqual(nested.items.map((item) => item.tags), [deep]);
  assert.deepEqual(nested.warnings, []);

  // 20,000 nested folders around 20,000 links (1.5 MB) would hold 400 million tags: it fails as soon as it passes the
  // budget, while every link at the budget's depth is read.
  const depth = 20_000;
  const file = `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${nest(Array.from({ length: depth }, (_, at) => `f${at}`))}${'<DT><A HREF="https://deep.example/">d</A>\n'.repeat(20_000)}`;
  const started = performance.now();
  throwsWith(() => parseImport(file, 'netscape-html'), 'too-large');
  assert.ok(performance.now() - started < 2000, `took ${Math.round(performance.now() - started)} ms`);
  const atBudget = `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n${nest(Array.from({ length: 40 }, (_, at) => `f${at}`))}${'<DT><A HREF="https://deep.example/">d</A>\n'.repeat(MAX_FOLDER_TAG_REFERENCES / 40)}`;
  assert.equal(parseImport(atBudget, 'netscape-html').items.length, MAX_IMPORT_ITEMS);
});

test('a link or folder whose end tag is missing ends at the next entry', () => {
  const { items, warnings } = parseImport(
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF="https://a.example/">A\n<DT><A HREF="https://b.example/">B</A>\n<DT><A HREF="https://c.example/">C\n<DD>note\n<DT><H3>Open\n<DL><p>\n<DT><A HREF="https://d.example/">D\n</DL><p>\n<DT><A HREF="https://e.example/">E',
    'netscape-html'
  );
  assert.deepEqual(items.map(brief), [
    link('https://a.example/', { title: 'A' }),
    link('https://b.example/', { title: 'B' }),
    link('https://c.example/', { title: 'C', notes: 'note' }),
    link('https://d.example/', { title: 'D', tags: ['Open'] }),
    link('https://e.example/', { title: 'E' })
  ]);
  assert.deepEqual(warnings, []);
});

test('ADD_DATE in seconds, milliseconds or microseconds is read as epoch milliseconds', () => {
  const dates = ['1700000000', '1700000000123', '1700000000123456', 'yesterday', ''].map(
    (date) => parseImport(`<!DOCTYPE NETSCAPE-Bookmark-file-1><DT><A HREF="https://example.com/" ADD_DATE="${date}">x</A>`, 'netscape-html').items[0].addedAt
  );
  assert.deepEqual(dates, [1_700_000_000_000, 1_700_000_000_123, 1_700_000_000_123, null, null]);
  // The unit is told by size: up to 1e11 is seconds, up to 1e14 milliseconds, above that microseconds.
  const edges = ['100000000000', '100000000001', '100000000000000', '100000000000001'].map(
    (date) => parseImport(`<!DOCTYPE NETSCAPE-Bookmark-file-1><DT><A HREF="https://example.com/" ADD_DATE="${date}">x</A>`, 'netscape-html').items[0].addedAt
  );
  assert.deepEqual(edges, [1e14, 100_000_000_001, 1e14, 100_000_000_000]);
});

test('Netscape text and attributes decode every HTML named reference, as a browser does', () => {
  const html = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>',
    '<DT><H3>Caf&eacute; &amp; more</H3>\n<DL><p>',
    '<DT><A HREF="https://a.example/?a=1&copy=2&amp;b=&lt;" TAGS="Na&iuml;ve,&hearts;">M&mdash;M &hellip; &NotANamedReference; &copy</A>',
    '<DD>Notes &ndash; with &laquo;quotes&raquo; &amp; &rarr; arrows',
    '</DL><p>\n</DL><p>'
  ].join('\n');
  assert.deepEqual(parseImport(html, 'netscape-html').items.map(brief), [
    link('https://a.example/?a=1&copy=2&b=<', {
      title: 'M\u2014M \u2026 &NotANamedReference; \u00a9',
      notes: 'Notes \u2013 with \u00abquotes\u00bb & \u2192 arrows',
      tags: ['Caf\u00e9-&-more', 'Na\u00efve', '\u2665']
    })
  ]);
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
  // The notes are one linkding notes part with no other marker in it, also once its references are decoded.
  assert.match(decodeEntities(ddText(html)), /^\[linkding-notes\](?:(?!\[\/?linkding-notes\])[\s\S])*\[\/linkding-notes\]$/);
  const { items } = parseImport(html, 'netscape-html');
  assert.deepEqual(items.map(brief), bookmarks.map(({ url, title, notes, tags, unread, archived }) => ({ url, title, notes, tags, unread, archived })));
  // A tag of that name cannot be saved, so a bookmark tagged with the marker is never exported as archived.
  throwsWith(() => normalizeTagName('Linkding:Bookmarks.Archived'), 'invalid-input');
});

/**
 * The description and notes linkding's importer reads from a `<DD>` (bookmarks/services/parser.py, handle_dd_data):
 * its `HTMLParser` decodes character references first, then it splits on the markers.
 */
function linkdingDd(html) {
  const desc = decodeEntities(ddText(html)).trim();
  return {
    description: desc.split('[linkding-notes]')[0],
    notes: desc.includes('[linkding-notes]') ? desc.split('[linkding-notes]')[1].split('[/linkding-notes]')[0] : ''
  };
}

test('renderNetscape keeps notes with literal linkding markers whole for linkding and for this import', () => {
  const bookmark = { url: 'https://a.example/', title: 'A', tags: [], unread: false, archived: false, createdAt: 0, updatedAt: 0 };
  const visible = (text) => text.replaceAll('\u2060', '');
  for (const notes of [
    'keep [/linkding-notes] tail',
    'keep [linkding-notes] tail',
    'keep [/linkding-notes] tail and [linkding-notes] more',
    '[linkding-notes][linkding-notes]x[/linkding-notes][/linkding-notes] &#91;/linkding-notes] end',
    'joined [\u2060/linkding-notes] and [\u2060\u2060linkding-notes] stay'
  ]) {
    const html = renderNetscape([{ ...bookmark, notes }]);
    const read = linkdingDd(html);
    assert.deepEqual({ ...read, notes: visible(read.notes) }, { description: '', notes: visible(notes) }, notes);
    assert.equal(parseImport(html, 'netscape-html').items[0].notes, notes);
  }
});

test("a word joiner in another file's linkding notes is kept: only this export's own joiners are removed", () => {
  const dd = (notes, header = '') =>
    `<!DOCTYPE NETSCAPE-Bookmark-file-1>\n${header}<DL><p>\n<DT><A HREF="https://a.example/">A</A>\n<DD>[linkding-notes]${notes}[/linkding-notes]\n</DL><p>\n`;
  for (const [written, notes] of [
    ['joined [\u2060/linkding-notes] stays', 'joined [\u2060/linkding-notes] stays'],
    ['joined [&#8288;/linkding-notes] stays', 'joined [\u2060/linkding-notes] stays'],
    ['a [\u2060linkding-notes] b [&#x2060;\u2060/linkding-notes] c [\u2060/linkding-notes]', 'a [\u2060linkding-notes] b [\u2060\u2060/linkding-notes] c [\u2060/linkding-notes]']
  ]) {
    assert.equal(parseImport(dd(written), 'netscape-html').items[0].notes, notes, written);
    // The export's generator only counts in the header, before the first list.
    const late = dd(written).replace('<DT>', '<META NAME="generator" CONTENT="subset.dev Bookmarks">\n<DT>');
    assert.equal(parseImport(late, 'netscape-html').items[0].notes, notes, written);
  }
  const own = renderNetscape([{ url: 'https://a.example/', title: 'A', notes: 'x', tags: [], unread: false, archived: false, createdAt: 0, updatedAt: 0 }]);
  assert.match(own, /^<META NAME="generator" CONTENT="subset\.dev Bookmarks">$/m);
  assert.ok(own.indexOf('<META NAME="generator"') < own.indexOf('<DL>'));
});

test('renderNetscape fails with too-large past MAX_EXPORT_LENGTH, before it puts the file together', () => {
  const frame = renderNetscape([]).length;
  // Long notes (renderNetscape does not check their length), with characters escaped to six.
  const heavy = { url: 'https://a.example/', title: 'A', notes: `${'"'.repeat(1_000)}${'x'.repeat(1_000_000)}`, tags: [], unread: false, archived: false, createdAt: 0, updatedAt: 0 };
  const entry = renderNetscape([heavy]).length - frame;
  const count = Math.floor((MAX_EXPORT_LENGTH - frame) / entry) - 1;
  const last = { ...heavy, notes: null, title: '' };
  const pad = MAX_EXPORT_LENGTH - frame - count * entry - (renderNetscape([last]).length - frame);
  const exact = [...new Array(count).fill(heavy), { ...last, title: 'x'.repeat(pad) }];
  assert.equal(renderNetscape(exact).length, MAX_EXPORT_LENGTH);
  exact[count] = { ...last, title: 'x'.repeat(pad + 1) };
  throwsWith(() => renderNetscape(exact), 'too-large');
});

test('renderNetscape writes notes where linkding reads notes, not the description', () => {
  const bookmark = { url: 'https://a.example/', title: 'A', tags: [], unread: false, archived: false, createdAt: 0, updatedAt: 0 };
  const notes = 'Remember to follow up\non <this> & [that]';
  const html = renderNetscape([{ ...bookmark, notes }]);
  assert.deepEqual(linkdingDd(html), { description: '', notes });
  assert.equal(parseImport(html, 'netscape-html').items[0].notes, notes);
});

test('renderNetscape writes addedAt as ADD_DATE, else createdAt', () => {
  const bookmark = { url: 'https://a.example/', title: 'A', notes: null, tags: [], unread: false, archived: false, createdAt: 1_800_000_000_000, updatedAt: 1_800_000_000_000 };
  const html = renderNetscape([{ ...bookmark, addedAt: 1_500_000_000_000 }, { ...bookmark, url: 'https://b.example/', addedAt: null }]);
  assert.deepEqual(
    parseImport(html, 'netscape-html').items.map((item) => item.addedAt),
    [1_500_000_000_000, 1_800_000_000_000]
  );
});

test('Netscape titles read like a browser: markup whitespace collapses, encoded whitespace stays', () => {
  const html = '<!DOCTYPE NETSCAPE-Bookmark-file-1>\n<DL><p>\n<DT><A HREF="https://a.example/">\n  Wrapped\n  title&nbsp;&nbsp;here&#10;</A>\n</DL><p>';
  assert.equal(parseImport(html, 'netscape-html').items[0].title, 'Wrapped title\u00a0\u00a0here\n');
});
