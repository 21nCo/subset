import assert from 'node:assert/strict';
import { mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { after, test } from 'node:test';
import { pathToFileURL } from 'node:url';
import { catalogFeedProblems, receiptProblems } from '../../../scripts/catalog-feed.mjs';
import {
  cacheFile,
  CatalogInvalidError,
  CatalogUnavailableError,
  catalogUrl,
  DEFAULT_CATALOG_URL,
  download,
  loadCatalog,
  MAX_FEED_BYTES,
  parseFeed,
  validateReceipt
} from '../src/feed.mjs';
import { compileSchema } from '../src/schema.mjs';

const feedDir = new URL('../../catalog/feed/', import.meta.url);
const fixturesDir = new URL('fixtures/', feedDir);
const fixtures = readdirSync(fixturesDir).filter((name) => name.endsWith('.json')).sort();
const fixture = (name) => readFileSync(new URL(name, fixturesDir));
const root = mkdtempSync(path.join(tmpdir(), 'subset-feed-test-'));
after(() => rmSync(root, { recursive: true, force: true }));

test('the bundled schemas are the catalog package\'s, byte for byte', () => {
  for (const name of ['catalog.schema.json', 'receipt.schema.json']) {
    assert.deepEqual(readFileSync(new URL(`../src/schemas/${name}`, import.meta.url)), readFileSync(new URL(name, feedDir)), name);
  }
});

test('the validator refuses a schema keyword or $ref it does not implement', () => {
  assert.throws(() => compileSchema({ type: 'object', patternProperties: {} }), /unsupported schema keyword patternProperties/);
  assert.throws(() => compileSchema({ type: 'number' }), /unsupported type/);
  assert.throws(() => compileSchema({ additionalProperties: { type: 'string' } }), /only additionalProperties: false/);
  assert.throws(() => compileSchema({ $ref: 'https://example.com/schema' }), /unsupported \$ref/);
  assert.throws(() => compileSchema({ $defs: { a: { format: 'uri' } } }), /unsupported schema keyword format/);
});

test('accepts every valid catalog fixture and refuses every invalid one with a reason', () => {
  const catalogs = fixtures.filter((name) => name.startsWith('catalog-'));
  assert.ok(catalogs.length >= 11);
  for (const name of catalogs) {
    const { feed, problems } = parseFeed(fixture(name));
    if (name.startsWith('catalog-valid-')) {
      assert.equal(problems, undefined, `${name}: ${problems}`);
      assert.equal(feed.schema, 'subset.catalog@1');
    } else {
      assert.equal(feed, undefined, name);
      assert.ok(problems.length > 0 && problems.every((problem) => typeof problem === 'string' && problem.length > 0), name);
    }
  }
  assert.match(parseFeed(fixture('catalog-invalid-oversize.json')).problems[0], /larger than 262144 bytes/);
  assert.match(parseFeed(fixture('catalog-invalid-duplicate-app.json')).problems.join('\n'), /app id "breaks" appears more than once/);
  assert.match(parseFeed(fixture('catalog-invalid-unknown-field.json')).problems.join('\n'), /is not allowed/);
});

test('accepts every valid receipt fixture and refuses every invalid one', () => {
  for (const name of fixtures.filter((file) => file.startsWith('receipt-'))) {
    const problems = validateReceipt(JSON.parse(fixture(name).toString('utf8')));
    assert.equal(problems.length === 0, name.startsWith('receipt-valid-'), `${name}: ${problems}`);
  }
});

// Documents derived from the fixtures by changing one thing each: removing a field, adding one, or replacing a value
// with another type, an empty string, a path that leaves its prefix, an out-of-range number or a different value.
function* variants(value, set) {
  if (Array.isArray(value)) {
    yield set([]);
    yield set([...value, ...value]);
    for (const [index, item] of value.entries()) yield* variants(item, (next) => set(value.map((old, i) => (i === index ? next : old))));
    return;
  }
  if (typeof value === 'object' && value !== null) {
    yield set({ ...value, extra: true });
    yield set([]);
    for (const key of Object.keys(value)) {
      const { [key]: _removed, ...rest } = value;
      yield set(rest);
      yield* variants(value[key], (next) => set({ ...value, [key]: next }));
    }
    return;
  }
  const replacements = typeof value === 'string'
    ? ['', 1, `${value}/../x`, `${value}%2e`, `${value}\u0085`, value.toUpperCase(), `${value}.mjs`, 'a'.repeat(1025), '2026-02-29T00:00:00Z', 'Contents/./x']
    : [0, -1, 1.5, 1e9, '1', null, true, 'node', 'beta', 'live'];
  for (const replacement of replacements) yield set(replacement);
}

test('agrees with the generator\'s Ajv validation on every fixture and on thousands of variants of them', () => {
  let compared = 0;
  for (const name of fixtures) {
    const original = JSON.parse(fixture(name).toString('utf8'));
    const receipt = name.startsWith('receipt-');
    for (const document of [original, ...variants(original, (next) => next)]) {
      const text = JSON.stringify(document);
      const ours = receipt ? validateReceipt(document).length === 0 : parseFeed(Buffer.from(text)).feed !== undefined;
      const ajv = receipt ? receiptProblems(text).length === 0 : catalogFeedProblems(text).length === 0;
      assert.equal(ours, ajv, `${name}: ${text.slice(0, 400)}`);
      compared += 1;
    }
  }
  assert.ok(compared > 2000, `only ${compared} documents compared`);
});

test('refuses a feed that is not UTF-8 JSON', () => {
  assert.match(parseFeed(Buffer.from('{')).problems[0], /^not JSON/);
  const valid = fixture('catalog-valid-live-only.json');
  assert.match(parseFeed(Buffer.concat([valid.subarray(0, 40), Buffer.from([0xff]), valid.subarray(40)])).problems[0], /^not JSON/);
});

test('the feed URL is the default, or an https: or file: SUBSET_CATALOG_URL', () => {
  assert.equal(catalogUrl({}).href, DEFAULT_CATALOG_URL);
  assert.equal(catalogUrl({ SUBSET_CATALOG_URL: '' }).href, DEFAULT_CATALOG_URL);
  assert.equal(catalogUrl({ SUBSET_CATALOG_URL: 'https://example.test/feed.json' }).href, 'https://example.test/feed.json');
  assert.equal(catalogUrl({ SUBSET_CATALOG_URL: 'file:///tmp/feed.json' }).protocol, 'file:');
  for (const [value, message] of [
    ['http://subset.21n.dev/catalog/v1.json', /must be an https: or file: URL, not http:/],
    ['ftp://example.test/feed.json', /not ftp:/],
    ['data:application/json,{}', /not data:/],
    ['not a url', /is not a URL/],
    ['https://user:secret@example.test/feed.json', /must not contain a user name or password/]
  ]) {
    assert.throws(() => catalogUrl({ SUBSET_CATALOG_URL: value }), (error) => error instanceof CatalogInvalidError && message.test(error.message), value);
  }
});

test('caches in ~/Library/Caches/Subset on macOS, and in the platform cache folder elsewhere', () => {
  assert.equal(cacheFile({ platform: 'darwin', env: {}, home: '/Users/a' }), '/Users/a/Library/Caches/Subset/catalog.json');
  assert.equal(cacheFile({ platform: 'linux', env: {}, home: '/home/a' }), '/home/a/.cache/subset/catalog.json');
  assert.equal(cacheFile({ platform: 'linux', env: { XDG_CACHE_HOME: '/c' }, home: '/home/a' }), '/c/subset/catalog.json');
  assert.equal(cacheFile({ platform: 'linux', env: { XDG_CACHE_HOME: 'relative' }, home: '/home/a' }), '/home/a/.cache/subset/catalog.json');
  assert.equal(cacheFile({ platform: 'win32', env: { LOCALAPPDATA: 'C:\\L' }, home: 'C:\\U' }), 'C:\\L\\Subset\\Cache\\catalog.json');
});

// --- Fetching and the cache -----------------------------------------------------------------------------------------

const MINUTE = 60_000;
const DAY = 24 * 60 * MINUTE;
const NOW = Date.parse('2026-11-13T12:00:00Z');
let homes = 0;
// A home folder and a feed file served from file:, holding `name`'s fixture.
function setup(name = 'catalog-valid-live-only.json') {
  const home = path.join(root, `home-${(homes += 1)}`);
  mkdirSync(home);
  const feedFile = path.join(home, 'feed.json');
  writeFileSync(feedFile, fixture(name));
  const env = { SUBSET_CATALOG_URL: pathToFileURL(feedFile).href };
  const load = (options = {}) => loadCatalog({ env, platform: 'darwin', home, now: NOW, ...options });
  return { home, feedFile, env, load, cache: cacheFile({ platform: 'darwin', env, home }) };
}

test('fetches and caches the feed, then uses the cache while it is younger than 5 minutes', async () => {
  const { feedFile, load, cache } = setup();
  const first = await load();
  assert.equal(first.cached, false);
  assert.equal(first.feed.apps[0].id, 'breaks');
  assert.equal(JSON.parse(readFileSync(cache, 'utf8')).fetchedAt, new Date(NOW).toISOString());
  // The source changes, but a fresh cache answers without fetching.
  writeFileSync(feedFile, fixture('catalog-valid-tools-only.json'));
  const fresh = await load({ now: NOW + 4 * MINUTE });
  assert.equal(fresh.cached, true);
  assert.equal(fresh.warning, undefined);
  assert.equal(fresh.feed.apps[0].id, 'breaks');
  // --refresh skips it.
  const refreshed = await load({ now: NOW + 4 * MINUTE, refresh: true });
  assert.equal(refreshed.cached, false);
  assert.equal(refreshed.feed.apps.length, 0);
});

test('fetches again once the cache is 5 minutes old, replacing it', async () => {
  const { feedFile, load, cache } = setup();
  await load();
  writeFileSync(feedFile, fixture('catalog-valid-tools-only.json'));
  const stale = await load({ now: NOW + 5 * MINUTE });
  assert.equal(stale.cached, false);
  assert.equal(stale.feed.apps.length, 0);
  assert.equal(JSON.parse(readFileSync(cache, 'utf8')).fetchedAt, new Date(NOW + 5 * MINUTE).toISOString());
});

test('without network, uses a stale cache younger than 7 days with a warning, and refuses an older one', async () => {
  const { feedFile, load } = setup();
  await load();
  rmSync(feedFile);
  const stale = await load({ now: NOW + 6 * DAY });
  assert.equal(stale.cached, true);
  assert.equal(stale.feed.apps[0].id, 'breaks');
  assert.match(stale.warning, /^could not fetch the catalog from file:.*feed\.json \(ENOENT\); using the copy cached 6 days ago\.$/);
  await assert.rejects(load({ now: NOW + 7 * DAY }), (error) => error instanceof CatalogUnavailableError && /the cached copy is 7 days old, more than 7 days\.$/.test(error.message));
  // --refresh never falls back to the cache.
  await assert.rejects(load({ now: NOW + MINUTE * 10, refresh: true }), (error) => error instanceof CatalogUnavailableError && /\(ENOENT\)\.$/.test(error.message));
});

test('without network or a cache, says so', async () => {
  const { feedFile, load } = setup();
  rmSync(feedFile);
  await assert.rejects(load(), /could not fetch the catalog from .* \(ENOENT\), and there is no cached copy\.$/);
});

test('an invalid feed is an error, keeps the cached copy, and no cache stands in for it', async () => {
  const { feedFile, load, cache } = setup();
  await load();
  const before = readFileSync(cache);
  for (const name of fixtures.filter((file) => file.startsWith('catalog-invalid-'))) {
    writeFileSync(feedFile, fixture(name));
    await assert.rejects(load({ now: NOW + 10 * MINUTE }), (error) => error instanceof CatalogInvalidError && /is not a valid subset\.catalog@1 feed, so it is not used:\n {2}\S/.test(error.message), name);
  }
  assert.deepEqual(readFileSync(cache), before);
});

test('ignores a cache for another URL, an unreadable one, and one dated in the future', async () => {
  const { feedFile, load, cache } = setup();
  await load();
  rmSync(feedFile);
  const entry = JSON.parse(readFileSync(cache, 'utf8'));
  for (const changed of [{ ...entry, url: 'https://example.test/other.json' }, { ...entry, fetchedAt: new Date(NOW + DAY).toISOString() }, { ...entry, body: '{}' }, { ...entry, schema: 'x' }]) {
    writeFileSync(cache, JSON.stringify(changed));
    await assert.rejects(load({ now: NOW + MINUTE }), /there is no cached copy/);
  }
  writeFileSync(cache, 'not json');
  await assert.rejects(load({ now: NOW + MINUTE }), /there is no cached copy/);
});

test('refuses a fresh cache that is not UTF-8, and fetches again', async () => {
  const { feedFile, load, cache } = setup();
  await load();
  // A byte that is never UTF-8 inside the cached feed's summary, a string the schema takes as it is.
  const bytes = readFileSync(cache);
  const at = bytes.indexOf('Take well-timed');
  assert.ok(at > 0);
  writeFileSync(cache, Buffer.concat([bytes.subarray(0, at), Buffer.from([0xff]), bytes.subarray(at)]));
  writeFileSync(feedFile, fixture('catalog-valid-tools-only.json'));
  const loaded = await load({ now: NOW + MINUTE });
  assert.equal(loaded.cached, false);
  assert.equal(loaded.feed.apps.length, 0);
  // Valid UTF-8 JSON, but the cached feed (its body string) holds a lone surrogate: the escape \ud800 in the cache
  // file, inside the summary. Encoded, it would become U+FFFD.
  writeFileSync(feedFile, fixture('catalog-valid-live-only.json'));
  await load({ now: NOW + 2 * MINUTE, refresh: true });
  const text = readFileSync(cache, 'utf8');
  writeFileSync(cache, text.replace('Take well-timed', '\\ud800Take well-timed'));
  const { body } = JSON.parse(readFileSync(cache, 'utf8'));
  assert.equal(body.isWellFormed(), false);
  assert.equal(JSON.parse(body).apps[0].summary.charCodeAt(0), 0xd800);
  writeFileSync(feedFile, fixture('catalog-valid-tools-only.json'));
  const again = await load({ now: NOW + 3 * MINUTE });
  assert.equal(again.cached, false);
  assert.equal(again.feed.apps.length, 0);
});

// A stand-in fetch answering with `body` (bytes, sent in chunks) and `status`, recording its requests.
function fakeFetch({ status = 200, body = fixture('catalog-valid-live-only.json'), headers = {}, error } = {}) {
  const requests = [];
  const fetch = async (url, init) => {
    requests.push({ url: String(url), init });
    if (error) throw error;
    const chunks = [];
    for (let at = 0; at < body.byteLength; at += 16 * 1024) chunks.push(body.subarray(at, at + 16 * 1024));
    let pulled = 0;
    const stream = new ReadableStream({
      pull(controller) {
        if (pulled < chunks.length) controller.enqueue(chunks[pulled++]);
        else controller.close();
      }
    });
    fetch.pulled = () => pulled;
    return new Response(stream, { status, headers });
  };
  fetch.requests = requests;
  return fetch;
}

test('fetches the https: feed without following redirects and caches it', async () => {
  const home = path.join(root, 'https-home');
  const fetch = fakeFetch();
  const loaded = await loadCatalog({ env: {}, platform: 'darwin', home, now: NOW, fetch });
  assert.equal(loaded.url, DEFAULT_CATALOG_URL);
  assert.equal(fetch.requests[0].url, DEFAULT_CATALOG_URL);
  assert.equal(fetch.requests[0].init.redirect, 'error');
  assert.ok(fetch.requests[0].init.signal instanceof AbortSignal);
  assert.equal(JSON.parse(readFileSync(cacheFile({ platform: 'darwin', env: {}, home }), 'utf8')).url, DEFAULT_CATALOG_URL);
});

test('stops reading a feed after 256 KiB and refuses it', async () => {
  const home = path.join(root, 'oversize-home');
  const fetch = fakeFetch({ body: Buffer.alloc(4 * MAX_FEED_BYTES, 0x20) });
  await assert.rejects(loadCatalog({ env: {}, platform: 'darwin', home, now: NOW, fetch }), /larger than 262144 bytes/);
  assert.ok(fetch.pulled() <= MAX_FEED_BYTES / (16 * 1024) + 2, `read ${fetch.pulled()} chunks`);
});

test('keeps at most 256 KiB and one byte of a feed that arrives as one larger chunk', async () => {
  const body = Buffer.alloc(8 * MAX_FEED_BYTES, 0x20);
  const fetch = async () => new Response(new ReadableStream({ start: (controller) => (controller.enqueue(body), controller.close()) }));
  const bytes = await download(new URL(DEFAULT_CATALOG_URL), fetch);
  assert.equal(bytes.byteLength, MAX_FEED_BYTES + 1);
  // A feed of exactly 256 KiB, in chunks of every size, is kept whole.
  const exact = Buffer.alloc(MAX_FEED_BYTES, 0x61);
  const fetchExact = fakeFetch({ body: exact });
  assert.deepEqual(await download(new URL(DEFAULT_CATALOG_URL), fetchExact), exact);
  await assert.rejects(loadCatalog({ env: {}, platform: 'darwin', home: path.join(root, 'one-chunk-home'), now: NOW, fetch }), /larger than 262144 bytes/);
});

test('an HTTP error or a network failure leaves the catalog unavailable, so a cached copy may stand in', async () => {
  const home = path.join(root, 'network-home');
  await loadCatalog({ env: {}, platform: 'darwin', home, now: NOW, fetch: fakeFetch() });
  for (const [fetch, reason] of [
    [fakeFetch({ status: 503 }), /\(HTTP 503\)/],
    [fakeFetch({ error: new TypeError('fetch failed', { cause: Object.assign(new Error('getaddrinfo ENOTFOUND'), { code: 'ENOTFOUND' }) }) }), /\(ENOTFOUND\)/],
    [fakeFetch({ error: new DOMException('timed out', 'TimeoutError') }), /\(no answer within 20 seconds\)/],
    [fakeFetch({ error: new TypeError('fetch failed', { cause: new Error('unexpected redirect') }) }), /\(unexpected redirect\)/]
  ]) {
    const loaded = await loadCatalog({ env: {}, platform: 'darwin', home, now: NOW + 10 * MINUTE, fetch });
    assert.equal(loaded.cached, true);
    assert.match(loaded.warning, reason);
    await assert.rejects(loadCatalog({ env: {}, platform: 'darwin', home, now: NOW + 8 * DAY, fetch }), reason);
  }
});
