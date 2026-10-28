// A daemon on the data directory argv[2] whose macOS sink runs real processes instead of osascript
// and afplay: each appends its part (`notification` or `Glass`) to the file argv[3] as it ends, a
// notification at once and a Glass 5 s after it starts. Prints a line once it is listening.
import { spawn } from 'node:child_process';
import { createMacosSink } from '../../src/alerts/index.mjs';
import { OSASCRIPT } from '../../src/alerts/macos.mjs';
import { startDaemon } from '../../src/daemon/index.mjs';

const [dataDir, heard] = process.argv.slice(2);
const PART = 'sleep "$1" && echo "$2" >> "$3"';
const sink = createMacosSink({
  spawn: (command, args, options) => {
    const [seconds, part] = command === OSASCRIPT ? ['0', 'notification'] : ['5', 'Glass'];
    return spawn('/bin/sh', ['-c', PART, 'sh', seconds, part, heard], options);
  }
});
await startDaemon({ dataDir, sink, log: () => {}, idleExitMs: 60_000 });
process.stdout.write('listening\n');
