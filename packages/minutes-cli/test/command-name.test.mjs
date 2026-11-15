// SET-233: the CLI names itself after SUBSET_COMMAND (`subset minutes`) when the `subset` launcher started it, and
// subset-minutes otherwise. Only text changes: exit codes and JSON event codes stay the same.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { main, usage, usageText } from '../src/main.mjs';

// Values that do not match ^subset [a-z0-9-]+$, which the CLI ignores.
const INVALID = ['', 'subset', 'subset Minutes', 'subset minutes --help', 'subset minutes\n', ' subset minutes', 'subset  minutes', 'npx subset.dev minutes', 'subset-minutes', 'subset min/utes'];

async function run(argv, env) {
  let stdout = '';
  let stderr = '';
  const code = await main({ argv, env, home: '/nonexistent-home', stdout: (text) => { stdout += text; }, stderr: (text) => { stderr += text; } });
  return { code, stdout, stderr };
}

test('help names subset-minutes when started directly and subset minutes through subset', async () => {
  const direct = await run(['--help'], {});
  assert.deepEqual(direct, { code: 0, stdout: usage, stderr: '' });
  assert.match(direct.stdout, /^Usage: subset-minutes <command> \[options\]\n/);
  assert.doesNotMatch(direct.stdout, /subset minutes/);

  const through = await run(['join', '--help'], { SUBSET_COMMAND: 'subset minutes' });
  assert.deepEqual(through, { code: 0, stdout: usageText('subset minutes'), stderr: '' });
  assert.match(through.stdout, /^Usage: subset minutes <command> \[options\]\n/);
  assert.doesNotMatch(through.stdout, /subset-minutes/);
  // Only the name differs from the bin's help.
  assert.equal(through.stdout.replaceAll('subset minutes', 'subset-minutes'), usage);

  // No arguments prints the help on stderr with exit 2, with the same name.
  assert.deepEqual(await run([], { SUBSET_COMMAND: 'subset minutes' }), { code: 2, stdout: '', stderr: usageText('subset minutes') });
});

test('help ignores a SUBSET_COMMAND that is not subset <tool>', async () => {
  for (const value of INVALID) {
    assert.equal((await run(['--help'], { SUBSET_COMMAND: value })).stdout, usage, JSON.stringify(value));
  }
});

test('the unknown-command hint names the command that started the CLI', async () => {
  const cases = [[{}, 'subset-minutes'], [{ SUBSET_COMMAND: 'subset minutes' }, 'subset minutes'], ...INVALID.map((value) => [{ SUBSET_COMMAND: value }, 'subset-minutes'])];
  for (const [env, name] of cases) {
    const message = `Unknown command "record". Run ${name} --help.`;
    assert.deepEqual(await run(['record'], env), { code: 2, stdout: '', stderr: `${message}\n` }, JSON.stringify(env.SUBSET_COMMAND));
    const json = await run(['record', '--json'], env);
    assert.equal(json.code, 2);
    const events = json.stdout.trim().split('\n').map((line) => JSON.parse(line));
    assert.deepEqual(events.map(({ type, code, message: text, reason }) => ({ type, code, message: text, reason })), [
      { type: 'error', code: 'usage', message, reason: undefined },
      { type: 'ended', code: undefined, message: undefined, reason: 'failed' }
    ]);
  }
});
