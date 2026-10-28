// The local web host behind `subset-timer serve`: the built board (apps/timer, copied to web/) and a
// guarded /api proxy to the daemon socket. It listens on 127.0.0.1 only and holds no timer state.
import { readFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { extname, resolve, sep } from 'node:path';
import { OPERATION_NAMES } from '@subset.dev/timer-core';

/** The first port `serve` tries; without `--port` it moves on to the next free one. */
export const DEFAULT_PORT = 4175;
/** How many ports after the first `serve` tries before it gives up. */
const PORT_ATTEMPTS = 20;
const MAX_BODY_BYTES = 1024 * 1024;
/** The only interface the server binds. Never `0.0.0.0` or `::`. */
const HOST = '127.0.0.1';
/** The daemon events the page receives. Alerts stay with the daemon, which plays them. */
const FORWARDED_EVENTS = new Set(['state', 'heartbeat']);

const MIME = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
  '.ico': 'image/x-icon',
  '.woff2': 'font/woff2'
};

const SECURITY_HEADERS = {
  'cache-control': 'no-store',
  'x-content-type-options': 'nosniff',
  'referrer-policy': 'no-referrer',
  'content-security-policy': "default-src 'self'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
};

export class PortInUseError extends Error {
  constructor(port) {
    super(`Port ${port} is in use.`);
    this.name = 'PortInUseError';
    this.port = port;
  }
}

function json(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, { 'content-type': 'application/json; charset=utf-8', 'content-length': Buffer.byteLength(text) });
  response.end(text);
}

const fail = (response, status, code, message) => json(response, status, { error: { code, message } });

