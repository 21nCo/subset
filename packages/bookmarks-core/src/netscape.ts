import { decodeHTML, decodeHTMLAttribute } from 'entities/decode';
import { MAX_IMPORT_ITEMS, toEpochMs, toTagName, tooManyItems, type ImportItem, type ImportWarning, type ParsedImport } from './import.js';
import { LINKDING_ARCHIVED_TAG } from './input.js';
import { BookmarkError } from './types.js';

/**
 * `renderNetscape` names itself in a `<META NAME="generator">` before the first list, which browsers and linkding
 * ignore, so the parser knows the word joiners in the notes markers are its own (see `escapeNotes`).
 */
const GENERATOR = 'subset.dev Bookmarks';

/** linkding's notes in its `<DD>`, matched before character references are decoded, so an encoded `[` is text. */
const LINKDING_NOTES = /\[linkding-notes\]([\s\S]*?)(?:\[\/linkding-notes\]|$)/;

/**
 * Safari does not mark its toolbar folder, so a folder with one of its names is taken to be it when it is outside
 * any `<DL>`, as only Safari writes its top-level folders. Safari writes the name in the Mac's language, so the
 * names are those of its Favorites in the languages it ships in, lowercased. Other browsers mark theirs with
 * `PERSONAL_TOOLBAR_FOLDER="true"`.
 */
const SAFARI_TOOLBAR_NAMES = new Set([
  ...['favorites', 'favourites', 'favorites bar', 'favourites bar'],
  // German, French, Spanish and Portuguese, Italian, Dutch, Swedish, Danish and Norwegian, Finnish, Polish, Czech,
  // Hungarian, Turkish, Russian, Ukrainian, Greek, Japanese, Chinese (simplified, traditional), Korean, Arabic, Hebrew.
  ...['favoriten', 'favoris', 'favoritos', 'preferiti', 'favorieten', 'favoriter', 'favoritter', 'suosikit', 'ulubione'],
  ...['oblíbené', 'kedvencek', 'favoriler', 'избранное', 'вибране', 'αγαπημένα', 'お気に入り', '个人收藏', '個人收藏'],
  ...['즐겨찾기', 'المفضلة', 'מועדפים']
]);

/**
 * Most folder tags a file may give its items in all: each item counts one per distinct enclosing folder. A file over
 * it fails with `too-large`, so the tags the parser keeps grow with the file, not with its depth times its links. It
 * allows every one of 50,000 items 40 enclosing folders.
 */
export const MAX_FOLDER_TAG_REFERENCES = 2_000_000;

const tooManyFolderTags = () =>
  new BookmarkError(
    'too-large',
    `The file's folders give its bookmarks more than ${MAX_FOLDER_TAG_REFERENCES.toLocaleString('en-US')} tags in all (MAX_FOLDER_TAG_REFERENCES)`
  );

/**
 * Decodes HTML character references in element text as a browser does: every named one (`&mdash;`, `&hellip;`, the
 * legacy ones without `;`) and every numeric one.
 */
export const decodeEntities = (text: string): string => (text.includes('&') ? decodeHTML(text) : text);

