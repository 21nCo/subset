// A separate process that takes, removes or releases a lock on command, for the lock race tests.
// It can be stopped just before a chosen file call: it reports `{ paused }` and blocks until the
// test writes to its FIFO, so the test decides what other processes do in between.
//
// argv: <lock path> <fifo path>. stdin: one JSON command per line. stdout: one JSON reply per line.
import * as nodeFs from 'node:fs';
import { basename } from 'node:path';
import { createInterface } from 'node:readline';
import { acquireLock, readLock, removeStaleLock } from '../../src/daemon/lock.mjs';

const [lockPath, fifo] = process.argv.slice(2);
const reply = (message) => nodeFs.writeSync(1, `${JSON.stringify(message)}\n`);

// Pause points of the current command: `{ id, op, arg = 0, name, nth = 1 }` stops before the nth
// call of an `op` (a pattern such as `openSync|renameSync`) whose argument `arg` has a base name
// matching `name`. Points sharing an id stop once.
let pauses = [];
const fired = new Set();
const seen = new Map();
const matches = (pause, op, args) => new RegExp(`^(?:${pause.op})$`).test(op) && new RegExp(pause.name).test(basename(String(args[pause.arg ?? 0])));
function before(op, args) {
  let point;
  for (const pause of pauses.filter((candidate) => matches(candidate, op, args))) {
    seen.set(pause, (seen.get(pause) ?? 0) + 1);
    point ??= !fired.has(pause.id) && seen.get(pause) === (pause.nth ?? 1) ? pause : undefined;
  }
  if (!point) return;
  fired.add(point.id);
  reply({ paused: point.id });
  // Opening a FIFO for reading blocks until the test opens it to write.
  nodeFs.readFileSync(fifo);
}
const fs = Object.fromEntries(['openSync', 'linkSync', 'unlinkSync', 'renameSync'].map((op) => [op, (...args) => {
  before(op, args);
  return nodeFs[op](...args);
}]));
const options = { fs: { ...nodeFs, ...fs } };

let lock = null;
const commands = {
  async acquire() {
    lock = await acquireLock(lockPath, options);
    return { acquired: lock.acquired };
  },
  // As `daemon run` does with a live holder it judged a reused pid: remove that lock, then acquire.
  async takeover() {
    lock = await acquireLock(lockPath, options);
    if (!lock.acquired && lock.holder) {
      removeStaleLock(lockPath, lock.holder, options);
      lock = await acquireLock(lockPath, options);
    }
    return { acquired: lock.acquired };
  },
  removeStale() {
    const held = readLock(lockPath);
    return { removed: held ? removeStaleLock(lockPath, held, options) : null };
  },
  release() {
    lock.release();
    return {};
  },
  holds() {
    return { holds: Boolean(lock?.acquired && lock.isHeld()) };
  }
};

for await (const line of createInterface({ input: process.stdin })) {
  const { cmd, pauses: points = [] } = JSON.parse(line);
  pauses = points;
  reply({ done: cmd, ...(await commands[cmd]()) });
}
