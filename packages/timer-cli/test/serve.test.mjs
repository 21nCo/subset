import assert from 'node:assert/strict';
import { spawn, spawnSync } from 'node:child_process';
import { request } from 'node:http';
import { createServer } from 'node:net';
import { join } from 'node:path';
import test from 'node:test';
import { createClient } from '../src/daemon/index.mjs';
import { startWebServer, PortInUseError } from '../src/serve.mjs';
import { PACKAGE_ROOT, refuseSpawn, runCli } from './cli/helpers.mjs';
import { eventually, startTestDaemon, tempDataDir, within } from './daemon/helpers.mjs';

// The package test script builds dist/cli.mjs and copies the built board into web/ first.
const WEB_DIR = join(PACKAGE_ROOT, 'web');
const CLI = join(PACKAGE_ROOT, 'dist/cli.mjs');
const PAGE = { 'x-subset-timer': '1' };

/** Holds a 127.0.0.1 port, so a server trying it finds it in use. Released after the test. */
async function busyPort(t) {
  const blocker = createServer();
  await new Promise((resolve) => blocker.listen(0, '127.0.0.1', resolve));
  t.after(() => new Promise((resolve) => blocker.close(resolve)));
  return blocker.address().port;
}

async function freePort() {
  const probe = createServer();
  await new Promise((resolve) => probe.listen(0, '127.0.0.1', resolve));
  const { port } = probe.address();
  await new Promise((resolve) => probe.close(resolve));
  return port;
}

/** One request to the web host with exact headers (a Host or Origin fetch would rewrite). */
function send(port, { method = 'GET', path = '/', headers = {}, body, raw } = {}) {
  return new Promise((resolve, reject) => {
    const outgoing = request({ host: '127.0.0.1', port, method, path, agent: false, headers: { host: `127.0.0.1:${port}`, ...headers } }, (response) => {
      const chunks = [];
      response.on('data', (chunk) => chunks.push(chunk));
      response.on('end', () => {
        const text = Buffer.concat(chunks).toString('utf8');
        let json = null;
        try {
          json = JSON.parse(text);
        } catch {
          // Static files and bare 403s are not JSON.
        }
        resolve({ status: response.statusCode, headers: response.headers, text, json });
      });
    });
    outgoing.on('error', reject);
    outgoing.end(raw ?? (body === undefined ? undefined : JSON.stringify(body)));
  });
}

/** A change from the page: the header and this server's Origin. */
const op = (port, name, input) => send(port, { method: 'POST', path: `/api/ops/${name}`, headers: { ...PAGE, origin: `http://127.0.0.1:${port}`, 'content-type': 'application/json' }, body: input });

/** Opens /api/events as the page does and collects its events. */
function openEvents(port) {
  const events = [];
  const waiters = [];
  let ended = false;
  let outgoing;
  const connected = new Promise((resolve, reject) => {
    outgoing = request({ host: '127.0.0.1', port, path: '/api/events', agent: false, headers: PAGE }, (response) => {
      let buffer = '';
      response.setEncoding('utf8');
      response.on('data', (chunk) => {
        buffer += chunk;
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const block = buffer.slice(0, end);
          buffer = buffer.slice(end + 2);
          events.push({ event: /^event: (.*)$/m.exec(block)[1], data: JSON.parse(/^data: (.*)$/m.exec(block)[1]) });
        }
        for (const waiter of waiters.splice(0)) waiter();
      });
      response.on('close', () => {
        ended = true;
        for (const waiter of waiters.splice(0)) waiter();
      });
      resolve(response);
    });
    outgoing.on('error', reject);
    outgoing.end();
  });
  return {
    events,
    connected,
    get ended() {
      return ended;
    },
    async waitFor(predicate, what) {
      await within((async () => {
        while (!predicate(events)) await new Promise((resolve) => waiters.push(resolve));
      })(), 5_000, what);
    },
    close: () => outgoing.destroy()
  };
}

