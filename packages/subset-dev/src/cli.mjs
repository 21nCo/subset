#!/usr/bin/env node
// subset <tool>[@<version>] [arguments...] or subset <command> [arguments...]: the subset.dev package's command.
// `npx subset.dev usage status` does what `npx @subset.dev/usage status` does: npm fetches the tool (the launcher
// depends on none of them), and the launcher then loads the tool's bin module into this same process. The commands
// (list, install and the others in commands.mjs) are the launcher's own; commands/<verb>.mjs runs `subset <verb>`.
// A tool bundled in an installed Subset Mac app runs from the app (helpers.mjs) unless a version is given.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { constants, homedir } from 'node:os';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { findToolBin } from './bin.mjs';
import { route, VERBS, verbHelp } from './commands.mjs';
import { findAppHelper, runNativeHelper } from './helpers.mjs';
import { ApplicationsFoldersError } from './macos/apps.mjs';
import { findNpmCli } from './npm.mjs';
import { fetchFailureMessage, npmDistTagsArgs, npmLocateArgs, resolveTool, TOOLS, toolSource } from './tools.mjs';

const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

// A two-column list: each name padded to the longest, then its description.
function columns(rows) {
  const width = Math.max(...rows.map(([name]) => name.length));
  return rows.map(([name, text]) => `  ${name.padEnd(width)}  ${text}`).join('\n');
}

function help() {
  const tools = columns(Object.entries(TOOLS).map(([name, tool]) => [name, `${tool.summary} (${toolSource(tool)})`]));
  const commands = columns(Object.entries(VERBS).map(([name, verb]) => [name, verb.summary]));
  return `Usage: subset <tool>[@<version>] [arguments...]
       subset <command> [arguments...]

Runs a Subset command-line tool. The arguments go to the tool unchanged;
"subset <tool> --help" shows the tool's own help. A tool that comes with a
Subset Mac app runs from the installed app, unless a version is given.

Tools:
${tools}

<version> is latest, beta, next or an exact version such as 0.2.0 of the npm
package (default: latest).

Commands:
${commands}

"subset help <command>" shows a command's usage.

Examples:
  npx subset.dev usage
  npx subset.dev usage status
  npx subset.dev timer@beta --help

Options:
  -h, --help     Show this help
  -v, --version  Show the subset.dev version
`;
}

function fail(message) {
  console.error(`subset: ${message}`);
  process.exit(1);
}

