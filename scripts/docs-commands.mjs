import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// Docs name Subset commands as `subset <tool>`, skills and MCP configs as `npx -y subset.dev <tool>` (AGENTS.md,
// SET-235). This finds a closed set of older forms in the repository's Markdown; other forms are not checked.
//   1. `npx @subset.dev/<package>` or `npx -y @subset.dev/<package>`, anywhere in a file;
//   2. a line starting with `subset-<tool>` (optionally after a `$ ` prompt) inside a fenced shell block;
//   3. `"command": "subset-<tool>"` inside a fenced JSON block.
// A line is in a fenced block where CommonMark (as GitHub and markdown-it render it, HTML blocks on) puts it there, so
// fences are found by CommonMark's block structure: block quotes, list items, lazy paragraph lines, setext headings,
// HTML blocks and indented code decide which lines open, continue and close a fence.

const SHELL_LANGUAGES = new Set(['bash', 'console', 'sh', 'sh-session', 'shell', 'shell-session', 'zsh']);
const JSON_LANGUAGES = new Set(['json', 'json5', 'jsonc']);
const EXCLUDED_SEGMENTS = new Set(['test', 'fixtures']);
const EXCLUDED_FILES = new Set(['docs/architecture.md']);

const ATX_HEADING = /^#{1,6}(?: |$)/;
const FENCE_OPEN = /^(?:(`{3,})(?!.*`)|(~{3,}))\s*([^\s{]*)/; // a backtick fence's info string has no backtick
const FENCE_CLOSE = /^(`{3,}|~{3,}) *$/;
const SETEXT_UNDERLINE = /^(?:=+|-+) *$/;
// Three or more of one of `-`, `*`, `_`, with spaces between: a thematic break, which is not a list item.
const THEMATIC_BREAK = /^([-*_])(?: *\1){2,} *$/;
// A list item's marker: a bullet, or up to nine digits and `.` or `)`, then a space or the end of the line.
const LIST_MARKER = /^(?:[-+*]|(\d{1,9})[.)])(?= |$)/;
const HTML_TAG = '(?:<[A-Za-z][A-Za-z0-9-]*(?:\\s+[a-zA-Z_:][a-zA-Z0-9:._-]*(?:\\s*=\\s*(?:[^"\'=<>`\\x00-\\x20]+|\'[^\']*\'|"[^"]*"))?)*\\s*\\/?>|<\\/[A-Za-z][A-Za-z0-9-]*\\s*>)';
const HTML_BLOCK_NAMES = 'address|article|aside|base|basefont|blockquote|body|caption|center|col|colgroup|dd|details|dialog|dir|div|dl|dt|fieldset|figcaption|figure|footer|form|frame|frameset|h[1-6]|head|header|hr|html|iframe|legend|li|link|main|menu|menuitem|nav|noframes|ol|optgroup|option|p|param|search|section|summary|table|tbody|td|tfoot|th|thead|title|tr|track|ul';
// HTML block start conditions 1 to 7 with their end conditions (null: a blank line); the last cannot interrupt a paragraph.
const HTML_BLOCKS = [
  [/^<(?:script|pre|style|textarea)(?=\s|>|$)/i, /<\/(?:script|pre|style|textarea)>/i],
  [/^<!--/, /-->/],
  [/^<\?/, /\?>/],
  [/^<![A-Z]/, />/],
  [/^<!\[CDATA\[/, /\]\]>/],
  [new RegExp(`^</?(?:${HTML_BLOCK_NAMES})(?=\\s|/?>|$)`, 'i'), null],
  [new RegExp(`^${HTML_TAG}\\s*$`), null]
];
const NPX_SCOPED = /\bnpx\s+(?:-y\s+)?@subset\.dev\/[a-z0-9][a-z0-9._-]*/g;
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Whether the docs check reads this repository-relative path: Markdown outside test/, fixtures/, changelogs and docs/architecture.md. */
export function isCheckedDoc(path) {
  const segments = path.split('/');
  if (!path.endsWith('.md') || EXCLUDED_FILES.has(path) || segments.at(-1) === 'CHANGELOG.md') return false;
  return !segments.slice(0, -1).some((segment) => EXCLUDED_SEGMENTS.has(segment));
}