/** A web host proxying to an in-process daemon on a real Unix socket in a temp data directory. */
async function servedDaemon(t, options = {}) {
  const daemon = await startTestDaemon(t);
  const client = createClient({ dataDir: daemon.dataDir, spawn: refuseSpawn });
  const host = await startWebServer({ client, webDir: WEB_DIR, port: await freePort(), ...options });
  t.after(() => host.close());
  return { ...daemon, host, port: host.port };
}

test('the server binds 127.0.0.1, a busy default port moves to the next free one, and --port requires its own', async (t) => {
  const busy = await busyPort(t);
  const client = createClient({ dataDir: tempDataDir(t), spawn: refuseSpawn });
  const host = await startWebServer({ client, webDir: WEB_DIR, port: busy });
  t.after(() => host.close());
  assert.equal(host.server.address().address, '127.0.0.1');
  assert.ok(host.port > busy, `expected a port after ${busy}, got ${host.port}`);
  assert.equal(host.url, `http://127.0.0.1:${host.port}`);
  await assert.rejects(startWebServer({ client, webDir: WEB_DIR, port: busy, strictPort: true }), PortInUseError);
});

test('/api/* needs the page header, its own host and origin, and sends no CORS headers', async (t) => {
  const { port, daemon } = await servedDaemon(t);
  const own = `http://127.0.0.1:${port}`;
  const refused = {
    'no header': await send(port, { path: '/api/timers' }),
    'cross-origin Origin': await send(port, { path: '/api/timers', headers: { ...PAGE, origin: 'http://evil.example' } }),
    'cross-site fetch metadata': await send(port, { path: '/api/timers', headers: { ...PAGE, 'sec-fetch-site': 'cross-site' } }),
    'another host name (DNS rebinding)': await send(port, { path: '/api/timers', headers: { ...PAGE, host: `evil.example:${port}` } }),
    'a change without Origin': await send(port, { method: 'POST', path: '/api/ops/create', headers: PAGE, body: { timer: { kind: 'stopwatch' } } }),
    'a change from another origin': await send(port, { method: 'POST', path: '/api/ops/create', headers: { ...PAGE, origin: 'http://localhost:1' }, body: { timer: { kind: 'stopwatch' } } }),
    'a preflight': await send(port, { method: 'OPTIONS', path: '/api/ops/create', headers: { origin: 'http://evil.example', 'access-control-request-method': 'POST', 'access-control-request-headers': 'x-subset-timer' } }),
    'events without the header': await send(port, { path: '/api/events' })
  };
  for (const [name, reply] of Object.entries(refused)) {
    assert.equal(reply.status, 403, name);
    assert.deepEqual(Object.keys(reply.headers).filter((header) => header.startsWith('access-control-')), [], name);
  }
  assert.equal(daemon.store.timers.length, 0, 'no refused change reached the daemon');

  const allowed = await send(port, { path: '/api/timers', headers: { ...PAGE, origin: own, 'sec-fetch-site': 'same-origin' } });
  assert.equal(allowed.status, 200);
  assert.deepEqual(Object.keys(allowed.headers).filter((header) => header.startsWith('access-control-')), []);
  assert.equal((await send(port, { path: '/api/timers', headers: { ...PAGE, host: `localhost:${port}` } })).status, 200);
  assert.equal((await send(port, { path: '/api/nope', headers: PAGE })).status, 404);
  assert.equal((await send(port, { path: '/api/ops/constructor', method: 'POST', headers: { ...PAGE, origin: own } })).status, 404);
  assert.equal((await send(port, { path: '/api/timers', method: 'DELETE', headers: { ...PAGE, origin: own } })).status, 405);
});

