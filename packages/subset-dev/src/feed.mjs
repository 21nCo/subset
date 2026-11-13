// The Subset catalog feed (subset.catalog@1, packages/catalog/README.md): where it is, fetching it with the reader
// rules (at most 256 KiB as received, the closed schema, unique IDs), and the copy cached for 5 minutes. An invalid
// feed is refused whole, never partly used, and does not replace the cached copy.
import { randomBytes } from 'node:crypto';
import { closeSync, constants, fstatSync, mkdirSync, openSync, readFileSync, readSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { compileSchema } from './schema.mjs';

export const DEFAULT_CATALOG_URL = 'https://subset.21n.dev/catalog/v1.json';
export const CATALOG_SCHEMA = 'subset.catalog@1';
export const MAX_FEED_BYTES = 256 * 1024;
export const FRESH_MS = 5 * 60 * 1000;
export const STALE_LIMIT_MS = 7 * 24 * 60 * 60 * 1000;
const FETCH_TIMEOUT_MS = 20_000;
const CACHE_SCHEMA = 'subset.catalog-cache@1';
// The cache holds the feed as a JSON string, whose escapes can make it several times longer than the feed.
const MAX_CACHE_BYTES = 8 * MAX_FEED_BYTES;

const readSchema = (name) => JSON.parse(readFileSync(new URL(`./schemas/${name}.schema.json`, import.meta.url), 'utf8'));
const validateCatalog = compileSchema(readSchema('catalog'));
export const validateReceipt = compileSchema(readSchema('receipt'));

/** The catalog could not be fetched (no network, a timeout, an HTTP error, a missing file): a cached copy may do. */
export class CatalogUnavailableError extends Error {}
/** The catalog was fetched but is refused by the reader rules: never used, and no cached copy stands in for it. */
export class CatalogInvalidError extends Error {}

// Values the schema cannot keep unique (README, Reader rules 4).
function duplicateProblems(feed) {
  const problems = [];
  const unique = (label, values) => {
    const seen = new Set();
    for (const value of values) {
      if (seen.has(value)) problems.push(`${label} ${JSON.stringify(value)} appears more than once`);
      seen.add(value);
    }
  };
  unique('app id', feed.apps.map((app) => app.id));
  unique('bundleId', feed.apps.map((app) => app.bundleId));
  unique('helper command', feed.apps.flatMap((app) => app.helpers.map((helper) => helper.command)));
  unique('tool id', feed.tools.map((tool) => tool.id));
  return problems;
}

/**
 * Parses a received feed (bytes) by the reader rules. Returns { feed } or { problems } listing why it is refused: more
 * than 256 KiB (checked before parsing), not UTF-8 JSON, invalid against the closed schema, or a duplicate ID.
 */
export function parseFeed(bytes) {
  if (bytes.byteLength > MAX_FEED_BYTES) return { problems: [`the feed is larger than ${MAX_FEED_BYTES} bytes`] };
  let feed;
  try {
    feed = JSON.parse(new TextDecoder('utf-8', { fatal: true, ignoreBOM: true }).decode(bytes));
  } catch (error) {
    return { problems: [`not JSON: ${error.message}`] };
  }
  const invalid = validateCatalog(feed);
  const problems = invalid.length > 0 ? invalid : duplicateProblems(feed);
  return problems.length > 0 ? { problems } : { feed };
}

/**
 * The feed URL: SUBSET_CATALOG_URL when set (an https: or file: URL), otherwise the default. Throws a
 * CatalogInvalidError for any other URL, or one with a user name or password.
 */
export function catalogUrl(env) {
  const overridden = env.SUBSET_CATALOG_URL !== undefined && env.SUBSET_CATALOG_URL !== '';
  const text = overridden ? env.SUBSET_CATALOG_URL : DEFAULT_CATALOG_URL;
  let url;
  try {
    url = new URL(text);
  } catch {
    throw new CatalogInvalidError(`SUBSET_CATALOG_URL is not a URL: ${text}`);
  }
  const allowed = overridden ? ['https:', 'file:'] : ['https:'];
  if (!allowed.includes(url.protocol)) throw new CatalogInvalidError(`SUBSET_CATALOG_URL must be an https: or file: URL, not ${url.protocol}`);
  if (url.username !== '' || url.password !== '') throw new CatalogInvalidError('SUBSET_CATALOG_URL must not contain a user name or password');
  return url;
}

/** Where the fetched feed is cached: ~/Library/Caches/Subset on macOS, the XDG cache on Linux, LocalAppData on Windows. */
export function cacheFile({ platform, env, home }) {
  if (platform === 'darwin') return path.join(home, 'Library', 'Caches', 'Subset', 'catalog.json');
  if (platform === 'win32') {
    const local = env.LOCALAPPDATA && path.win32.isAbsolute(env.LOCALAPPDATA) ? env.LOCALAPPDATA : path.win32.join(home, 'AppData', 'Local');
    return path.win32.join(local, 'Subset', 'Cache', 'catalog.json');
  }
  const xdg = env.XDG_CACHE_HOME && path.posix.isAbsolute(env.XDG_CACHE_HOME) ? env.XDG_CACHE_HOME : path.posix.join(home, '.cache');
  return path.posix.join(xdg, 'subset', 'catalog.json');
}

/**
 * Reads at most `limit + 1` bytes of a regular file, so an oversized one is known to be too large without reading it
 * all. Anything else (a folder, a named pipe, a device) throws instead of being read, and is opened without waiting
 * for a writer.
 */
export function readBounded(file, limit) {
  const fd = openSync(file, constants.O_RDONLY | (constants.O_NONBLOCK ?? 0));
  try {
    if (!fstatSync(fd).isFile()) throw Object.assign(new Error(`${file} is not a file`), { code: 'ENOTFILE' });
    const buffer = Buffer.alloc(limit + 1);
    let size = 0;
    while (size < buffer.length) {
      const read = readSync(fd, buffer, size, buffer.length - size, null);
      if (read === 0) break;
      size += read;
    }
    return buffer.subarray(0, size);
  } finally {
    closeSync(fd);
  }
}

// The feed's bytes, at most MAX_FEED_BYTES + 1 of them. https: fetches refuse redirects and time out after 20 s.
async function download(url, fetchImpl) {
  if (url.protocol === 'file:') {
    try {
      return readBounded(fileURLToPath(url), MAX_FEED_BYTES);
    } catch (error) {
      throw new CatalogUnavailableError(error.code ?? error.message);
    }
  }
  let response;
  try {
    response = await fetchImpl(url, { redirect: 'error', signal: AbortSignal.timeout(FETCH_TIMEOUT_MS), headers: { accept: 'application/json' } });
  } catch (error) {
    throw new CatalogUnavailableError(networkReason(error));
  }
  if (!response.ok) {
    await response.body?.cancel().catch(() => {});
    throw new CatalogUnavailableError(`HTTP ${response.status}`);
  }
  const chunks = [];
  let size = 0;
  try {
    for await (const chunk of response.body ?? []) {
      chunks.push(chunk);
      size += chunk.byteLength;
      if (size > MAX_FEED_BYTES) {
        await response.body.cancel().catch(() => {});
        break;
      }
    }
  } catch (error) {
    throw new CatalogUnavailableError(networkReason(error));
  }
  return Buffer.concat(chunks);
}

function networkReason(error) {
  if (error?.name === 'TimeoutError') return `no answer within ${FETCH_TIMEOUT_MS / 1000} seconds`;
  const cause = error?.cause;
  return cause?.code ?? cause?.message ?? error?.message ?? String(error);
}

// The cached feed for `url`: { feed, fetchedAt } or undefined when there is none, it is for another URL, or it is
// unreadable, invalid or dated in the future (it is then simply not used).
function readCache(file, url, now) {
  let entry;
  try {
    const bytes = readBounded(file, MAX_CACHE_BYTES);
    if (bytes.byteLength > MAX_CACHE_BYTES) return undefined;
    entry = JSON.parse(bytes.toString('utf8'));
  } catch {
    return undefined;
  }
  if (entry?.schema !== CACHE_SCHEMA || entry.url !== url.href || typeof entry.body !== 'string' || typeof entry.fetchedAt !== 'string') return undefined;
  const fetchedAt = Date.parse(entry.fetchedAt);
  if (!Number.isFinite(fetchedAt) || fetchedAt > now) return undefined;
  const { feed } = parseFeed(Buffer.from(entry.body, 'utf8'));
  return feed ? { feed, fetchedAt } : undefined;
}

// Replaces the cached copy atomically (a uniquely named temporary file renamed over it). The cache is best-effort: when
// its folder cannot be made or written (not a folder, no permission, a full disk) nothing is thrown, the temporary file
// is removed if it can be, and the next run fetches again.
function writeCache(file, url, bytes, now) {
  const temporary = `${file}.${process.pid}.${randomBytes(4).toString('hex')}.tmp`;
  try {
    mkdirSync(path.dirname(file), { recursive: true });
    const entry = { schema: CACHE_SCHEMA, url: url.href, fetchedAt: new Date(now).toISOString(), body: bytes.toString('utf8') };
    writeFileSync(temporary, JSON.stringify(entry), { mode: 0o600 });
    renameSync(temporary, file);
  } catch {
    try {
      rmSync(temporary, { force: true });
    } catch {
      // The temporary file cannot be removed either (its folder is not a folder or not writable): leave it.
    }
  }
}

/** A duration as people say it: 42 seconds, 5 minutes, 3 hours, 2 days. */
export function age(ms) {
  const units = [['day', 86_400_000], ['hour', 3_600_000], ['minute', 60_000], ['second', 1000]];
  const [unit, size] = units.find(([, unitSize]) => ms >= unitSize) ?? units.at(-1);
  const count = Math.floor(ms / size);
  return `${count} ${unit}${count === 1 ? '' : 's'}`;
}

/**
 * The catalog feed, from the cache when it is younger than 5 minutes (unless `refresh`), otherwise fetched, validated
 * and cached. When it cannot be fetched (and `refresh` is not set), a cached copy younger than 7 days is used with a
 * warning. Returns { feed, url, fetchedAt, cached, warning? }; throws a CatalogInvalidError or a
 * CatalogUnavailableError with the message to show.
 */
export async function loadCatalog({ env, platform, home, refresh = false, now = Date.now(), fetch: fetchImpl = globalThis.fetch }) {
  const url = catalogUrl(env);
  const file = cacheFile({ platform, env, home });
  const cached = refresh ? undefined : readCache(file, url, now);
  if (cached && now - cached.fetchedAt < FRESH_MS) return { feed: cached.feed, url: url.href, fetchedAt: cached.fetchedAt, cached: true };
  let bytes;
  try {
    bytes = await download(url, fetchImpl);
  } catch (error) {
    if (!(error instanceof CatalogUnavailableError)) throw error;
    const reason = `could not fetch the catalog from ${url.href} (${error.message})`;
    if (cached && now - cached.fetchedAt < STALE_LIMIT_MS) {
      const warning = `${reason}; using the copy cached ${age(now - cached.fetchedAt)} ago.`;
      return { feed: cached.feed, url: url.href, fetchedAt: cached.fetchedAt, cached: true, warning };
    }
    if (cached) throw new CatalogUnavailableError(`${reason}, and the cached copy is ${age(now - cached.fetchedAt)} old, more than 7 days.`);
    throw new CatalogUnavailableError(`${reason}${refresh ? '' : ', and there is no cached copy'}.`);
  }
  const { feed, problems } = parseFeed(bytes);
  if (problems) throw new CatalogInvalidError(`the catalog at ${url.href} is not a valid ${CATALOG_SCHEMA} feed, so it is not used:\n  ${problems.join('\n  ')}`);
  writeCache(file, url, bytes, now);
  return { feed, url: url.href, fetchedAt: now, cached: false };
}
