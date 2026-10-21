import { randomBytes } from 'node:crypto';
import { chmodSync, lstatSync, readdirSync, renameSync, unlinkSync } from 'node:fs';
import { createServer } from 'node:http';
import { join } from 'node:path';
import { OPERATION_NAMES, agentTimerResult, project, runOperation, settle } from '@subset/timer';
import { createRecordingSink, deliverToSink } from './alerts.mjs';
import { acquireLock } from './lock.mjs';
import { ensureDataDir, resolveDataDir } from './paths.mjs';
import { createScheduler, systemClock } from './scheduler.mjs';
import { createStateStore } from './store.mjs';

export const HEARTBEAT_MS = 15_000;
export const IDLE_EXIT_MS = 10 * 60_000;
const MAX_BODY_BYTES = 1024 * 1024;
/**
 * While a subscriber has a frame undrained, later state and heartbeat frames replace the queued
 * one and alerts queue up. One that leaves a frame undrained this long, or queues more alerts than
 * this, has stopped reading and is dropped.
 */
const SUBSCRIBER_STALL_MS = 30_000;
const MAX_QUEUED_ALERT_BYTES = 1024 * 1024;
/** How long requests already being handled get to finish, with a 503 at most, once shutdown begins. */
const SHUTDOWN_GRACE_MS = 1_000;
const STATUS_BY_CODE = { invalid_input: 400, not_found: 404, invalid_state: 409, limit_reached: 409 };
/** The name a socket is bound under before it is renamed to `daemon.sock`; no longer than that name. */
const BIND_NAME = /^\.ds-[0-9a-f]{6}$/;

export class DaemonRunningError extends Error {
  constructor(pid) {
    super(`already running (pid ${pid ?? 'unknown'})`);
    this.name = 'DaemonRunningError';
    this.pid = pid;
  }
}

const stretchKey = (mark) => `${mark.timerId}:${mark.startedAt}:${mark.base}`;

function isCode(error, ...codes) {
  return error && codes.includes(error.code);
}

export function stderrLog(message) {
  process.stderr.write(`${new Date().toISOString()} ${message}\n`);
}

export class LockLostError extends Error {
  constructor() {
    super('daemon.lock is no longer held by this daemon.');
    this.name = 'LockLostError';
  }
}

async function takeLock(paths) {
  const lock = await acquireLock(paths.lock);
  if (!lock.acquired) throw new DaemonRunningError(lock.holder?.pid ?? null);
  return lock;
}

function listen(server, socketPath) {
  return new Promise((resolve, reject) => {
    // The umask makes the socket 0600 from the moment it exists; the chmod below confirms it.
    const previous = process.umask(0o077);
    server.once('error', reject);
    server.listen(socketPath, () => {
      server.off('error', reject);
      resolve();
    });
    process.umask(previous);
  });
}

/**
 * Starts the per-user daemon: the single writer of `state.json`, serving HTTP/1.1 JSON on
 * `daemon.sock` only. Throws `DaemonRunningError` when another daemon holds the lock. Resolves a
 * handle whose `closed` promise settles with the exit code after `shutdown` or the idle exit.
 *
 * `startupHook(step)` runs, for tests, once the lock is taken (`locked`) and once the socket is
 * bound but not yet published (`bound`). Throws `LockLostError` when the lock is lost before then.
 */
