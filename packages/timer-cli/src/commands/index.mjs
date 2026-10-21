// The subset-timer command. `cli.mjs` calls `main` with the real process; tests pass a client and capture output.
import { parseArgs } from 'node:util';
import manifest from '../../package.json' with { type: 'json' };
import { createClient } from '../daemon/client.mjs';
import { checkSocketPath, resolveDataDir } from '../daemon/paths.mjs';
import { daemonCommands } from './daemon.mjs';
import { presetCommands } from './presets.mjs';
import { serveCommands } from './serve.mjs';
import { CliError, EXIT } from './shared.mjs';
import { timerCommands } from './timers.mjs';

export const VERSION = manifest.version;

export const HELP = `Usage: subset-timer [command] [options]

Starts and controls countdowns, stopwatches and interval workouts. A per-user daemon keeps
timers running after a command exits and plays their alerts; the first command starts it.

Timers
  list                    List every timer (the default command)
  status <ref>            Show one timer
  start <spec>            Create and start a timer. <spec> is one of:
                            a duration: 90s, 25m, 1h30m, 1:30 (m:ss) or 1:02:03 (h:mm:ss)
                            stopwatch
                            a preset: tabata, emom, hiit, pomodoro, amrap, or a saved one's name or id
                            interval --work 40s [--rest 20s] --rounds 10 [--prep 10s] [--cooldown 60s]
                            a timer id, to start an idle timer again after reset
    --until <time>        Count down to a local time such as 17:30 instead of a <spec>
    --name <name>         Name the new timer
    --no-sound            Play no sounds for it (notifications still show)
  pause <ref>             Pause a running timer
  resume <ref>            Resume a paused timer
  lap <ref>               Record a lap on a stopwatch or a countdown with laps (amrap)
  skip <ref>              Jump to the next interval step
  reset <ref>             Return a timer to idle, clearing its progress
  rm <ref>                Remove a timer

Presets
  presets                 List the built-in and saved presets
  preset save <name>      Save an interval preset from --work, --rest, --rounds, --prep, --cooldown, --no-sound
  preset rm <ref>         Remove a saved preset

Daemon and agent skill
  daemon run              Run the daemon in the foreground (other commands start it when needed)
  daemon status           Show the daemon's pid, data directory and alerts; never starts it
  daemon stop             Stop the daemon; timers keep their place and continue when it starts again
  skill path              Print the folder of the bundled agent skill

Web
  serve                   Open the Timer board in the browser, served on 127.0.0.1 until Ctrl-C
    --port <n>            Use this port, failing when it is taken (default: 4175, or the next free one)
    --no-open             Print the URL without opening the browser

Options
  --json                  Print the result, or {"error":{"code","message"}}, as JSON on stdout
  --help, --version

<ref> is a timer or preset id, or a unique name ignoring case.
Data: ~/.local/share/subset/timer, or SUBSET_TIMER_DATA_DIR. SUBSET_TIMER_ALERTS=off silences alerts.
Exit status: 0 ok, 2 invalid input or an ambiguous <ref>, 3 daemon unavailable, 4 not found or invalid state.
`;

const COMMANDS = { ...timerCommands, ...presetCommands, ...daemonCommands, ...serveCommands };
const GROUPS = new Set(Object.keys(COMMANDS).filter((name) => name.includes(' ')).map((name) => name.split(' ')[0]));

/** The command `argv` names and the arguments after it. No command, or only options, is `list`. */
function findCommand(argv) {
  if (!argv.length || argv[0].startsWith('-')) return { name: 'list', rest: argv };
  const [first, second] = argv;
  const name = GROUPS.has(first) ? `${first} ${second ?? ''}`.trim() : first;
  // Own properties only, so names such as "constructor" are unknown commands.
  if (!Object.hasOwn(COMMANDS, name)) {
    const hint = GROUPS.has(first) ? `Unknown ${first} command "${second ?? ''}".` : `Unknown command "${first}".`;
    throw new CliError('invalid_input', `${hint} Run subset-timer --help.`);
  }
  return { name, rest: argv.slice(name.split(' ').length) };
}

/**
 * True when `--help` or `-h` is an option of the command line: not an option's value, such as
 * `--name=--help`, nor an argument after `--`.
 */
