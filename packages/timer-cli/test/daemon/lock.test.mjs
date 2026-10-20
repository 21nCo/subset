import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import * as nodeFs from 'node:fs';
import { existsSync, readdirSync, mkdirSync, readFileSync, renameSync, statSync, unlinkSync, utimesSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import test from 'node:test';
import { DaemonRunningError, LockLostError, acquireLock, createRecordingSink, createFakeClock, daemonPaths, isReusedPid, processStartTime, readLock, socketRequest, startDaemon } from '../../src/daemon/index.mjs';
import { eventually, spawnDaemonProcess, startTestDaemon, subscribe, tempDataDir, within } from './helpers.mjs';

function deadPid() {
  const { pid } = spawnSync(process.execPath, ['-e', '']);
  return pid;
}

const TOKEN = 'a'.repeat(32);
const OTHER = 'b'.repeat(32);
const LOCK_CONTENT = new RegExp(`^${process.pid}\n[0-9a-f]{32}\n$`);

function lockPath(t) {
  const dir = tempDataDir(t);
  mkdirSync(dir, { recursive: true, mode: 0o700 });
  return join(dir, 'daemon.lock');
}

test('the lock is created holding the pid, refuses a second holder and is released', async (t) => {
  const path = lockPath(t);
  const first = await acquireLock(path);
  assert.equal(first.acquired, true);
  assert.match(readFileSync(path, 'utf8'), LOCK_CONTENT);
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

test('a lock without a valid pid is stale at once, as no lock is ever seen half written', async (t) => {
  const path = lockPath(t);
  for (const content of ['', 'garbage\n']) {
    writeFileSync(path, content);
    const lock = await acquireLock(path);
    assert.equal(lock.acquired, true, JSON.stringify(content));
    lock.release();
  }
});

test('a lock created again at the same path by the same process is told apart from the earlier one', async (t) => {
  const path = lockPath(t);
  const first = await acquireLock(path);
  // As when the lock is removed from under a daemon and its successor runs in the same process:
  // Linux then often gives the new file the inode the removed one had.
  unlinkSync(path);
  const second = await acquireLock(path);
  assert.equal(second.acquired, true);
  assert.notEqual(second.token, first.token);
  assert.equal(first.isHeld(), false);
  assert.equal(second.isHeld(), true);
  first.release();
  assert.equal(second.isHeld(), true);
  second.release();
  assert.equal(existsSync(path), false);
});

test('releasing leaves a lock another process has since created', async (t) => {
  const path = lockPath(t);
  const lock = await acquireLock(path);
  const successor = `${deadPid()}\n${TOKEN}\n`;
  writeFileSync(`${path}.next`, successor);
  // Another daemon replaced the lock (as after a takeover); this one must not remove it.
  renameSync(`${path}.next`, path);
  lock.release();
  assert.equal(readFileSync(path, 'utf8'), successor);
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
    assert.equal(await within(survivor.exited, 10_000), 0);
    assert.equal(existsSync(join(dataDir, 'daemon.lock')), false);
    assert.equal(existsSync(join(dataDir, 'daemon.sock')), false);
  });
}

test('a lock whose live pid started after the lock was written is a reused pid, and is replaced', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const bystander = spawn(process.execPath, ['-e', 'setTimeout(() => {}, 60_000)'], { stdio: 'ignore' });
  t.after(() => bystander.kill('SIGKILL'));
  await eventually(() => processStartTime(bystander.pid) !== null);
  const path = join(dataDir, 'daemon.lock');
  // Written after the bystander started, the lock could be its own.
  writeFileSync(path, `${bystander.pid}\n`);
  await assert.rejects(startDaemon({ dataDir, log: () => {} }), (error) => error instanceof DaemonRunningError && error.pid === bystander.pid);

  // Written 20 s before the bystander started, it belonged to a daemon that died.
  const old = (Date.now() - 20_000) / 1000;
  utimesSync(path, old, old);
  const daemon = await startDaemon({ dataDir, log: () => {} });
  t.after(() => daemon.shutdown());
  assert.equal(readLock(path).pid, process.pid);
});

test('a live holder that started before its lock is never replaced, however old the lock and with no socket', async (t) => {
  const dataDir = tempDataDir(t);
  mkdirSync(dataDir, { recursive: true, mode: 0o700 });
  const paths = daemonPaths(dataDir);
  const lockedAt = Date.now() - 3_600_000;
  const holder = { pid: process.pid, mtimeMs: lockedAt };
  // A daemon suspended between taking the lock and listening, or one whose socket was removed.
  assert.equal(await isReusedPid(paths, holder, { startTimeOf: () => lockedAt - 1_000 }), false);
  assert.equal(await isReusedPid(paths, holder, { startTimeOf: () => lockedAt + 1_000 }), false);
  assert.equal(await isReusedPid(paths, holder, { startTimeOf: () => null }), false);
  assert.equal(await isReusedPid(paths, holder, { startTimeOf: () => lockedAt + 60_000 }), true);
});

test('a running daemon whose socket was removed keeps its lock', async (t) => {
  const dataDir = tempDataDir(t);
  const run = spawnDaemonProcess(dataDir);
  t.after(() => run.child.kill('SIGKILL'));
  const socket = join(dataDir, 'daemon.sock');
  await eventually(() => existsSync(socket), 10_000);
  unlinkSync(socket);
  await assert.rejects(startDaemon({ dataDir, log: () => {} }), (error) => error instanceof DaemonRunningError && error.pid === run.child.pid);
  assert.equal(readLock(join(dataDir, 'daemon.lock')).pid, run.child.pid);
});

test('a daemon that lost its lock never writes or alerts again and leaves its successor\'s socket', async (t) => {
  const dataDir = tempDataDir(t);
  const first = await startTestDaemon(t, { dataDir });
  const events = subscribe(first.daemon.paths.socket);
  await events.waitFor((list) => list.length === 1);
  await first.op('start', { timer: { kind: 'countdown', durationMs: 1_000, name: 'First' } });
  await events.waitFor((list) => list.length === 2);
  // The lock is removed from under the first daemon, and a second one starts.
  unlinkSync(first.daemon.paths.lock);
  const second = await startTestDaemon(t, { dataDir, clock: createFakeClock(first.clock.now()) });
  assert.equal((await second.op('create', { timer: { kind: 'stopwatch', name: 'Second' } })).status, 200);
  const written = readFileSync(join(dataDir, 'state.json'), 'utf8');

  // The first daemon's countdown finishes: it would record and announce that, but it no longer
  // holds the lock, so its successor does both.
  first.clock.advance(1_000);
  assert.equal(await within(first.daemon.closed), 1);
  await events.connected;
  await eventually(() => events.ended);
  assert.ok(first.logs.some((line) => /daemon\.lock is no longer held/.test(line)));
  assert.equal(readFileSync(join(dataDir, 'state.json'), 'utf8'), written);
  assert.deepEqual(first.sink.received, []);
  assert.deepEqual(events.events.map(({ event }) => event), ['state', 'state']);
  assert.equal((await second.call('GET', '/v1/daemon')).status, 200);
  assert.deepEqual((await second.call('GET', '/v1/timers')).body.structuredContent.timers.map((timer) => timer.definition.name), ['First', 'Second']);
});

for (const timers of ['paused', 'none']) {
  for (const loss of ['removed', 'replaced']) {
    test(`a daemon with ${timers === 'paused' ? 'a paused timer' : 'no timers'} and a subscriber notices its lock was ${loss} within a minute`, async (t) => {
      const dataDir = tempDataDir(t);
      const first = await startTestDaemon(t, { dataDir });
      if (timers === 'paused') {
        const { id } = (await first.op('start', { timer: { kind: 'stopwatch', name: 'Paused' } })).body.timer.definition;
        await first.op('pause', { id });
      }
      const events = subscribe(first.daemon.paths.socket);
      await events.waitFor((list) => list.length === 1);
      const files = () => Object.fromEntries(['state.json', 'scheduler.json'].map((name) => [name, existsSync(join(dataDir, name)) ? readFileSync(join(dataDir, name), 'utf8') : null]));
      unlinkSync(first.daemon.paths.lock);
      const second = loss === 'replaced' ? await startTestDaemon(t, { dataDir, clock: createFakeClock(first.clock.now()) }) : null;
      const before = files();

      first.clock.advance(60_000);
      assert.equal(await within(first.daemon.closed), 1);
      await eventually(() => events.ended);
      assert.deepEqual(files(), before);
      // The old daemon is gone, so whatever answers on the socket is its successor, still holding its lock.
      if (second) {
        assert.equal((await second.call('GET', '/v1/daemon')).status, 200);
        assert.equal(readLock(join(dataDir, 'daemon.lock')).pid, process.pid);
      }
    });
  }
}

test('a holder\'s start time is never later than its real start, however slow ps is', () => {
  // The holder started at 100 s and wrote its lock at 100.1 s. Asked at 101.5 s, ps reports 1 s
  // elapsed (floored) and takes 2 s to answer.
  let wall = 101_500;
  const now = () => wall;
  const elapsedOf = () => {
    wall += 2_000;
    return '00:01\n';
  };
  const startedAt = processStartTime(4242, { now, elapsedOf });
  assert.ok(startedAt <= 100_000, `${startedAt}`);
  assert.ok(startedAt >= 100_000 - 2_000, `${startedAt}`);
  assert.equal(processStartTime(4242, { now, elapsedOf: () => { throw new Error('ps failed'); } }), null);
  assert.equal(processStartTime(4242, { now, elapsedOf: () => '' }), null);
  assert.equal(processStartTime(4242, { now: () => 200_000_000, elapsedOf: () => '1-02:03:04' }), 200_000_000 - (((24 + 2) * 60 + 3) * 60 + 4) * 1_000 - 1_000);
});

test('a lock is never seen before its pid and token are in it', async (t) => {
  const path = lockPath(t);
  const seen = [];
  const fs = {
    ...nodeFs,
    writeSync(...args) {
      // Another process looks while this one writes.
      seen.push(readLock(path));
      return nodeFs.writeSync(...args);
    }
  };
  const lock = await acquireLock(path, { fs });
  assert.equal(lock.acquired, true);
  assert.deepEqual(seen, [null]);
  assert.match(readFileSync(path, 'utf8'), LOCK_CONTENT);
});

test('a takeover marker whose holder is gone is removed at once, as are files it left', async (t) => {
  const path = lockPath(t);
  const dead = deadPid();
  writeFileSync(path, `${dead}\n${TOKEN}\n`);
  writeFileSync(`${path}.takeover.${TOKEN}`, `${dead}\n${OTHER}\n`);
  const leftovers = [
    `${path}.${dead}-${TOKEN}.new`,
    `${path}.takeover.${TOKEN}.${dead}-${OTHER}.new`,
    // Markers for generations their files no longer hold: nobody acts on them again.
    `${path}.takeover.${OTHER}`,
    `${path}.takeover.${OTHER}.takeover.${TOKEN}`
  ];
  const live = `${path}.${process.ppid}-${TOKEN}.new`;
  for (const file of [...leftovers, live]) writeFileSync(file, `${process.ppid}\n${TOKEN}\n`);
  const started = Date.now();
  const lock = await acquireLock(path);
  assert.equal(lock.acquired, true);
  assert.ok(Date.now() - started < 500, `${Date.now() - started} ms`);
  assert.equal(existsSync(`${path}.takeover.${TOKEN}`), false);
  assert.deepEqual(leftovers.filter((file) => existsSync(file)), []);
  // One a live process is still writing is left to it.
  assert.equal(existsSync(live), true);
});

test('a takeover marker whose holder is alive is kept however long it is stopped, unless the pid was reused', async (t) => {
  const path = lockPath(t);
  const stale = `${deadPid()}\n${TOKEN}\n`;
  writeFileSync(path, stale);
  const marker = `${path}.takeover.${TOKEN}`;
  const held = `${process.ppid}\n${OTHER}\n`;
  writeFileSync(marker, held);
  const writtenAt = Date.now() - 60_000;
  utimesSync(marker, writtenAt / 1000, writtenAt / 1000);
  // Its holder started before the marker: it is a process stopped mid-takeover, and acts when it resumes.
  const stopped = await acquireLock(path, { startTimeOf: () => writtenAt - 1_000 });
  assert.deepEqual(stopped, { acquired: false, holder: null });
  assert.equal(readFileSync(path, 'utf8'), stale);
  assert.equal(readFileSync(marker, 'utf8'), held);
  // It started after the marker: the holder died and the system gave its pid to another process.
  const reused = await acquireLock(path, { startTimeOf: () => writtenAt + 30_000 });
  assert.equal(reused.acquired, true);
  assert.deepEqual(readdirSync(join(path, '..')), ['daemon.lock']);
});

test('a process that removes a stale lock on its last try still creates its own', async (t) => {
  const path = lockPath(t);
  writeFileSync(path, `${deadPid()}\n${TOKEN}\n`);
  let tries = 0;
  const fs = {
    ...nodeFs,
    linkSync(from, to) {
      if (to === path) tries++;
      // Another process holds the takeover until this one's last try.
      else if (tries < 50) throw Object.assign(new Error('file exists'), { code: 'EEXIST' });
      return nodeFs.linkSync(from, to);
    }
  };
  const lock = await acquireLock(path, { fs });
  assert.equal(tries, 51);
  assert.equal(lock.acquired, true);
  assert.equal(lock.isHeld(), true);
});

test('a pid write that fails leaves no lock behind, and one that is short is completed', async (t) => {
  const path = lockPath(t);
  const failures = {
    throws(fd, buffer, offset) {
      nodeFs.writeSync(fd, buffer, offset, 1);
      throw Object.assign(new Error('no space left on device'), { code: 'ENOSPC' });
    },
    'takes no bytes': () => 0
  };
  for (const [name, writeSync] of Object.entries(failures)) {
    await assert.rejects(acquireLock(path, { fs: { ...nodeFs, writeSync } }), (error) => ['ENOSPC', 'EIO'].includes(error.code), name);
    assert.deepEqual(readdirSync(join(path, '..')), [], name);
    const started = Date.now();
    const lock = await acquireLock(path);
    assert.equal(lock.acquired, true, name);
    assert.ok(Date.now() - started < 1_000, name);
    lock.release();
  }
  const oneByte = (fd, buffer, offset) => nodeFs.writeSync(fd, buffer, offset, 1);
  const lock = await acquireLock(path, { fs: { ...nodeFs, writeSync: oneByte } });
  assert.equal(lock.acquired, true);
  assert.match(readFileSync(path, 'utf8'), LOCK_CONTENT);
});

for (const step of ['locked', 'bound']) {
  test(`a daemon whose lock is taken over once it is ${step} leaves its successor reachable`, async (t) => {
    const dataDir = tempDataDir(t);
    let successor;
    const startupHook = async (at) => {
      if (at !== step) return;
      // The lock is removed from under the starting daemon, and another daemon starts and listens.
      unlinkSync(join(dataDir, 'daemon.lock'));
      successor = await startTestDaemon(t, { dataDir, sink: { ...createRecordingSink(), name: 'successor' } });
    };
    await assert.rejects(startDaemon({ dataDir, log: () => {}, startupHook }), (error) => error instanceof LockLostError);
    assert.ok(successor);
    const { body } = await socketRequest(join(dataDir, 'daemon.sock'), 'GET', '/v1/daemon');
    assert.equal(body.alerts, 'successor');
    // It still holds the lock: it can write.
    assert.equal((await successor.op('create', { timer: { kind: 'stopwatch' } })).status, 200);
    assert.deepEqual(readdirSync(dataDir).filter((name) => name.startsWith('.ds-')), []);
  });
}
