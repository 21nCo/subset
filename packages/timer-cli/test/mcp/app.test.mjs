import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { after } from 'node:test';
import { assertMcpAppContracts, defineMcpFnServer } from '@mcpfn/core';
import { McpFnTestClient } from '@mcpfn/testing';
import { build } from 'rolldown';
import { compile } from 'svelte/compiler';
import { BOARD_TOOLS, BOARD_URI, boardHtmlFile } from '../../src/mcp/app.mjs';
import { defineTimerMcpServer } from '../../src/mcp/server.mjs';
import { timerTools } from '../../src/mcp/tools.mjs';
import { PACKAGE_ROOT, cliDaemon } from '../cli/helpers.mjs';

const REPO = join(PACKAGE_ROOT, '../..');
// The package test script builds @subset/timer-web, which writes the view here.
const BOARD_HTML = join(PACKAGE_ROOT, 'mcp-app/board.html');
const MIME = 'text/html;profile=mcp-app';
const NO_DOMAINS = { connectDomains: [], resourceDomains: [], frameDomains: [] };

/**
 * The view's own sources for Node: the bridge (apps/timer/src/mcp-bridge.ts), the MCP App component
 * with the board it mounts, compiled for server rendering, and the board's view model, which decides
 * what the board shows for an action's reply.
 */
async function bundleView() {
  const dir = mkdtempSync(join(tmpdir(), 'timer-mcp-app-'));
  after(() => rmSync(dir, { recursive: true, force: true }));
  const entry = [
    `export { createBridge, PROTOCOL_VERSION, REFRESH_MS } from ${JSON.stringify(join(REPO, 'apps/timer/src/mcp-bridge.ts'))};`,
    `export { default as McpApp } from ${JSON.stringify(join(REPO, 'apps/timer/src/McpApp.svelte'))};`,
    `export { failureText, readBoardResult, readOutcome } from ${JSON.stringify(join(REPO, 'packages/timer/src/view/view-model.ts'))};`,
    `export { render } from 'svelte/server';`
  ].join('\n');
  await build({
    cwd: PACKAGE_ROOT,
    input: 'mcp-app-view',
    platform: 'node',
    logLevel: 'silent',
    resolve: { extensionAlias: { '.js': ['.ts', '.js'] } },
    plugins: [
      { name: 'entry', resolveId: (id) => (id === 'mcp-app-view' ? '\0mcp-app-view' : null), load: (id) => (id === '\0mcp-app-view' ? entry : null) },
      {
        name: 'svelte',
        transform(code, id) {
          if (!id.endsWith('.svelte')) return null;
          return { code: compile(code, { filename: id, generate: 'server' }).js.code, moduleType: 'js' };
        }
      }
    ],
    output: { dir, format: 'esm', entryFileNames: 'view.mjs' }
  });
  return import(join(dir, 'view.mjs'));
}

const view = await bundleView();

/** The Timer MCP server over an in-process daemon holding the SET-74 fixture store. */
async function mcpSession(t) {
  const daemon = await cliDaemon(t, { fixture: true });
  const declaration = defineTimerMcpServer({ client: daemon.client, now: () => daemon.clock.now(), boardHtml: boardHtmlFile(PACKAGE_ROOT) });
  const mcp = await McpFnTestClient.connect(declaration.createServer());
  t.after(() => mcp.close());
  const timer = async (id) => (await daemon.op('get', { id })).body.timer;
  return { ...daemon, declaration, mcp, timer };
}

/**
 * A host on postMessage: it answers `ui/initialize` with `theme` and runs each `tools/call` on the
 * Timer server, as an MCP Apps host does, unless `refuse` returns a reason (a declined approval).
 */
