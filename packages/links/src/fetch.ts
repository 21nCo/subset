import { isBlockedAddress, isBlockedHostname, isIpAddress } from './address.js';
import { parseHttpUrl } from './canonicalize.js';
import { MAX_DOCUMENT_BYTES, parseContentType } from './decode.js';
import { MAX_TITLE_LENGTH, type LinkDetailsV1 } from './details.js';
import { parseLinkDetails } from './parse.js';

// Kept equal to package.json by test/fetch.test.mjs.
const VERSION = '0.1.0';
/** The User-Agent sent when the caller passes none. */
export const DEFAULT_USER_AGENT = `SubsetLinks/${VERSION} (+https://subset.dev)`;

/** Why a fetch failed. `unsupported_type` comes only from `fetchResource`. */
export type LinkFetchErrorCode =
  | 'invalid_url'
  | 'blocked_address'
  | 'blocked_port'
  | 'timeout'
  | 'too_many_redirects'
  | 'http_status'
  | 'too_large'
  | 'network'
  | 'unsupported_type';

/** The error `fetchLinkDetails` and `fetchResource` reject with. */
export class LinkFetchError extends Error {
  readonly code: LinkFetchErrorCode;
  /** The HTTP status, for `http_status`. */
  readonly status?: number;
  /** The URL being fetched when the error happened, without credentials. Absent for `invalid_url` on the input. */
  readonly url?: string;

  constructor(code: LinkFetchErrorCode, message: string, details: { status?: number; url?: string; cause?: unknown } = {}) {
    super(message, details.cause === undefined ? undefined : { cause: details.cause });
    this.name = 'LinkFetchError';
    this.code = code;
    if (details.status !== undefined) this.status = details.status;
    if (details.url !== undefined) this.url = details.url;
  }
}

/**
 * The subset of the web `fetch` the fetcher calls. It must honour `redirect: 'manual'`: a response it reached by
 * following a redirect itself is refused with `network`, because the hops it followed were never checked.
 */
export type FetchFunction = (input: string, init: RequestInit) => Promise<Response>;
/**
 * Resolves a hostname to its IP addresses, for example with Node's `dns.lookup(hostname, { all: true })`.
 * This is a check before each request only: `fetch` resolves the name again when it connects, so it does not
 * stop DNS rebinding. A Node host that needs that pins the connection too, for example with an undici `Agent`
 * whose `connect.lookup` rejects any address for which `isBlockedAddress` is true, on every redirect hop.
 */
export type ResolveHost = (hostname: string) => readonly string[] | Promise<readonly string[]>;

export interface SafeFetchOptions {
  /** Defaults to the global `fetch`. */
  fetch?: FetchFunction;
  /**
   * When given, every address it returns for a hostname is checked before that hostname is fetched. A check
   * before the request only, not a defense against DNS rebinding: see `ResolveHost`.
   */
  resolveHost?: ResolveHost;
  /**
   * Limit for the whole operation, redirects, resolution and body included, even when every step is ready at once.
   * Defaults to 5,000 ms; at most 2,147,483,647.
   */
  timeoutMs?: number;
  /**
   * Most body bytes kept. The stream is cancelled once the bound is reached, so the last read may have received
   * part of a chunk beyond it, which is dropped. `fetchLinkDetails` keeps at most the smaller of this and
   * `MAX_DOCUMENT_BYTES`, the part `parseLinkDetails` parses, and stops once the body fills that bound, counting it
   * as a cut.
   */
  maxBytes?: number;
  /** Most redirects followed. Defaults to 5. */
  maxRedirects?: number;
  /** Defaults to `DEFAULT_USER_AGENT`. */
  userAgent?: string;
  /** Ports allowed besides 80 and 443. */
  allowPorts?: readonly number[];
}

/** `maxBytes` defaults to 2,000,000. */
export type FetchLinkDetailsOptions = SafeFetchOptions;

export interface FetchResourceOptions extends SafeFetchOptions {
  /** Accepted media ranges, such as `image/png` or `image/*`. Sent as the Accept header. Defaults to any type. */
  accept?: readonly string[];
}

export interface FetchedResource {
  /** The resource's URL after redirects, without credentials. */
  url: string;
  /** Media type without parameters; `application/octet-stream` when the response declares none. */
  contentType: string;
  bytes: Uint8Array;
}