/** Escapes text for an HTML attribute value or element content. */
export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&${{ '&': 'amp', '<': 'lt', '>': 'gt', '"': 'quot', "'": '#39' }[char]};`);
}

function parseAttributes(source: string): Map<string, string> {
  const attributes = new Map<string, string>();
  for (const match of source.matchAll(/([^\s"'=<>/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
    const name = match[1].toUpperCase();
    // In an attribute a legacy reference followed by `=` or a letter or digit is text, as in `?a=1&copy=2`.
    if (!attributes.has(name)) attributes.set(name, decodeHTMLAttribute(match[2] ?? match[3] ?? match[4] ?? ''));
  }
  return attributes;
}

interface TagToken {
  /** Where the tag starts and the text after it starts. */
  start: number;
  end: number;
  closing: boolean;
  /** Uppercased. */
  name: string;
  attributes: string;
}

/**
 * The start and end tags of `text`, and its comments (named `!--`), so their text is not read as element text. A
 * comment that is never closed runs to the end, as in HTML. A quoted value runs to its closing quote, also past `>`,
 * as in HTML; a quote that is never closed runs to the end. Each character is read once, so a malformed file of any
 * size is read in linear time.
 */
function* scanTags(text: string): Generator<TagToken> {
  for (let at = text.indexOf('<'); at !== -1; ) {
    if (text.startsWith('<!--', at)) {
      const close = text.indexOf('-->', at + 4);
      const end = close === -1 ? text.length : close + 3;
      yield { start: at, end, closing: false, name: '!--', attributes: '' };
      at = text.indexOf('<', end);
      continue;
    }
    const closing = text[at + 1] === '/';
    let cursor = at + (closing ? 2 : 1);
    const nameStart = cursor;
    if (!/[a-zA-Z]/.test(text[cursor] ?? '')) {
      at = text.indexOf('<', at + 1);
      continue;
    }
    while (cursor < text.length && /[a-zA-Z0-9]/.test(text[cursor])) cursor++;
    const name = text.slice(nameStart, cursor).toUpperCase();
    const attributesStart = cursor;
    while (cursor < text.length && text[cursor] !== '>') {
      const char = text[cursor];
      if (char === '"' || char === "'") {
        const close = text.indexOf(char, cursor + 1);
        cursor = close === -1 ? text.length : close + 1;
      } else cursor++;
    }
    const end = Math.min(cursor + 1, text.length);
    yield { start: at, end, closing, name, attributes: text.slice(attributesStart, cursor) };
    at = text.indexOf('<', end);
  }
}

/**
 * Tags that end a `<DD>` note, or a link or folder whose end tag is missing: the next entry or list. A link in a note
 * is part of the note, so only a link or folder ends at an `<A>`.
 */
const ENDS_NOTE = new Set(['DT', 'DD', 'DL', 'H1', 'H3', 'HR']);
const ENDS_ENTRY = new Set([...ENDS_NOTE, 'A']);
const ENDS_ENTRY_CLOSING = new Set(['DL', 'BODY', 'HTML']);
const endsEntry = (tag: TagToken, ends = ENDS_ENTRY) => (tag.closing ? ENDS_ENTRY_CLOSING : ends).has(tag.name);

/**
 * Element text as a browser shows it: each run of HTML whitespace (space, tab, line feed, form feed, carriage return)
 * in the markup is one space, trimmed, and then character references are decoded, so an encoded space, line break or
 * a no-break space is kept.
 */
const collapse = (text: string) => decodeEntities(text.replace(/[ \t\n\f\r]+/g, ' ').replace(/^ | $/g, ''));

/**
 * Reads a Netscape bookmark file. Each `<DT><A>` is an item: `HREF`, the link text as title, `TAGS` (comma
 * separated), `ADD_DATE` and `TOREAD="1"` as unread, and the `<DD>` right after it as notes. The name of each
 * enclosing `<H3>` folder becomes a tag, except the browser toolbar folder. linkding's `linkding:bookmarks.archived`
 * tag makes the item archived, and the `[linkding-notes]` part of its `<DD>` follows the description in the notes.
 * Comments are not text, and the text of a link inside a note is part of the note.
 */
export function parseNetscape(text: string): ParsedImport {
  const head = text.replace(/^(?:\s|<!--[\s\S]*?-->)*/, '');
  if (!/^<!DOCTYPE\s+NETSCAPE-Bookmark-file-1\s*>/i.test(head)) {
    throw new BookmarkError('invalid-input', 'The file is not a Netscape bookmark file (it does not start with <!DOCTYPE NETSCAPE-Bookmark-file-1>)');
  }
  const items: ImportItem[] = [];
  const warnings: ImportWarning[] = [];
  // One entry per open <DL>: whether its folder added a tag to folderTags (not the top level, the toolbar, a nameless
  // folder or one already open under another spelling).
  const folders: boolean[] = [];
  // The distinct tags of the open folders, outermost first, and their keys.
  const folderTags: string[] = [];
  const folderKeys = new Set<string>();
  // The folder tags the items so far have, counted against MAX_FOLDER_TAG_REFERENCES.
  let folderTagReferences = 0;
  // The folder whose <DL> comes next: undefined when none is waiting.
  let nextFolder: string | null | undefined;
  let mode: 'text' | 'folder' | 'link' | 'note' = 'text';
  let buffer = '';
  let attributes = new Map<string, string>();
  // The item a <DD> right after it describes.
  let noteTarget: ImportItem | null = null;
  // Whether renderNetscape wrote the file: its generator <META> comes before the first list.
  let ownExport = false;
  let listSeen = false;
  let last = 0;

  const finishNote = () => {
    if (noteTarget) setNotes(noteTarget, buffer, ownExport);
    noteTarget = null;
    mode = 'text';
  };
  const finishFolder = () => {
    const title = collapse(buffer);
    const safariTopLevel = folders.length === 0;
    const toolbar =
      attributes.get('PERSONAL_TOOLBAR_FOLDER')?.toLowerCase() === 'true' ||
      (safariTopLevel && SAFARI_TOOLBAR_NAMES.has(title.normalize('NFC').toLowerCase()));
    nextFolder = toolbar ? null : toTagName(title);
    if (!toolbar && nextFolder === null && title !== '') warnings.push({ message: `Folder ${JSON.stringify(title)} gives no tag name` });
    mode = 'text';
  };
  const finishLink = (title: string) => {
    folderTagReferences += folderTags.length;
    if (folderTagReferences > MAX_FOLDER_TAG_REFERENCES) throw tooManyFolderTags();
    noteTarget = addLink(items, attributes, collapse(title), folderTags);
    mode = 'text';
  };

  for (const tag of scanTags(text)) {
    if (mode !== 'text') buffer += text.slice(last, tag.start);
    last = tag.end;
    const { closing, name } = tag;
    if (name === '!--') continue;

    // A folder name or link text ends at its end tag or, when that is missing, at the next entry or the end of its
    // list, which is then read as usual; other markup in it is dropped.
    if (mode === 'folder') {
      const ended = closing && name === 'H3';
      if (!ended && !endsEntry(tag)) continue;
      finishFolder();
      if (ended) continue;
    }
    if (mode === 'link') {
      const ended = closing && name === 'A';
      if (!ended && !endsEntry(tag)) continue;
      finishLink(buffer);
      if (ended) continue;
    }
    if (mode === 'note') {
      if (name === 'BR' && !closing) buffer += '\n';
      // A note ends at the next entry or at the end of its list; other markup in it, a link too, is dropped.
      if (!endsEntry(tag, ENDS_NOTE)) continue;
      finishNote();
    }

    if (closing) {
      if (name === 'DL') {
        if (folders.pop()) folderKeys.delete(folderTags.pop()!.toLowerCase());
        nextFolder = undefined;
      }
      continue;
    }
    switch (name) {
      case 'META': {
        const meta = parseAttributes(tag.attributes);
        if (!listSeen && meta.get('NAME')?.toLowerCase() === 'generator' && meta.get('CONTENT') === GENERATOR) ownExport = true;
        break;
      }
      case 'DL': {
        listSeen = true;
        const key = nextFolder?.toLowerCase();
        const counted = key !== undefined && !folderKeys.has(key);
        if (counted) {
          folderTags.push(nextFolder!);
          folderKeys.add(key);
        }
        folders.push(counted);
        nextFolder = undefined;
        break;
      }
      case 'H3':
        noteTarget = null;
        mode = 'folder';
        buffer = '';
        attributes = parseAttributes(tag.attributes);
        break;
      case 'A':
        if (items.length === MAX_IMPORT_ITEMS) throw tooManyItems();
        // A folder with no <DL> before the next link is empty.
        nextFolder = undefined;
        mode = 'link';
        buffer = '';
        attributes = parseAttributes(tag.attributes);
        break;
      case 'DD':
        mode = 'note';
        buffer = '';
        break;
      case 'DT':
      case 'HR':
        noteTarget = null;
        break;
    }
  }
  if (mode === 'link') finishLink(buffer + text.slice(last));
  else if (mode === 'note') {
    buffer += text.slice(last);
    finishNote();
  }
  return { items, warnings };
}

/** Adds the item a `<DT><A>` describes; its tags are the enclosing folders' and then its own, one per key. */
function addLink(items: ImportItem[], attributes: Map<string, string>, title: string, folderTags: readonly string[]): ImportItem {
  const tags = [...folderTags];
  const keys = new Set(tags.map((tag) => tag.toLowerCase()));
  let archived = false;
  for (const raw of (attributes.get('TAGS') ?? '').split(',')) {
    if (raw.trim().toLowerCase() === LINKDING_ARCHIVED_TAG) archived = true;
    else {
      const tag = toTagName(raw);
      if (tag !== null && !keys.has(tag.toLowerCase())) {
        keys.add(tag.toLowerCase());
        tags.push(tag);
      }
    }
  }
  const item: ImportItem = {
    url: (attributes.get('HREF') ?? '').trim(),
    title: title === '' ? null : title,
    notes: null,
    tags,
    unread: attributes.get('TOREAD') === '1',
    archived,
    addedAt: toEpochMs(attributes.get('ADD_DATE'))
  };
  items.push(item);
  return item;
}

/**
 * Sets the notes a `<DD>` gives: its text, with linkding's notes part (and any text after it) as further paragraphs.
 * In a file `renderNetscape` wrote (`ownExport`), the notes part loses the word joiner `escapeNotes` put in each
 * marker-shaped text; the notes of any other file are kept as they are.
 */
function setNotes(item: ImportItem, raw: string, ownExport: boolean): void {
  const notes = LINKDING_NOTES.exec(raw);
  const parts = notes ? [raw.slice(0, notes.index), notes[1], raw.slice(notes.index + notes[0].length)] : [raw];
  const decoded = parts.map((part, at) => (at === 1 && ownExport ? decodeEntities(part).replace(JOINED_MARKER, '[') : decodeEntities(part)));
  const joined = decoded.map((part) => part.trim()).filter((part) => part !== '').join('\n\n');
  item.notes = joined === '' ? null : joined;
}

/** The fields of a bookmark the Netscape export writes. */
export interface NetscapeBookmark {
  url: string;
  title: string | null;
  notes: string | null;
  tags: string[];
  unread: boolean;
  archived: boolean;
  /** When the exporter that the bookmark was imported from says it was added, in epoch milliseconds: its `ADD_DATE`. */
  addedAt?: number | null;
  /** Epoch milliseconds: the `ADD_DATE` of a bookmark with no `addedAt`. */
  createdAt: number;
  /** Epoch milliseconds. */
  updatedAt: number;
}

const seconds = (ms: number) => String(Math.floor(ms / 1000));

const HTML_SPACE = /[ \t\n\f\r]/;

/**
 * Escapes a title as element text that reads back the same: every HTML whitespace character is a character
 * reference, except a single space between two other characters, which the reader keeps as it is.
 */
function escapeTitle(title: string): string {
  return escapeHtml(title).replace(/[ \t\n\f\r]/g, (char, at: number, text: string) =>
    char === ' ' && at > 0 && at < text.length - 1 && !HTML_SPACE.test(text[at - 1]) && !HTML_SPACE.test(text[at + 1]) ? ' ' : `&#${char.charCodeAt(0)};`
  );
}