function fakeHost(mcp, { theme = 'dark' } = {}) {
  const listeners = new Set();
  const sent = [];
  const calls = [];
  const inflight = new Set();
  const host = {
    refuse: null,
    sent,
    calls,
    window: {
      postMessage(message, targetOrigin) {
        assert.equal(targetOrigin, '*');
        const data = structuredClone(message);
        sent.push(data);
        const work = answer(data);
        inflight.add(work);
        work.finally(() => inflight.delete(work));
      }
    },
    view: {
      addEventListener: (type, listener) => (assert.equal(type, 'message'), listeners.add(listener)),
      removeEventListener: (type, listener) => listeners.delete(listener)
    },
    /** Posts `data` to the view from `source` (the host's window unless given). */
    deliver(data, source = host.window) {
      for (const listener of [...listeners]) listener({ source, data: structuredClone(data) });
    },
    notify: (method, params) => host.deliver({ jsonrpc: '2.0', method, params }),
    /** Waits until every request the view sent has its answer and the view has taken it. */
    async idle() {
      do {
        await Promise.all([...inflight]);
        await new Promise(setImmediate);
      } while (inflight.size);
    },
    listening: () => listeners.size
  };
  const reply = (id, body) => host.deliver({ jsonrpc: '2.0', id, ...body });
  async function answer(message) {
    // postMessage delivers later, never during the call.
    await null;
    if (!message.method || !('id' in message)) return;
    if (message.method === 'ui/initialize') {
      return reply(message.id, { result: { protocolVersion: '2026-01-26', hostInfo: { name: 'fake-host', version: '1.0.0' }, hostCapabilities: { serverTools: {} }, hostContext: { theme } } });
    }
    if (message.method === 'tools/call') {
      calls.push(message.params);
      const refusal = host.refuse?.(message.params);
      if (refusal) return reply(message.id, { error: { code: -32000, message: refusal } });
      return reply(message.id, { result: await mcp.callTool(message.params.name, message.params.arguments) });
    }
  }
  return host;
}

/** Fake interval timers: `fire()` runs every live one once. */
function fakeIntervals() {
  const live = new Map();
  let next = 0;
  return {
    live,
    setInterval: (callback, ms) => (live.set(++next, { callback, ms }), next),
    clearInterval: (handle) => live.delete(handle),
    fire: () => [...live.values()].forEach(({ callback }) => callback())
  };
}

async function connectedBridge(t, options = {}) {
  const session = await mcpSession(t);
  const host = fakeHost(session.mcp, options);
  const intervals = fakeIntervals();
  const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-timer-board', version: '1.0.0' }, setInterval: intervals.setInterval, clearInterval: intervals.clearInterval });
  t.after(() => bridge.close());
  const connected = bridge.connect();
  await host.idle();
  await connected;
  return { ...session, host, bridge, intervals };
}

/** The markup `McpApp.svelte` renders for the bridge's current state. */
const rendered = (bridge) => view.render(view.McpApp, { props: { bridge } }).body;

test('resources/list and resources/read return the board: its ui:// URI, MIME type, CSP metadata and HTML', async (t) => {
  const { mcp } = await mcpSession(t);
  const resources = await mcp.listResources();
  assert.deepEqual(resources.map(({ uri, name, mimeType }) => ({ uri, name, mimeType })), [{ uri: 'ui://subset-timer/board@1', name: 'timer-board', mimeType: MIME }]);
  assert.equal(BOARD_URI, 'ui://subset-timer/board@1');
  // No external connect, resource or frame domains: the view reaches the server only through the host.
  assert.deepEqual(resources[0]._meta, { ui: { csp: NO_DOMAINS, prefersBorder: true } });

  const read = await mcp.readResource(BOARD_URI);
  assert.equal(read.contents.length, 1);
  const [content] = read.contents;
  assert.deepEqual({ uri: content.uri, mimeType: content.mimeType, _meta: content._meta }, { uri: BOARD_URI, mimeType: MIME, _meta: { ui: { csp: NO_DOMAINS, prefersBorder: true } } });
  assert.equal(content.text, readFileSync(BOARD_HTML, 'utf8'));
  assert.match(content.text, /^<!doctype html>/i);
});

test('timer_start, timer_list and timer_get link to the board, which mcpfn validates; the other tools return no view', async (t) => {
  const { mcp, declaration, client } = await mcpSession(t);
  assert.doesNotThrow(() => assertMcpAppContracts(declaration.registry));
  const tools = await mcp.listTools();
  assert.deepEqual(BOARD_TOOLS.toSorted(), ['timer_get', 'timer_list', 'timer_start']);
  for (const tool of tools) {
    if (BOARD_TOOLS.includes(tool.name)) {
      assert.deepEqual(tool._meta, { ui: { resourceUri: BOARD_URI, visibility: ['model', 'app'] }, 'ui/resourceUri': BOARD_URI }, tool.name);
    } else {
      assert.equal(tool._meta, undefined, tool.name);
    }
  }
  assert.equal(tools.filter((tool) => tool._meta).length, 3);
  // The validation is live: the same tools without the resource are refused.
  const unlinked = defineMcpFnServer({ info: { name: 'subset-timer', version: '0.1.0' }, tools: timerTools({ client }) });
  assert.throws(() => unlinked.manifest(), /Tool timer_\w+ links to missing MCP App resource ui:\/\/subset-timer\/board@1/);

  // A result is the same for every host: no view data rides on it.
  const listed = await mcp.callTool('timer_list', {});
  assert.deepEqual(Object.keys(listed).sort(), ['content', 'structuredContent']);
});

