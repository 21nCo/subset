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
const NPX_SCOPED = /\bnpx\s+(?:-y\s+)?@subset\.dev\/[a-z0-9][a-z0-9._-]*/g;
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Whether the docs check reads this repository-relative path: Markdown outside test/, fixtures/, changelogs and docs/architecture.md. */
export function isCheckedDoc(path) {
  const segments = path.split('/');
  if (!path.endsWith('.md') || EXCLUDED_FILES.has(path) || segments.at(-1) === 'CHANGELOG.md') return false;
  return !segments.slice(0, -1).some((segment) => EXCLUDED_SEGMENTS.has(segment));
}

/** A line's leading indentation in columns (a tab goes to the next multiple of 4) and the text after it. */
function splitIndent(line) {
  let width = 0;
  let index = 0;
  for (; index < line.length && (line[index] === ' ' || line[index] === '\t'); index += 1) {
    width += line[index] === '\t' ? 4 - (width % 4) : 1;
  }
  return { width, rest: line.slice(index) };
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
  const items = []; // the content columns of the open list items, outermost first (CommonMark, without lazy lines)
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    const at = `${path}:${index + 1}`;
    for (const [form] of line.matchAll(NPX_SCOPED)) {
      problems.push(`${at}: "${form}" runs a scoped package; write npx subset.dev <tool> (npx -y subset.dev <tool> in skills and MCP configs)`);
    }
    const { width, rest } = splitIndent(line);
    // A line indented less than the list item holding the block ends the item, and with it the block.
    if (fence !== null && rest !== '' && width < fence.base) fence = null;
    if (fence === null) {
      if (rest === '') continue; // a blank line keeps the list items open
      while (items.length > 0 && width < items.at(-1)) items.pop();
      let base = items.at(-1) ?? 0;
      let column = width;
      let content = rest;
      // Markers indented up to 3 columns from the enclosing item open items; their content may open a fence.
      for (let marker; column - base <= 3 && (marker = LIST_MARKER.exec(content)); ) {
        const after = splitIndent(content.slice(marker[0].length));
        // One to four spaces after the marker set the item's content column; more start indented code in it.
        base = column + marker[0].length + (after.rest === '' || after.width > 4 ? 1 : after.width);
        items.push(base);
        column += marker[0].length + after.width;
        content = after.rest;
      }
      // A fence is indented at most 3 columns from its list item (from the margin outside one); more is indented
      // code. A backtick fence's info string has no backtick (CommonMark), so ```x``` on one line is inline code.
      const opening = column - base <= 3 && /^(?:(`{3,})(?!.*`)|(~{3,}))\s*([^\s{]*)/.exec(content);
      if (opening) {
        const marker = opening[1] ?? opening[2];
        fence = { marker: marker[0], length: marker.length, language: opening[3].toLowerCase(), base };
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