// The tool's bin file, fetched by npm, and the PATH npm would run it with. npm's own messages and errors go to stderr.
function locate(tool) {
  const npmCli = findNpmCli();
  if (npmCli === undefined && process.platform === 'win32') fail(`could not find npm. Run npx ${tool.spec} instead.`);
  // Without npm_execpath on macOS and Linux, `npm` from PATH is an executable script, started without a shell.
  const [command, argv] = npmCli ? [process.execPath, [npmCli, ...npmLocateArgs(tool)]] : ['npm', npmLocateArgs(tool)];
  const result = spawnSync(command, argv, { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8' });
  if (result.error) fail(`could not start npm: ${result.error.message}`);
  // npm ended by a signal (an interrupted fetch) is not asked about again.
  if (result.status !== 0) fail(fetchFailureMessage(tool, result.signal ? undefined : probeRegistry(command, npmCli, tool)));
  const reportedPath = result.stdout.trim().split(/\r?\n/).at(-1) ?? '';
  const file = findToolBin(reportedPath, tool) ?? fail(`npm fetched ${tool.spec}, but its ${tool.bin} command was not found.`);
  return { file, reportedPath };
}

// After a failed fetch, asks the registry once for the tool's dist-tags, quietly and for at most 30 seconds, so the
// failure can say whether the tool is not on npm or has only a beta. Never runs when the fetch succeeds.
function probeRegistry(command, npmCli, tool) {
  const argv = npmCli ? [npmCli, ...npmDistTagsArgs(tool)] : npmDistTagsArgs(tool);
  return spawnSync(command, argv, { stdio: ['ignore', 'pipe', 'ignore'], encoding: 'utf8', timeout: 30_000 });
}

// Loads a tool's ES module into this process, as if Node.js had been started on it: no second process stands between
// the tool and the terminal, so it alone gets every signal (Ctrl-C, a hangup, a SIGTERM to the process or its group)
// exactly once, reads the terminal directly, and sets the exit code. Tool bins are ES modules
// (scripts/check-workspaces.mjs) that read their arguments from process.argv.
async function load(name, file, args) {
  // Informational: tells the tool the command that started it, so it can print `subset usage ...` in its messages.
  process.env.SUBSET_COMMAND = `subset ${name}`;
  process.argv = [process.argv[0], file, ...args];
  await import(pathToFileURL(file).href);
}

// Runs the npm package of a tool.
async function runPackage(tool, args) {
  const { file, reportedPath } = locate(tool);
  // The tool and the commands it starts see the PATH they would have under npx, with its packages' bin folders.
  process.env.PATH = reportedPath;
  await load(tool.name, file, args);
}

// Exits as the helper did: with its exit code, or by the signal that ended it (with 128 + its number should this
// process survive it, as for SIGPIPE, which Node.js ignores).
function exitLike({ code, signal }) {
  if (signal === null) {
    process.exitCode = code;
    return;
  }
  process.exitCode = 128 + (constants.signals[signal] ?? 0);
  process.kill(process.pid, signal);
}

// Runs the command of an installed app (helpers.mjs) and returns true, fails when the app's command is refused, or
// returns false when there is no app or it has no such command, for the npm package to run.
async function runFromApp(tool, args) {
  const { app } = tool;
  let found;
  try {
    found = await findAppHelper(app, { env: process.env, home: homedir() });
  } catch (error) {
    if (!(error instanceof ApplicationsFoldersError)) throw error;
    fail(error.message);
  }
  if (found.status === 'refused') fail(`${found.bundle} was not run: ${found.reason}.`);
  // An app from before its command was bundled: the npm package runs instead, when there is one.
  if (found.status === 'missing' && tool.package === undefined) fail(`${found.bundle} has no ${app.helper}. Update it with: subset update ${app.id}`);
  if (found.status !== 'found') return false;
  if (found.kind === 'node') {
    await load(tool.name, found.file, args);
    return true;
  }
  process.env.SUBSET_COMMAND = `subset ${tool.name}`;
  let result;
  try {
    result = await runNativeHelper(found.file, args, { env: process.env });
  } catch (error) {
    fail(`could not start ${found.file}: ${error.message}`);
  }
  exitLike(result);
  return true;
}

// subset <tool>: a version given always runs the npm package; otherwise the installed app's command, then the npm
// package. A tool with no package fails with how to get its app.
async function run(tool, args) {
  if (!tool.explicit && tool.app && process.platform === 'darwin' && (await runFromApp(tool, args))) return;
  if (tool.package !== undefined) return runPackage(tool, args);
  const { app } = tool;
  if (process.platform !== 'darwin') fail(`${tool.name} comes with the ${app.appName} app, which runs only on macOS.`);
  fail(`${tool.name} comes with the ${app.appName} app. Install it with: subset install ${app.id}`);
}

const command = route(process.argv.slice(2), { isTool: (name) => Object.hasOwn(TOOLS, name) });
switch (command.action) {
  case 'help':
    process.stdout.write(help());
    break;
  case 'version':
    console.log(version);
    break;
  case 'usage':
    process.stdout.write(verbHelp(command.verb));
    break;
  case 'tool-help':
    console.log(`"subset ${command.tool} --help" shows the help of ${command.tool} (${toolSource(TOOLS[command.tool])}).`);
    break;
  case 'error':
    console.error(`subset: ${command.message}`);
    process.exitCode = 2;
    break;
  case 'command': {
    // list, install, update and uninstall are the verbs route() runs. Loaded only here, so running a tool never reads
    // the catalog schemas.
    const context = { env: process.env, platform: process.platform, home: homedir(), stdout: process.stdout, stderr: process.stderr };
    const runners = {
      list: async () => (await import('./commands/list.mjs')).runList,
      install: async () => (await import('./commands/install.mjs')).runInstall,
      update: async () => (await import('./commands/update.mjs')).runUpdate,
      uninstall: async () => (await import('./commands/uninstall.mjs')).runUninstall
    };
    const run = await runners[command.verb]();
    process.exitCode = await run(command.args, context);
    break;
  }
  default: {
    const tool = resolveTool(command.argument);
    if (tool.error) {
      console.error(`subset: ${tool.error}`);
      process.exitCode = 2;
    } else {
      await run(tool, command.args);
    }
  }
}
