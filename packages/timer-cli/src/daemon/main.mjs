#!/usr/bin/env node
// The default daemon entry of `createClient`; the CLI passes its own file, which runs `subset-timer daemon run`.
import { runDaemonCommand } from './server.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== 'daemon' || args[1] !== 'run') {
  process.stderr.write('usage: main.mjs daemon run\n');
  process.exit(2);
}
await runDaemonCommand();
