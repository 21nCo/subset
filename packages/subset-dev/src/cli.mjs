#!/usr/bin/env node
// subset <tool>[@<version>] [arguments...]: the subset.dev package's command. It runs a Subset command-line tool
// through `npm exec`, so `npx subset.dev usage status` is `npx @subset.dev/usage status`. It depends on none of the
// tools; npm fetches only the one that is run.
import { spawn } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { npmExecArgs, resolveTool, TOOLS } from './tools.mjs';

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

<version> is a dist-tag or exact version, such as beta or 0.2.0 (default: latest).

Examples:
  npx subset.dev usage
  npx subset.dev usage status
  npx subset.dev timer@beta --help

Options:
  -h, --help     Show this help
  -v, --version  Show the subset.dev version
`;
}

// How to start npm: the npm that launched this command (npx or npm exec set npm_execpath) through this Node.js, so nothing
// is looked up on PATH or through a shell; otherwise `npm` from PATH.
function npmCommand() {
  const execPath = process.env.npm_execpath;
  if (execPath && /(?:^|[\\/])np[mx]-cli\.js$/.test(execPath)) {
    const npmCli = path.join(path.dirname(execPath), 'npm-cli.js');
    if (existsSync(npmCli)) return { command: process.execPath, prefix: [npmCli], shell: false };
  }
  // npm is a .cmd script on Windows, which only a shell can start.
  return { command: 'npm', prefix: [], shell: process.platform === 'win32' };
}

const quoteForCmd = (argument) => (/^[\w@./:=-]+$/.test(argument) ? argument : `"${argument.replaceAll('"', '""')}"`);

function run(tool, args) {
  const npm = npmCommand();
  const argv = [...npm.prefix, ...npmExecArgs(tool, args)];
  const child = spawn(npm.command, npm.shell ? argv.map(quoteForCmd) : argv, { stdio: 'inherit', shell: npm.shell });
  // Ctrl-C reaches the whole process group; a signal sent to this process alone is passed on so the tool can clean up.
  const forward = (signal) => child.kill(signal);
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, forward);
  child.on('error', (error) => {
    console.error(`subset: could not start npm: ${error.message}`);
    process.exit(1);
  });
  child.on('exit', (code, signal) => {
    for (const name of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.off(name, forward);
    if (signal) process.kill(process.pid, signal);
    else process.exit(code ?? 1);
  });
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
    run(tool, rest);
  }
}