function readBody(request) {
  return new Promise((resolveBody, reject) => {
    const chunks = [];
    let size = 0;
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > MAX_BODY_BYTES) {
        request.pause();
        reject(Object.assign(new Error('The request body is larger than 1 MiB.'), { status: 413 }));
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolveBody(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

/**
 * Whether a request may reach `/api/*`: it names this server as its host (no DNS rebinding), and is
 * same-origin with the header `X-Subset-Timer: 1`, which a cross-origin page cannot send without a
 * CORS preflight this server never approves. A change must also carry this server's `Origin`.
 */
function allowedApiRequest(request, origin) {
  if (request.headers['x-subset-timer'] !== '1') return false;
  if (['cross-site', 'same-site'].includes(request.headers['sec-fetch-site'])) return false;
  const sent = request.headers.origin;
  if (sent !== undefined && sent !== origin) return false;
  return request.method === 'GET' || sent === origin;
}

/**
 * The page origin for a request's `Host` when it names this server on `port`, else `null` (no DNS
 * rebinding). Browsers leave out the default HTTP port, so on port 80 the portless forms count too.
 */
function pageOrigin(requestHost, port) {
  const names = [`${HOST}:${port}`, `localhost:${port}`];
  if (port === 80) names.push(HOST, 'localhost');
  return names.includes(requestHost) ? new URL(`http://${requestHost}`).origin : null;
}

function listenOnce(server, port) {
  return new Promise((resolveListen, reject) => {
    const onError = (error) => reject(error);
    server.once('error', onError);
    server.listen(port, HOST, () => {
      server.off('error', onError);
      resolveListen();
    });
  });
}

/**
 * Starts the web host on 127.0.0.1. `strictPort` (from `--port`) requires `port` and throws
 * `PortInUseError` when it is taken; otherwise a taken port moves to the next one. Resolves
 * `{ port, url, server, close }`; `close` ends every event stream and connection.
 *
 * @param {object} options
 * @param {ReturnType<import('./daemon/client.mjs').createClient>} options.client The daemon client the proxy uses.
 * @param {string} options.webDir The built board: `index.html` and its assets.
 */
export async function startWebServer({ client, webDir, port = DEFAULT_PORT, strictPort = false }) {
  const web = resolve(webDir);
  /** Each open event stream, closed on shutdown. */
  const streams = new Set();

  async function proxy(response, reply) {
    let answer;
    try {
      answer = await reply;
    } catch (error) {
      fail(response, 503, 'daemon_unavailable', error.message);
      return;
    }
    json(response, answer.status, answer.body);
  }

  async function runOp(request, response, name) {
    let text;
    try {
      text = await readBody(request);
    } catch (error) {
      response.setHeader('connection', 'close');
      response.on('finish', () => request.destroy());
      fail(response, error.status ?? 400, 'invalid_input', error.message);
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
    await proxy(response, client.op(name, input));
  }

  /** Relays the daemon's state and heartbeat events; the stream ends when the daemon's does. */
  async function events(request, response) {
    let gone = false;
    response.on('close', () => {
      gone = true;
    });
    // Events that arrive before the stream is open, such as the daemon's first state, wait for it.
    const early = [];
    let send = (frame) => early.push(frame);
    let upstream;
    try {
      upstream = await client.events(({ event, data }) => {
        if (FORWARDED_EVENTS.has(event)) send(`event: ${event}\ndata: ${JSON.stringify(data)}\n\n`);
      });
    } catch (error) {
      if (!gone) fail(response, 503, 'daemon_unavailable', error.message);
      return;
    }
    if (gone) {
      upstream.close();
      return;
    }
    const entry = { response, upstream };
    streams.add(entry);
    response.on('close', () => {
      streams.delete(entry);
      upstream.close();
    });
    void upstream.done.then(() => response.end());
    response.writeHead(200, { 'content-type': 'text/event-stream; charset=utf-8', connection: 'keep-alive' });
    response.flushHeaders();
    // While the page has not read a frame, only the latest state waits; a heartbeat is dropped.
    let waiting = false;
    let latest = null;
    const write = (frame) => {
      if (response.write(frame)) return;
      waiting = true;
      response.once('drain', () => {
        waiting = false;
        const next = latest;
        latest = null;
        if (next) write(next);
      });
    };
    send = (frame) => {
      if (!waiting) write(frame);
      else if (frame.startsWith('event: state\n')) latest = frame;
    };
    for (const frame of early) send(frame);
  }

  const routes = {
    '/api/timers': { GET: (request, response) => proxy(response, client.timers()) },
    '/api/presets': { GET: (request, response) => proxy(response, client.presets()) },
    '/api/events': { GET: events }
  };

  async function api(request, response, pathname) {
    if (pathname.startsWith('/api/ops/')) {
      let name;
      try {
        name = decodeURIComponent(pathname.slice('/api/ops/'.length));
      } catch {
        name = null;
      }
      if (!OPERATION_NAMES.includes(name)) return fail(response, 404, 'not_found', 'No such operation.');
      if (request.method !== 'POST') return methodNotAllowed(response, ['POST']);
      return runOp(request, response, name);
    }
    const route = Object.hasOwn(routes, pathname) ? routes[pathname] : null;
    if (!route) return fail(response, 404, 'not_found', 'No such route.');
    if (!Object.hasOwn(route, request.method)) return methodNotAllowed(response, Object.keys(route));
    return route[request.method](request, response);
  }

  function methodNotAllowed(response, allowed) {
    response.setHeader('allow', allowed.join(', '));
    fail(response, 405, 'method_not_allowed', `Use ${allowed.join(' or ')}.`);
  }

  async function staticFile(request, response, pathname) {
    if (request.method !== 'GET' && request.method !== 'HEAD') {
      response.setHeader('allow', 'GET, HEAD');
      response.writeHead(405).end();
      return;
    }
    let relative;
    try {
      relative = decodeURIComponent(pathname === '/' ? '/index.html' : pathname);
    } catch {
      relative = null;
    }
    const target = relative === null || relative.includes('\0') ? null : resolve(web, `.${relative}`);
    if (!target || !target.startsWith(web + sep)) {
      response.writeHead(404).end();
      return;
    }
    let body;
    try {
      body = await readFile(target);
    } catch {
      response.writeHead(404).end();
      return;
    }
    response.writeHead(200, { 'content-type': MIME[extname(target)] ?? 'application/octet-stream', 'content-length': body.length });
    response.end(request.method === 'HEAD' ? undefined : body);
  }

  async function handle(request, response) {
    const origin = pageOrigin(request.headers.host, port);
    if (!origin) {
      response.writeHead(403).end();
      return;
    }
    for (const [name, value] of Object.entries(SECURITY_HEADERS)) response.setHeader(name, value);
    const pathname = (request.url ?? '/').split('?')[0];
    if (pathname === '/api' || pathname.startsWith('/api/')) {
      if (!allowedApiRequest(request, origin)) return fail(response, 403, 'forbidden', 'Only the Timer page can use this API.');
      return api(request, response, pathname);
    }
    return staticFile(request, response, pathname);
  }

  const server = createServer((request, response) => {
    handle(request, response).catch(() => {
      if (!response.headersSent) fail(response, 500, 'internal', 'The Timer web host failed to handle the request.');
      else response.destroy();
    });
  });

  for (let attempt = 0; ; attempt++) {
    try {
      await listenOnce(server, port);
      break;
    } catch (error) {
      if (error.code !== 'EADDRINUSE') throw error;
      if (strictPort || attempt + 1 >= PORT_ATTEMPTS || port >= 65_535) throw new PortInUseError(port);
      port++;
    }
  }

  let closing = null;
  function close() {
    closing ??= new Promise((resolveClose) => {
      server.close(() => resolveClose());
      for (const { response, upstream } of streams) {
        upstream.close();
        response.end();
      }
      streams.clear();
      // Browser keep-alive connections would otherwise hold the server open.
      server.closeAllConnections();
    });
    return closing;
  }

  return { port, url: `http://${HOST}:${port}`, server, close };
}
