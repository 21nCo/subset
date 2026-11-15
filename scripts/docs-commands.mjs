import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// Docs name Subset commands as `subset <tool>`, skills and MCP configs as `npx -y subset.dev <tool>` (AGENTS.md,
// SET-235). This finds a closed set of older forms in the repository's Markdown; other forms are not checked.
//   1. `npx @subset.dev/<package>` or `npx -y @subset.dev/<package>`, anywhere in a file;
//   2. a line starting with `subset-<tool>` (optionally after a `$ ` prompt) inside a fenced shell block, a fence
//      being indented at most 3 spaces from the margin or from its list item's content (CommonMark);
//   3. `"command": "subset-<tool>"` inside a fenced JSON block.

const SHELL_LANGUAGES = new Set(['bash', 'console', 'sh', 'sh-session', 'shell', 'shell-session', 'zsh']);
const JSON_LANGUAGES = new Set(['json', 'json5', 'jsonc']);
const EXCLUDED_SEGMENTS = new Set(['test', 'fixtures']);
const EXCLUDED_FILES = new Set(['docs/architecture.md']);

// A list item's marker: a bullet, or up to nine digits and `.` or `)`, then a space, a tab or the end of the line.
const LIST_MARKER = /^(?:[-+*]|\d{1,9}[.)])(?=[ \t]|$)/;
// A thematic break (three or more of one of `-`, `*`, `_`, with spaces or tabs between), which is not a list item.
const THEMATIC_BREAK = /^([-*_])(?:[ \t]*\1){2,}[ \t]*$/;
const NPX_SCOPED = /\bnpx\s+(?:-y\s+)?@subset\.dev\/[a-z0-9][a-z0-9._-]*/g;
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Whether the docs check reads this repository-relative path: Markdown outside test/, fixtures/, changelogs and docs/architecture.md. */
export function isCheckedDoc(path) {
  const segments = path.split('/');
  if (!path.endsWith('.md') || EXCLUDED_FILES.has(path) || segments.at(-1) === 'CHANGELOG.md') return false;
  return !segments.slice(0, -1).some((segment) => EXCLUDED_SEGMENTS.has(segment));
}

/**
 * The leading spaces and tabs of `text`, which starts at column `start`, as a width in columns (a tab goes to the next
 * multiple of 4), and the text after them.
 */
function splitIndent(text, start = 0) {
  let column = start;
  let index = 0;
  for (; index < text.length && (text[index] === ' ' || text[index] === '\t'); index += 1) {
    column += text[index] === '\t' ? 4 - (column % 4) : 1;
  }
  return { width: column - start, rest: text.slice(index) };
}

/**
 * Returns `<path>:<line>: <problem>` for each closed-set form in a Markdown document. `tools` are the subset.dev
 * launcher's tool names (packages/subset-dev/src/tools.mjs); `subset-<tool>` is checked for each of them.
 */
export function docCommandProblems(path, text, tools) {
  const alternatives = [...tools].map(escapeRegExp).join('|');
  const shellCommand = alternatives ? new RegExp(`^\\s*(?:\\$\\s+)?(subset-(?:${alternatives}))(?=\\s|$)`) : null;
  const jsonCommand = alternatives ? new RegExp(`"command"\\s*:\\s*"(subset-(?:${alternatives}))"`, 'g') : null;
  const problems = [];
  let fence = null; // { marker, length, language, base } while inside a fenced block
  const items = []; // the content columns of the open list items, outermost first
  let paragraph = null; // the content column of the container whose paragraph the previous line was in, if any
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    const at = `${path}:${index + 1}`;
    for (const [form] of line.matchAll(NPX_SCOPED)) {
      problems.push(`${at}: "${form}" runs a scoped package; write npx subset.dev <tool> (npx -y subset.dev <tool> in skills and MCP configs)`);
    }
    const { width, rest } = splitIndent(line);
    // A line indented less than the list item holding the block ends the item, and with it the block.
    if (fence !== null && rest !== '' && width < fence.base) fence = null;
    if (fence === null) {
      if (rest === '') {
        paragraph = null; // a blank line ends a paragraph and keeps the list items open
        continue;
      }
      let depth = items.length;
      while (depth > 0 && width < items[depth - 1]) depth -= 1;
      let base = depth > 0 ? items[depth - 1] : 0;
      let column = width;
      let content = rest;
      const opened = [];
      // Markers indented up to 3 columns from the enclosing item open items; their content may open a fence.
      for (let marker; column - base <= 3 && !THEMATIC_BREAK.test(content) && (marker = LIST_MARKER.exec(content)); ) {
        const after = splitIndent(content.slice(marker[0].length), column + marker[0].length);
        // A list that interrupts a paragraph starts with an item that is not empty and, if numbered, is 1; otherwise the
        // line continues the paragraph, or underlines it as a setext heading.
        if (opened.length === 0 && paragraph === base && (after.rest === '' || (/^\d/.test(marker[0]) && !/^0*1\D/.test(marker[0])))) break;
        // One to four spaces after the marker set the item's content column; more start indented code in it.
        base = column + marker[0].length + (after.rest === '' || after.width > 4 ? 1 : after.width);
        opened.push(base);
        column += marker[0].length + after.width;
        content = after.rest;
      }
      // A fence is indented at most 3 columns from its list item (from the margin outside one); more is indented
      // code. A backtick fence's info string has no backtick (CommonMark), so ```x``` on one line is inline code.
      const indented = column - base > 3;
      const opening = !indented && /^(?:(`{3,})(?!.*`)|(~{3,}))\s*([^\s{]*)/.exec(content);
      const ending = !indented && (content === '' || THEMATIC_BREAK.test(content) || /^#{1,6}(?:[ \t]|$)/.test(content)
        || (paragraph !== null && opened.length === 0 && /^(?:=+|-+)[ \t]*$/.test(content)));
      // A paragraph's continuation keeps its list items open even when it is indented less (a lazy line).
      if (paragraph === null || opened.length > 0 || opening || ending) items.splice(depth, Infinity, ...opened);
      if (opening) {
        const marker = opening[1] ?? opening[2];
        fence = { marker: marker[0], length: marker.length, language: opening[3].toLowerCase(), base };
        paragraph = null;
      } else if (ending || (indented && (paragraph === null || opened.length > 0))) {
        paragraph = null; // an empty item, a break, a heading or its underline, or indented code
      } else if (paragraph === null || opened.length > 0) {
        paragraph = base;
      }
      continue;
    }
    const closing = width - fence.base <= 3 && /^(`{3,}|~{3,})\s*$/.exec(rest);
    if (closing && closing[1][0] === fence.marker && closing[1].length >= fence.length) {
      fence = null;
      continue;
    }
    if (shellCommand && SHELL_LANGUAGES.has(fence.language)) {
      const match = shellCommand.exec(line);
      if (match) problems.push(`${at}: a shell block runs ${match[1]}; write subset ${match[1].slice('subset-'.length)} (npx -y subset.dev ${match[1].slice('subset-'.length)} in skills)`);
    }
    if (jsonCommand && JSON_LANGUAGES.has(fence.language)) {
      for (const [, command] of line.matchAll(jsonCommand)) {
        const tool = command.slice('subset-'.length);
        problems.push(`${at}: an MCP config runs "${command}"; write "command": "npx", "args": ["-y", "subset.dev", "${tool}", "mcp"]`);
      }
    }
  }
  return problems;
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
