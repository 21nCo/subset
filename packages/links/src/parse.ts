import { canonicalizeUrl, parseHttpUrl } from './canonicalize.js';
import { decodeDocument, parseContentType } from './decode.js';
import {
  isIso8601,
  isLanguageTag,
  MAX_DESCRIPTION_LENGTH,
  MAX_ICONS,
  MAX_TITLE_LENGTH,
  type LinkDetailsV1,
  type LinkIcon,
  type LinkIconRel
} from './details.js';
import { scanHtml } from './tokens.js';

export interface ParseLinkDetailsOptions {
  /** The document's URL, after redirects. Relative URLs in the document resolve against it. */
  url: string | URL;
  /** The response's Content-Type header. Defaults to `text/html`. */
  contentType?: string;
}

const HTML_TYPES = new Set(['text/html', 'application/xhtml+xml']);
// Meta keys whose content is a URL: only an absolute http or https result counts as a value.
const URL_KEYS = new Set(['og:image:secure_url', 'og:image', 'twitter:image']);
const ICON_RANK: Record<LinkIconRel, number> = { icon: 0, 'shortcut icon': 1, 'apple-touch-icon': 2 };

/**
 * Reads link details from the first 512 KB of an HTML document. `html` may be text or the raw response
 * bytes; bytes are decoded using the Content-Type charset or the document's `<meta>` charset. A document
 * that is not HTML yields only the URL, content type and fallback icon. Throws `LinkUrlError` when
 * `options.url` is not an absolute http or https URL.
 */
export function parseLinkDetails(html: string | ArrayBuffer | ArrayBufferView, options: ParseLinkDetailsOptions): LinkDetailsV1 {
  const documentUrl = parseHttpUrl(options.url instanceof URL ? options.url.href : options.url);
  const contentType = parseContentType(options.contentType) ?? { essence: 'text/html' };
  const fallbackIcons: LinkIcon[] = [{ url: new URL('/favicon.ico', documentUrl).href, rel: 'icon' }];
  if (!HTML_TYPES.has(contentType.essence)) {
    return { version: 1, url: documentUrl.href, icons: fallbackIcons, contentType: contentType.essence };
  }

  const found = collect(decodeDocument(html, contentType.charset), documentUrl);
  const meta = (...keys: string[]) => keys.map((key) => found.meta.get(key)).find((value) => value !== undefined);
  // Keys are added in the order LinkDetailsV1 declares them, so serialized records read consistently;
  // icons and contentType are set before the record is returned.
  const details = { version: 1, url: documentUrl.href } as LinkDetailsV1;
  assign(details, 'canonicalUrl', found.canonicalUrl);
  assign(details, 'title', truncate(meta('og:title', 'twitter:title') ?? found.title, MAX_TITLE_LENGTH));
  assign(details, 'description', truncate(meta('og:description', 'twitter:description', 'name:description'), MAX_DESCRIPTION_LENGTH));
  assign(details, 'siteName', meta('og:site_name'));
  assign(details, 'language', found.language);
  assign(details, 'type', meta('og:type'));
  assign(details, 'image', meta('og:image:secure_url', 'og:image', 'twitter:image'));
  details.icons = found.icons.length ? found.icons : fallbackIcons;
  assign(details, 'author', meta('name:author', 'article:author'));
  assign(details, 'publishedTime', meta('article:published_time'));
  details.contentType = contentType.essence;
  return details;
}

interface Found {
  /** First usable value per key. Open Graph, Twitter and article keys come from `property` or `name`; other names are prefixed `name:`. */
  meta: Map<string, string>;
  title?: string;
  language?: string;
  canonicalUrl?: string;
  icons: LinkIcon[];
}

