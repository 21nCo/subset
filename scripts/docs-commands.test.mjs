import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import test from 'node:test';
import { checkedDocs, docCommandProblems, isCheckedDoc, repositoryDocProblems } from './docs-commands.mjs';

const TOOLS = ['minutes', 'point-in-time', 'system', 'timer', 'usage'];
const problems = (text, path = 'README.md') => docCommandProblems(path, text, TOOLS);
const lines = (...items) => items.join('\n');

test('npx of a scoped @subset.dev package fails with its file and line, with or without -y', () => {
  assert.deepEqual(problems(lines('# Usage', '', 'Run `npx @subset.dev/usage status`.')), [
    'README.md:3: "npx @subset.dev/usage" runs a scoped package; write npx subset.dev <tool> (npx -y subset.dev <tool> in skills and MCP configs)'
  ]);
  const found = problems(lines('```sh', 'npx -y @subset.dev/timer@beta list', '```'), 'packages/x/README.md');
  assert.equal(found.length, 1);
  assert.match(found[0], /^packages\/x\/README\.md:2: "npx -y @subset\.dev\/timer" runs a scoped package/);
});

test('a shell block line that starts with subset-<tool> fails with its file and line', () => {
  for (const language of ['sh', 'bash', 'shell', 'zsh', 'console', 'Shell']) {
    assert.deepEqual(problems(lines('Intro', `\`\`\`${language}`, 'npm ci', 'subset-timer start 25m --json', '```')), [
      'README.md:4: a shell block runs subset-timer; write subset timer (npx -y subset.dev timer in skills)'
    ], language);
  }
  // A prompt, indentation, a bare command, a tilde fence and a hyphenated tool name are the same form.
  assert.match(problems(lines('```console', '$ subset-minutes join https://example.com/x --json', '```'))[0], /^README\.md:2: .*subset-minutes/);
  assert.match(problems(lines('- step', '  ```sh', '  subset-usage', '  ```'))[0], /^README\.md:3: .*subset-usage/);
  assert.match(problems(lines('~~~bash', 'subset-point-in-time status', '~~~'))[0], /^README\.md:2: .*subset point-in-time/);
});

test('"command": "subset-<tool>" in a JSON block fails with its file and line', () => {
  assert.deepEqual(problems(lines('Claude Desktop:', '', '```json', '{ "mcpServers": { "subset-timer": { "command": "subset-timer", "args": ["mcp"] } } }', '```')), [
    'README.md:4: an MCP config runs "subset-timer"; write "command": "npx", "args": ["-y", "subset.dev", "timer", "mcp"]'
  ]);
  assert.match(problems(lines('```jsonc', '{', '  "command" :"subset-usage",', '}', '```'))[0], /^README\.md:3: an MCP config runs "subset-usage"/);
});

test('the documented forms and package names in prose pass', () => {
  const allowed = lines(
    'The `subset-timer` CLI is `@subset.dev/timer`; its bin is subset-timer. Install with `npm install -g subset.dev`.',
    'subset-timer start 25m',
    '```sh',
    'subset timer start 25m --name Tea',
    'npx subset.dev usage status',
    'npx -y subset.dev timer list --json',
    'ln -s /Applications/X.app/Contents/Helpers/subset-system /usr/local/bin/subset-system',
    'subset-timers start',
    'subset-dev --help',
    '```',
    '```json',
    '{ "mcpServers": { "subset-timer": { "command": "npx", "args": ["-y", "subset.dev", "timer", "mcp"] } } }',
    '{ "tools": [{ "id": "usage", "package": "@subset.dev/usage", "bin": "subset-usage" }] }',
    '```'
  );
  assert.deepEqual(problems(allowed), []);
});