const DEFAULT_TIMEOUT_MS = 5000;
const MAX_TIMEOUT_MS = 2_147_483_647;
const DEFAULT_MAX_BYTES = 2_000_000;
const DEFAULT_MAX_REDIRECTS = 5;
const HTML_ACCEPT = 'text/html,application/xhtml+xml;q=0.9,*/*;q=0.8';
const HTML_TYPES = new Set(['text/html', 'application/xhtml+xml']);
const REDIRECT_STATUSES = new Set([301, 302, 303, 307, 308]);
// How many hops and body reads run between two yields to the event loop.
const YIELD_EVERY_STEPS = 16;
// First size of the buffer a body is copied into; it doubles as needed, up to the byte limit.
const INITIAL_BODY_BYTES = 64 * 1024;
const MEDIA_RANGE = /^(?:\*\/\*|[a-z0-9!#$%&'*+.^_`|~-]+\/(?:\*|[a-z0-9!#$%&'*+.^_`|~-]+))$/;
// Details fields a document can supply besides the URL, content type and fallback icon.
const BASE_KEYS = new Set(['version', 'url', 'icons', 'contentType']);

interface Settings {
  fetch: FetchFunction;
  resolveHost?: ResolveHost;
  timeoutMs: number;
  maxBytes: number;
  maxRedirects: number;
  userAgent: string;
  allowPorts: ReadonlySet<number>;
}

/**
 * Fetches an http(s) page and reads its link details. Every hop, including each redirect, is checked
 * against the blocked hostnames, addresses and ports before any request is made to it, and against the
 * addresses `resolveHost` returns when it is given. HTML is parsed with `parseLinkDetails`; another media
 * type yields the URL, content type and a title from the file name, without reading the body. Rejects with
 * `LinkFetchError`, or with a `TypeError` or `RangeError` for invalid options.
 */
export async function fetchLinkDetails(input: string | URL, options: FetchLinkDetailsOptions = {}): Promise<LinkDetailsV1> {
  const settings = settle(options);
  const deadline = new Deadline(settings.timeoutMs);
  try {
    const { response, url } = await open(input, settings, HTML_ACCEPT, deadline);
    const header = response.headers.get('content-type') ?? undefined;
    const contentType = parseContentType(header);
    // A missing or malformed Content-Type is read as HTML, as parseLinkDetails does.
    if (contentType && !HTML_TYPES.has(contentType.essence)) {
      discard(response);
      const details = fileDetails(url, contentType.essence);
      deadline.check(url);
      return details;
    }
    // Bytes past MAX_DOCUMENT_BYTES are never parsed, so they are not read. Stops at the bound without waiting
    // for more, so a body that fills it counts as cut.
    const limit = Math.min(settings.maxBytes, MAX_DOCUMENT_BYTES);
    const { bytes, truncated } = await readBody(response, limit, url, deadline, true);
    const details = parseLinkDetails(bytes, { url, contentType: header });
    deadline.check(url);
    if (truncated && !hasDocumentDetails(details, url)) {
      throw new LinkFetchError('too_large', `The body reaches ${limit} bytes and its start has no link details`, { url: url.href });
    }
    return details;
  } finally {
    deadline.clear();
  }
}

/**
 * Fetches a resource such as an icon with the same address, redirect and time checks as `fetchLinkDetails`.
 * Rejects with `unsupported_type` when the media type matches no `accept` range and with `too_large` when
 * the body exceeds `maxBytes` (default 2,000,000).
 */
export async function fetchResource(input: string | URL, options: FetchResourceOptions = {}): Promise<FetchedResource> {
  const settings = settle(options);
  const accept = mediaRanges(options.accept);
  const deadline = new Deadline(settings.timeoutMs);
  try {
    const { response, url } = await open(input, settings, accept.join(', '), deadline);
    const contentType = parseContentType(response.headers.get('content-type') ?? undefined)?.essence ?? 'application/octet-stream';
    if (!accept.some((range) => matchesRange(range, contentType))) {
      discard(response);
      throw new LinkFetchError('unsupported_type', `The response type ${contentType} is not accepted`, { url: url.href });
    }
    const tooLarge = () => new LinkFetchError('too_large', `The body exceeds ${settings.maxBytes} bytes`, { url: url.href });
    // A declared length over the limit fails before any of the body is read.
    if (Number(response.headers.get('content-length') ?? Number.NaN) > settings.maxBytes) {
      discard(response);
      throw tooLarge();
    }
    const { bytes, truncated } = await readBody(response, settings.maxBytes, url, deadline, false);
    deadline.check(url);
    if (truncated) throw tooLarge();
    return { url: url.href, contentType, bytes };
  } finally {
    deadline.clear();
  }
}

/** Requests `input`, following redirects manually and checking every hop, until a 2xx response. */
async function open(input: string | URL, settings: Settings, accept: string, deadline: Deadline): Promise<{ response: Response; url: URL }> {
  let url = target(input);
  for (let redirects = 0; ; redirects++) {
    await deadline.step(url);
    await check(url, settings, deadline);
    let response: Response;
    let pending: Promise<Response> | undefined;
    // Called without a receiver: a runtime's own fetch throws "Illegal invocation" when `this` is settings.
    const fetchFunction = settings.fetch;
    try {
      pending = fetchFunction(url.href, {
        method: 'GET',
        headers: { accept, 'user-agent': settings.userAgent },
        redirect: 'manual',
        credentials: 'omit',
        signal: deadline.signal
      });
      response = await deadline.race(pending, url);
    } catch (error) {
      // When the deadline wins, a response that still arrives is released rather than left open.
      Promise.resolve(pending).then((late) => late && discard(late), () => {});
      throw failure(error, deadline, url);
    }
    // A browser's fetch hides a manual redirect's Location, so the next hop cannot be checked.
    if (response.type === 'opaqueredirect') {
      throw new LinkFetchError('network', 'The runtime hides redirect targets, so the redirect cannot be checked', { url: url.href });
    }
    if (followedRedirect(response, url)) {
      discard(response);
      throw new LinkFetchError('network', 'The fetch followed a redirect itself, so its hops cannot be checked', { url: url.href });
    }
    const location = REDIRECT_STATUSES.has(response.status) ? response.headers.get('location') : null;
    if (location !== null) {
      discard(response);
      if (redirects >= settings.maxRedirects) {
        throw new LinkFetchError('too_many_redirects', `More than ${settings.maxRedirects} redirects`, { url: url.href });
      }
      url = target(location, url);
      continue;
    }
    if (response.status < 200 || response.status > 299) {
      discard(response);
      throw new LinkFetchError('http_status', `The server answered ${response.status}`, { status: response.status, url: url.href });
    }
    return { response, url };
  }
}

/**
 * Whether `fetch` ignored `redirect: 'manual'` and answered from another URL. A response URL never has a fragment,
 * so the requested URL is compared without one; a response URL that does not parse counts as followed.
 */
function followedRedirect(response: Response, url: URL): boolean {
  if (response.redirected === true) return true;
  const responseUrl: unknown = response.url;
  if (responseUrl === undefined || responseUrl === '') return false;
  if (typeof responseUrl !== 'string') return true;
  let actual: URL;
  try {
    actual = new URL(responseUrl);
  } catch {
    return true;
  }
  const requested = new URL(url.href);
  actual.hash = '';
  requested.hash = '';
  return actual.href !== requested.href;
}

/** Parses a URL (relative to `base` for a redirect), removing any credentials so they are never sent. */
function target(input: string | URL, base?: URL): URL {
  let url: URL;
  try {
    url = parseHttpUrl(input, base);
  } catch (error) {
    throw new LinkFetchError('invalid_url', base ? 'The redirect target is not an http or https URL' : 'Expected an absolute http or https URL', {
      url: base?.href,
      cause: error
    });
  }
  url.username = '';
  url.password = '';
  return url;
}

async function check(url: URL, settings: Settings, deadline: Deadline): Promise<void> {
  const hostname = url.hostname;
  const literal = isIpAddress(hostname);
  if (literal ? isBlockedAddress(hostname) : isBlockedHostname(hostname)) {
    throw new LinkFetchError('blocked_address', `${hostname} is a private or reserved address`, { url: url.href });
  }
  const port = url.port ? Number(url.port) : url.protocol === 'https:' ? 443 : 80;
  if (port !== 80 && port !== 443 && !settings.allowPorts.has(port)) {
    throw new LinkFetchError('blocked_port', `Port ${port} is not allowed`, { url: url.href });
  }
  if (literal || !settings.resolveHost) return;
  const resolveHost = settings.resolveHost;
  let addresses: readonly string[];
  try {
    addresses = await deadline.race(Promise.resolve().then(() => resolveHost(hostname)), url);
  } catch (error) {
    throw failure(error, deadline, url);
  }
  if (!Array.isArray(addresses) || addresses.length === 0) {
    throw new LinkFetchError('network', `${hostname} did not resolve to any address`, { url: url.href });
  }
  // A value that is not an address string counts as blocked. Every index is read, so a hole is checked too.
  for (let index = 0; index < addresses.length; index++) {
    const address: unknown = addresses[index];
    if (typeof address === 'string' && !isBlockedAddress(address)) continue;
    throw new LinkFetchError('blocked_address', `${hostname} resolves to a private or reserved address`, { url: url.href });
  }
}

/**
 * Keeps at most `maxBytes` of the body, then cancels the stream; the read that passes the bound may have
 * received the rest of its chunk, which is dropped. With `stopAtLimit`, reading stops as soon as the body fills
 * `maxBytes` and that counts as truncated; without it, one more read tells a body of exactly `maxBytes` from a
 * larger one. Each chunk is copied into one buffer that grows up to `maxBytes`, so memory follows the bytes
 * kept, not the number of reads.
 */
async function readBody(
  response: Response,
  maxBytes: number,
  url: URL,
  deadline: Deadline,
  stopAtLimit: boolean
): Promise<{ bytes: Uint8Array; truncated: boolean }> {
  let buffer = new Uint8Array(0);
  let total = 0;
  let truncated = false;
  let done = false;
  const reader = response.body?.getReader();
  if (!reader) return { bytes: buffer, truncated };
  try {
    while (!done) {
      await deadline.step(url);
      const next = await deadline.race(reader.read(), url);
      done = next.done;
      if (next.done) break;
      const kept = Math.min(next.value.byteLength, maxBytes - total);
      if (total + kept > buffer.byteLength) {
        const grown = new Uint8Array(Math.min(maxBytes, Math.max(total + kept, buffer.byteLength * 2, INITIAL_BODY_BYTES)));
        grown.set(buffer.subarray(0, total));
        buffer = grown;
      }
      buffer.set(next.value.subarray(0, kept), total);
      total += kept;
      if (kept < next.value.byteLength || (stopAtLimit && total === maxBytes)) {
        truncated = true;
        break;
      }
    }
  } catch (error) {
    throw failure(error, deadline, url);
  } finally {
    if (!done) reader.cancel().catch(() => {});
  }
  return { bytes: total === buffer.byteLength ? buffer : buffer.slice(0, total), truncated };
}

/** Releases a body that will not be read. */
function discard(response: Response): void {
  try {
    response.body?.cancel().catch(() => {});
  } catch {
    // An already locked or consumed body needs no release.
  }
}

/** The record for a non-HTML response: URL, content type, fallback icon and the file name as title. */
function fileDetails(url: URL, contentType: string): LinkDetailsV1 {
  const base = parseLinkDetails('', { url, contentType });
  const title = fileName(url);
  return title ? { version: 1, url: base.url, title, icons: base.icons, contentType: base.contentType } : base;
}

function fileName(url: URL): string | undefined {
  const segment = url.pathname.slice(url.pathname.lastIndexOf('/') + 1);
  let name: string;
  try {
    name = decodeURIComponent(segment);
  } catch {
    name = segment;
  }
  name = name.replace(/\s+/g, ' ').trim();
  return name ? [...name].slice(0, MAX_TITLE_LENGTH).join('') : undefined;
}

/** Whether the document supplied anything beyond the URL, content type and fallback icon. */
function hasDocumentDetails(details: LinkDetailsV1, url: URL): boolean {
  if (Object.keys(details).some((key) => !BASE_KEYS.has(key))) return true;
  const fallback = new URL('/favicon.ico', url).href;
  return details.icons.some((icon) => icon.url !== fallback || icon.rel !== 'icon' || icon.sizes !== undefined || icon.type !== undefined);
}

function matchesRange(range: string, type: string): boolean {
  if (range === '*/*') return true;
  return range.endsWith('/*') ? type.startsWith(range.slice(0, -1)) : type === range;
}

function failure(error: unknown, deadline: Deadline, url: URL): LinkFetchError {
  if (deadline.expired) return deadline.error(url);
  if (error instanceof LinkFetchError) return error;
  return new LinkFetchError('network', error instanceof Error ? error.message : 'The request failed', { url: url.href, cause: error });
}

/**
 * The time limit of one operation. It throws `timeout` from `step`, `race` and `check` once `timeoutMs` has
 * passed, judged by the clock rather than by its timer alone, and aborts the signal. `race` also rejects work
 * that settles after the limit, so a late response, read or resolution is never used. `step` yields to timers
 * and other tasks every few calls, so reads that are always ready can neither outlast the limit nor hold the
 * event loop. `race` keeps one subscription per pending call and drops it when the work settles.
 */
class Deadline {
  readonly signal: AbortSignal;
  private readonly controller = new AbortController();
  private readonly started = performance.now();
  private readonly waiters = new Set<() => void>();
  private readonly timer: ReturnType<typeof setTimeout>;
  private readonly timeoutMs: number;
  private ended = false;
  private steps = 0;

  constructor(timeoutMs: number) {
    this.timeoutMs = timeoutMs;
    this.signal = this.controller.signal;
    this.timer = setTimeout(() => this.expire(), timeoutMs);
  }

  get expired(): boolean {
    if (!this.ended && performance.now() - this.started >= this.timeoutMs) this.expire();
    return this.ended;
  }

  /** Called before each hop and each body read. */
  async step(url: URL): Promise<void> {
    this.check(url);
    if (++this.steps % YIELD_EVERY_STEPS === 0) {
      await new Promise((resolve) => setTimeout(resolve, 0));
      this.check(url);
    }
  }

  /**
   * Settles as `work` does, or rejects with `timeout` when the time is up first or when `work` settles after it,
   * whether or not `work` honours the signal. `work` is observed before anything else, so its later rejection is
   * never left unhandled.
   */
  race<T>(work: Promise<T>, url: URL): Promise<T> {
    return new Promise<T>((resolve, reject) => {
      const expire = () => reject(this.error(url));
      Promise.resolve(work).then(
        (value) => {
          this.waiters.delete(expire);
          if (this.expired) reject(this.error(url));
          else resolve(value);
        },
        (error: unknown) => {
          this.waiters.delete(expire);
          reject(this.expired ? this.error(url) : error);
        }
      );
      if (this.expired) expire();
      else this.waiters.add(expire);
    });
  }

  /** Throws `timeout` once the time is up; called before an operation returns its result. */
  check(url: URL): void {
    if (this.expired) throw this.error(url);
  }

  error(url: URL): LinkFetchError {
    return new LinkFetchError('timeout', `No complete response within ${this.timeoutMs} ms`, { url: url.href });
  }

  clear(): void {
    clearTimeout(this.timer);
    this.waiters.clear();
  }

  private expire(): void {
    if (this.ended) return;
    this.ended = true;
    clearTimeout(this.timer);
    this.controller.abort();
    for (const waiter of this.waiters) waiter();
    this.waiters.clear();
  }
}

function settle(options: SafeFetchOptions): Settings {
  if (typeof options !== 'object' || options === null) throw new TypeError('Expected an options object');
  const fetchFunction = options.fetch ?? globalFetch();
  if (typeof fetchFunction !== 'function') throw new TypeError('options.fetch must be a function');
  if (options.resolveHost !== undefined && typeof options.resolveHost !== 'function') throw new TypeError('options.resolveHost must be a function');
  const timeoutMs = options.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  // setTimeout fires at once for a delay above 2^31 - 1 ms.
  if (typeof timeoutMs !== 'number' || !(timeoutMs > 0 && timeoutMs <= MAX_TIMEOUT_MS)) {
    throw new RangeError(`options.timeoutMs must be a positive number up to ${MAX_TIMEOUT_MS}`);
  }
  const maxBytes = options.maxBytes ?? DEFAULT_MAX_BYTES;
  if (!Number.isSafeInteger(maxBytes) || maxBytes < 1) throw new RangeError('options.maxBytes must be a positive integer');
  const maxRedirects = options.maxRedirects ?? DEFAULT_MAX_REDIRECTS;
  if (!Number.isSafeInteger(maxRedirects) || maxRedirects < 0) throw new RangeError('options.maxRedirects must be a non-negative integer');
  const userAgent = options.userAgent ?? DEFAULT_USER_AGENT;
  if (typeof userAgent !== 'string' || userAgent.trim() === '') throw new TypeError('options.userAgent must be a non-empty string');
  const allowPorts = options.allowPorts ?? [];
  if (!Array.isArray(allowPorts) || !allowPorts.every((port) => Number.isInteger(port) && port >= 1 && port <= 65535)) {
    throw new RangeError('options.allowPorts must be port numbers from 1 to 65535');
  }
  return { fetch: fetchFunction, resolveHost: options.resolveHost, timeoutMs, maxBytes, maxRedirects, userAgent, allowPorts: new Set(allowPorts) };
}

function mediaRanges(accept: readonly string[] | undefined): string[] {
  if (accept === undefined) return ['*/*'];
  if (!Array.isArray(accept) || accept.length === 0) throw new TypeError('options.accept must be a non-empty array of media ranges');
  return accept.map((range) => {
    const value = typeof range === 'string' ? range.trim().toLowerCase() : '';
    if (!MEDIA_RANGE.test(value) || (value.startsWith('*/') && value !== '*/*')) throw new TypeError(`options.accept has an invalid media range: ${String(range)}`);
    return value;
  });
}

// Bound so a runtime whose fetch requires `this` to be the global (Workers, browsers) accepts the call.
function globalFetch(): FetchFunction | undefined {
  return typeof globalThis.fetch === 'function' ? (input, init) => globalThis.fetch(input, init) : undefined;
}