function collect(text: string, documentUrl: URL): Found {
  const meta = new Map<string, string>();
  const iconsByRank: LinkIcon[][] = [[], [], []];
  let title: string | undefined;
  let titleText: string[] | undefined;
  // Only the document's first <title> counts, even when it is empty.
  let sawTitle = false;
  let language: string | undefined;
  let canonicalUrl: string | undefined;
  let sawHtml = false;

  const setMeta = (key: string, content: string) => {
    if (meta.has(key)) return;
    let value = collapse(content);
    if (value && URL_KEYS.has(key)) value = resolveHttpUrl(value, documentUrl);
    else if (value && key === 'article:published_time' && !isIso8601(value)) value = undefined;
    if (value) meta.set(key, value);
  };

  const addIcon = (icons: LinkIcon[], rel: LinkIconRel, href: string, attributes: ReadonlyMap<string, string>) => {
    // A rank never contributes more than MAX_ICONS, so later duplicates cannot be needed.
    if (icons.length >= MAX_ICONS) return;
    const url = resolveHttpUrl(collapse(href), documentUrl);
    if (!url || icons.some((icon) => icon.url === url)) return;
    const icon: LinkIcon = { url, rel };
    assign(icon, 'sizes', collapse(attributes.get('sizes'))?.toLowerCase());
    assign(icon, 'type', collapse(attributes.get('type'))?.toLowerCase());
    icons.push(icon);
  };

  scanHtml(text, {
    attributesOf: new Set(['html', 'meta', 'link']),
    get capturingText() {
      return titleText !== undefined;
    },
    openTag(name, attributes, foreign) {
      switch (name) {
        case 'html':
          if (!sawHtml) language = languageTag(attributes.get('lang'));
          sawHtml = true;
          break;
        case 'title':
          // A <title> inside inline SVG or MathML labels a graphic, not the document.
          if (!sawTitle && !foreign) {
            sawTitle = true;
            titleText = [];
          }
          break;
        case 'meta': {
          const content = attributes.get('content');
          if (content === undefined) break;
          for (const attribute of ['property', 'name'] as const) {
            const key = attributes.get(attribute)?.trim().toLowerCase();
            if (!key) continue;
            if (/^(?:og|twitter|article):/.test(key)) setMeta(key, content);
            else if (attribute === 'name') setMeta(`name:${key}`, content);
          }
          break;
        }
        case 'link': {
          const rel = (attributes.get('rel') ?? '').toLowerCase().split(/[\t\n\f\r ]+/);
          const href = attributes.get('href');
          if (href === undefined) break;
          if (canonicalUrl === undefined && rel.includes('canonical')) canonicalUrl = canonicalHref(href, documentUrl);
          const iconRel: LinkIconRel | undefined = rel.includes('apple-touch-icon')
            ? 'apple-touch-icon'
            : rel.includes('icon')
              ? rel.includes('shortcut') ? 'shortcut icon' : 'icon'
              : undefined;
          if (iconRel) addIcon(iconsByRank[ICON_RANK[iconRel]]!, iconRel, href, attributes);
          break;
        }
      }
    },
    text(data) {
      titleText?.push(data);
    },
    closeTag(name) {
      if (name === 'title' && titleText) {
        title = collapse(titleText.join(''));
        titleText = undefined;
      }
    }
  });

  // An unclosed <title> runs to the end of the parsed text, as in a browser.
  if (titleText) title = collapse(titleText.join(''));

  const icons: LinkIcon[] = [];
  const seen = new Set<string>();
  for (const icon of iconsByRank.flat()) {
    if (seen.has(icon.url)) continue;
    seen.add(icon.url);
    icons.push(icon);
  }
  return { meta, title, language, canonicalUrl, icons: icons.slice(0, MAX_ICONS) };
}

function canonicalHref(href: string, documentUrl: URL): string | undefined {
  const url = resolveHttpUrl(collapse(href), documentUrl);
  return url === undefined ? undefined : canonicalizeUrl(url);
}

function resolveHttpUrl(href: string | undefined, base: URL): string | undefined {
  if (!href) return undefined;
  try {
    return parseHttpUrl(href, base).href;
  } catch {
    return undefined;
  }
}

function languageTag(value: string | undefined): string | undefined {
  const tag = value?.trim();
  return tag && isLanguageTag(tag) ? tag : undefined;
}

/** Collapses runs of whitespace to one space and trims; an empty result is undefined. */
function collapse(value: string | undefined): string | undefined {
  const text = value?.replace(/\s+/gu, ' ').trim();
  return text ? text : undefined;
}

function truncate(value: string | undefined, maxCodePoints: number): string | undefined {
  // A string has at least as many UTF-16 code units as code points.
  if (value === undefined || value.length <= maxCodePoints) return value;
  return Array.from(value).slice(0, maxCodePoints).join('').trimEnd();
}

function assign<T extends object, K extends keyof T>(target: T, key: K, value: T[K] | undefined): void {
  if (value !== undefined) target[key] = value;
}
