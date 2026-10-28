/** Longest `title`, in characters (Unicode code points). */
export const MAX_TITLE_LENGTH = 500;
/** Longest `description`, in characters (Unicode code points). */
export const MAX_DESCRIPTION_LENGTH = 2000;
/** Most icons in one record. */
export const MAX_ICONS = 16;

/** Which `<link rel>` an icon came from. */
export type LinkIconRel = 'icon' | 'shortcut icon' | 'apple-touch-icon';

export interface LinkIcon {
  /** Absolute http or https URL. */
  url: string;
  rel: LinkIconRel;
  /** The `sizes` attribute, whitespace collapsed and lowercased, for example `180x180` or `any`. */
  sizes?: string;
  /** The declared media type, for example `image/png`. */
  type?: string;
}

/** Version 1 of the link details read from one HTML document. Optional fields are omitted when absent. */
export interface LinkDetailsV1 {
  version: 1;
  /** The document URL the details were read from. */
  url: string;
  /** The page's `<link rel=canonical>`, canonicalized with `canonicalizeUrl`. */
  canonicalUrl?: string;
  title?: string;
  description?: string;
  siteName?: string;
  /** The `<html lang>` language tag. */
  language?: string;
  /** The Open Graph type, for example `article`. */
  type?: string;
  /** Absolute http or https URL of the preview image. */
  image?: string;
  /** Declared icons, or the site's `/favicon.ico` when none is declared. */
  icons: LinkIcon[];
  author?: string;
  /** `article:published_time` as written, when it is an ISO 8601 date or date-time (see `isIso8601`). */
  publishedTime?: string;
  /** The document's media type without parameters, for example `text/html`. */
  contentType: string;
}

export type LinkDetails = LinkDetailsV1;

const DETAIL_KEYS = new Set([
  'version',
  'url',
  'canonicalUrl',
  'title',
  'description',
  'siteName',
  'language',
  'type',
  'image',
  'icons',
  'author',
  'publishedTime',
  'contentType'
]);
const OPTIONAL_TEXT_KEYS = ['title', 'description', 'siteName', 'language', 'type', 'author'] as const;
const ICON_KEYS = new Set(['url', 'rel', 'sizes', 'type']);
const ICON_RELS = new Set<string>(['icon', 'shortcut icon', 'apple-touch-icon']);
const MEDIA_TYPE = /^[a-z0-9!#$%&'*+.^_`|~-]+\/[a-z0-9!#$%&'*+.^_`|~-]+$/;
const LANGUAGE_TAG = /^[A-Za-z]{1,8}(?:-[A-Za-z0-9]{1,8})*$/;
// Extended-format ISO 8601: a calendar date, optionally with a time and an offset.
const ISO_8601 = /^(\d{4})-(\d{2})-(\d{2})(?:T(\d{2}):(\d{2})(?::(\d{2})(?:[.,]\d+)?)?(?:Z|[+-](\d{2}):(\d{2}))?)?$/;

/** Runtime check for a `LinkDetailsV1` from an untrusted source, such as storage or another process. */
export function isLinkDetailsV1(value: unknown): value is LinkDetailsV1 {
  if (!isRecord(value) || value.version !== 1) return false;
  for (const key of Object.keys(value)) if (!DETAIL_KEYS.has(key)) return false;
  if (!isHttpUrl(value.url)) return false;
  if (value.canonicalUrl !== undefined && !isHttpUrl(value.canonicalUrl)) return false;
  if (value.image !== undefined && !isHttpUrl(value.image)) return false;
  for (const key of OPTIONAL_TEXT_KEYS) if (value[key] !== undefined && !isText(value[key])) return false;
  if (typeof value.title === 'string' && codePointLength(value.title) > MAX_TITLE_LENGTH) return false;
  if (typeof value.description === 'string' && codePointLength(value.description) > MAX_DESCRIPTION_LENGTH) return false;
  if (value.language !== undefined && !isLanguageTag(value.language)) return false;
  if (value.publishedTime !== undefined && !isIso8601(value.publishedTime)) return false;
  if (typeof value.contentType !== 'string' || !MEDIA_TYPE.test(value.contentType)) return false;
  return Array.isArray(value.icons) && value.icons.length <= MAX_ICONS && everyIcon(value.icons);
}

// Checks every index, so a sparse array (a hole, which `every` would skip) is rejected.
function everyIcon(icons: unknown[]): boolean {
  for (let index = 0; index < icons.length; index++) if (!isLinkIcon(icons[index])) return false;
  return true;
}

function isLinkIcon(value: unknown): value is LinkIcon {
  if (!isRecord(value)) return false;
  for (const key of Object.keys(value)) if (!ICON_KEYS.has(key)) return false;
  return (
    isHttpUrl(value.url) &&
    typeof value.rel === 'string' &&
    ICON_RELS.has(value.rel) &&
    (value.sizes === undefined || isText(value.sizes)) &&
    (value.type === undefined || isText(value.type))
  );
}

/**
 * Whether `value` is an ISO 8601 calendar date or date-time in extended format, with real field values.
 * Leap seconds (second `60`) are rejected, as JavaScript `Date` cannot represent them.
 */
export function isIso8601(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  const match = ISO_8601.exec(value);
  if (!match) return false;
  const [, year, month, day, hour = '0', minute = '0', second = '0', offsetHour = '0', offsetMinute = '0'] = match;
  const date = new Date(0);
  date.setUTCFullYear(Number(year), Number(month) - 1, Number(day));
  return (
    date.getUTCFullYear() === Number(year) &&
    date.getUTCMonth() === Number(month) - 1 &&
    date.getUTCDate() === Number(day) &&
    Number(hour) <= 23 &&
    Number(minute) <= 59 &&
    Number(second) <= 59 &&
    Number(offsetHour) <= 23 &&
    Number(offsetMinute) <= 59
  );
}

/** Whether `value` has the shape of a BCP 47 language tag, for example `en` or `pt-BR`. */
export function isLanguageTag(value: unknown): value is string {
  return typeof value === 'string' && LANGUAGE_TAG.test(value);
}

/** Whether `value` is a string that parses as an absolute http or https URL. */
export function isHttpUrl(value: unknown): value is string {
  if (typeof value !== 'string') return false;
  try {
    const { protocol } = new URL(value);
    return protocol === 'http:' || protocol === 'https:';
  } catch {
    return false;
  }
}

function isText(value: unknown): value is string {
  return typeof value === 'string' && value.length > 0;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === 'object' && value !== null && !Array.isArray(value);
}

function codePointLength(value: string): number {
  let length = 0;
  for (const _ of value) length++;
  return length;
}