function wantsHelp(argv) {
  let options = {};
  try {
    options = COMMANDS[findCommand(argv).name].options;
  } catch {
    // An unknown command still shows help when asked.
  }
  const { tokens } = parseArgs({ args: argv, options: { ...options, help: { type: 'boolean', short: 'h' } }, allowPositionals: true, strict: false, tokens: true });
  return tokens.some((token) => token.kind === 'option' && token.name === 'help');
}

/** A client of the daemon for `env`'s data directory, refusing one whose socket path no daemon could use. */
function connect(env, cliPath) {
  const dataDir = resolveDataDir(env);
  try {
    checkSocketPath(dataDir);
  } catch (error) {
    throw new CliError('daemon_unavailable', error.message);
  }
  return createClient({ dataDir, cliPath, env });
}

function errorText(error) {
  const lines = [`subset-timer: ${error.message}`];
  for (const candidate of error.details.candidates ?? []) {
    lines.push(`  ${candidate.id}  ${candidate.name}${candidate.status ? ` (${candidate.status})` : ''}`);
  }
  return `${lines.join('\n')}\n`;
}

/**
 * @param {object} io
 * @param {string[]} io.argv Arguments after the executable and script.
 * @param {Record<string, string | undefined>} io.env
 * @param {(text: string) => void} io.stdout
 * @param {(text: string) => void} io.stderr
 * @param {string} io.cliPath The script a client runs as `daemon run` when it starts the daemon.
 * @param {string} io.packageRoot The installed package folder, which holds `skills/`.
 * @param {object} [io.client] A daemon client (tests pass one bound to a test daemon).
 * @param {() => number} [io.now] Epoch milliseconds, for `--until`.
 * @param {Function} [io.startDaemon] Starts the daemon for `daemon run` (tests replace it).
 * @param {Function} [io.foreground] Runs the started daemon until it exits (tests replace it).
 * @param {(url: string) => void} [io.openUrl] Opens the `serve` URL in a browser (tests replace it).
 * @param {() => Promise<void>} [io.untilStopped] Resolves when `serve` should stop; Ctrl-C by default.
 * @returns {Promise<number>} The exit status.
 */
export async function main(io) {
  const { argv, stdout, stderr, env = process.env } = io;
  // Until the arguments parse, any --json asks for a JSON error; after that, only the parsed option counts.
  let json = argv.includes('--json');
  if (wantsHelp(argv)) {
    stdout(HELP);
    return EXIT.ok;
  }
  if (argv[0] === '--version' || argv[0] === '-v') {
    stdout(`${VERSION}\n`);
    return EXIT.ok;
  }
  try {
    const { name, rest } = findCommand(argv);
    const command = COMMANDS[name];
    let parsed;
    try {
      parsed = parseArgs({ args: rest, options: { ...command.options, json: { type: 'boolean' } }, allowPositionals: true, strict: true });
    } catch (error) {
      throw new CliError('invalid_input', `${error.message} Run subset-timer --help.`);
    }
    json = parsed.values.json === true;
    const print = (output) => stdout(`${json ? JSON.stringify(output.json) : output.text}\n`);
    const [min, max] = command.positionals;
    if (parsed.positionals.length < min || parsed.positionals.length > max) {
      throw new CliError('invalid_input', `Wrong number of arguments for ${name}. Run subset-timer --help.`);
    }
    if (parsed.positionals.some((value) => !value.trim())) throw new CliError('invalid_input', `${name} needs a non-empty argument.`);
    // Commands that need no daemon client never check the data directory.
    const client = command.client === false ? undefined : (io.client ?? connect(env, io.cliPath));
    const output = await command.run({
      client,
      env,
      values: parsed.values,
      positionals: parsed.positionals,
      now: io.now ?? Date.now,
      packageRoot: io.packageRoot,
      startDaemon: io.startDaemon,
      foreground: io.foreground,
      openUrl: io.openUrl,
      untilStopped: io.untilStopped,
      print
    });
    if (output) print(output);
    return EXIT.ok;
  } catch (caught) {
    const error = caught instanceof CliError ? caught : Object.assign(new CliError('internal', caught?.message ?? String(caught)), { exitCode: 1 });
    if (json) stdout(`${JSON.stringify({ error: { code: error.code, message: error.message, ...error.details } })}\n`);
    else stderr(errorText(error));
    return error.exitCode;
  }
}