test('operations proxied end to end change the daemon state, and its errors pass through', async (t) => {
  const { port, daemon } = await servedDaemon(t);
  const started = await op(port, 'start', { timer: { kind: 'countdown', durationMs: 60_000 }, name: 'Tea' });
  assert.equal(started.status, 200);
  const { id } = started.json.timer.definition;
  assert.deepEqual(daemon.store.timers.map((timer) => [timer.definition.id, timer.runtime.status]), [[id, 'running']]);

  assert.equal((await op(port, 'pause', { id })).status, 200);
  assert.equal(daemon.store.timers[0].runtime.status, 'paused');
  const listed = await send(port, { path: '/api/timers', headers: PAGE });
  assert.deepEqual(listed.json.structuredContent.timers.map((timer) => [timer.definition.name, timer.runtime.status]), [['Tea', 'paused']]);
  const presets = await send(port, { path: '/api/presets', headers: PAGE });
  assert.ok(presets.json.presets.some((preset) => preset.id === 'tabata'));

  // The daemon's refusals reach the page as they are.
  const missing = await op(port, 'resume', { id: 't_00000000' });
  assert.equal(missing.status, 404);
  assert.equal(missing.json.error.code, 'not_found');
  const malformed = await send(port, { method: 'POST', path: '/api/ops/create', headers: { ...PAGE, origin: `http://127.0.0.1:${port}` }, raw: '{"timer":' });
  assert.equal(malformed.status, 400);
  assert.equal((await op(port, 'remove', { id })).status, 200);
  assert.deepEqual(daemon.store.timers, []);
});

test('the event stream carries a state event after an operation and lets go of the daemon when the page leaves', async (t) => {
  const { port, daemon } = await servedDaemon(t);
  const stream = openEvents(port);
  const response = await stream.connected;
  assert.equal(response.statusCode, 200);
  assert.match(response.headers['content-type'], /^text\/event-stream/);
  await stream.waitFor((events) => events.some((event) => event.event === 'state'), 'the first state');
  assert.deepEqual(stream.events[0].data.structuredContent.timers, []);

  const started = await op(port, 'start', { timer: { kind: 'stopwatch' } });
  const { id } = started.json.timer.definition;
  await stream.waitFor((events) => events.some((event) => event.event === 'state' && event.data.structuredContent.timers.some((timer) => timer.definition.id === id)), 'a state with the new timer');
  assert.ok(stream.events.every((event) => ['state', 'heartbeat'].includes(event.event)), 'alerts stay with the daemon');

  assert.equal(daemon.subscriberCount, 1);
  stream.close();
  await eventually(() => daemon.subscriberCount === 0);
});

test('a daemon that cannot be reached is a 503, and closing the host ends open streams', async (t) => {
  // No daemon is listening and this client may not start one.
  const client = createClient({ dataDir: tempDataDir(t), spawn: refuseSpawn });
  const host = await startWebServer({ client, webDir: WEB_DIR, port: await freePort() });
  t.after(() => host.close());
  for (const path of ['/api/timers', '/api/presets', '/api/events']) {
    const reply = await send(host.port, { path, headers: PAGE });
    assert.equal(reply.status, 503, path);
    assert.equal(reply.json.error.code, 'daemon_unavailable', path);
  }

  const { port, daemon, host: served } = await servedDaemon(t);
  const stream = openEvents(port);
  await stream.waitFor((events) => events.length > 0, 'the first state');
  assert.equal(daemon.subscriberCount, 1);
  await within(served.close(), 5_000, 'the web host to close');
  await eventually(() => stream.ended);
  await eventually(() => daemon.subscriberCount === 0);
});

test('the static board is served with its title and favicon, and other paths are 404', async (t) => {
  const { port } = await servedDaemon(t);
  const index = await send(port);
  assert.equal(index.status, 200);
  assert.match(index.headers['content-type'], /^text\/html/);
  assert.match(index.text, /<title>Timer<\/title>/);
  assert.match(index.text, /rel="icon" href="\/favicon\.svg"/);
  assert.match(index.headers['content-security-policy'], /default-src 'self'/);
  const asset = /src="(\/assets\/[^"]+\.js)"/.exec(index.text)[1];
  assert.match((await send(port, { path: asset })).headers['content-type'], /^text\/javascript/);
  assert.equal((await send(port, { path: '/favicon.svg' })).headers['content-type'], 'image/svg+xml');
  for (const path of ['/nope', '/%2e%2e/package.json', '/assets/', '/%E0%A4%A']) assert.equal((await send(port, { path })).status, 404, path);
  assert.equal((await send(port, { method: 'POST', path: '/', headers: { origin: `http://127.0.0.1:${port}` } })).status, 405);
});

