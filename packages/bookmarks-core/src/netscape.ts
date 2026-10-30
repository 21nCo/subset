import { MAX_IMPORT_ITEMS, toEpochMs, toTagName, tooManyItems, type ImportItem, type ImportWarning, type ParsedImport } from './import.js';
import { LINKDING_ARCHIVED_TAG } from './input.js';
import { BookmarkError } from './types.js';

/** linkding's notes in its `<DD>`, matched before character references are decoded, so an encoded `[` is text. */
const LINKDING_NOTES = /\[linkding-notes\]([\s\S]*?)(?:\[\/linkding-notes\]|$)/;

/**
 * Safari does not mark its toolbar folder, so a folder with one of its names is taken to be it when it is outside
 * any `<DL>`, as only Safari writes its top-level folders. Other browsers mark theirs with
 * `PERSONAL_TOOLBAR_FOLDER="true"`.
 */
const SAFARI_TOOLBAR_NAMES = new Set(['favorites', 'favourites', 'favorites bar', 'favourites bar']);

/**
 * Most folder tags a file may give its items in all: each item counts one per distinct enclosing folder. A file over
 * it fails with `too-large`, so the tags the parser keeps grow with the file, not with its depth times its links. It
 * allows every one of 50,000 items 40 enclosing folders.
 */
export const MAX_FOLDER_TAG_REFERENCES = 2_000_000;

const tooManyFolderTags = () =>
  new BookmarkError('too-large', `The file's folders give its bookmarks more than ${MAX_FOLDER_TAG_REFERENCES.toLocaleString('en-US')} tags in all`);

const NAMED_ENTITIES: Record<string, string> = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };

/** Decodes HTML character references: the named ones exporters write and every numeric one. */
export function decodeEntities(text: string): string {
  if (!text.includes('&')) return text;
  return text.replace(/&(#[0-9]{1,7}|#[xX][0-9a-fA-F]{1,6}|[a-zA-Z]{2,6});/g, (whole, ref: string) => {
    if (ref[0] !== '#') return NAMED_ENTITIES[ref.toLowerCase()] ?? whole;
    const code = ref[1] === 'x' || ref[1] === 'X' ? parseInt(ref.slice(2), 16) : parseInt(ref.slice(1), 10);
    return code > 0 && code <= 0x10ffff && (code < 0xd800 || code > 0xdfff) ? String.fromCodePoint(code) : '�';
  });
}

/** Escapes text for an HTML attribute value or element content. */
export function escapeHtml(text: string): string {
  return text.replace(/[&<>"']/g, (char) => `&${{ '&': 'amp', '<': 'lt', '>': 'gt', '"': 'quot', "'": '#39' }[char]};`);
}

function parseAttributes(source: string): Map<string, string> {
  const attributes = new Map<string, string>();
  for (const match of source.matchAll(/([^\s"'=<>/]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+)))?/g)) {
    const name = match[1].toUpperCase();
    if (!attributes.has(name)) attributes.set(name, decodeEntities(match[2] ?? match[3] ?? match[4] ?? ''));
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
 * The start and end tags of `text`, skipping comments. A quoted value runs to its closing quote, also past `>`, as
 * in HTML; a quote that is never closed runs to the end. Each character is read once, so a malformed file of any size
 * is read in linear time.
 */
function* scanTags(text: string): Generator<TagToken> {
  for (let at = text.indexOf('<'); at !== -1; ) {
    if (text.startsWith('<!--', at)) {
      const close = text.indexOf('-->', at + 4);
      at = close === -1 ? -1 : text.indexOf('<', close + 3);
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

/** Tags that end a `<DD>` note, or a link or folder whose end tag is missing: the next entry or list. */
const ENDS_ENTRY = new Set(['DT', 'DD', 'DL', 'H1', 'H3', 'HR', 'A']);
const ENDS_ENTRY_CLOSING = new Set(['DL', 'BODY', 'HTML']);
const endsEntry = (tag: TagToken) => (tag.closing ? ENDS_ENTRY_CLOSING : ENDS_ENTRY).has(tag.name);

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
  let last = 0;

  const finishNote = () => {
    if (noteTarget) setNotes(noteTarget, buffer);
    noteTarget = null;
    mode = 'text';
  };
  const finishFolder = () => {
    const title = collapse(buffer);
    const safariTopLevel = folders.length === 0;
    const toolbar = attributes.get('PERSONAL_TOOLBAR_FOLDER')?.toLowerCase() === 'true' || (safariTopLevel && SAFARI_TOOLBAR_NAMES.has(title.toLowerCase()));
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
      // A note ends at the next entry or at the end of its list; other markup in it is dropped.
      if (!endsEntry(tag)) continue;
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
      case 'DL': {
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

/** Sets the notes a `<DD>` gives: its text, with linkding's notes part (and any text after it) as further paragraphs. */
function setNotes(item: ImportItem, raw: string): void {
  const notes = LINKDING_NOTES.exec(raw);
  const parts = notes ? [raw.slice(0, notes.index), notes[1], raw.slice(notes.index + notes[0].length)] : [raw];
  const joined = parts.map((part) => decodeEntities(part).trim()).filter((part) => part !== '').join('\n\n');
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
  /** Epoch milliseconds. */
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

/** Escapes notes as `<DD>` text that reads back the same: `[` is a character reference, so no text is a linkding marker. */
const escapeNotes = (notes: string) => escapeHtml(notes).replace(/\[/g, '&#91;');

/**
 * Writes bookmarks as a Netscape bookmark file, in linkding's form: one flat list of `<DT><A>` with `ADD_DATE`,
 * `LAST_MODIFIED`, `TOREAD`, `TAGS` (with `linkding:bookmarks.archived` for an archived bookmark) and a `<DD>` note.
 */
export function renderNetscape(bookmarks: Iterable<NetscapeBookmark>): string {
  const lines = [
    '<!DOCTYPE NETSCAPE-Bookmark-file-1>',
    '<!-- This is an automatically generated file. It will be read and overwritten. DO NOT EDIT! -->',
    '<META HTTP-EQUIV="Content-Type" CONTENT="text/html; charset=UTF-8">',
    '<TITLE>Bookmarks</TITLE>',
    '<H1>Bookmarks</H1>',
    '<DL><p>'
  ];
  for (const bookmark of bookmarks) {
    const tags = bookmark.archived ? [...bookmark.tags, LINKDING_ARCHIVED_TAG] : bookmark.tags;
    const attributes = [
      `HREF="${escapeHtml(bookmark.url)}"`,
      `ADD_DATE="${seconds(bookmark.createdAt)}"`,
      `LAST_MODIFIED="${seconds(bookmark.updatedAt)}"`,
      `TOREAD="${bookmark.unread ? '1' : '0'}"`,
      ...(tags.length > 0 ? [`TAGS="${escapeHtml(tags.join(','))}"`] : [])
    ];
    lines.push(`<DT><A ${attributes.join(' ')}>${escapeTitle(bookmark.title ?? '')}</A>`);
    if (bookmark.notes) lines.push(`<DD>${escapeNotes(bookmark.notes)}`);
  }
  lines.push('</DL><p>', '');
  return lines.join('\n');
}
