import { MAX_IMPORT_ITEMS, toEpochMs, toTagName, tooManyItems, type ImportItem, type ImportWarning, type ParsedImport } from './import.js';
import { BookmarkError } from './types.js';

/** The rows of an RFC 4180 CSV file: quoted fields may hold commas, line breaks and doubled quotes. */
function* csvRows(text: string): Generator<string[]> {
  let row: string[] = [];
  let field = '';
  let quoted = false;
  for (let at = 0; at < text.length; at++) {
    const char = text[at];
    if (quoted) {
      if (char !== '"') field += char;
      else if (text[at + 1] === '"') {
        field += '"';
        at++;
      } else quoted = false;
    } else if (char === '"') quoted = true;
    else if (char === ',') {
      row.push(field);
      field = '';
    } else if (char === '\n' || char === '\r') {
      if (char === '\r' && text[at + 1] === '\n') at++;
      row.push(field);
      yield row;
      row = [];
      field = '';
    } else field += char;
  }
  if (field !== '' || row.length > 0) {
    row.push(field);
    yield row;
  }
}

/**
 * Reads Pocket's CSV export (`title,url,time_added,tags,status`, columns found by their header). Tags are separated
 * by `|`, `status` `unread` makes the item unread and `archive` archived, and a title that is just the URL (Pocket's
 * placeholder) is none.
 */
export function parsePocketCsv(text: string): ParsedImport {
  const rows = csvRows(text);
  const header = rows.next();
  const columns = header.done ? [] : header.value.map((name) => name.trim().toLowerCase());
  const column = (name: string) => columns.indexOf(name);
  const [url, title, timeAdded, tags, status] = ['url', 'title', 'time_added', 'tags', 'status'].map(column);
  if (url === -1) throw new BookmarkError('invalid-input', 'The file is not a Pocket CSV export (its first line has no url column)');
  const items: ImportItem[] = [];
  const warnings: ImportWarning[] = [];
  for (const row of rows) {
    if (row.length === 1 && row[0].trim() === '') continue;
    if (items.length === MAX_IMPORT_ITEMS) throw tooManyItems();
    if (row.length !== columns.length) {
      warnings.push({ item: items.length + 1, message: `The row has ${row.length} fields where the header has ${columns.length}` });
    }
    const field = (index: number) => (index === -1 ? '' : (row[index] ?? '').trim());
    const link = field(url);
    const name = field(title).replace(/\s+/g, ' ');
    const state = field(status).toLowerCase();
    items.push({
      url: link,
      title: name === '' || name === link ? null : name,
      notes: null,
      tags: field(tags)
        .split('|')
        .map(toTagName)
        .filter((tag): tag is string => tag !== null),
      unread: state === 'unread',
      archived: state === 'archive',
      addedAt: toEpochMs(field(timeAdded))
    });
  }
  return { items, warnings };
}
