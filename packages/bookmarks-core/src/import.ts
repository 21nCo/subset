import { MAX_TAG_LENGTH } from './input.js';
import { BookmarkError } from './types.js';

/** Largest import file: 20 MB (20 × 1,024 × 1,024 bytes). */
export const MAX_IMPORT_BYTES = 20 * 1024 * 1024;
/** Most bookmarks one import may hold. */
export const MAX_IMPORT_ITEMS = 50_000;
/** Most warnings an import reports; a last warning counts the rest. */
export const MAX_IMPORT_WARNINGS = 100;

/** The closed set of import formats. */
export const IMPORT_KINDS = ['netscape-html', 'pocket-csv'] as const;
export type ImportKind = (typeof IMPORT_KINDS)[number];

/** One bookmark read from an import file, before it is checked: an invalid URL is skipped by `importBookmarks`. */
export interface ImportItem {
  /** As written in the file (entities decoded); `''` when the entry had none. */
  url: string;
  title?: string | null;
  notes?: string | null;
  /** Folder names and the file's own tags, made into valid tag names (see `toTagName`). */
  tags?: string[];
  unread?: boolean;
  archived?: boolean;
  /**
   * When the exporter says the bookmark was added, in epoch milliseconds. datafn sets `createdAt` itself on insert,
   * so an import does not keep it yet.
   */
  addedAt?: number | null;
}

export interface ImportWarning {
  /** 1-based position of the item in the file, when the warning is about one item. */
  item?: number;
  url?: string;
  message: string;
}

export interface ParsedImport {
  items: ImportItem[];
  warnings: ImportWarning[];
}

export interface ImportResult {
  /** New bookmarks. */
  added: number;
  /** Items whose canonical URL was already saved, or appeared earlier in the file: only their new tags were added. */
  merged: number;
  /** Items with a missing, invalid or non-http(s) URL. */
  skipped: number;
  warnings: ImportWarning[];
}

/** Collects warnings up to `MAX_IMPORT_WARNINGS`, then counts the rest in one last warning. */
export function warningList(initial: readonly ImportWarning[] = []) {
  const kept: ImportWarning[] = [];
  let dropped = 0;
  const add = (warning: ImportWarning) => {
    if (kept.length < MAX_IMPORT_WARNINGS) kept.push(warning);
    else dropped++;
  };
  for (const warning of initial) add(warning);
  return {
    add,
    list: (): ImportWarning[] => (dropped === 0 ? [...kept] : [...kept, { message: `${dropped} more warnings not shown` }])
  };
}

const CONTROL = /\p{Cc}/gu;

/**
 * Makes a folder name or an exporter's tag into a tag name: NFC-normalized, control characters removed, leading and
 * trailing whitespace and commas trimmed, each inner run of whitespace and commas replaced by `-`, and cut to 64
 * characters. `Reading list` becomes `Reading-list`. Null when nothing is left.
 */
export function toTagName(raw: string): string | null {
  const name = raw
    .normalize('NFC')
    .replace(CONTROL, '')
    .replace(/^[\s,]+|[\s,]+$/gu, '')
    .replace(/[\s,]+/gu, '-');
  if (name === '') return null;
  const chars = [...name];
  return chars.length > MAX_TAG_LENGTH ? chars.slice(0, MAX_TAG_LENGTH).join('') : name;
}

/** Reads `ADD_DATE`-style times: seconds, milliseconds or microseconds since the epoch, as exporters differ. */
export function toEpochMs(value: string | undefined | null): number | null {
  if (value === undefined || value === null || !/^\s*\d{1,20}\s*$/.test(value)) return null;
  const number = Number(value);
  const ms = number > 1e14 ? Math.floor(number / 1000) : number > 1e11 ? number : number * 1000;
  return Number.isSafeInteger(ms) ? ms : null;
}

export const tooManyItems = () => new BookmarkError('too-large', `The file has more than ${MAX_IMPORT_ITEMS.toLocaleString('en-US')} bookmarks`);