test('the built board.html inlines its script and styles and loads nothing (static scan)', () => {
  const html = readFileSync(BOARD_HTML, 'utf8');
  assert.match(html, /^<!doctype html>/i);
  const scripts = [...html.matchAll(/<script\b([^>]*)>([\s\S]*?)<\/script>/gi)];
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0][1].trim(), 'type="module"');
  assert.ok(scripts[0][2].length > 10_000, 'the board and the bridge are inlined');
  const styles = [...html.matchAll(/<style\b[^>]*>([\s\S]*?)<\/style>/gi)].map((match) => match[1]);
  assert.ok(styles.some((css) => css.includes('--timer-bg')), 'the board styles are inlined');
  // The markup outside the inlined code: no script src, stylesheet link, or any src or href.
  const markup = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/gi, '');
  assert.doesNotMatch(markup, /<script\b[^>]*\bsrc\s*=/i);
  assert.doesNotMatch(markup, /<link\b/i);
  assert.doesNotMatch(markup, /\s(?:src|href|srcset|action|poster)\s*=/i);
  // No stylesheet imports or url() other than inline data, and no module imports from a URL.
  for (const css of styles) assert.doesNotMatch(css, /@import|url\(\s*['"]?(?!data:)/i);
  assert.doesNotMatch(scripts[0][2], /\bimport\s*\(\s*["'`](?:https?:)?\/\/|\bfrom\s*["'](?:https?:)?\/\//);
});

test('the bridge initializes with the host, renders the tool result it passes and follows the host theme', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  const [init, initialized] = host.sent;
  assert.deepEqual(init, { jsonrpc: '2.0', id: 1, method: 'ui/initialize', params: { protocolVersion: '2026-01-26', appInfo: { name: 'subset-timer-board', version: '1.0.0' }, appCapabilities: {} } });
  assert.deepEqual(initialized, { jsonrpc: '2.0', method: 'ui/notifications/initialized' });
  assert.equal(bridge.state().theme, 'dark');
  assert.match(rendered(bridge), /Waiting for the timers/);

  // The host passes the timer_start result: the board shows its structuredContent, without the
  // write's affectedTimerId, which is not a view prop.
  const started = await mcp.callTool('timer_start', { durationSeconds: 300, name: 'Tea' });
  host.notify('ui/notifications/tool-input', { arguments: { durationSeconds: 300, name: 'Tea' } });
  host.notify('ui/notifications/tool-result', started);
  const { result } = bridge.state();
  const { affectedTimerId, ...board } = started.structuredContent;
  assert.match(affectedTimerId, /^t_\w{8}$/);
  assert.deepEqual(result, board);
  assert.equal(view.readBoardResult(result).ok, true);
  const markup = rendered(bridge);
  assert.match(markup, /<section class="board [^"]*\bcompact\b/);
  assert.match(markup, />Tea</);
  assert.match(markup, />Tabata</);
  // capabilities.create: the create form shows.
  assert.match(markup, /New timer/);
  assert.doesNotMatch(markup, /Waiting for the timers/);

  // A message from anywhere but the host is ignored.
  host.deliver({ jsonrpc: '2.0', method: 'ui/notifications/tool-result', params: { structuredContent: { ...board, timers: [] } } }, {});
  assert.equal(bridge.state().result, result);

  host.notify('ui/notifications/host-context-changed', { theme: 'light' });
  assert.equal(bridge.state().theme, 'light');
  host.notify('ui/notifications/host-context-changed', { displayMode: 'inline' });
  assert.equal(bridge.state().theme, 'light');
  host.notify('ui/notifications/host-context-changed', { theme: 'sepia' });
  assert.equal(bridge.state().theme, null);
});

test('each board action calls the matching tool with its arguments, and its reply meets the Timer contract', async (t) => {
  const { host, bridge, timer } = await connectedBridge(t);
  const { invoke } = bridge.actions;

  /** Runs an action, checks the tool call it made and that the board accepts its reply. */
  async function act(operation, input, call, timerId = input.id ?? null) {
    const from = host.calls.length;
    const outcome = invoke(operation, input);
    await host.idle();
    const reply = await outcome;
    assert.deepEqual(host.calls.slice(from), [call], operation);
    const read = view.readOutcome(operation, timerId, reply);
    assert.equal(read.ok, true, `${operation}: ${JSON.stringify(read.failure)}`);
    return read.result;
  }

  await act('pause', { id: 't_adygqpxx' }, { name: 'timer_pause', arguments: { id: 't_adygqpxx' } });
  assert.equal((await timer('t_adygqpxx')).runtime.status, 'paused');
  await act('resume', { id: 't_adygqpxx' }, { name: 'timer_resume', arguments: { id: 't_adygqpxx' } });
  await act('skip', { id: 't_adygqpxx' }, { name: 'timer_skip', arguments: { id: 't_adygqpxx' } });
  await act('lap', { id: 't_rcrt44q9' }, { name: 'timer_lap', arguments: { id: 't_rcrt44q9' } });
  await act('reset', { id: 't_dk1facen' }, { name: 'timer_reset', arguments: { id: 't_dk1facen' } });
  assert.equal((await timer('t_dk1facen')).runtime.status, 'idle');
  // Start on an idle timer is timer_start by id.
  await act('start', { id: 't_dk1facen' }, { name: 'timer_start', arguments: { id: 't_dk1facen' } });
  assert.equal((await timer('t_dk1facen')).runtime.status, 'running');
  assert.deepEqual(await act('remove', { id: 't_v9pdg8p9' }, { name: 'timer_remove', arguments: { id: 't_v9pdg8p9' } }), { removedId: 't_v9pdg8p9', observedAt: (await act('list', {}, { name: 'timer_list', arguments: {} })).observedAt });
  assert.equal(await timer('t_v9pdg8p9'), undefined);
  const listed = await act('list', {}, { name: 'timer_list', arguments: {} });
  assert.ok(!listed.timers.some((snapshot) => snapshot.definition.id === 't_v9pdg8p9'));
  assert.ok((await act('presets.list', {}, { name: 'timer_presets', arguments: {} })).presets.some((preset) => preset.id === 'tabata'));
  assert.equal((await act('get', { id: 't_rcrt44q9' }, { name: 'timer_get', arguments: { id: 't_rcrt44q9' } })).timer.definition.id, 't_rcrt44q9');

  // The create form's inputs, in the tools' seconds.
  const created = async (input, args) => {
    const { timer: snapshot } = await act('create', input, { name: 'timer_start', arguments: args });
    assert.equal(snapshot.runtime.status, 'running');
    return snapshot.definition;
  };
  assert.equal((await created({ preset: 'tabata', name: 'Box' }, { preset: 'tabata', name: 'Box' })).name, 'Box');
  const laps = await created({ timer: { kind: 'countdown', name: 'Laps', durationMs: 90_000, lapsEnabled: true, sound: false } }, { durationSeconds: 90, laps: true, name: 'Laps', sound: false });
  assert.deepEqual([laps.durationMs, laps.lapsEnabled, laps.sound], [90_000, true, false]);
  assert.equal((await created({ timer: { kind: 'stopwatch', name: 'Run' } }, { stopwatch: true, name: 'Run' })).kind, 'stopwatch');
  const interval = await created(
    { timer: { kind: 'interval', name: 'Rows', countdownTicks: false, rounds: 3, prepMs: 10_000, segments: [{ label: 'Pull', phase: 'work', durationMs: 40_000 }, { label: 'Rest', phase: 'rest', durationMs: 20_000 }] } },
    { interval: { rounds: 3, prep: 10, segments: [{ label: 'Pull', phase: 'work', seconds: 40 }, { label: 'Rest', phase: 'rest', seconds: 20 }] }, name: 'Rows', ticks: false }
  );
  assert.deepEqual([interval.rounds, interval.prepMs, interval.countdownTicks, interval.segments[0].label], [3, 10_000, false, 'Pull']);

  // A duration the tools cannot take fails in the view, with no tool call.
  const calls = host.calls.length;
  const fraction = await invoke('create', { timer: { kind: 'countdown', durationMs: 1_500 } });
  assert.equal(host.calls.length, calls);
  assert.equal(view.failureText(view.readOutcome('create', null, fraction).failure), 'Create failed: duration: the Timer tools take whole seconds');
});

test('a tool error shows as the board\'s inline error; a refused call or a failed tool result says why', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  // t_dk1facen is paused; the daemon's refusal reaches the board as the action's failure.
  const outcome = bridge.actions.invoke('pause', { id: 't_dk1facen' });
  await host.idle();
  const refused = view.readOutcome('pause', 't_dk1facen', await outcome);
  assert.equal(refused.ok, false);
  assert.equal(view.failureText(refused.failure), 'Pause failed: Timer t_dk1facen is paused; only a running timer can pause.');

  // The host refuses the call (the user declined it): the action fails with the host's reason.
  host.refuse = ({ name }) => (name === 'timer_remove' ? 'The user declined timer_remove.' : null);
  const declined = assert.rejects(bridge.actions.invoke('remove', { id: 't_ac50bvkp' }), /The user declined timer_remove\./);
  await host.idle();
  await declined;

  // The tool result the host passes is an error: the view says so instead of a board.
  host.notify('ui/notifications/tool-result', await mcp.callTool('timer_get', { id: 't_00000000' }));
  assert.equal(bridge.state().toolError, 'No timer t_00000000.');
  assert.equal(bridge.state().result, null);
  assert.match(rendered(bridge), /<p class="error[^"]*" role="alert">No timer t_00000000\.</);
});

test('a cancelled tool call shows as cancelled', async (t) => {
  const { host, bridge } = await connectedBridge(t);
  host.notify('ui/notifications/tool-cancelled', { reason: 'user' });
  assert.equal(bridge.state().toolError, 'The tool call was cancelled.');
});

test('the bridge reads timer_list every 10 s while the view is visible, stops while hidden and ends at teardown', async (t) => {
  const { host, bridge, intervals, op } = await connectedBridge(t);
  assert.deepEqual([...intervals.live.values()].map(({ ms }) => ms), [view.REFRESH_MS]);
  assert.equal(view.REFRESH_MS, 10_000);

  // A change made elsewhere (the CLI) shows on the next read.
  await op('pause', { id: 't_adygqpxx' });
  intervals.fire();
  await host.idle();
  assert.deepEqual(host.calls, [{ name: 'timer_list', arguments: {} }]);
  assert.equal(bridge.state().result.timers.find((snapshot) => snapshot.definition.id === 't_adygqpxx').runtime.status, 'paused');

  // Hidden or detached: no reads. Shown again: one read at once, then every 10 s.
  bridge.setVisible(false);
  assert.equal(intervals.live.size, 0);
  bridge.setVisible(false);
  await host.idle();
  assert.equal(host.calls.length, 1);
  bridge.setVisible(true);
  await host.idle();
  assert.equal(host.calls.length, 2);
  assert.equal(intervals.live.size, 1);

  // A failed read keeps the board and says so, until the next read succeeds.
  const shown = bridge.state().result;
  host.refuse = () => 'The host is offline.';
  intervals.fire();
  await host.idle();
  assert.equal(bridge.state().result, shown);
  assert.equal(bridge.state().refreshError, 'The host is offline.');
  assert.match(rendered(bridge), /Could not refresh the timers: The host is offline\./);
  host.refuse = null;
  intervals.fire();
  await host.idle();
  assert.equal(bridge.state().refreshError, null);

  // ping is answered; an unknown request is refused.
  host.deliver({ jsonrpc: '2.0', id: 'p1', method: 'ping' });
  host.deliver({ jsonrpc: '2.0', id: 'u1', method: 'ui/unknown' });
  assert.deepEqual(host.sent.slice(-2), [{ jsonrpc: '2.0', id: 'p1', result: {} }, { jsonrpc: '2.0', id: 'u1', error: { code: -32601, message: 'Method not found: ui/unknown' } }]);

  // Teardown: answered, then nothing more is read or sent, and actions fail.
  host.deliver({ jsonrpc: '2.0', id: 'td', method: 'ui/resource-teardown', params: {} });
  assert.deepEqual(host.sent.at(-1), { jsonrpc: '2.0', id: 'td', result: {} });
  assert.equal(bridge.state().closed, true);
  assert.equal(intervals.live.size, 0);
  assert.equal(host.listening(), 0);
  const sent = host.sent.length;
  bridge.setVisible(false);
  bridge.setVisible(true);
  bridge.sizeChanged(400, 300);
  await assert.rejects(bridge.actions.invoke('pause', { id: 't_rcrt44q9' }), /The host closed the Timer view\./);
  await host.idle();
  assert.equal(host.sent.length, sent);
  assert.equal(intervals.live.size, 0);
});

test('the bridge tells the host the view size once connected, and only when it changes', async (t) => {
  const session = await mcpSession(t);
  const host = fakeHost(session.mcp);
  const intervals = fakeIntervals();
  const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-timer-board', version: '1.0.0' }, setInterval: intervals.setInterval, clearInterval: intervals.clearInterval });
  t.after(() => bridge.close());
  bridge.sizeChanged(320, 200);
  // Nothing is scheduled or sized before the handshake.
  assert.equal(intervals.live.size, 0);
  const connected = bridge.connect();
  await host.idle();
  await connected;
  const sizes = () => host.sent.filter((message) => message.method === 'ui/notifications/size-changed').map((message) => message.params);
  assert.deepEqual(sizes(), [{ width: 320, height: 200 }]);
  bridge.sizeChanged(320, 200);
  bridge.sizeChanged(320, 260);
  assert.deepEqual(sizes(), [{ width: 320, height: 200 }, { width: 320, height: 260 }]);
});
