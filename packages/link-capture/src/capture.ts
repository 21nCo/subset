import type { BrowserFacade } from '@extfn/core';
import { canonicalizeUrl, MAX_DOCUMENT_BYTES, MAX_TITLE_LENGTH, parseLinkDetails, type LinkDetailsV1 } from '@subset.dev/links';

/** Most characters (Unicode code points) of selected text kept in a capture. */
export const MAX_SELECTION_LENGTH = 10_000;

/** Most characters of `<html lang>` read from the page; a language tag is far shorter, so a longer value is dropped. */
export const MAX_LANG_LENGTH = 64;

// The shape of a BCP 47 tag, as `parseLinkDetails` checks it; anything else is dropped before it reaches the parser.
const LANGUAGE_TAG = /^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$/;

// Half of a surrogate pair without its other half: not a character, and invalid once the text is sent as UTF-8.
const LONE_SURROGATE = /[\uD800-\uDBFF](?![\uDC00-\uDFFF])|(?<![\uD800-\uDBFF])[\uDC00-\uDFFF]/g;

/** Fields every capture has. */
interface CaptureBase {
  /** The page or link URL, without any `user:password@`. */
  url: string;
  /** `canonicalizeUrl(url)` from `@subset.dev/links`. */
  canonicalUrl: string;
  /** The tab title or link text, whitespace collapsed; the URL when there is none. At most `MAX_TITLE_LENGTH` characters. */
  title: string;
  /** Text selected on the page, trimmed; omitted when nothing is selected. At most `MAX_SELECTION_LENGTH` characters. */
  selectionText?: string;
  /** ISO 8601 time of the capture. */
  capturedAt: string;
}

/** The current tab, read on a user action: `details` were parsed from the page's `<head>` in the extension. */
export interface TabCapture extends CaptureBase {
  source: 'tab';
  details: LinkDetailsV1;
}

/** A link from the context menu: the page behind it was not opened, so its details are left to the server. */
export interface LinkCapture extends CaptureBase {
  source: 'link';
}

export type Capture = TabCapture | LinkCapture;

export type LinkCaptureErrorCode =
  /** No active tab, or the tab has no id. */
  | 'no-active-tab'
  /** The tab or link is not an http or https page (a browser page, a file, a `javascript:` link). */
  | 'unsupported-page'
  /** The browser refused to run the read script (a protected page, a closed tab) or the script returned no snapshot. */
  | 'page-unavailable';

export class LinkCaptureError extends Error {
  readonly code: LinkCaptureErrorCode;

  constructor(code: LinkCaptureErrorCode, options?: { cause?: unknown }) {
    super(`Link capture failed: ${code}`, options);
    this.name = 'LinkCaptureError';
    this.code = code;
  }
}

export interface CaptureOptions {
  /** The capture time; defaults to the current time. */
  now?: () => Date;
}

/** What `readPage` returns from the tab. */
export interface PageSnapshot {
  url: string;
  title: string;
  selectionText: string;
  /**
   * `<head>` with each child element that fits (`outerHTML`), at most `MAX_DOCUMENT_BYTES` of UTF-8, cut without
   * splitting a character. A child too large for what is left (a big inline script) is skipped unserialized.
   */
  html: string;
  /** `<html lang>`, which `parseLinkDetails` reads but which is outside `<head>`; at most `MAX_LANG_LENGTH` + 1 characters. */
  lang: string;
  /** `document.contentType`, for example `text/html` or `image/png`. */
  contentType: string;
}

/**
 * Runs inside the tab through `scripting.executeScript`. The browser serializes the function's source, so it uses only
 * its arguments and the page's globals, never this module's imports or constants.
 */
