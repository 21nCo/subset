import { scanHtml } from './tokens.js';

/** Only this many bytes of a document are parsed. A string counts as its UTF-8 encoding. */
export const MAX_DOCUMENT_BYTES = 512 * 1024;

// The HTML standard's encoding sniffing looks for a <meta> charset in the first 1,024 bytes.
const PRESCAN_BYTES = 1024;
const CHARSET_PARAMETER = /charset\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s;"']+))/i;

export interface ContentType {
  /** `type/subtype`, lowercased, without parameters. */
  essence: string;
  charset?: string;
}

/** Parses a Content-Type header value. Returns undefined for a value without a valid `type/subtype`. */
export function parseContentType(value: string | undefined): ContentType | undefined {
  if (!value) return undefined;
  const [mediaType = '', ...parameters] = value.split(';');
  const essence = mediaType.trim().toLowerCase();
  if (!/^[a-z0-9!#$%&'*+.^_`|~-]+\/[a-z0-9!#$%&'*+.^_`|~-]+$/.test(essence)) return undefined;
  const charset = CHARSET_PARAMETER.exec(parameters.join(';'));
  const label = charset?.[1] ?? charset?.[2] ?? charset?.[3];
  return label ? { essence, charset: label.trim() } : { essence };
}

/**
 * The first `MAX_DOCUMENT_BYTES` of a document as text, with a string measured as UTF-8. Bytes are decoded with, in order, a byte order mark,
 * the Content-Type charset, a `<meta>` charset in the first 1,024 bytes, or UTF-8. A label the runtime's
 * TextDecoder does not support is skipped.
 */
export function decodeDocument(input: string | ArrayBuffer | ArrayBufferView, headerCharset?: string): string {
  if (typeof input === 'string') {
    // A UTF-16 code unit is at most 3 UTF-8 bytes.
    if (input.length * 3 <= MAX_DOCUMENT_BYTES) return input;
    // encodeInto stops at the first character that does not fit, so `read` never splits one, and it
    // counts a lone surrogate as the 3 bytes of U+FFFD, as TextEncoder#encode does for byte input.
    const { read } = new TextEncoder().encodeInto(input, new Uint8Array(MAX_DOCUMENT_BYTES));
    return input.slice(0, read);
  }
  const bytes = toBytes(input).subarray(0, MAX_DOCUMENT_BYTES);
  const encoding = bomEncoding(bytes) ?? supportedEncoding(headerCharset) ?? metaEncoding(bytes) ?? 'utf-8';
  // Streaming mode drops a multi-byte sequence the 512 KB cut left incomplete instead of emitting U+FFFD.
  return new TextDecoder(encoding).decode(bytes, { stream: true });
}

function toBytes(input: ArrayBuffer | ArrayBufferView): Uint8Array {
  if (input instanceof ArrayBuffer) return new Uint8Array(input);
  if (ArrayBuffer.isView(input)) return new Uint8Array(input.buffer, input.byteOffset, input.byteLength);
  throw new TypeError('Expected the document as a string, ArrayBuffer or typed array');
}

function bomEncoding(bytes: Uint8Array): string | undefined {
  if (bytes[0] === 0xef && bytes[1] === 0xbb && bytes[2] === 0xbf) return 'utf-8';
  if (bytes[0] === 0xfe && bytes[1] === 0xff) return 'utf-16be';
  if (bytes[0] === 0xff && bytes[1] === 0xfe) return 'utf-16le';
  return undefined;
}

/** The TextDecoder name for a charset label, or undefined when the runtime does not support it. */
function supportedEncoding(label: string | undefined): string | undefined {
  if (!label) return undefined;
  try {
    return new TextDecoder(label.trim()).encoding;
  } catch {
    return undefined;
  }
}

function metaEncoding(bytes: Uint8Array): string | undefined {
  // Every byte maps to one character, so ASCII markup reads correctly whatever the real encoding is.
  const head = String.fromCharCode(...bytes.subarray(0, PRESCAN_BYTES));
  let label: string | undefined;
  scanHtml(head, {
    attributesOf: new Set(['meta']),
    openTag(name, attributes) {
      if (label !== undefined || name !== 'meta') return;
      const content = attributes.get('content');
      if (attributes.has('charset')) label = attributes.get('charset');
      else if (attributes.get('http-equiv')?.trim().toLowerCase() === 'content-type' && content !== undefined) {
        const match = CHARSET_PARAMETER.exec(content);
        label = match?.[1] ?? match?.[2] ?? match?.[3];
      }
    }
  });
  const encoding = supportedEncoding(label);
  // A document whose bytes are ASCII-compatible enough to declare a charset this way is not UTF-16, and
  // x-user-defined means windows-1252 here (HTML standard, "prescan a byte stream").
  if (encoding === 'utf-16le' || encoding === 'utf-16be') return 'utf-8';
  if (encoding === 'x-user-defined') return 'windows-1252';
  return encoding;
}
