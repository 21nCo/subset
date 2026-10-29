import { canonicalizeUrl, LinkUrlError } from '@subset.dev/links';
import { BookmarkError } from './types.js';

/** Longest saved URL, in characters (linkding's limit). */
export const MAX_URL_LENGTH = 2048;
/** Longest user title, in characters (linkding's limit). */
export const MAX_TITLE_LENGTH = 512;
/** Longest notes, in characters. */
export const MAX_NOTES_LENGTH = 20_000;
/** Longest tag name, in characters (linkding's limit). */
export const MAX_TAG_LENGTH = 64;

const length = (value: string) => [...value].length;
const CONTROL = /\p{Cc}/u;

export function normalizeUrl(input: unknown): { url: string; canonicalUrl: string } {
  if (typeof input !== 'string') throw new BookmarkError('invalid-url', 'The URL must be a string');
  const trimmed = input.trim();
  if (length(trimmed) > MAX_URL_LENGTH) throw new BookmarkError('invalid-url', `The URL is longer than ${MAX_URL_LENGTH} characters`);
  try {
    const canonicalUrl = canonicalizeUrl(trimmed);
    const url = new URL(trimmed).href;
    if (length(url) > MAX_URL_LENGTH || length(canonicalUrl) > MAX_URL_LENGTH) {
      throw new BookmarkError('invalid-url', `The URL is longer than ${MAX_URL_LENGTH} characters`);
    }
    return { url, canonicalUrl };
  } catch (error) {
    if (error instanceof LinkUrlError) throw new BookmarkError('invalid-url', error.message, { cause: error });
    throw error;
  }
}

/** Trims optional text; empty means none. `undefined` stays `undefined` (unchanged in an update). */
export function normalizeText(input: unknown, field: string, max: number): string | null | undefined {
  if (input === undefined) return undefined;
  if (input === null) return null;
  if (typeof input !== 'string') throw new BookmarkError('invalid-input', `${field} must be a string or null`);
  const value = input.trim();
  if (length(value) > max) throw new BookmarkError('invalid-input', `${field} is longer than ${max} characters`);
  return value === '' ? null : value;
}

export function normalizeBoolean(input: unknown, field: string): boolean | undefined {
  if (input === undefined) return undefined;
  if (typeof input !== 'boolean') throw new BookmarkError('invalid-input', `${field} must be a boolean`);
  return input;
}

/**
 * A tag name is NFC-normalized and trimmed, then must be non-empty, at most 64 characters and free of whitespace,
 * commas and control characters, so it survives linkding's space- and comma-separated tag strings. Its key is
 * the lowercased name.
 */
export function normalizeTagName(input: unknown): { name: string; nameKey: string } {
  if (typeof input !== 'string') throw new BookmarkError('invalid-input', 'A tag name must be a string');
  const name = input.normalize('NFC').trim();
  if (name === '') throw new BookmarkError('invalid-input', 'A tag name cannot be empty');
  if (/[\s,]/u.test(name) || CONTROL.test(name)) {
    throw new BookmarkError('invalid-input', `Tag name ${JSON.stringify(name)} contains whitespace, a comma or a control character`);
  }
  if (length(name) > MAX_TAG_LENGTH) throw new BookmarkError('invalid-input', `Tag name is longer than ${MAX_TAG_LENGTH} characters`);
  return { name, nameKey: name.toLowerCase() };
}

/** Normalizes a list of tag names, keeping the first spelling of each key. */
export function normalizeTagNames(input: unknown): { name: string; nameKey: string }[] {
  if (input === undefined) return [];
  if (!Array.isArray(input)) throw new BookmarkError('invalid-input', 'Tags must be an array of names');
  const byKey = new Map<string, { name: string; nameKey: string }>();
  for (const entry of input) {
    const tag = normalizeTagName(entry);
    if (!byKey.has(tag.nameKey)) byKey.set(tag.nameKey, tag);
  }
  return [...byKey.values()];
}

export function normalizeIds(input: unknown, field: string): string[] {
  if (!Array.isArray(input)) throw new BookmarkError('invalid-input', `${field} must be an array of ids`);
  // Array.from visits holes too, so a sparse array is rejected before anything is written.
  return [...new Set(Array.from(input, (id) => normalizeId(id, field)))];
}

export function normalizeId(input: unknown, field: string): string {
  if (typeof input !== 'string' || input === '' || input.length > 255)
    throw new BookmarkError('invalid-input', `${field} must be a non-empty id`);
  return input;
}
