import { MAX_IMPORT_ITEMS, toEpochMs, toTagName, tooManyItems, type ImportItem, type ImportWarning, type ParsedImport } from './import.js';
import { BookmarkError } from './types.js';

/** linkding's export marks an archived bookmark with this tag, which is not a tag of the bookmark. */
export const LINKDING_ARCHIVED_TAG = 'linkding:bookmarks.archived';
const LINKDING_NOTES = /\[linkding-notes\]([\s\S]*?)(?:\[\/linkding-notes\]|$)/;

/**
 * Safari does not mark its toolbar folder, so a top-level folder with one of its names is taken to be it. Other
 * browsers mark theirs with `PERSONAL_TOOLBAR_FOLDER="true"`.
 */
const SAFARI_TOOLBAR_NAMES = new Set(['favorites', 'favourites', 'favorites bar', 'favourites bar']);

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

/** Tags that end a `<DD>` note: the next entry or list. */
const ENDS_NOTE = new Set(['DT', 'DD', 'DL', 'H1', 'H3', 'HR', 'A']);
const ENDS_NOTE_CLOSING = new Set(['DL', 'BODY', 'HTML']);

const collapse = (text: string) => decodeEntities(text).replace(/\s+/g, ' ').trim();

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
  // One entry per open <DL>: the tag its folder gives, or null (the top level, the toolbar, a nameless folder).
  const folders: (string | null)[] = [];
  // One entry per open <DL>: whether a folder opened it (a top-level <DL> has no folder).
  const inFolder: boolean[] = [];
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

  for (const tag of scanTags(text)) {
    if (mode !== 'text') buffer += text.slice(last, tag.start);
    last = tag.end;
    const { closing, name } = tag;

    if (mode === 'folder') {
      if (closing && name === 'H3') {
        const title = collapse(buffer);
        const topLevel = !inFolder.includes(true);
        const toolbar = attributes.get('PERSONAL_TOOLBAR_FOLDER')?.toLowerCase() === 'true' || (topLevel && SAFARI_TOOLBAR_NAMES.has(title.toLowerCase()));
        nextFolder = toolbar ? null : toTagName(title);
        if (!toolbar && nextFolder === null && title !== '') warnings.push({ message: `Folder ${JSON.stringify(title)} gives no tag name` });
        mode = 'text';
      }
      continue;
    }
    if (mode === 'link') {
      if (closing && name === 'A') {
        noteTarget = addLink(items, attributes, collapse(buffer), folders);
        mode = 'text';
      }
      continue;
    }
    if (mode === 'note') {
      if (name === 'BR' && !closing) buffer += '\n';
      // A note ends at the next entry or at the end of its list; other markup in it is dropped.
      if (closing ? !ENDS_NOTE_CLOSING.has(name) : !ENDS_NOTE.has(name)) continue;
      finishNote();
    }

    if (closing) {
      if (name === 'DL') {
        folders.pop();
        inFolder.pop();
        nextFolder = undefined;
      }
      continue;
    }
    switch (name) {
      case 'DL':
        folders.push(nextFolder ?? null);
        inFolder.push(nextFolder !== undefined);
        nextFolder = undefined;
        break;
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
  if (mode === 'link') addLink(items, attributes, collapse(buffer + text.slice(last)), folders);
  else if (mode === 'note') {
    buffer += text.slice(last);
    finishNote();
  }
  return { items, warnings };
}

function addLink(items: ImportItem[], attributes: Map<string, string>, title: string, folders: (string | null)[]): ImportItem {
  const tags: string[] = folders.filter((folder): folder is string => folder !== null);
  let archived = false;
  for (const raw of (attributes.get('TAGS') ?? '').split(',')) {
    if (raw.trim().toLowerCase() === LINKDING_ARCHIVED_TAG) archived = true;
    else {
      const tag = toTagName(raw);
      if (tag !== null) tags.push(tag);
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

function setNotes(item: ImportItem, raw: string): void {
  const text = decodeEntities(raw);
  const notes = LINKDING_NOTES.exec(text);
  const parts = notes ? [text.slice(0, notes.index), notes[1]] : [text];
  const joined = parts.map((part) => part.trim()).filter((part) => part !== '').join('\n\n');
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
    lines.push(`<DT><A ${attributes.join(' ')}>${escapeHtml(bookmark.title ?? '')}</A>`);
    if (bookmark.notes) lines.push(`<DD>${escapeHtml(bookmark.notes)}`);
  }
  lines.push('</DL><p>', '');
  return lines.join('\n');
}