export async function startDaemon({
  dataDir = resolveDataDir(),
  clock = systemClock,
  sink = createRecordingSink(),
  log = stderrLog,
  idleExitMs = IDLE_EXIT_MS,
  heartbeatMs = HEARTBEAT_MS,
  startupHook = async () => {}
} = {}) {
  const paths = ensureDataDir(dataDir);
  const lock = await takeLock(paths);
  let stateStore;
  let store;
  let marks;
  try {
    stateStore = createStateStore(paths, { log, now: clock.now });
    store = stateStore.load();
    marks = stateStore.loadMarks();
    await startupHook('locked');
    // While we hold the lock, any socket file left here belongs to a daemon that is gone.
    if (!lock.isHeld()) throw new LockLostError();
    for (const path of [paths.socket, ...readdirSync(paths.dataDir).filter((name) => BIND_NAME.test(name)).map((name) => join(paths.dataDir, name))]) {
      try {
        unlinkSync(path);
      } catch (error) {
        if (!isCode(error, 'ENOENT')) throw error;
      }
    }
  } catch (error) {
    lock.release();
    throw error;
  }

  const startedAt = clock.now();
  /** Each subscriber's response, with the frames waiting for it to drain the earlier ones. */
  const subscribers = new Map();
  let closing = false;
  let resolveClosed;
  const closed = new Promise((resolve) => {
    resolveClosed = resolve;
  });
  let idleHandle = null;
  let heartbeatHandle = null;
  let socketIno = null;

  // How long a frame has waited is measured on a monotonic clock, so a changed wall clock neither
  // drops a subscriber that is reading nor keeps one that stopped.
  const monotonicNow = () => (clock.monotonic ?? clock.now)();
  const elapsedSince = (start) => monotonicNow() - start;
  const send = (response, event, data) => {
    const subscriber = subscribers.get(response);
    const frame = `event: ${event}\ndata: ${JSON.stringify(data)}\n\n`;
    if (subscriber.waitingSince === null) {
      if (!response.write(frame)) waitForDrain(response, subscriber);
      return;
    }
    if (event !== 'alert') subscriber.queue = subscriber.queue.filter((queued) => queued.event !== event);
    subscriber.queue.push({ event, frame });
    const alertBytes = subscriber.queue.reduce((total, queued) => total + (queued.event === 'alert' ? queued.frame.length : 0), 0);
    if (elapsedSince(subscriber.waitingSince) > SUBSCRIBER_STALL_MS || alertBytes > MAX_QUEUED_ALERT_BYTES) response.destroy();
  };
  function waitForDrain(response, subscriber) {
    subscriber.waitingSince = monotonicNow();
    response.once('drain', () => {
      subscriber.waitingSince = null;
      while (subscriber.queue.length) {
        if (!response.write(subscriber.queue.shift().frame)) return waitForDrain(response, subscriber);
      }
    });
  }
  const broadcast = (event, data) => {
    for (const response of subscribers.keys()) send(response, event, data);
  };
  const broadcastState = () => broadcast('state', agentTimerResult(store, clock.now()));

  /**
   * True while this daemon still holds `daemon.lock`. It is checked on every scheduler run (at
   * least once a minute), heartbeat and request, so one that lost it (the file was removed or
   * replaced, or can no longer be read) never writes, publishes or alerts again, and shuts down,
   * ending its event streams so subscribers reconnect to the daemon that holds it.
   */
  function stillHeld() {
    let held = false;
    try {
      held = lock.isHeld();
    } catch (error) {
      log(`could not read daemon.lock: ${error.message}`);
    }
    if (held) return true;
    if (!closing) {
      log('daemon.lock is no longer held by this daemon; exiting without writing.');
      void shutdown(1);
    }
    return false;
  }

  function write(save) {
    if (!stillHeld()) throw new LockLostError();
    save();
  }

  /** Persists a new store before showing it, so nothing reports a change the disk does not hold. */
  function commit(next) {
    write(() => stateStore.save(next));
    store = next;
    broadcastState();
    updateIdle();
  }

  /** Records running timers whose time is up as finished. A failed save is retried at the next run. */
  function settleFinished(now) {
    const timers = store.timers.map((timer) => settle(timer, now));
    if (timers.every((timer, index) => timer === store.timers[index])) return;
    try {
      commit({ ...store, timers });
    } catch (error) {
      if (!(error instanceof LockLostError)) log(`could not save finished timers: ${error.message}`);
    }
  }

  /** The stretches `scheduler.json` holds marks for, and whether a failed save left it behind. */
  let savedStretches = new Set((marks ?? []).map(stretchKey));
  let marksDirty = false;
  function saveMarks(list) {
    write(() => stateStore.saveMarks(list));
    savedStretches = new Set(list.map(stretchKey));
    marksDirty = false;
  }

  const scheduler = createScheduler({
    clock,
    initialMarks: marks,
    getTimers: () => store.timers,
    onRun(alerts, now) {
      // A successor that took the lock delivers these alerts itself.
      if (!stillHeld()) return;
      for (const { alert, timer } of alerts) {
        broadcast('alert', alert);
        deliverToSink(sink, alert, timer, log);
      }
      const current = scheduler.marks;
      const stretchesChanged = current.length !== savedStretches.size || current.some((mark) => !savedStretches.has(stretchKey(mark)));
      // A save that failed is retried at every later run, so a restart never reports as missed
      // what was delivered.
      if (alerts.length || stretchesChanged || marksDirty) {
        try {
          saveMarks(current);
        } catch (error) {
          marksDirty = true;
          if (!(error instanceof LockLostError)) log(`could not save scheduler.json: ${error.message}`);
        }
      }
      if (closing) return;
      settleFinished(now);
      updateIdle();
    }
  });

  const busy = () => {
    if (subscribers.size) return true;
    const now = clock.now();
    return store.timers.some((timer) => ['running', 'paused'].includes(project(timer, now).status));
  };
  function updateIdle({ activity = false } = {}) {
    if (closing) return;
    if (busy()) {
      if (idleHandle !== null) clock.clearTimeout(idleHandle);
      idleHandle = null;
      return;
    }
    if (idleHandle !== null && !activity) return;
    if (idleHandle !== null) clock.clearTimeout(idleHandle);
    idleHandle = clock.setTimeout(() => {
      idleHandle = null;
      if (busy()) return;
      log('idle for 10 minutes; exiting.');
      void shutdown(0);
    }, idleExitMs);
  }

  function heartbeat() {
    heartbeatHandle = null;
    if (!stillHeld()) return;
    heartbeatHandle = clock.setTimeout(heartbeat, heartbeatMs);
    broadcast('heartbeat', { at: clock.now() });
  }

  function reply(response, status, body) {
    const text = JSON.stringify(body);
    // While shutting down, each connection is closed once its answer is sent.
    if (closing) response.setHeader('connection', 'close');
    response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
    response.end(text);
  }
  const fail = (response, status, code, message, extra = {}) => reply(response, status, { error: { code, message, ...extra } });

  function readBody(request) {
    return new Promise((resolve, reject) => {
      const chunks = [];
      let size = 0;
      request.on('data', (chunk) => {
        size += chunk.length;
        if (size > MAX_BODY_BYTES) {
          request.pause();
          reject(Object.assign(new Error('Request body is larger than 1 MiB.'), { status: 413 }));
          return;
        }
        chunks.push(chunk);
      });
      request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
      request.on('error', reject);
    });
  }

  async function runOp(request, response, name) {
    let text;
    try {
      text = await readBody(request);
    } catch (error) {
      if (error.status) {
        // Answer, then drop the connection rather than read the rest of the body.
        response.setHeader('connection', 'close');
        response.on('finish', () => request.destroy());
        fail(response, error.status, 'invalid_input', error.message);
      }
      return;
    }
    let input;
    if (text.trim() !== '') {
      try {
        input = JSON.parse(text);
      } catch {
        fail(response, 400, 'invalid_input', 'The request body is not JSON.');
        return;
      }
    }
    if (closing) {
      fail(response, 503, 'daemon_unavailable', 'The daemon is shutting down.');
      return;
    }
    // Alerts due before this change are delivered against the timers as they were, and the
    // scheduler marks the stretches the change begins from the same moment.
    const now = clock.now();
    scheduler.run(now);
    if (closing) {
      fail(response, 503, 'daemon_unavailable', 'The daemon is shutting down.');
      return;
    }
    const outcome = runOperation(name, store, input, now);
    if (!outcome.ok) {
      reply(response, STATUS_BY_CODE[outcome.error.code] ?? 400, { error: outcome.error });
      return;
    }
    if (outcome.store !== store && !applyChange(response, outcome.store, now)) return;
    reply(response, 200, outcome.result);
  }

  /** Saves and publishes `next`, the store after an operation at `now`; answers and returns false when that fails. */
  function applyChange(response, next, now) {
    try {
      // A stretch the change begins (a start, resume or skip) is marked from now before the change
      // is saved, so a daemon that stops before its next run neither repeats nor reports as missed
      // what the stretch jumped over. A mark for a stretch that never began is dropped later.
      const known = scheduler.marks;
      const knownKeys = new Set(known.map(stretchKey));
      const begun = scheduler.marksFor(next.timers, now).filter((mark) => !savedStretches.has(stretchKey(mark)) && !knownKeys.has(stretchKey(mark)));
      if (begun.length) saveMarks([...known, ...begun]);
      commit(next);
    } catch (error) {
      if (error instanceof LockLostError) {
        fail(response, 503, 'daemon_unavailable', 'The daemon is shutting down.');
        return false;
      }
      log(`could not save state.json: ${error.message}`);
      fail(response, 500, 'storage_failed', 'The daemon could not save the change.');
      return false;
    }
    scheduler.run(now);
    return true;
  }

  function subscribe(request, response) {
    response.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', 'cache-control': 'no-cache', connection: 'keep-alive' });
    subscribers.set(response, { queue: [], waitingSince: null });
    send(response, 'state', agentTimerResult(store, clock.now()));
    updateIdle();
    response.on('close', () => {
      subscribers.delete(response);
      updateIdle({ activity: true });
    });
  }

  const routes = {
    '/v1/timers': { GET: (request, response) => reply(response, 200, agentTimerResult(store, clock.now())) },
    '/v1/presets': { GET: (request, response) => reply(response, 200, runOperation('presets.list', store, {}, clock.now()).result) },
    '/v1/events': { GET: subscribe },
    '/v1/daemon': {
      GET: (request, response) => reply(response, 200, { pid: process.pid, dataDir: paths.dataDir, socket: paths.socket, alerts: sink.name, startedAt })
    },
    '/v1/shutdown': {
      POST: (request, response) => {
        response.setHeader('connection', 'close');
        response.on('finish', () => void shutdown(0));
        reply(response, 200, { ok: true });
      }
    }
  };

  async function handle(request, response) {
    if (closing || !stillHeld()) {
      fail(response, 503, 'daemon_unavailable', 'The daemon is shutting down.');
      return;
    }
    updateIdle({ activity: true });
    const [pathname] = (request.url ?? '/').split('?');
    if (pathname.startsWith('/v1/ops/')) {
      let name;
      try {
        name = decodeURIComponent(pathname.slice('/v1/ops/'.length));
      } catch {
        name = pathname.slice('/v1/ops/'.length);
      }
      if (!OPERATION_NAMES.includes(name)) return fail(response, 404, 'not_found', `Unknown operation ${name}.`);
      if (request.method !== 'POST') return methodNotAllowed(response, ['POST']);
      return runOp(request, response, name);
    }
    const route = Object.hasOwn(routes, pathname) ? routes[pathname] : null;
    if (!route) return fail(response, 404, 'not_found', `No route ${pathname}.`);
    if (!Object.hasOwn(route, request.method)) return methodNotAllowed(response, Object.keys(route));
    return route[request.method](request, response);
  }
  function methodNotAllowed(response, allowed) {
    response.setHeader('allow', allowed.join(', '));
    fail(response, 405, 'method_not_allowed', `Use ${allowed.join(' or ')}.`);
  }

  const server = createServer((request, response) => {
    handle(request, response).catch((error) => {
      log(`request failed: ${error.stack ?? error.message}`);
      if (!response.headersSent) fail(response, 500, 'internal', 'The daemon failed to handle the request.');
      else response.destroy();
    });
  });

  // The socket is bound under another name and renamed into place, so it appears with its final
  // mode, and so closing the server (which unlinks the bound name) never removes a successor's socket.
  // It is published only while this daemon still holds the lock, so it never replaces a successor's.
  const bindPath = join(paths.dataDir, `.ds-${randomBytes(3).toString('hex')}`);
  try {
    await listen(server, bindPath);
    chmodSync(bindPath, 0o600);
    socketIno = lstatSync(bindPath).ino;
    await startupHook('bound');
    if (!lock.isHeld()) throw new LockLostError();
    renameSync(bindPath, paths.socket);
  } catch (error) {
    server.close();
    try {
      unlinkSync(bindPath);
    } catch (unlinkError) {
      if (!isCode(unlinkError, 'ENOENT')) log(`could not remove ${bindPath}: ${unlinkError.message}`);
    }
    lock.release();
    throw error;
  }

  function shutdown(code = 0) {
    if (closing) return closed;
    closing = true;
    scheduler.stop();
    for (const handle of [idleHandle, heartbeatHandle]) if (handle !== null) clock.clearTimeout(handle);
    for (const response of subscribers.keys()) response.end();
    subscribers.clear();
    // Requests already being handled answer (a change not yet applied gets 503) before their
    // connections are closed; those still open after the grace are closed then.
    const grace = setTimeout(() => server.closeAllConnections(), SHUTDOWN_GRACE_MS);
    server.close(() => {
      clearTimeout(grace);
      // Another daemon may have bound the path since; only this daemon's own socket is removed.
      try {
        if (lstatSync(paths.socket).ino === socketIno) unlinkSync(paths.socket);
      } catch (error) {
        if (!isCode(error, 'ENOENT')) log(`could not remove the socket: ${error.message}`);
      }
      try {
        lock.release();
      } catch (error) {
        log(`could not remove the lock: ${error.message}`);
      }
      resolveClosed(code);
    });
    server.closeIdleConnections();
    return closed;
  }

  heartbeatHandle = clock.setTimeout(heartbeat, heartbeatMs);
  scheduler.run();
  updateIdle({ activity: true });
  log(`listening on ${paths.socket} (pid ${process.pid}).`);

  return {
    pid: process.pid,
    paths,
    server,
    sink,
    closed,
    shutdown,
    get store() {
      return store;
    },
    get subscriberCount() {
      return subscribers.size;
    }
  };
}

/**
 * `daemon run`: runs in the foreground until shut down or idle. A second daemon exits with code 3
 * and `already running (pid N)`.
 */
export async function runDaemonCommand({ env = process.env, sink, log = stderrLog } = {}) {
  let daemon;
  try {
    daemon = await startDaemon({ dataDir: resolveDataDir(env), sink, log });
  } catch (error) {
    if (error instanceof DaemonRunningError) {
      process.stderr.write(`${error.message}\n`);
      process.exit(3);
    }
    process.stderr.write(`subset-timer daemon: ${error.message}\n`);
    process.exit(1);
  }
  for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) process.on(signal, () => daemon.shutdown(0));
  process.exit(await daemon.closed);
}