test('serve prints its URL, opens the browser unless --no-open, and stops when asked', async (t) => {
  const { dataDir } = await startTestDaemon(t);
  const client = createClient({ dataDir, spawn: refuseSpawn });
  for (const noOpen of [false, true]) {
    const port = await freePort();
    const opened = [];
    let stop;
    const stopped = new Promise((resolve) => (stop = resolve));
    const running = runCli(['serve', '--port', String(port), '--json', ...(noOpen ? ['--no-open'] : [])], {
      client,
      openUrl: (url) => opened.push(url),
      untilStopped: async () => {
        assert.equal((await send(port)).status, 200);
        await stopped;
      }
    });
    await eventually(() => opened.length > 0 || noOpen);
    stop();
    const result = await running;
    assert.equal(result.code, 0, result.stderr);
    assert.deepEqual(result.json(), { url: `http://127.0.0.1:${port}`, port });
    assert.deepEqual(opened, noOpen ? [] : [`http://127.0.0.1:${port}`]);
    await assert.rejects(send(port), { code: 'ECONNREFUSED' });
  }
});

test('serve --port with a busy or invalid port fails with exit 2', async (t) => {
  const busy = await busyPort(t);
  const client = createClient({ dataDir: tempDataDir(t), spawn: refuseSpawn });
  const taken = await runCli(['serve', '--port', String(busy), '--no-open'], { client });
  assert.equal(taken.code, 2);
  assert.match(taken.stderr, new RegExp(`Port ${busy} is in use`));
  for (const port of ['0', '65536', 'abc', '80.5']) {
    assert.equal((await runCli(['serve', '--port', port, '--no-open'], { client })).code, 2, port);
  }
  // The built CLI exits 2 as well.
  const built = spawnSync(process.execPath, [CLI, 'serve', '--no-open', '--port', String(busy)], { env: { ...process.env, SUBSET_TIMER_DATA_DIR: tempDataDir(t), SUBSET_TIMER_ALERTS: 'off' }, encoding: 'utf8', timeout: 20_000 });
  assert.equal(built.status, 2, built.stderr);
});

test('the built CLI serves the board, starts the daemon for the page, and exits on Ctrl-C with a stream open', async (t) => {
  const dataDir = tempDataDir(t);
  const port = await freePort();
  const child = spawn(process.execPath, [CLI, 'serve', '--no-open', '--port', String(port)], { env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir, SUBSET_TIMER_ALERTS: 'off' }, stdio: ['ignore', 'pipe', 'pipe'] });
  const exited = new Promise((resolve) => child.on('exit', (code, signal) => resolve({ code, signal })));
  t.after(() => child.kill('SIGKILL'));
  let stdout = '';
  child.stdout.on('data', (chunk) => (stdout += chunk));
  await eventually(() => stdout.includes(`http://127.0.0.1:${port}`), 10_000);

  assert.match((await send(port)).text, /<title>Timer<\/title>/);
  // The first API call starts the per-user daemon, as any command does.
  const started = await op(port, 'start', { timer: { kind: 'countdown', durationMs: 60_000 } });
  assert.equal(started.status, 200, started.text);
  const stream = openEvents(port);
  await stream.waitFor((events) => events.some((event) => event.event === 'state' && event.data.structuredContent.timers.length === 1), 'the started timer');

  child.kill('SIGINT');
  assert.deepEqual(await within(exited, 5_000, 'serve to exit'), { code: 0, signal: null });
  await eventually(() => stream.ended);
  // The daemon outlives the web host, and the timer the page started keeps running.
  const status = spawnSync(process.execPath, [CLI, 'list', '--json'], { env: { ...process.env, SUBSET_TIMER_DATA_DIR: dataDir, SUBSET_TIMER_ALERTS: 'off' }, encoding: 'utf8', timeout: 20_000 });
  assert.equal(JSON.parse(status.stdout).structuredContent.timers[0].projection.status, 'running');
});