/** `line` with its tabs replaced by spaces up to the next multiple of 4 columns, as CommonMark reads block structure. */
function expandTabs(line) {
  let expanded = '';
  for (const char of line) expanded += char === '\t' ? ' '.repeat(4 - (expanded.length % 4)) : char;
  return expanded;
}

/**
 * Yields `{ index, language, content }` for each line inside a fenced code block of a Markdown document, `content`
 * being the line without its block-quote and list-item prefixes. It follows CommonMark's parsing strategy for each
 * line: match the open containers (block quotes, list items) in order, then open new blocks, and only a line that
 * opens no block may continue a paragraph lazily, keeping unmatched containers open.
 */
function* fencedLines(text) {
  const open = []; // the open containers, outermost first: { quote: true } or a list item { width, empty }
  let leaf = null; // the open leaf in the innermost container: paragraph, fence, code (indented) or html
  for (const [index, raw] of text.split(/\r?\n/).entries()) {
    const line = expandTabs(raw);
    let column = 0;
    let next;
    let indent;
    let blank;
    const look = () => {
      for (next = column; line[next] === ' '; next += 1);
      indent = next - column;
      blank = next >= line.length;
    };
    let depth = 0;
    for (; depth < open.length; depth += 1) {
      look();
      const container = open[depth];
      if (container.quote) {
        if (indent > 3 || line[next] !== '>') break;
        column = next + (line[next + 1] === ' ' ? 2 : 1);
      } else if (blank) {
        if (container.empty) break; // an item that starts with a blank line ends at a second one
        column = next;
      } else if (indent >= container.width) {
        column += container.width;
      } else {
        break;
      }
    }
    look();
    let leafMatched = false;
    if (depth === open.length && leaf) {
      if (leaf.kind === 'fence') {
        const closing = indent <= 3 && FENCE_CLOSE.exec(line.slice(next));
        if (closing && closing[1][0] === leaf.char && closing[1].length >= leaf.length) leaf = null;
        else yield { index, language: leaf.language, content: line.slice(column) };
        continue;
      }
      leafMatched = leaf.kind === 'code' ? indent >= 4 || blank : leaf.kind === 'paragraph' || leaf.end === null ? !blank : true;
      if (leafMatched && leaf.kind !== 'paragraph') {
        if (leaf.end?.test(line.slice(column))) leaf = null;
        continue;
      }
    }
    let allClosed = depth === open.length && (leaf === null || leafMatched);
    let inParagraph = allClosed && leaf?.kind === 'paragraph'; // the line's innermost matched block is a paragraph
    // Closes the blocks the line did not match, before a new block is added to the innermost matched container.
    const add = () => {
      open.length = depth;
      if (depth > 0) open[depth - 1].empty = false;
      allClosed = true;
      inParagraph = false;
      leaf = null;
    };
    let leafLine = false; // the line opened a leaf block, or underlined a paragraph
    for (;;) {
      look();
      const rest = line.slice(next);
      if (indent >= 4) {
        // Indented code, which cannot interrupt a paragraph.
        if (!blank && leaf?.kind !== 'paragraph') {
          add();
          leaf = { kind: 'code' };
          leafLine = true;
        }
        break;
      }
      if (rest[0] === '>') {
        add();
        open.push({ quote: true });
        depth += 1;
        column = next + (line[next + 1] === ' ' ? 2 : 1);
        continue;
      }
      const fence = FENCE_OPEN.exec(rest);
      const html = rest[0] === '<' ? HTML_BLOCKS.findIndex(([opening]) => opening.test(rest)) : -1;
      const marker = LIST_MARKER.exec(rest);
      leafLine = true;
      if (ATX_HEADING.test(rest)) {
        add();
      } else if (fence) {
        add();
        const run = fence[1] ?? fence[2];
        leaf = { kind: 'fence', char: run[0], length: run.length, language: fence[3].toLowerCase() };
      } else if (html >= 0 && (html < 6 || (!inParagraph && (allClosed || leaf?.kind !== 'paragraph')))) {
        add();
        const end = HTML_BLOCKS[html][1];
        if (!end?.test(rest)) leaf = { kind: 'html', end };
      } else if (inParagraph && SETEXT_UNDERLINE.test(rest)) {
        leaf = null; // a setext heading: only a paragraph in the same containers takes an underline
      } else if (THEMATIC_BREAK.test(rest)) {
        add();
      } else if (marker && !(inParagraph && (/^ *$/.test(rest.slice(marker[0].length)) || (marker[1] !== undefined && Number(marker[1]) !== 1)))) {
        // A list interrupts a paragraph only with an item that is not empty and, if numbered, is 1. One to four spaces
        // after the marker set the item's content column; none (an empty item) or five or more set it one column on.
        const spaces = /^ */.exec(rest.slice(marker[0].length))[0].length;
        const padding = marker[0].length + (next + marker[0].length + spaces >= line.length || spaces > 4 ? 1 : spaces);
        add();
        open.push({ width: indent + padding, empty: true });
        depth += 1;
        column = next + padding;
        leafLine = false;
        continue;
      } else {
        leafLine = false;
      }
      break;
    }
    if (leafLine) continue;
    // A line that opens no block continues the open paragraph, lazily when its containers did not all match.
    if (!allClosed && !blank && leaf?.kind === 'paragraph') continue;
    if (!allClosed) {
      open.length = depth;
      leaf = null;
    }
    if (leaf === null && !blank) {
      add();
      leaf = { kind: 'paragraph' };
    }
  }
}

