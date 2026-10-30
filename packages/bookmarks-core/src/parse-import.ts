import { IMPORT_KINDS, MAX_IMPORT_BYTES, type ImportKind, type ParsedImport } from './import.js';
import { parseNetscape } from './netscape.js';
import { parsePocketCsv } from './pocket.js';
import { BookmarkError } from './types.js';

function decode(file: string | Uint8Array | ArrayBuffer): string {
  if (typeof file === 'string') {
    // Every character is at least one UTF-8 byte; only a string that might be too large is measured.
    if (file.length > MAX_IMPORT_BYTES || (file.length * 3 > MAX_IMPORT_BYTES && new TextEncoder().encode(file).length > MAX_IMPORT_BYTES)) {
      throw tooLarge();
    }
    return file.charCodeAt(0) === 0xfeff ? file.slice(1) : file;
  }
  const bytes = file instanceof Uint8Array ? file : file instanceof ArrayBuffer ? new Uint8Array(file) : null;
  if (!bytes) throw new BookmarkError('invalid-input', 'The file must be a string, Uint8Array or ArrayBuffer');
  if (bytes.byteLength > MAX_IMPORT_BYTES) throw tooLarge();
  // Exports are UTF-8; TextDecoder drops a byte-order mark and replaces invalid bytes.
  return new TextDecoder('utf-8').decode(bytes);
}

const tooLarge = () => new BookmarkError('too-large', `The file is larger than ${MAX_IMPORT_BYTES / 1024 / 1024} MB`);

/**
 * Reads an export file into import items. `netscape-html` is the bookmark file Chrome, Firefox, Safari, Edge,
 * linkding, Raindrop and Pinboard export; `pocket-csv` is Pocket's CSV export. A file over 20 MB or with more than
 * 50,000 bookmarks fails with `too-large`, and a file that is not of the kind with `invalid-input`.
 */
export function parseImport(file: string | Uint8Array | ArrayBuffer, kind: ImportKind): ParsedImport {
  if (!IMPORT_KINDS.includes(kind)) throw new BookmarkError('invalid-input', `The import kind must be one of ${IMPORT_KINDS.join(', ')}`);
  const text = decode(file);
  return kind === 'netscape-html' ? parseNetscape(text) : parsePocketCsv(text);
}