export function readPage(maxHeadBytes: number, maxTextLength: number, maxLangLength: number): PageSnapshot {
  // An SVG or XML document (an image, a feed, a sitemap) has no <head> and its root is not an HTMLElement, so it has no
  // `lang` property: every read is checked rather than assumed, and such a page still gives its URL and type.
  // A cut that would end in the first half of a surrogate pair drops that half, so no character is split.
  const text = (value: unknown, max: number) => {
    if (typeof value !== 'string') return '';
    const cut = value.slice(0, max);
    return cut.length < value.length && /[\uD800-\uDBFF]$/.test(cut) ? cut.slice(0, -1) : cut;
  };
  // The head is never serialized whole. Each child element's size is first estimated from its tag, attribute and text
  // lengths, stopping as soon as it passes the room left, and only a child that fits is serialized; `work` caps the
  // nodes and characters looked at across all children. So time and memory stay near maxHeadBytes however large the
  // head is, and tags after a skipped child are still read.
  let work = 2 * maxHeadBytes;
  const size = (root: Node, limit: number): number => {
    let total = 0;
    for (let node: Node | null = root; node; ) {
      let cost = 1;
      if (node.nodeType === 1) {
        const { localName, attributes } = node as Element;
        cost += 2 * localName.length + 5;
        // A template's content is serialized but is not among its child nodes, so its size is unknown.
        if (localName === 'template') return Infinity;
        for (let index = 0; index < attributes.length && cost <= limit; index++) {
          cost += attributes[index].name.length + attributes[index].value.length + 4;
        }
      } else if (node.nodeType === 3 || node.nodeType === 4 || node.nodeType === 8) {
        cost += (node as CharacterData).length + 11;
      }
      // A length is read in constant time, so only the part within the limit counts as work.
      work -= Math.min(cost, limit - total + 1);
      total += cost;
      if (total > limit || work < 0) return Infinity;
      // Depth first, never leaving `root`.
      let next: Node | null = node.firstChild;
      for (let at: Node | null = node; !next && at && at !== root; at = at.parentNode) next = at.nextSibling;
      node = next;
    }
    return total;
  };
  const parts: string[] = [];
  let left = maxHeadBytes - '<head></head>'.length;
  for (let child = document.head?.firstElementChild ?? null; child && left > 0 && work > 0; child = child.nextElementSibling) {
    work--;
    if (size(child, left) > left) continue;
    const html = text(child.outerHTML, Infinity);
    parts.push(html);
    left -= html.length;
  }
  const head = document.head ? `<head>${parts.join('')}</head>` : '';
  // encodeInto stops before a character that does not fit, so the cut never splits one; `read` counts UTF-16 units.
  const { read } = new TextEncoder().encodeInto(head, new Uint8Array(maxHeadBytes));
  const selection = typeof window.getSelection === 'function' ? window.getSelection() : null;
  const root = document.documentElement as { lang?: unknown } | null;
  return {
    url: location.href,
    // A code point is at most two UTF-16 units, so this keeps every character the extension may keep, and no more.
    title: text(document.title, maxTextLength * 2),
    selectionText: text(selection ? selection.toString() : '', maxTextLength * 2),
    html: head.slice(0, read),
    // One character past the limit, so the extension can tell a value that was too long from one that fit.
    lang: root ? text(root.lang, maxLangLength + 1) : '',
    contentType: text(document.contentType, Infinity)
  };
}

interface BrowserTab {
  id?: number;
  url?: string;
}

/**
 * Reads the active tab of the current window. Call it from a user action (opening the popup, a command or a menu
 * click), which grants `activeTab` for that tab: no host permission is needed. The page's `<head>` is parsed here, in
 * the extension, with `parseLinkDetails`. Rejects with `LinkCaptureError`.
 */