/** A `[` that starts a linkding marker, after any word joiners (U+2060). */
const MARKER = /\[(?=\u2060*\/?linkding-notes\])/g;
/** A `[` and the word joiner `escapeNotes` put after it. */
const JOINED_MARKER = /\[\u2060(?=\u2060*\/?linkding-notes\])/g;

/**
 * Escapes notes as the text of linkding's `[linkding-notes]` marker in a `<DD>`, so linkding reads them as notes, not
 * as the page description. linkding decodes character references before it looks for the markers, so a marker in the
 * notes gets a word joiner (U+2060, invisible) after its `[` instead, and is text to linkding and to this parser,
 * which removes that joiner again in a file with this exporter's generator `<META>`; one already there gets another,
 * so the notes read back exactly.
 */
const escapeNotes = (notes: string) => `[linkding-notes]${escapeHtml(notes).replace(MARKER, '[\u2060')}[/linkding-notes]`;

/**
 * Longest file the export writes, in characters (UTF-16 code units): 128 Mi, a quarter of the longest string V8 holds.
 * A larger export fails with `too-large` as soon as it would pass it, before the file is put together.
 */
export const MAX_EXPORT_LENGTH = 128 * 1024 * 1024;

const tooLargeExport = () =>
  new BookmarkError('too-large', `The export would be longer than ${MAX_EXPORT_LENGTH.toLocaleString('en-US')} characters (MAX_EXPORT_LENGTH)`);