test('subset-<tool> lines are checked only inside shell blocks and "command" only inside JSON blocks', () => {
  const text = lines(
    '```text',
    'subset-timer start 25m',
    '{ "command": "subset-timer" }',
    '```',
    'subset-timer list',
    '```sh',
    'echo "command": "subset-timer"',
    '```',
    '```json',
    'subset-timer list',
    '```',
    '`"command": "subset-timer"` in prose'
  );
  assert.deepEqual(problems(text), []);
});

test('a block ends only at its own closing fence', () => {
  // A ``` line inside a ```` block, or ``` inside a ~~~ block, does not end it; the line after the real end is prose.
  const text = lines('````sh', '```', 'subset-usage status', '````', 'subset-usage status', '~~~sh', '```', 'subset-timer list', '~~~', 'subset-timer list');
  assert.deepEqual(problems(text).map((problem) => problem.split(':')[1]), ['3', '8']);
  // Inline code with three backticks on one line opens no block.
  assert.deepEqual(problems(lines('```sh echo```', 'subset-timer list')), []);
  // An unclosed block runs to the end of the file.
  assert.equal(problems(lines('```bash', 'subset-timer list')).length, 1);
});

test('a fence opens with up to three spaces of indentation, counted from its list item', () => {
  // Fences indented 0 to 3 spaces are checked.
  for (const indent of ['', ' ', '  ', '   ']) {
    assert.deepEqual(problems(lines('Intro', '', `${indent}\`\`\`sh`, `${indent}subset-timer list`, `${indent}\`\`\``)).map((problem) => problem.split(':')[1]), ['4'], JSON.stringify(indent));
  }
  // Four spaces at the top level make an indented code block (or a paragraph's continuation), not a fence.
  assert.deepEqual(problems(lines('Intro', '', '    ```sh', '    subset-timer list', '    ```', '', 'subset-timer list')), []);
  assert.deepEqual(problems(lines('Intro', '\t```sh', '\tsubset-timer list', '\t```')), []);
  // A fence nested in a list item is indented from the item's content: four spaces under "1. " or "- " is a fence.
  assert.deepEqual(problems(lines('1. Step:', '', '    ```sh', '    subset-timer list', '    ```')).map((problem) => problem.split(':')[1]), ['4']);
  assert.deepEqual(problems(lines('- Step:', '    ```sh', '    subset-usage status', '    ```', '- Next', '  ```bash', '  subset-minutes doctor', '  ```')).map((problem) => problem.split(':')[1]), ['3', '7']);
  assert.deepEqual(problems(lines('1. Step:', '   - Nested:', '     ```sh', '     subset-system status', '     ```')).map((problem) => problem.split(':')[1]), ['4']);
  assert.deepEqual(problems(lines('- ```sh', '  subset-timer list', '  ```')).map((problem) => problem.split(':')[1]), ['2']);
  // Seven spaces under "- " (five past its content) is indented code inside the item, not a fence.
  assert.deepEqual(problems(lines('- Step:', '', '       ```sh', '       subset-timer list', '       ```')), []);
  // A tab after the marker advances to the next multiple of four columns, so the item's content starts at column 4.
  assert.deepEqual(problems(lines('-\tStep:', '', '\t```sh', '\tsubset-timer list', '\t```')).map((problem) => problem.split(':')[1]), ['4']);
  assert.deepEqual(problems(lines('-\tStep:', '\t```json', '\t{ "command": "subset-timer" }', '\t```')).map((problem) => problem.split(':')[1]), ['3']);
  // A thematic break is not a list item, so four spaces after it is indented code.
  for (const rule of ['- - -', '* * *', '---', '***', '_ _ _', '-  -  -  -']) {
    assert.deepEqual(problems(lines(rule, '', '    ```sh', '    subset-timer list', '    ```')), [], rule);
  }
  // A "-" under a paragraph underlines a setext heading, so a fence after it is at the top level.
  assert.deepEqual(problems(lines('Title', '-', '', '  ```sh', 'subset-timer list', '  ```')).map((problem) => problem.split(':')[1]), ['5']);
  assert.deepEqual(problems(lines('Title', '-', '', '  ```json', '{ "command": "subset-timer" }', '  ```')).map((problem) => problem.split(':')[1]), ['5']);
  assert.deepEqual(problems(lines('Title', '-', '', '    ```sh', '    subset-timer list', '    ```')), []);
  assert.deepEqual(problems(lines('Title', '=====', '-', '', '  ```sh', '  subset-timer list', '  ```')).map((problem) => problem.split(':')[1]), ['6']);
  // A numbered line other than 1 cannot start a list inside a paragraph, so it continues the paragraph.
  assert.deepEqual(problems(lines('Released in', '2026. A good year.', '', '    ```sh', '    subset-timer list', '    ```')), []);
  // A lazy continuation line keeps its list item open, so the fence after it is in the item.
  assert.deepEqual(problems(lines('- Step', 'continued', '', '    ```sh', '    subset-timer list', '    ```')).map((problem) => problem.split(':')[1]), ['5']);
  // Once the list ends, four spaces is indented code again.
  assert.deepEqual(problems(lines('- Step', '', 'Prose.', '', '    ```sh', '    subset-timer list', '    ```')), []);
});

