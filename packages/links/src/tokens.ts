import { Tokenizer } from 'htmlparser2';

export interface TagHandlers {
  /** Tags whose attributes are collected; other tags still produce events, with empty attributes. */
  attributesOf: ReadonlySet<string>;
  /**
   * A start tag, after all its attributes. Names are lowercased; the first of a repeated attribute wins.
   * `foreign` is true inside inline SVG or MathML.
   */
  openTag(name: string, attributes: ReadonlyMap<string, string>, foreign: boolean): void;
  closeTag?(name: string): void;
  /** Whether `text` wants the text that follows; other text is skipped without being copied. */
  readonly capturingText?: boolean;
  /** Decoded text, in pieces. */
  text?(data: string): void;
}

const NO_ATTRIBUTES: ReadonlyMap<string, string> = new Map();

/**
 * Runs htmlparser2's tokenizer over `html`, decoding entities. The tokenizer alone keeps no element stack, so
 * the work is linear in the input; htmlparser2's Parser keeps one with Array#unshift, which is quadratic on
 * deeply nested markup. Script, style and title content is raw text, as in a browser, except inside SVG or
 * MathML.
 */
export function scanHtml(html: string, handlers: TagHandlers): void {
  let tagName = '';
  let attributes: Map<string, string> | undefined;
  let attributeName = '';
  let attributeValue = '';
  let foreignDepth = 0;

  const openTag = (selfClosing: boolean) => {
    handlers.openTag(tagName, attributes ?? NO_ATTRIBUTES, foreignDepth > 0);
    if ((tagName === 'svg' || tagName === 'math') && !selfClosing) foreignDepth++;
    attributes = undefined;
  };

  const tokenizer = new Tokenizer(
    { decodeEntities: true },
    {
      onopentagname(start, end) {
        tagName = html.slice(start, end).toLowerCase();
        attributes = handlers.attributesOf.has(tagName) ? new Map() : undefined;
      },
      onattribname(start, end) {
        if (attributes) attributeName = html.slice(start, end).toLowerCase();
        attributeValue = '';
      },
      onattribdata(start, end) {
        if (attributes) attributeValue += html.slice(start, end);
      },
      onattribentity(codePoint) {
        if (attributes) attributeValue += String.fromCodePoint(codePoint);
      },
      onattribend() {
        if (attributes && !attributes.has(attributeName)) attributes.set(attributeName, attributeValue);
        attributeValue = '';
      },
      onopentagend: () => openTag(false),
      onselfclosingtag: () => openTag(true),
      onclosetag(start, end) {
        const name = html.slice(start, end).toLowerCase();
        if ((name === 'svg' || name === 'math') && foreignDepth > 0) foreignDepth--;
        handlers.closeTag?.(name);
      },
      ontext(start, end) {
        if (handlers.capturingText) handlers.text?.(html.slice(start, end));
      },
      ontextentity(codePoint) {
        if (handlers.capturingText) handlers.text?.(String.fromCodePoint(codePoint));
      },
      oncdata() {},
      oncomment() {},
      ondeclaration() {},
      onprocessinginstruction() {},
      onend() {},
      isInForeignContext: () => foreignDepth > 0
    }
  );
  tokenizer.write(html);
  tokenizer.end();
}