const HEADER = [
  '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
  '<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->',
  '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
  `<META NAME="generator" CONTENT="${GENERATOR}">`,
  '<TITLE>Bookmarks</TITLE>',
  '<H1>Bookmarks</H1>',
  '<DL><p>',
  ''
].join('\n');
const FOOTER = '</DL><p>\n';

/** The `<DT><A>` line of a bookmark, and its `<DD>` line when it has notes, each ending in a line break. */
function renderEntry(bookmark: NetscapeBookmark): string {
  const tags = bookmark.archived ? [...bookmark.tags, LINKDING_ARCHIVED_TAG] : bookmark.tags;
  const attributes = [
    `HREF="${escapeHtml(bookmark.url)}"`,
    `ADD_DATE="${seconds(bookmark.addedAt ?? bookmark.createdAt)}"`,
    `LAST_MODIFIED="${seconds(bookmark.updatedAt)}"`,
    `TOREAD="${bookmark.unread ? '1' : '0'}"`,
    ...(tags.length > 0 ? [`TAGS="${escapeHtml(tags.join(','))}"`] : [])
  ];
  const link = `<DT><A ${attributes.join(' ')}>${escapeTitle(bookmark.title ?? '')}</A>\n`;
  return bookmark.notes ? `${link}<DD>${escapeNotes(bookmark.notes)}\n` : link;
}