test('fences follow block quotes, HTML blocks and lazy lines as CommonMark nests them', () => {
  const at = (...items) => problems(lines(...items)).map((problem) => problem.split(':')[1]);
  const fenced = ['    ```sh', '    subset-timer list', '    ```'];
  const fencedJson = ['    ```json', '    { "command": "subset-usage" }', '    ```'];
  // A block quote or an HTML block after a list paragraph is not lazy: it ends the list, so four spaces is indented code.
  assert.deepEqual(at('- Step', '> Note', '', ...fenced), []);
  assert.deepEqual(at('- Step', '> Note', '', ...fencedJson), []);
  assert.deepEqual(at('- Step', '<div>', '', ...fenced), []);
  assert.deepEqual(at('- Step', '<div>', '', ...fencedJson), []);
  // A lazy "=" or "--" line is paragraph text, not a setext underline, so the list item stays open and holds the fence.
  for (const underline of ['=', '--']) {
    assert.deepEqual(at('- Foo', underline, '', ...fenced), ['5'], underline);
    assert.deepEqual(at('- Foo', underline, '', ...fencedJson), ['5'], underline);
  }
  // A fence in a block quote is checked; a quote's lines need their ">" (a lazy line ends the fence and the quote).
  assert.deepEqual(at('> ```sh', '> subset-timer list', '> ```'), ['2']);
  assert.deepEqual(at('> - Step', '>', '>   ```json', '>   { "command": "subset-usage" }', '>   ```'), ['4']);
  assert.deepEqual(at('> ```sh', 'subset-timer list', '```sh', 'subset-timer list'), ['4']);
  // An HTML block hides fence-like lines until its end condition; a comment's ends at "-->".
  assert.deepEqual(at('<div>', '```sh', 'subset-timer list', '```'), []);
  assert.deepEqual(at('<!--', '```sh', 'subset-timer list', '-->', '```sh', 'subset-timer list', '```'), ['6']);
  // Only "-->" ends a comment block: "--!>" does not, so the fence after it is still comment text, on both paths.
  for (const [opening, body] of [['```sh', 'subset-timer list'], ['```json', '{ "command": "subset-usage" }']]) {
    assert.deepEqual(at('<!-- note', 'x -->', opening, body, '```'), ['4'], opening);
    assert.deepEqual(at('<!-- note', 'x --!>', opening, body, '```'), [], opening);
    assert.deepEqual(at('<!-- note --> text', opening, body, '```'), ['3'], opening);
    assert.deepEqual(at('<!-- note --!> text', opening, body, '```'), [], opening);
  }
  // The other literal ends: a raw-text tag's end tag in any case, "?>", ">" and "]]>"; indented code is not ended by them.
  assert.deepEqual(at('<script>', '</SCRIPT>', '```sh', 'subset-timer list', '```'), ['4']);
  assert.deepEqual(at('<script>', '</script >', '```sh', 'subset-timer list', '```'), []);
  assert.deepEqual(at('<?php', '?>', '```sh', 'subset-timer list', '```'), ['4']);
  assert.deepEqual(at('<!DOCTYPE html', '>', '```sh', 'subset-timer list', '```'), ['4']);
  assert.deepEqual(at('<![CDATA[', ']]>', '```sh', 'subset-timer list', '```'), ['4']);
  assert.deepEqual(at('    -->', '', '```sh', 'subset-timer list', '```'), ['4']);
});

