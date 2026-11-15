// SET-233: the CLI names itself after SUBSET_COMMAND (`subset timer`) when the `subset` launcher started it, and
// subset-timer otherwise. Only human text changes: exit codes and --json output stay byte-identical.
import assert from 'node:assert/strict';
import { test } from 'node:test';
import { HELP, helpText } from '../../src/commands/index.mjs';
import { cliDaemon, runCli } from './helpers.mjs';

const ENV = { SUBSET_TIMER_ALERTS: 'off' };
const THROUGH_SUBSET = { ...ENV, SUBSET_COMMAND: 'subset timer' };
// Values that do not match ^subset [a-z0-9-]+$, which the CLI ignores.
const INVALID = ['', 'subset', 'subset Timer', 'subset timer --help', 'subset timer\n', ' subset timer', 'subset  timer', 'npx subset.dev timer', 'subset-timer', 'subset tim/er'];

test('help names subset-timer when started directly', async () => {
  const help = await runCli(['start', '--help'], { env: ENV });
  assert.deepEqual({ code: help.code, stdout: help.stdout }, { code: 0, stdout: HELP });
  assert.match(help.stdout, /^Usage: subset-timer \[command\] \[options\]\n/);
  assert.match(help.stdout, /^ {2}subset-timer start 25m --name Focus$/m);
  assert.doesNotMatch(help.stdout, /subset timer/);
});

test('help names subset timer when SUBSET_COMMAND is subset timer', async () => {
  for (const argv of [['--help'], ['start', '--help'], ['frobnicate', '-h']]) {
    const help = await runCli(argv, { env: THROUGH_SUBSET });
    assert.deepEqual({ code: help.code, stdout: help.stdout, stderr: help.stderr }, { code: 0, stdout: helpText('subset timer'), stderr: '' });
  }
  const help = helpText('subset timer');
  assert.match(help, /^Usage: subset timer \[command\] \[options\]\n/);
  assert.match(help, /^ {2}subset timer start 25m --name Focus$/m);
  assert.doesNotMatch(help, /subset-timer/);
  // Only the name differs from the bin's help.
  assert.equal(help.replaceAll('subset timer', 'subset-timer'), HELP);
});

test('help ignores a SUBSET_COMMAND that is not subset <tool>', async () => {
  for (const value of INVALID) {
    const help = await runCli(['--help'], { env: { ...ENV, SUBSET_COMMAND: value } });
    assert.equal(help.stdout, HELP, JSON.stringify(value));
  }
});

test('error hints name the command that started the CLI', async () => {
  const cases = [
    [ENV, 'subset-timer'],
    [THROUGH_SUBSET, 'subset timer'],
    ...INVALID.map((value) => [{ ...ENV, SUBSET_COMMAND: value }, 'subset-timer'])
  ];
  for (const [env, name] of cases) {
    const unknown = await runCli(['frobnicate'], { env });
    assert.deepEqual(
      { code: unknown.code, stdout: unknown.stdout, stderr: unknown.stderr },
      { code: 2, stdout: '', stderr: `${name}: Unknown command "frobnicate". Run ${name} --help.\n` },
      JSON.stringify(env.SUBSET_COMMAND)
    );
  }
});

test('--json errors name subset-timer whatever SUBSET_COMMAND is', async () => {
  const argvs = [['frobnicate', '--json'], ['preset', 'frob', '--json'], ['list', '--frobnicate', '--json'], ['status', '--json']];
  for (const argv of argvs) {
    const direct = await runCli(argv, { env: ENV });
    assert.equal(direct.code, 2);
    assert.match(direct.json().error.message, /Run subset-timer --help\.$/);
    for (const env of [THROUGH_SUBSET, { ...ENV, SUBSET_COMMAND: 'subset Timer' }]) {
      const through = await runCli(argv, { env });
      assert.deepEqual({ code: through.code, stdout: through.stdout, stderr: through.stderr }, { code: direct.code, stdout: direct.stdout, stderr: direct.stderr }, argv.join(' '));
    }
  }
  assert.deepEqual((await runCli(['frobnicate', '--json'], { env: THROUGH_SUBSET })).json(), {
    error: { code: 'invalid_input', message: 'Unknown command "frobnicate". Run subset-timer --help.' }
  });
  const options = await runCli(['list', '--frobnicate'], { env: THROUGH_SUBSET });
  assert.equal(options.code, 2);
  assert.match(options.stderr, /^subset timer: .+ Run subset timer --help\.\n$/);
  const count = await runCli(['status'], { env: THROUGH_SUBSET });
  assert.deepEqual({ code: count.code, stderr: count.stderr }, { code: 2, stderr: 'subset timer: Wrong number of arguments for status. Run subset timer --help.\n' });
});

test('start hints name the command that started the CLI', async (t) => {
  const { run } = await cliDaemon(t);
  for (const [env, name] of [[ENV, 'subset-timer'], [THROUGH_SUBSET, 'subset timer'], [{ ...ENV, SUBSET_COMMAND: 'subset Timer' }, 'subset-timer']]) {
    const missing = await run(['start'], { env });
    assert.deepEqual({ code: missing.code, stderr: missing.stderr }, { code: 2, stderr: `${name}: start needs a <spec> or --until. Run ${name} --help.\n` });
    const preset = await run(['start', 'nosuchpreset'], { env });
    assert.deepEqual({ code: preset.code, stderr: preset.stderr }, {
      code: 4,
      stderr: `${name}: "nosuchpreset" is not a duration, stopwatch, interval or preset. Run ${name} presets to list presets.\n`
    });
    // The --json messages name the bin whatever SUBSET_COMMAND is.
    const missingJson = await run(['start', '--json'], { env });
    assert.deepEqual({ code: missingJson.code, stdout: missingJson.stdout }, {
      code: 2,
      stdout: `${JSON.stringify({ error: { code: 'invalid_input', message: 'start needs a <spec> or --until. Run subset-timer --help.' } })}\n`
    });
    const presetJson = await run(['start', 'nosuchpreset', '--json'], { env });
    assert.deepEqual({ code: presetJson.code, stdout: presetJson.stdout }, {
      code: 4,
      stdout: `${JSON.stringify({ error: { code: 'not_found', message: '"nosuchpreset" is not a duration, stopwatch, interval or preset. Run subset-timer presets to list presets.' } })}\n`
    });
  }
});