/**
 * Writes a Netscape bookmark file a bookmark at a time, so a caller reading pages keeps only the text written so far.
 * `add` fails with `too-large` when the file would pass `MAX_EXPORT_LENGTH`.
 */
export function netscapeWriter(): { add(bookmark: NetscapeBookmark): void; finish(): string } {
  const parts = [HEADER];
  let length = HEADER.length + FOOTER.length;
  return {
    add(bookmark) {
      const entry = renderEntry(bookmark);
      length += entry.length;
      if (length > MAX_EXPORT_LENGTH) throw tooLargeExport();
      parts.push(entry);
    },
    finish: () => [...parts, FOOTER].join('')
  };
}

/**
 * Writes bookmarks as a Netscape bookmark file, in linkding's form: one flat list of `<DT><A>` with `ADD_DATE`,
 * `LAST_MODIFIED`, `TOREAD`, `TAGS` (with `linkding:bookmarks.archived` for an archived bookmark) and a `<DD>` with
 * the notes in linkding's notes marker. A file longer than `MAX_EXPORT_LENGTH` fails with `too-large`.
 */
export function renderNetscape(bookmarks: Iterable<NetscapeBookmark>): string {
  const writer = netscapeWriter();
  for (const bookmark of bookmarks) writer.add(bookmark);
  return writer.finish();
}
