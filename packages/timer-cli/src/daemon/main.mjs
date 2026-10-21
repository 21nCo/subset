#!/usr/bin/env node
// The daemon entry a client spawns until the SET-77 CLI provides `subset-timer daemon run`.
import { runDaemonCommand } from './server.mjs';

const args = process.argv.slice(2);
if (args.length !== 2 || args[0] !== 'daemon' || args[1] !== 'run') {
  process.stderr.write('usage: main.mjs daemon run\n');
  process.exit(2);
}
await runDaemonCommand();
