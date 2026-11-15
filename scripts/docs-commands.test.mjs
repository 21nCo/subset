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
