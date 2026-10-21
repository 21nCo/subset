// The subset-timer command. `cli.mjs` calls `main` with the real process; tests pass a client and capture output.
import { parseArgs } from 'node:util';
import manifest from '../../package.json' with { type: 'json' };
import { createClient } from '../daemon/client.mjs';
import { resolveDataDir } from '../daemon/paths.mjs';
import { daemonCommands } from './daemon.mjs';
import { presetCommands } from './presets.mjs';
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

Options
  --json                  Print the result, or {"error":{"code","message"}}, as JSON on stdout
  --help, --version

<ref> is a timer or preset id, or a unique name ignoring case.
Data: ~/.local/share/subset/timer, or SUBSET_TIMER_DATA_DIR. SUBSET_TIMER_ALERTS=off silences alerts.
Exit status: 0 ok, 2 invalid input or an ambiguous <ref>, 3 daemon unavailable, 4 not found or invalid state.
`;

const COMMANDS = { ...timerCommands, ...presetCommands, ...daemonCommands };
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
 * @param {Function} [io.runDaemon] Runs `daemon run` (tests replace it).
 * @returns {Promise<number>} The exit status.
 */
export async function main(io) {
  const { argv, stdout, stderr, env = process.env } = io;
  // Until the arguments parse, any --json asks for a JSON error; after that, only the parsed option counts.
  let json = argv.includes('--json');
  if (argv.includes('--help') || argv.includes('-h')) {
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
    const [min, max] = command.positionals;
    if (parsed.positionals.length < min || parsed.positionals.length > max) {
      throw new CliError('invalid_input', `Wrong number of arguments for ${name}. Run subset-timer --help.`);
    }
    if (parsed.positionals.some((value) => !value.trim())) throw new CliError('invalid_input', `${name} needs a non-empty argument.`);
    const client = io.client ?? createClient({ dataDir: resolveDataDir(env), cliPath: io.cliPath, env });
    const output = await command.run({
      client,
      env,
      values: parsed.values,
      positionals: parsed.positionals,
      now: io.now ?? Date.now,
      packageRoot: io.packageRoot,
      runDaemon: io.runDaemon
    });
    if (output) stdout(`${json ? JSON.stringify(output.json) : output.text}\n`);
    return EXIT.ok;
  } catch (caught) {
    const error = caught instanceof CliError ? caught : Object.assign(new CliError('internal', caught?.message ?? String(caught)), { exitCode: 1 });
    if (json) stdout(`${JSON.stringify({ error: { code: error.code, message: error.message, ...error.details } })}\n`);
    else stderr(errorText(error));
    return error.exitCode;
  }
}