/**
 * Returns `<path>:<line>: <problem>` for each closed-set form in a Markdown document. `tools` are the subset.dev
 * launcher's tool names (packages/subset-dev/src/tools.mjs); `subset-<tool>` is checked for each of them.
 */
export function docCommandProblems(path, text, tools) {
  const alternatives = [...tools].map(escapeRegExp).join('|');
  const shellCommand = alternatives ? new RegExp(`^\\s*(?:\\$\\s+)?(subset-(?:${alternatives}))(?=\\s|$)`) : null;
  const jsonCommand = alternatives ? new RegExp(`"command"\\s*:\\s*"(subset-(?:${alternatives}))"`, 'g') : null;
  const problems = []; // [line index, problem]
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    for (const [form] of line.matchAll(NPX_SCOPED)) {
      problems.push([index, `${path}:${index + 1}: "${form}" runs a scoped package; write npx subset.dev <tool> (npx -y subset.dev <tool> in skills and MCP configs)`]);
    }
  }
  for (const { index, language, content } of fencedLines(text)) {
    const at = `${path}:${index + 1}`;
    const shell = shellCommand && SHELL_LANGUAGES.has(language) && shellCommand.exec(content);
    if (shell) {
      const tool = shell[1].slice('subset-'.length);
      problems.push([index, `${at}: a shell block runs ${shell[1]}; write subset ${tool} (npx -y subset.dev ${tool} in skills)`]);
    }
    if (jsonCommand && JSON_LANGUAGES.has(language)) {
      for (const [, command] of content.matchAll(jsonCommand)) {
        const tool = command.slice('subset-'.length);
        problems.push([index, `${at}: an MCP config runs "${command}"; write "command": "npx", "args": ["-y", "subset.dev", "${tool}", "mcp"]`]);
      }
    }
  }
  return problems.sort(([a], [b]) => a - b).map(([, problem]) => problem);
}

/** The repository's checked Markdown files (tracked or new, not ignored), relative to `root`. */
export function checkedDocs(root) {
  const listed = execFileSync('git', ['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', '*.md'], { cwd: root, encoding: 'utf8' });
  return [...new Set(listed.split('\0'))].filter((path) => path && isCheckedDoc(path) && existsSync(join(root, path))).sort();
}

/** Every closed-set form in the repository's checked Markdown. */
export function repositoryDocProblems(root, tools) {
  return checkedDocs(root).flatMap((path) => docCommandProblems(path, readFileSync(join(root, path), 'utf8'), tools));
}
