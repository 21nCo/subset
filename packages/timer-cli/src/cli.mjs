#!/usr/bin/env node
// The subset-timer entry point. Both src/cli.mjs and the bundled dist/cli.mjs sit one folder below the
// package root, which holds skills/; the daemon a client starts runs this same file as `daemon run`.
import { fileURLToPath } from 'node:url';
import { main } from './commands/index.mjs';

process.exitCode = await main({
  argv: process.argv.slice(2),
  env: process.env,
  stdout: (text) => process.stdout.write(text),
  stderr: (text) => process.stderr.write(text),
  cliPath: fileURLToPath(import.meta.url),
  packageRoot: fileURLToPath(new URL('..', import.meta.url))
});