test('a closing fence is indented at most three spaces from its block, and a list item ends its block', () => {
  // A ``` line indented four spaces inside a top-level block is content, so the block goes on.
  assert.deepEqual(problems(lines('```sh', '    ```', 'subset-timer list', '```', 'subset-timer list')).map((problem) => problem.split(':')[1]), ['3']);
  // Up to three spaces still closes it.
  assert.deepEqual(problems(lines('```sh', '   ```', 'subset-timer list')), []);
  // A block in a list item closes at the item's indentation, or ends with the item.
  assert.deepEqual(problems(lines('- Step', '  ```sh', '  subset-usage status', '  ```', '  subset-usage status')).map((problem) => problem.split(':')[1]), ['3']);
  assert.deepEqual(problems(lines('- Step', '  ```sh', '  subset-usage status', 'Prose ends the item.', 'subset-usage status', '```sh', 'subset-timer list', '```')).map((problem) => problem.split(':')[1]), ['3', '7']);
});

test('reads Markdown outside test/, fixtures/, changelogs and docs/architecture.md', () => {
  for (const path of ['README.md', 'packages/timer-cli/README.md', 'packages/timer-cli/skills/subset-timer/SKILL.md', 'docs/macos-release.md', 'native/system/README.md']) {
    assert.equal(isCheckedDoc(path), true, path);
  }
  for (const path of ['packages/x/test/README.md', 'scripts/fixtures/a.md', 'test/x.md', 'CHANGELOG.md', 'packages/x/CHANGELOG.md', 'docs/architecture.md', 'README.txt', 'packages/x/README.mdx']) {
    assert.equal(isCheckedDoc(path), false, path);
  }
  assert.equal(isCheckedDoc('packages/testing/README.md'), true);
});

test('checks the tracked and new Markdown of a repository, not ignored or excluded files', (t) => {
  const root = mkdtempSync(join(tmpdir(), 'subset-docs-'));
  t.after(() => rmSync(root, { recursive: true, force: true }));
  const write = (path, text) => {
    mkdirSync(dirname(join(root, path)), { recursive: true });
    writeFileSync(join(root, path), text);
  };
  execFileSync('git', ['init', '-q'], { cwd: root });
  write('.gitignore', 'node_modules/\n');
  write('README.md', lines('```sh', 'subset-usage status', '```'));
  write('packages/a/README.md', 'Run `npx @subset.dev/a`.');
  write('packages/a/test/README.md', 'Run `npx @subset.dev/a`.');
  write('docs/architecture.md', 'Run `npx @subset.dev/a`.');
  write('node_modules/x/README.md', 'Run `npx @subset.dev/a`.');
  execFileSync('git', ['add', 'README.md'], { cwd: root });
  assert.deepEqual(checkedDocs(root), ['README.md', 'packages/a/README.md']);
  assert.deepEqual(repositoryDocProblems(root, TOOLS).map((problem) => problem.split(': ')[0]), ['README.md:2', 'packages/a/README.md:1']);
  // A tracked file deleted from the working tree is skipped.
  rmSync(join(root, 'README.md'));
  assert.deepEqual(checkedDocs(root), ['packages/a/README.md']);
});
