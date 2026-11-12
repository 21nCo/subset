#!/usr/bin/env node
// subset <tool>[@<version>] [arguments...]: the subset.dev package's command. It runs a Subset command-line tool
// through `npm exec`, so `npx subset.dev usage status` is `npx @subset.dev/usage status`. It depends on none of the
// tools; npm fetches only the one that is run.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import process from 'node:process';
import { findNpmCli } from './npm.mjs';
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

// npm passes SIGINT and SIGTERM on to the tool but not SIGHUP, so a hangup is sent to npm as SIGTERM.
const FORWARDED_SIGNALS = { SIGINT: 'SIGINT', SIGTERM: 'SIGTERM', SIGHUP: 'SIGTERM' };

function run(tool, args) {
  const npmCli = findNpmCli();
  if (npmCli === undefined && process.platform === 'win32') {
    console.error(`subset: could not find npm. Run npx ${tool.spec} instead.`);
    process.exit(1);
  }
  // Without npm_execpath on macOS and Linux, `npm` from PATH is an executable script, started without a shell.
  const [command, argv] = npmCli ? [process.execPath, [npmCli, ...npmExecArgs(tool, args)]] : ['npm', npmExecArgs(tool, args)];
  const child = spawn(command, argv, { stdio: 'inherit' });
  // Ctrl-C reaches the whole process group; a signal sent to this process alone is passed on so the tool can clean up.
  const forward = (signal) => child.kill(FORWARDED_SIGNALS[signal]);
  for (const signal of Object.keys(FORWARDED_SIGNALS)) process.on(signal, forward);
  child.on('error', (error) => {
    console.error(`subset: could not start npm: ${error.message}`);
    process.exit(1);
  });
  child.on('exit', (code, signal) => {
    for (const name of Object.keys(FORWARDED_SIGNALS)) process.off(name, forward);
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
