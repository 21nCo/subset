import assert from 'node:assert/strict';
import { execFileSync, spawn, spawnSync } from 'node:child_process';
import { mkdirSync, mkdtempSync, readdirSync, rmSync, writeFileSync } from 'node:fs';
import { writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { createInterface } from 'node:readline';
import test from 'node:test';
import { fileURLToPath } from 'node:url';
import { readLock } from '../../src/daemon/index.mjs';
import { tempDataDir, within } from './helpers.mjs';

// Each contender is a process of its own, as daemons starting together are, stopped at chosen file
// calls so that the interleavings below happen exactly. They are named for the protocol they test:
// whatever a process saw earlier, only the holder of a generation's marker removes that generation.

const CONTENDER = fileURLToPath(new URL('./lock-contender.mjs', import.meta.url));
const LOCK = '^daemon\\.lock$';
// Stops a process recovering an abandoned marker just before it acts on what it read.
const RECOVERING = [{ op: 'renameSync', name: 'takeover' }, { op: 'openSync', name: 'takeover\\..*takeover\\.' }];
// Stops a process that removed an abandoned marker aside just before it puts back what it found there.
const RESTORING = [{ op: 'linkSync', name: '\\.dead$' }];
const at = (id, points) => points.map((point) => ({ id, ...point }));

function deadPid() {
  return spawnSync(process.execPath, ['-e', '']).pid;
}

function setup(t) {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const fifos = mkdtempSync(join(tmpdir(), 'stf-'));
  t.after(() => rmSync(fifos, { recursive: true, force: true }));
  const lockPath = join(dataDir, 'daemon.lock');
  let count = 0;
  const contender = () => {
    const fifo = join(fifos, `c${count++}`);
    execFileSync('mkfifo', [fifo]);
    const child = spawn(process.execPath, [CONTENDER, lockPath, fifo], { stdio: ['pipe', 'pipe', 'inherit'] });
    const exited = new Promise((resolve) => child.once('exit', resolve));
    t.after(() => child.kill('SIGKILL'));
    const lines = createInterface({ input: child.stdout })[Symbol.asyncIterator]();
    const next = async () => JSON.parse((await within(lines.next(), 10_000)).value);
    /** Sends a command and resolves its reply, or `{ paused }` once it stops at one of `pauses`. */
    const run = (cmd, pauses = []) => {
      child.stdin.write(`${JSON.stringify({ cmd, pauses })}\n`);
      return next();
    };
    return {
      pid: child.pid,
      run,
      resume: () => writeFile(fifo, 'go').then(next),
      async kill() {
        child.kill('SIGKILL');
        await within(exited, 10_000);
      },
      holds: async () => (await run('holds')).holds
    };
  };
  return { dataDir, lockPath, contender };
}

/** A process stopped between deciding to remove the lock and removing it, then killed: its marker is abandoned. */
async function crashMidRemoval(contender, cmd) {
  const crashed = contender();
  assert.deepEqual(await crashed.run(cmd, [{ id: 'crash', op: 'unlinkSync', name: LOCK }]), { paused: 'crash' });
  await crashed.kill();
}

/** Resumes a contender that may be paused, until it replies to its command. */
async function finish(contender, message) {
  let reply = message;
  while (reply.paused) reply = await contender.resume();
  return reply;
}

test('recovering an abandoned marker never lets a process that read it earlier displace a live takeover', async (t) => {
  const { dataDir, lockPath, contender } = setup(t);
  writeFileSync(lockPath, `${deadPid()}\n${'0'.repeat(32)}\n`);
  await crashMidRemoval(contender, 'acquire');

  // A reads the abandoned marker and stops before acting on it.
  const a = contender();
  assert.deepEqual(await a.run('acquire', [...at('a1', RECOVERING), ...at('a2', RESTORING)]), { paused: 'a1' });
  // B removes the abandoned marker, claims the removal and stops just before removing the stale lock.
  const b = contender();
  assert.deepEqual(await b.run('acquire', [{ id: 'b', op: 'unlinkSync', name: LOCK }]), { paused: 'b' });
  // A acts on what it read; C starts meanwhile.
  const aReply = await a.resume();
  const c = contender();
  const cReply = await c.run('acquire');
  const results = { a: await finish(a, aReply), c: cReply, b: await b.resume() };

  const holders = Object.entries({ a, b, c }).filter(([name]) => results[name].acquired);
  assert.deepEqual(holders.map(([name]) => name), ['b'], JSON.stringify(results));
  for (const [name, holder] of holders) assert.equal(await holder.holds(), true, name);
  assert.equal(readLock(lockPath).pid, b.pid);
  assert.deepEqual(readdirSync(dataDir), ['daemon.lock']);
});

test('a live owner releasing while another process takes over a reused pid never removes the new lock', async (t) => {
  const { lockPath, contender } = setup(t);
  const owner = contender();
  assert.deepEqual(await owner.run('acquire'), { done: 'acquire', acquired: true });
  await crashMidRemoval(contender, 'removeStale');

  const a = contender();
  assert.deepEqual(await a.run('removeStale', [...at('a1', RECOVERING), ...at('a2', RESTORING)]), { paused: 'a1' });
  // R recovers the abandoned marker (and, judging the owner's pid reused, may remove its lock).
  const r = contender();
  assert.equal((await r.run('removeStale')).done, 'removeStale');
  // The owner releases, and stops just before removing its lock.
  const releasing = await owner.run('release', [{ id: 'o', op: 'unlinkSync', name: LOCK }]);
  const aReply = await a.resume();
  // C judges the owner's pid reused, removes its lock and acquires.
  const c = contender();
  assert.deepEqual(await c.run('takeover'), { done: 'takeover', acquired: true });
  await finish(a, aReply);
  await finish(owner, releasing);

  assert.equal(await c.holds(), true);
  assert.equal(readLock(lockPath).pid, c.pid);
});

test('a marker abandoned while an abandoned marker was being removed is recovered within the client budget', async (t) => {
  const { dataDir, lockPath, contender } = setup(t);
  writeFileSync(lockPath, `${deadPid()}\n${'0'.repeat(32)}\n`);
  await crashMidRemoval(contender, 'acquire');
  // This one dies while removing the first abandoned marker.
  const crashed = contender();
  const recovering = [{ id: 'y', op: 'unlinkSync', name: '^daemon\\.lock\\.takeover(\\.[0-9a-f]{32})?$' }, { id: 'y', op: 'renameSync', name: 'takeover' }];
  assert.deepEqual(await crashed.run('acquire', recovering), { paused: 'y' });
  await crashed.kill();

  const z = contender();
  const started = Date.now();
  assert.deepEqual(await z.run('acquire'), { done: 'acquire', acquired: true });
  assert.ok(Date.now() - started < 3_000, `${Date.now() - started} ms`);
  assert.equal(await z.holds(), true);
  assert.deepEqual(readdirSync(dataDir), ['daemon.lock']);
});
