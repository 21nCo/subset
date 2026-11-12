#!/usr/bin/env node
// subset <tool>[@<version>] [arguments...]: the subset.dev package's command. `npx subset.dev usage status` does what
// `npx @subset.dev/usage status` does: npm fetches the tool (the launcher depends on none of them), and the launcher
// then loads the tool's bin module into this same process.
import { spawnSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { pathToFileURL } from 'node:url';
import { findToolBin } from './bin.mjs';
import { findNpmCli } from './npm.mjs';
import { npmLocateArgs, resolveTool, TOOLS } from './tools.mjs';

const { version } = JSON.parse(readFileSync(new URL('../package.json', import.meta.url), 'utf8'));

function help() {
  const width = Math.max(...Object.keys(TOOLS).map((name) => name.length));
  const tools = Object.entries(TOOLS)
    .map(([name, tool]) => `  ${name.padEnd(width)}  ${tool.summary} (${tool.package})`)
    .join('\n');
  return `Usage: subset <tool>[@<version>] [arguments...]

Runs a Subset command-line tool. The arguments go to the tool unchanged;
"subset <tool> --help" shows the tool's own help.

Tools:
${tools}

<version> is latest, beta, next or an exact version such as 0.2.0 (default: latest).

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

// The tool's bin file, fetched by npm. npm's own messages and errors go to stderr.
function locate(tool) {
  const npmCli = findNpmCli();
  if (npmCli === undefined && process.platform === 'win32') fail(`could not find npm. Run npx ${tool.spec} instead.`);
  // Without npm_execpath on macOS and Linux, `npm` from PATH is an executable script, started without a shell.
  const [command, argv] = npmCli ? [process.execPath, [npmCli, ...npmLocateArgs(tool)]] : ['npm', npmLocateArgs(tool)];
  const result = spawnSync(command, argv, { stdio: ['ignore', 'pipe', 'inherit'], encoding: 'utf8' });
  if (result.error) fail(`could not start npm: ${result.error.message}`);
  if (result.status !== 0) fail(`npm could not fetch ${tool.spec}.`);
  const reportedPath = result.stdout.trim().split(/\r?\n/).at(-1) ?? '';
  return findToolBin(reportedPath, tool) ?? fail(`npm fetched ${tool.spec}, but its ${tool.bin} command was not found.`);
}

// Runs the tool in this process, as if Node.js had been started on its bin: no second process stands between the
// tool and the terminal, so it alone gets every signal (Ctrl-C, a hangup, a SIGTERM to the process or its group)
// exactly once, reads the terminal directly, and sets the exit code. Tool bins are ES modules
// (scripts/check-workspaces.mjs) that read their arguments from process.argv.
async function run(tool, args) {
  const file = locate(tool);
  process.argv = [process.argv[0], file, ...args];
  await import(pathToFileURL(file).href);
}

const [first, ...rest] = process.argv.slice(2);
if (first === undefined || first === '-h' || first === '--help' || first === 'help') {
  process.stdout.write(help());
} else if (first === '-v' || first === '--version') {
  console.log(version);
} else {
  const tool = resolveTool(first);
  if (tool.error) {
    console.error(`subset: ${tool.error}`);
    process.exitCode = 2;
  } else {
    await run(tool, rest);
  }
}
