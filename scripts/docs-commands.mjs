import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { join } from 'node:path';

// Docs name Subset commands as `subset <tool>`, skills and MCP configs as `npx -y subset.dev <tool>` (AGENTS.md,
// SET-235). This finds a closed set of older forms in the repository's Markdown; other forms are not checked.
//   1. `npx @subset.dev/<package>` or `npx -y @subset.dev/<package>`, anywhere in a file;
//   2. a line starting with `subset-<tool>` (optionally after a `$ ` prompt) inside a fenced shell block;
//   3. `"command": "subset-<tool>"` inside a fenced JSON block.

const SHELL_LANGUAGES = new Set(['bash', 'console', 'sh', 'sh-session', 'shell', 'shell-session', 'zsh']);
const JSON_LANGUAGES = new Set(['json', 'json5', 'jsonc']);
const EXCLUDED_SEGMENTS = new Set(['test', 'fixtures']);
const EXCLUDED_FILES = new Set(['docs/architecture.md']);

const NPX_SCOPED = /\bnpx\s+(?:-y\s+)?@subset\.dev\/[a-z0-9][a-z0-9._-]*/g;
const escapeRegExp = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

/** Whether the docs check reads this repository-relative path: Markdown outside test/, fixtures/, changelogs and docs/architecture.md. */
export function isCheckedDoc(path) {
  const segments = path.split('/');
  if (!path.endsWith('.md') || EXCLUDED_FILES.has(path) || segments.at(-1) === 'CHANGELOG.md') return false;
  return !segments.slice(0, -1).some((segment) => EXCLUDED_SEGMENTS.has(segment));
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
  let fence = null; // { marker, length, language } while inside a fenced block
  for (const [index, line] of text.split(/\r?\n/).entries()) {
    const at = `${path}:${index + 1}`;
    for (const [form] of line.matchAll(NPX_SCOPED)) {
      problems.push(`${at}: "${form}" runs a scoped package; write npx subset.dev <tool> (npx -y subset.dev <tool> in skills and MCP configs)`);
    }
    if (fence === null) {
      // A backtick fence's info string has no backtick (CommonMark), so ```x``` on one line is inline code.
      const opening = /^\s*(?:(`{3,})(?!.*`)|(~{3,}))\s*([^\s{]*)/.exec(line);
      if (opening) {
        const marker = opening[1] ?? opening[2];
        fence = { marker: marker[0], length: marker.length, language: opening[3].toLowerCase() };
      }
      continue;
    }
    const closing = /^\s*(`{3,}|~{3,})\s*$/.exec(line);
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
