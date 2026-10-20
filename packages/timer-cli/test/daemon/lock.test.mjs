import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, renameSync, statSync, utimesSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { DaemonRunningError, acquireLock, readLock, socketRequest, startDaemon } from '../../src/daemon/index.mjs';
import { eventually, spawnDaemonProcess, tempDataDir } from './helpers.mjs';

function deadPid() {
  const { pid } = spawnSync(process.execPath, ['-e', '']);
  return pid;
}

function lockPath(t) {
  const dir = tempDataDir(t);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return join(dir, 'daemon.lock');
}

test('the lock is created holding the pid, refuses a second holder and is released', async (t) => {
  const path = lockPath(t);
  const first = await acquireLock(path);
  assert.equal(first.acquired, true);
  assert.equal(readFileSync(path, 'utf8'), `${process.pid}\n`);
  assert.equal(statSync(path).mode & 0o777, 0o600);
  const second = await acquireLock(path, { pid: 999_999 });
  assert.equal(second.acquired, false);
  assert.equal(second.holder.pid, process.pid);
  first.release();
  assert.equal(existsSync(path), false);
});

test('a lock whose pid is not alive is taken over', async (t) => {
  const path = lockPath(t);
  writeFileSync(path, `${deadPid()}\n`);
  const lock = await acquireLock(path);
  assert.equal(lock.acquired, true);
  assert.equal(readLock(path).pid, process.pid);
});

test('a lock without a pid is being written, until it is older than the grace period', async (t) => {
  const path = lockPath(t);
  writeFileSync(path, '');
  const young = await acquireLock(path);
  assert.equal(young.acquired, false);
  assert.equal(young.holder.pid, null);
  const old = (Date.now() - 5_000) / 1000;
  utimesSync(path, old, old);
  assert.equal((await acquireLock(path)).acquired, true);
});

test('releasing leaves a lock another process has since created', async (t) => {
  const path = lockPath(t);
  const lock = await acquireLock(path);
  writeFileSync(`${path}.next`, '1\n');
  // Another daemon replaced the lock (as after a takeover); this one must not remove it.
  renameSync(`${path}.next`, path);
  lock.release();
  assert.equal(readFileSync(path, 'utf8'), '1\n');
});

for (const stale of [false, true]) {
  test(`concurrent daemon runs leave exactly one daemon${stale ? ' when they take over a stale lock' : ''}`, async (t) => {
    const dataDir = tempDataDir(t);
    if (stale) {
      mkdirSync(dataDir, { recursive: true, mode: 0o700 });
      writeFileSync(join(dataDir, 'daemon.lock'), `${deadPid()}\n`);
    }
    const runs = Array.from({ length: 4 }, () => spawnDaemonProcess(dataDir));
    t.after(() => runs.forEach((run) => run.child.kill('SIGKILL')));
    const exits = [];
    runs.forEach((run, index) => run.exited.then((code) => exits.push({ index, code })));
    await eventually(() => exits.length === runs.length - 1, 10_000);
    const [survivor] = runs.filter((run, index) => !exits.some((exit) => exit.index === index));
    // The others can exit before the winner has opened its socket.
    let status;
    await eventually(() => existsSync(join(dataDir, 'daemon.sock')), 10_000);
    for (let attempt = 0; !status; attempt++) {
      status = await socketRequest(join(dataDir, 'daemon.sock'), 'GET', '/v1/daemon').catch((error) => {
        if (attempt > 100) throw error;
      });
    }
    assert.equal(status.body.pid, survivor.child.pid);
    assert.equal(readLock(join(dataDir, 'daemon.lock')).pid, survivor.child.pid);
    for (const exit of exits) {
      assert.equal(exit.code, 3);
      assert.equal(runs[exit.index].stderr().trim(), `already running (pid ${survivor.child.pid})`);
    }
    await socketRequest(join(dataDir, 'daemon.sock'), 'POST', '/v1/shutdown');
    assert.equal(await survivor.exited, 0);
    assert.equal(existsSync(join(dataDir, 'daemon.lock')), false);
    assert.equal(existsSync(join(dataDir, 'daemon.sock')), false);
  });
}

test('a live pid that has not served the socket for 10 s is a reused pid, and its lock is replaced', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const bystander = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60_000)'], { stdio: 'ignore' });
  t.after(() => bystander.kill('SIGKILL'));
  const path = join(dataDir, 'daemon.lock');
  writeFileSync(path, `${bystander.pid}\n`);
  await assert.rejects(startDaemon({ dataDir, log: () => {} }), (error) => error instanceof DaemonRunningError && error.pid === bystander.pid);

  const old = (Date.now() - 20_000) / 1000;
  utimesSync(path, old, old);
  const daemon = await startDaemon({ dataDir, log: () => {} });
  t.after(() => daemon.shutdown());
  assert.equal(readLock(path).pid, process.pid);
});