export async function captureActiveTab(browser: BrowserFacade, options: CaptureOptions = {}): Promise<TabCapture> {
  const tabs = await browser.call<BrowserTab[] | undefined>('tabs.query', { active: true, currentWindow: true });
  const tab = Array.isArray(tabs) ? tabs[0] : undefined;
  if (!tab || typeof tab.id !== 'number') throw new LinkCaptureError('no-active-tab');
  // With activeTab the URL is visible; a browser or file page is refused before trying to inject into it.
  if (typeof tab.url === 'string' && pageUrl(tab.url) === undefined) throw new LinkCaptureError('unsupported-page');

  let results: unknown;
  try {
    results = await browser.call('scripting.executeScript', {
      target: { tabId: tab.id },
      func: readPage,
      args: [MAX_DOCUMENT_BYTES, MAX_SELECTION_LENGTH, MAX_LANG_LENGTH]
    });
  } catch (error) {
    throw new LinkCaptureError('page-unavailable', { cause: error });
  }
  const snapshot = toSnapshot(Array.isArray(results) ? (results[0] as { result?: unknown } | undefined)?.result : undefined);
  if (!snapshot) throw new LinkCaptureError('page-unavailable');
  // The document URL, not the tab's, so a page that changed its address since the tab updated is saved as shown.
  const url = pageUrl(snapshot.url);
  if (url === undefined) throw new LinkCaptureError('unsupported-page');

  // `parseLinkDetails` reads the first MAX_DOCUMENT_BYTES, so the (ASCII) wrapper comes out of the head's share.
  const open = `<html lang="${languageTag(snapshot.lang)}">`;
  const close = '</html>';
  const head = cutUtf8(snapshot.html, MAX_DOCUMENT_BYTES - open.length - close.length);
  const html = `${open}${head}${close}`;
  const details = parseLinkDetails(html, { url, contentType: snapshot.contentType || undefined });
  const selectionText = truncate(wellFormed(snapshot.selectionText).trim(), MAX_SELECTION_LENGTH).trim();
  return {
    source: 'tab',
    url,
    canonicalUrl: canonicalizeUrl(url),
    title: cleanTitle(snapshot.title) || details.title || truncate(url, MAX_TITLE_LENGTH),
    ...(selectionText ? { selectionText } : {}),
    details,
    capturedAt: (options.now?.() ?? new Date()).toISOString()
  };
}

/**
 * A link from the context menu (`info.linkUrl`, plus `info.linkText` where the browser gives it). The page is not
 * opened, so the capture has no details: the save target's server reads them. Throws `LinkCaptureError`
 * `unsupported-page` for a link that is not http or https.
 */
export function captureLink(url: string, linkText?: string, options: CaptureOptions = {}): LinkCapture {
  const linkUrl = typeof url === 'string' ? pageUrl(url) : undefined;
  if (linkUrl === undefined) throw new LinkCaptureError('unsupported-page');
  return {
    source: 'link',
    url: linkUrl,
    canonicalUrl: canonicalizeUrl(linkUrl),
    title: (typeof linkText === 'string' ? cleanTitle(linkText) : '') || truncate(linkUrl, MAX_TITLE_LENGTH),
    capturedAt: (options.now?.() ?? new Date()).toISOString()
  };
}

/** The URL without credentials when it is absolute http(s), otherwise undefined. */
function pageUrl(value: string): string | undefined {
  let parsed: URL;
  try {
    parsed = new URL(value);
  } catch {
    return undefined;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return undefined;
  parsed.username = '';
  parsed.password = '';
  return parsed.href;
}

function toSnapshot(value: unknown): PageSnapshot | undefined {
  if (typeof value !== 'object' || value === null) return undefined;
  const record = value as Record<string, unknown>;
  const keys = ['url', 'title', 'selectionText', 'html', 'lang', 'contentType'] as const;
  if (!keys.every((key) => typeof record[key] === 'string')) return undefined;
  return Object.fromEntries(keys.map((key) => [key, record[key]])) as unknown as PageSnapshot;
}

function cleanTitle(value: string): string {
  return truncate(wellFormed(value).replace(/\s+/g, ' ').trim(), MAX_TITLE_LENGTH).trim();
}

/** `value` without lone surrogates, which a page may send (or a cut may leave), so every later cut is between characters. */
function wellFormed(value: string): string {
  return value.replace(LONE_SURROGATE, '');
}

/** The first `max` code points of a well-formed `value`. */
function truncate(value: string, max: number): string {
  if (value.length <= max) return value;
  let end = 0;
  for (let count = 0; count < max && end < value.length; count++) end += value.codePointAt(end)! > 0xffff ? 2 : 1;
  return value.slice(0, end);
}

/** The page returns at most `maxBytes`; this keeps a misbehaving page from sending more to the parser. */
function cutUtf8(value: string, maxBytes: number): string {
  if (value.length * 3 <= maxBytes) return value;
  const { read } = new TextEncoder().encodeInto(value, new Uint8Array(maxBytes));
  return value.slice(0, read);
}

/** The page's `lang` when it is a language tag, otherwise empty: a long or odd value (markup, quotes) is dropped. */
function languageTag(value: string): string {
  const tag = value.trim();
  return tag.length <= MAX_LANG_LENGTH && LANGUAGE_TAG.test(tag) ? tag : '';
}
