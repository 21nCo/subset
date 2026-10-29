import assert from 'node:assert/strict';
import { mkdtempSync, readFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test, { after } from 'node:test';
import { fileURLToPath } from 'node:url';
import { assertMcpAppContracts, defineMcpFnServer } from '@mcpfn/core';
import { McpFnTestClient } from '@mcpfn/testing';
import { createUsageStatus, isUsageStatus } from '@subset.dev/usage-core';
import { build } from 'rolldown';
import { compile } from 'svelte/compiler';
import { DASHBOARD_URI, dashboardHtmlFile } from '../src/mcp-app.mjs';
import { defineUsageMcpServer, usageTools } from '../src/mcp.mjs';

const PACKAGE_ROOT = fileURLToPath(new URL('..', import.meta.url));
const REPO = join(PACKAGE_ROOT, '../..');
// `npm run build` at the repository root builds @subset.dev/usage-web, and the package build copies the view here.
const DASHBOARD_HTML = join(PACKAGE_ROOT, 'mcp-app/dashboard.html');
const MIME = 'text/html;profile=mcp-app';
const NO_DOMAINS = { connectDomains: [], resourceDomains: [], frameDomains: [] };
// The dashboard reads the real clock (it drops trend points older than 48 hours), so every fixture time
// derives from the clock the render uses, not a fixed date.
const NOW = Date.now();
const HOUR = 60 * 60_000;
const at = (ms) => new Date(NOW + ms).toISOString();

/** `entry` and everything it imports, bundled into one module for Node, with Svelte compiled for server rendering. */
async function bundle(entry, plugins = []) {
  const dir = mkdtempSync(join(tmpdir(), 'usage-mcp-app-'));
  after(() => rmSync(dir, { recursive: true, force: true }));
  await build({
    cwd: PACKAGE_ROOT,
    input: 'mcp-app-view',
    platform: 'node',
    logLevel: 'silent',
    // phosphor-svelte exports its icon components only under the `svelte` condition.
    resolve: { extensionAlias: { '.js': ['.ts', '.js'] }, conditionNames: ['svelte', 'node', 'import', 'default'] },
    plugins: [
      ...plugins,
      { name: 'entry', resolveId: (id) => (id === 'mcp-app-view' ? '\0mcp-app-view' : null), load: (id) => (id === '\0mcp-app-view' ? entry : null) },
      {
        name: 'svelte',
        transform(code, id) {
          if (!id.endsWith('.svelte')) return null;
          return { code: compile(code, { filename: id, generate: 'server' }).js.code, moduleType: 'js' };
        },
      },
    ],
    output: { dir, format: 'esm', entryFileNames: 'view.mjs' },
  });
  return import(join(dir, 'view.mjs'));
}

const source = (path) => JSON.stringify(join(REPO, path));
/** The view's own sources: the bridge, the MCP App page with the dashboard it mounts, and the dashboard itself. */
const view = await bundle([
  `export * from ${source('apps/usage/src/mcp-bridge.ts')};`,
  `export { default as McpApp } from ${source('apps/usage/src/McpApp.svelte')};`,
  `export { default as UsageDashboard } from ${source('packages/usage/src/UsageDashboard.svelte')};`,
  `export { render } from 'svelte/server';`,
].join('\n'));
/** The same page with the dashboard replaced by a stub that records the props the page passes it. */
const stubbed = await bundle(`export { default as McpApp } from ${source('apps/usage/src/McpApp.svelte')}; export { render } from 'svelte/server';`, [{
  name: 'dashboard-stub',
  resolveId: (id) => (id === '@subset.dev/usage-core/view' ? '\0dashboard-stub' : null),
  load: (id) => (id === '\0dashboard-stub' ? 'export default function UsageDashboard(_renderer, props) { (globalThis.dashboardProps ??= []).push(props); }' : null),
}]);

const window = (usedPercent, overrides = {}) => ({
  limitId: 'five_hour', label: '5-hour', kind: 'provider-reported-quota', usedPercent, remainingPercent: 100 - usedPercent,
  remainingKind: 'provider-reported-quota', durationMinutes: 300, resetsAt: at(3 * HOUR), ...overrides,
});
const account = (id, provider, overrides = {}) => ({
  id, label: id, provider, source: 'Fixture', plan: null, observedAt: at(-2 * 60_000), state: 'ok',
  windows: [window(25)], resetCredits: null, errors: [], ...overrides,
});
const fixtureStatus = (used = 25) => createUsageStatus([
  account('chatgpt_main', 'codex-chatgpt', { label: 'Main ChatGPT', windows: [window(used)] }),
  account('claude_work', 'claude-code', { label: 'Work Claude', windows: [window(60, { limitId: 'seven_day', label: 'Weekly', durationMinutes: 10_080 })] }),
  // Signed out: the dashboard offers Fix for it when the host can open account settings.
  account('amp_cli', 'amp', { label: 'Amp CLI', state: 'unauthorized', windows: [], observedAt: null, errors: [{ code: 'amp_failed', message: 'The amp usage command failed.' }] }),
], new Date(NOW));
// Three points across 2 hours, enough for a trend.
const fixtureHistory = () => ({
  schemaVersion: 1,
  series: { chatgpt_main: { 'five_hour\u00005-hour': [[NOW - 3 * HOUR, 5], [NOW - 2 * HOUR, 15], [NOW - HOUR, 25]] } },
});

/** The usage MCP server over fixture reads; `state.status` and `state.history` change what later reads return. */
async function mcpSession(t, state = {}) {
  state.status ??= fixtureStatus();
  state.history ??= fixtureHistory();
  const declaration = defineUsageMcpServer({
    version: '0.0.0-test', now: () => NOW, providers: ['codex-chatgpt', 'claude-code', 'amp'],
    readStatus: async () => state.status, readHistory: async () => state.history, dashboardHtml: dashboardHtmlFile(PACKAGE_ROOT),
  });
  const mcp = await McpFnTestClient.connect(declaration.createServer());
  t.after(() => mcp.close());
  return { declaration, mcp, state };
}

/**
 * A host on postMessage: it answers `ui/initialize` with `theme` and runs each `tools/call` on the usage
 * server, as an MCP Apps host does. A call `withhold` picks gets no reply; `refuse` answers it with an error.
 * `initialize` set to 'withhold' or 'refuse' does the same to `ui/initialize`.
 */
function fakeHost(mcp, { theme = 'dark' } = {}) {
  const listeners = new Set();
  const keyListeners = new Set();
  const inflight = new Set();
  const host = {
    sent: [],
    calls: [],
    withhold: null,
    refuse: null,
    initialize: 'answer',
    window: {
      postMessage(message, targetOrigin) {
        assert.equal(targetOrigin, '*');
        const data = structuredClone(message);
        host.sent.push(data);
        const work = answer(data);
        inflight.add(work);
        work.finally(() => inflight.delete(work));
      },
    },
    view: {
      addEventListener: (type, listener) => (assert.ok(['message', 'keydown'].includes(type), type), (type === 'message' ? listeners : keyListeners).add(listener)),
      removeEventListener: (type, listener) => (type === 'message' ? listeners : keyListeners).delete(listener),
    },
    /** Posts `data` to the view from `from` (the host's window unless given). */
    deliver(data, from = host.window) {
      for (const listener of [...listeners]) listener({ source: from, data: structuredClone(data) });
    },
    notify: (method, params) => host.deliver({ jsonrpc: '2.0', method, params }),
    /** The user presses `key` on the view; `inField` puts the focus in an input. Returns whether the view took it. */
    press(key, { inField = false, ...modifiers } = {}) {
      const event = { key, metaKey: false, ctrlKey: false, altKey: false, ...modifiers, prevented: false,
        target: { closest: (selectors) => (inField && selectors.split(', ').includes('input') ? {} : null) }, preventDefault() { event.prevented = true; } };
      for (const listener of [...keyListeners]) listener(event);
      return event.prevented;
    },
    /** Answers the view's last withheld tool call with `result`. */
    answerLast(result) {
      const { id } = host.sent.findLast((message) => message.method === 'tools/call');
      host.deliver({ jsonrpc: '2.0', id, result });
    },
    /** The ids of the view's `name` tool calls, oldest first. */
    callIds: (name) => host.sent.filter((message) => message.method === 'tools/call' && message.params.name === name).map(({ id }) => id),
    /** Answers the view's call `id` with `result`. */
    answer: (id, result) => host.deliver({ jsonrpc: '2.0', id, result }),
    /** Waits until every request the view sent has its answer and the view has taken it. */
    async idle() {
      do {
        await Promise.all([...inflight]);
        await new Promise(setImmediate);
      } while (inflight.size);
    },
    listening: () => listeners.size + keyListeners.size,
  };
  const reply = (id, body) => host.deliver({ jsonrpc: '2.0', id, ...body });
  async function answer(message) {
    // postMessage delivers later, never during the call.
    await null;
    if (!message.method || !('id' in message)) return;
    if (message.method === 'ui/initialize') {
      if (host.initialize === 'withhold') return;
      if (host.initialize === 'refuse') return reply(message.id, { error: { code: -32000, message: 'Not now.' } });
      return reply(message.id, { result: initializeResult(theme) });
    }
    if (message.method === 'tools/call') {
      host.calls.push(message.params);
      if (host.withhold?.(message.params)) return;
      const refusal = host.refuse?.(message.params);
      if (refusal) return reply(message.id, { error: { code: -32000, message: refusal } });
      return reply(message.id, { result: await mcp.callTool(message.params.name, message.params.arguments) });
    }
  }
  return host;
}

const initializeResult = (theme) => ({ protocolVersion: '2026-01-26', hostInfo: { name: 'fake-host', version: '1.0.0' }, hostCapabilities: { serverTools: {} }, hostContext: { theme } });

/** Fake timeouts on a fake clock: `advance(ms)` runs every live timeout due by then, as if that long had passed. */
function fakeTimeouts() {
  const live = new Map();
  let next = 0;
  let now = 0;
  return {
    setTimeout: (callback, ms) => (live.set(++next, { callback, due: now + ms }), next),
    clearTimeout: (handle) => live.delete(handle),
    size: () => live.size,
    advance(ms) {
      now += ms;
      for (const [handle, timeout] of [...live]) {
        if (timeout.due > now) continue;
        live.delete(handle);
        timeout.callback();
      }
    },
  };
}

async function connectedBridge(t, { state, theme } = {}) {
  const session = await mcpSession(t, state);
  const host = fakeHost(session.mcp, { theme });
  const timeouts = fakeTimeouts();
  const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' }, ...timeouts });
  t.after(() => bridge.close());
  const connected = bridge.connect();
  await host.idle();
  await connected;
  return { ...session, host, bridge, timeouts };
}

/** The agent's usage_status call, as the host passes its input and result to the view. */
async function passToolResult({ mcp, host }, args = {}) {
  const result = await mcp.callTool('usage_status', args);
  host.notify('ui/notifications/tool-input', { arguments: args });
  host.notify('ui/notifications/tool-result', result);
  return result;
}

/** The markup `McpApp.svelte` renders for the bridge's current state. */
const rendered = (bridge) => view.render(view.McpApp, { props: { bridge } }).body;

/** The text of `markup`: the runs between its tags, joined (read out, not stripped, so no tag is left half-removed). */
const textOf = (markup) => [...`>${markup}`.matchAll(/>([^<]*)/g)].map(([, text]) => text).join('');

/** Each button's label: its aria-label, or its text. */
const buttonLabels = (markup) => [...markup.matchAll(/<button\b([^>]*)>([\s\S]*?)<\/button\s*>/gi)]
  .map(([, attributes, inner]) => attributes.match(/aria-label="([^"]*)"/)?.[1] ?? textOf(inner).replace(/\s+/g, ' ').trim());

/** The local sign-ins disclosure AGENTS.md requires: every tool named, and the endpoints called undocumented. */
const LOCAL_SIGN_IN_TOOLS = ['Claude Code', 'Factory Droid', 'the Cursor app', 'Devin', 'Pi', 'OpenCode', 'omp', 'Hermes', 'Antigravity account email'];
function assertDisclosure(markup) {
  const text = textOf(markup).replace(/\s+/g, ' ');
  const disclosure = text.match(/With Use local sign-ins on,[^.]*\.[^.]*\./)?.[0];
  assert.ok(disclosure, 'the local sign-ins disclosure is shown');
  for (const tool of LOCAL_SIGN_IN_TOOLS) assert.ok(disclosure.includes(tool), tool);
  assert.match(disclosure, /usage endpoints are undocumented/);
}

/**
 * The dashboard's write controls, by its own labels: Manage accounts (manageAccounts), the account menu
 * "Options for …" with Pin and Account settings (togglePin, openAccount), an account's Fix or Set up link
 * (openAccount), and redeeming a banked reset (redeemReset), which only its dialog shows.
 */
const WRITE_LABELS = [/^Manage accounts$/, /^Options for /, /^(?:Un)?[Pp]in$/, /^Account settings$/, /^Fix$/, /^Set up$/, /^Use a reset/, /^Use 1 reset now$/, /^Keep$/];
const writeControls = (markup) => buttonLabels(markup).filter((label) => WRITE_LABELS.some((pattern) => pattern.test(label)));

test('resources/list and resources/read return the dashboard: its ui:// URI, MIME type, CSP metadata and HTML', async (t) => {
  const { mcp } = await mcpSession(t);
  assert.equal(DASHBOARD_URI, 'ui://subset-usage/dashboard@1');
  const resources = await mcp.listResources();
  assert.deepEqual(resources.map(({ uri, name, mimeType }) => ({ uri, name, mimeType })), [{ uri: DASHBOARD_URI, name: 'usage-dashboard', mimeType: MIME }]);
  // No external connect, resource or frame domains: the view reaches the server only through the host.
  assert.deepEqual(resources[0]._meta, { ui: { csp: NO_DOMAINS, prefersBorder: true } });

  const read = await mcp.readResource(DASHBOARD_URI);
  assert.equal(read.contents.length, 1);
  const [content] = read.contents;
  assert.deepEqual({ uri: content.uri, mimeType: content.mimeType, _meta: content._meta }, { uri: DASHBOARD_URI, mimeType: MIME, _meta: { ui: { csp: NO_DOMAINS, prefersBorder: true } } });
  assert.equal(content.text, readFileSync(DASHBOARD_HTML, 'utf8'));
  assert.match(content.text, /^<!doctype html>/i);
});

test('usage_status links to the dashboard, which mcpfn validates; usage_history returns no view and results are unchanged', async (t) => {
  const { mcp, declaration } = await mcpSession(t);
  assert.doesNotThrow(() => assertMcpAppContracts(declaration.registry));
  const tools = Object.fromEntries((await mcp.listTools()).map((tool) => [tool.name, tool]));
  assert.deepEqual(tools.usage_status._meta, { ui: { resourceUri: DASHBOARD_URI, visibility: ['model', 'app'] }, 'ui/resourceUri': DASHBOARD_URI });
  assert.equal(tools.usage_history._meta, undefined);
  // The validation is live: the same tools without the resource are refused.
  const unlinked = defineMcpFnServer({ info: { name: 'subset-usage', version: '0.0.0' }, tools: usageTools({ readStatus: async () => fixtureStatus(), readHistory: async () => fixtureHistory(), providers: [] }) });
  assert.throws(() => unlinked.manifest(), /Tool usage_status links to missing MCP App resource ui:\/\/subset-usage\/dashboard@1/);

  // A host without MCP Apps gets the SET-104 result: text and the UsageStatus, with no view data on it.
  const status = await mcp.callTool('usage_status', {});
  assert.deepEqual(Object.keys(status).sort(), ['content', 'structuredContent']);
  assert.ok(isUsageStatus(status.structuredContent));
  const history = await mcp.callTool('usage_history', {});
  assert.deepEqual(Object.keys(history).sort(), ['content', 'structuredContent']);
});

test('the built dashboard.html inlines its scripts, styles and trend chart and loads nothing (static scan)', () => {
  const html = readFileSync(DASHBOARD_HTML, 'utf8');
  assert.match(html, /^<!doctype html>/i);
  // Trend charts are on by default only while the file stays under 1.5 MB (SET-105); above it they start off.
  assert.ok(Buffer.byteLength(html) < 1.5 * 1024 * 1024, `dashboard.html is ${Buffer.byteLength(html)} bytes`);
  // Closing tags may carry spaces or attributes (`</script >`), which a browser still reads as the end.
  const blocks = [...html.matchAll(/<(script|style)\b([^>]*)>([\s\S]*?)<\/\1\b[^>]*>/gi)];
  const scripts = blocks.filter(([, tag]) => tag.toLowerCase() === 'script').map(([, , attributes, code]) => [, attributes, code]);
  assert.equal(scripts.length, 1);
  assert.equal(scripts[0][1].trim(), 'type="module"');
  const [, , code] = scripts[0];
  // The dashboard, the bridge and the ECharts line chart behind the lazy trend import are all inlined.
  assert.match(code, /ui\/initialize/);
  assert.match(code, /usage_history/);
  assert.match(code, /echarts|zrender/i);
  // No dynamic import and no Vite placeholder (an unfilled __VITE_PRELOAD__ throws when trends load).
  assert.doesNotMatch(code, /\bimport\s*\(/);
  assert.doesNotMatch(code, /__VITE_[A-Z_]+__/);
  assert.doesNotMatch(code, /\bimport\s*["'{*]|\bfrom\s*["'](?:https?:)?\/\//);
  const styles = blocks.filter(([, tag]) => tag.toLowerCase() === 'style').map(([, , , css]) => css);
  assert.ok(styles.some((css) => css.includes('--subset-font')), 'the page sets the system font stack');
  // The markup outside the inlined code (the text between the blocks, read out rather than stripped): no
  // script src, stylesheet link, or any src or href.
  let markup = '';
  let from = 0;
  for (const block of blocks) {
    markup += html.slice(from, block.index);
    from = block.index + block[0].length;
  }
  markup += html.slice(from);
  assert.doesNotMatch(markup, /<script\b[^>]*\bsrc\s*=/i);
  assert.doesNotMatch(markup, /<link\b/i);
  assert.doesNotMatch(markup, /\s(?:src|href|srcset|action|poster)\s*=/i);
  // No font files, stylesheet imports or url() other than inline data.
  for (const css of styles) assert.doesNotMatch(css, /@import|@font-face|url\(\s*['"]?(?!data:)/i);
  // Inside the code, a literal src, href or url() may only name inline data or a fragment (#id in an SVG icon).
  for (const [, target] of code.matchAll(/(?:\b(?:src|href)\s*=\s*\\?["'`]|url\(\s*\\?["'`]?)([^"'`)\s\\]*)/g)) {
    assert.match(target, /^(?:#|data:|$|\$\{)/, `the view references ${target}`);
  }
});

test('the bridge initializes, renders the usage_status result the host passes, loads history and follows the host theme', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  const [init, initialized] = host.sent;
  assert.deepEqual(init, { jsonrpc: '2.0', id: 1, method: 'ui/initialize', params: { protocolVersion: '2026-01-26', appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' }, appCapabilities: {} } });
  assert.deepEqual(initialized, { jsonrpc: '2.0', method: 'ui/notifications/initialized' });
  assert.equal(bridge.state().theme, 'dark');
  // Before the tool result: placeholders, and no Refresh to press.
  assert.match(rendered(bridge), /aria-label="Loading accounts"/);
  assert.ok(!buttonLabels(rendered(bridge)).includes('Refresh'));

  // History comes from one usage_history call once connected.
  assert.deepEqual(host.calls, [{ name: 'usage_history', arguments: { hours: 168 } }]);
  assert.deepEqual(bridge.state().history, fixtureHistory());

  const result = await passToolResult({ mcp, host });
  assert.deepEqual(bridge.state().status, result.structuredContent);
  const markup = rendered(bridge);
  for (const label of ['Main ChatGPT', 'Work Claude', 'Amp CLI', '5-hour', 'Weekly', 'The amp usage command failed.']) assert.ok(markup.includes(label), label);
  assert.ok(buttonLabels(markup).some((label) => /^Refresh/.test(label)), 'Refresh is shown');
  assert.doesNotMatch(markup, /Loading accounts/);
  // The trend for the account with history is on by default (dashboard.html is under 1.5 MB).
  assert.match(markup, /aria-label="Expand trend chart"/);

  // A message from anywhere but the host is ignored.
  host.deliver({ jsonrpc: '2.0', method: 'ui/notifications/tool-result', params: { structuredContent: createUsageStatus([]) } }, {});
  assert.deepEqual(bridge.state().status, result.structuredContent);

  host.notify('ui/notifications/host-context-changed', { theme: 'light' });
  assert.equal(bridge.state().theme, 'light');
  host.notify('ui/notifications/host-context-changed', { displayMode: 'inline' });
  assert.equal(bridge.state().theme, 'light');
  host.notify('ui/notifications/host-context-changed', { theme: 'sepia' });
  assert.equal(bridge.state().theme, null);
  // Nothing was read meanwhile: the view does not poll.
  assert.equal(host.calls.length, 1);
});

test('Refresh calls usage_status with the provider the agent asked for, then reads usage_history again', async (t) => {
  const state = {};
  const { host, bridge, mcp, timeouts } = await connectedBridge(t, { state });
  await passToolResult({ mcp, host }, { provider: 'claude-code' });
  assert.deepEqual(bridge.state().status.accounts.map((each) => each.id), ['claude_work']);

  state.status = createUsageStatus([account('claude_work', 'claude-code', { label: 'Work Claude', windows: [window(80)] })], new Date(NOW + HOUR));
  state.history = { schemaVersion: 1, series: {} };
  const refreshed = bridge.refresh();
  assert.equal(bridge.state().busy, true);
  // A second press while one runs sends nothing more.
  void bridge.refresh();
  await host.idle();
  await refreshed;
  assert.deepEqual(host.calls.slice(1), [{ name: 'usage_status', arguments: { provider: 'claude-code' } }, { name: 'usage_history', arguments: { hours: 168 } }]);
  assert.equal(bridge.state().busy, false);
  assert.equal(bridge.state().status.generatedAt, new Date(NOW + HOUR).toISOString());
  assert.equal(bridge.state().status.accounts[0].windows[0].usedPercent, 80);
  assert.deepEqual(bridge.state().history.series, {});
  // Every reply arrived, so no deadline is left running.
  assert.equal(timeouts.size(), 0);

  // An agent call without a provider refreshes every account.
  await passToolResult({ mcp, host });
  void bridge.refresh();
  await host.idle();
  assert.deepEqual(host.calls.at(-2), { name: 'usage_status', arguments: {} });
});

test('a failed Refresh keeps the dashboard and says why; a reply that never comes ends at its deadline', async (t) => {
  const { host, bridge, mcp, timeouts } = await connectedBridge(t);
  const result = await passToolResult({ mcp, host });

  // History is read again only after a status: a refused, failed or unreadable Refresh reads nothing more,
  // so a host that asks before each call does not ask again right after the user declined.
  const callsSince = (before) => host.calls.slice(before).map(({ name }) => name);
  let before = host.calls.length;
  host.refuse = () => 'The user declined.';
  await Promise.all([bridge.refresh(), host.idle()]);
  assert.equal(bridge.state().refreshError, 'The user declined.');
  assert.deepEqual(bridge.state().status, result.structuredContent);
  assert.match(rendered(bridge), /Could not refresh: The user declined\./);
  assert.deepEqual(callsSince(before), ['usage_status']);

  host.refuse = null;
  host.withhold = ({ name }) => name === 'usage_status';
  before = host.calls.length;
  const refreshed = bridge.refresh();
  await host.idle();
  assert.equal(bridge.state().busy, true);
  // usage_history's shorter deadline does not end a usage_status call; its own does.
  timeouts.advance(view.HISTORY_TIMEOUT_MS);
  await host.idle();
  assert.equal(bridge.state().busy, true);
  timeouts.advance(view.STATUS_TIMEOUT_MS - view.HISTORY_TIMEOUT_MS);
  await refreshed;
  assert.equal(bridge.state().busy, false);
  assert.equal(bridge.state().refreshError, view.STATUS_LATE);
  assert.match(rendered(bridge), /Could not refresh: The host has not replied to usage_status yet/);
  // Refresh and R work again at the deadline, though the first call never replies.
  assert.equal(host.press('r'), true);
  assert.equal(bridge.state().busy, true);
  timeouts.advance(view.STATUS_TIMEOUT_MS);
  await host.idle();
  assert.deepEqual([bridge.state().busy, bridge.state().refreshError], [false, view.STATUS_LATE]);
  assert.equal(host.callIds('usage_status').length, 3);
  assert.deepEqual(callsSince(before), ['usage_status', 'usage_status']);

  // A tool result the host passes while a Refresh is out is newer: the late reply does not replace it.
  const late = bridge.refresh();
  await host.idle();
  const pendingId = host.sent.findLast((message) => message.method === 'tools/call').id;
  const newer = await passToolResult({ mcp, host });
  host.withhold = null;
  host.deliver({ jsonrpc: '2.0', id: pendingId, result: { structuredContent: createUsageStatus([]), content: [] } });
  await Promise.all([late, host.idle()]);
  assert.deepEqual(bridge.state().status, newer.structuredContent);
  assert.equal(bridge.state().refreshError, null);

  // A malformed error envelope from the host gets the plain message, never a TypeError from reading it.
  host.withhold = ({ name }) => name === 'usage_status';
  const replyTo = async (body) => {
    const pressed = bridge.refresh();
    await host.idle();
    host.deliver({ jsonrpc: '2.0', id: host.callIds('usage_status').at(-1), ...body });
    await Promise.all([pressed, host.idle()]);
  };
  before = host.calls.length;
  for (const content of [{}, [null], 'text']) {
    await replyTo({ result: { isError: true, content, structuredContent: { error: 'down' } } });
    assert.equal(bridge.state().refreshError, 'The usage tool failed.', JSON.stringify(content));
    assert.deepEqual(bridge.state().status, newer.structuredContent);
  }
  // A result that is not a usage status, or no result at all, is shown as a failure too.
  await replyTo({ result: { content: [], structuredContent: { schemaVersion: 1, accounts: 'none' } } });
  assert.match(bridge.state().refreshError, /not a usage status/);
  await replyTo({ result: 'none' });
  assert.equal(bridge.state().refreshError, 'The host returned no tool result.');
  assert.deepEqual(bridge.state().status, newer.structuredContent);
  assert.deepEqual(callsSince(before), Array(5).fill('usage_status'));
});

/** A status read late: one account read and one that timed out, which the view shows side by side. */
const slowStatus = (used) => createUsageStatus([
  account('chatgpt_main', 'codex-chatgpt', { label: 'Main ChatGPT', windows: [window(used)] }),
  account('amp_cli', 'amp', { label: 'Amp CLI', state: 'unavailable', windows: [], observedAt: null, errors: [{ code: 'amp_timeout', message: 'The amp usage command timed out.' }] }),
], new Date(NOW));
const toolResult = (status) => ({ content: [{ type: 'text', text: 'Usage' }], structuredContent: status });

test('the usage_status deadline ends the busy state, not the call: a valid status that arrives later is shown', async (t) => {
  const { host, bridge, mcp, timeouts } = await connectedBridge(t);
  await passToolResult({ mcp, host });
  host.withhold = ({ name }) => name === 'usage_status';
  // The server's read has no overall bound (a custom Claude config directory alone may wait for four 60 s
  // Keychain prompts), so replies at 241 s and 400 s, well past the deadline, must still show.
  for (const [ms, used] of [[241_000, 40], [400_000, 55]]) {
    const refreshed = bridge.refresh();
    await host.idle();
    timeouts.advance(21_000);
    await host.idle();
    assert.deepEqual([bridge.state().busy, bridge.state().refreshError], [true, null], `${ms} ms`);
    timeouts.advance(view.STATUS_TIMEOUT_MS - 21_000);
    await refreshed;
    assert.deepEqual([bridge.state().busy, bridge.state().refreshError], [false, view.STATUS_LATE], `${ms} ms`);
    timeouts.advance(ms - view.STATUS_TIMEOUT_MS);
    const historyReads = host.callIds('usage_history').length;
    host.answerLast(toolResult(slowStatus(used)));
    await host.idle();
    assert.deepEqual([bridge.state().status, bridge.state().refreshError, bridge.state().busy], [slowStatus(used), null, false], `${ms} ms`);
    // A late status reads history again, as a timely one does.
    assert.equal(host.callIds('usage_history').length, historyReads + 1);
    const markup = rendered(bridge);
    for (const text of ['Main ChatGPT', 'Amp CLI', 'The amp usage command timed out.']) assert.ok(markup.includes(text), text);
    assert.doesNotMatch(markup, /Could not refresh/);
  }
});

test('late replies show in the order their calls began; teardown ends calls past their deadline', async (t) => {
  const { host, bridge, mcp, timeouts } = await connectedBridge(t);
  await passToolResult({ mcp, host });
  host.withhold = ({ name }) => name === 'usage_status';
  /** Presses Refresh and lets its call pass the deadline unanswered; returns the call's id. */
  const expiredRefresh = async () => {
    const refreshed = bridge.refresh();
    await host.idle();
    timeouts.advance(view.STATUS_TIMEOUT_MS);
    await refreshed;
    return host.callIds('usage_status').at(-1);
  };

  // An earlier Refresh's reply after a later one's was shown is dropped.
  const first = await expiredRefresh();
  void bridge.refresh();
  await host.idle();
  const second = host.callIds('usage_status').at(-1);
  host.answer(second, toolResult(slowStatus(10)));
  await host.idle();
  host.answer(first, toolResult(slowStatus(90)));
  await host.idle();
  assert.deepEqual(bridge.state().status, slowStatus(10));
  // An earlier Refresh's failure says nothing about the later one still running, nor about what it shows.
  const third = await expiredRefresh();
  void bridge.refresh();
  await host.idle();
  host.deliver({ jsonrpc: '2.0', id: third, error: { code: -32000, message: 'Too late.' } });
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().refreshError, bridge.state().busy], [slowStatus(10), view.STATUS_LATE, true]);
  host.answer(host.callIds('usage_status').at(-1), toolResult(slowStatus(11)));
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().refreshError, bridge.state().busy], [slowStatus(11), null, false]);

  // An earlier Refresh's reply before the later one's is shown, then replaced; the later one stays busy meanwhile.
  const fourth = await expiredRefresh();
  void bridge.refresh();
  await host.idle();
  const fifth = host.callIds('usage_status').at(-1);
  host.answer(fourth, toolResult(slowStatus(20)));
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().busy, bridge.state().refreshError], [slowStatus(20), true, null]);
  host.answer(fifth, toolResult(slowStatus(30)));
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().busy], [slowStatus(30), false]);

  // A tool result the host passes after the call began is newer: the late reply is dropped.
  const sixth = await expiredRefresh();
  const newer = await passToolResult({ mcp, host });
  assert.equal(bridge.state().refreshError, null);
  host.answer(sixth, toolResult(slowStatus(40)));
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().refreshError], [newer.structuredContent, null]);

  // Teardown ends every open call, past its deadline or not; a reply after it is not read.
  const seventh = await expiredRefresh();
  host.deliver({ jsonrpc: '2.0', id: 'teardown-1', method: 'ui/resource-teardown', params: {} });
  const sent = host.sent.length;
  host.answer(seventh, toolResult(slowStatus(50)));
  await host.idle();
  assert.deepEqual([bridge.state().status, bridge.state().closed, bridge.state().busy], [newer.structuredContent, true, false]);
  assert.equal(host.sent.length, sent);
  assert.equal(timeouts.size(), 0);
});

test('usage_history follows the same rule: its deadline ends the wait, a later reply is shown unless a newer read was', async (t) => {
  const session = await mcpSession(t);
  const host = fakeHost(session.mcp);
  const timeouts = fakeTimeouts();
  const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' }, ...timeouts });
  t.after(() => bridge.close());
  host.withhold = ({ name }) => name === 'usage_history';
  const connected = bridge.connect();
  await host.idle();
  timeouts.advance(view.HISTORY_TIMEOUT_MS);
  await connected;
  assert.equal(bridge.state().history, undefined);
  const history = (points) => ({ schemaVersion: 1, series: { chatgpt_main: { 'five_hour\u00005-hour': points } } });
  host.answer(host.callIds('usage_history')[0], { content: [], structuredContent: history([[NOW - HOUR, 5]]) });
  await host.idle();
  assert.deepEqual(bridge.state().history, history([[NOW - HOUR, 5]]));

  // Two Refreshes, each reading history; the later read's reply comes first, so the earlier one's is dropped.
  await passToolResult({ mcp: session.mcp, host });
  for (let i = 0; i < 2; i += 1) {
    const refreshed = bridge.refresh();
    await host.idle();
    timeouts.advance(view.HISTORY_TIMEOUT_MS);
    await refreshed;
  }
  const [, earlier, later] = host.callIds('usage_history');
  host.answer(later, { content: [], structuredContent: history([[NOW - HOUR, 30]]) });
  await host.idle();
  host.answer(earlier, { content: [], structuredContent: history([[NOW - HOUR, 20]]) });
  await host.idle();
  assert.deepEqual(bridge.state().history, history([[NOW - HOUR, 30]]));
});

test('ui/initialize has a deadline: a withheld or refused answer shows a failure with a Refresh that asks again', async (t) => {
  const session = await mcpSession(t);
  const start = (initialize) => {
    const host = fakeHost(session.mcp);
    host.initialize = initialize;
    const timeouts = fakeTimeouts();
    const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' }, ...timeouts });
    t.after(() => bridge.close());
    return { host, timeouts, bridge, connected: bridge.connect() };
  };
  const initializeIds = (host) => host.sent.filter(({ method }) => method === 'ui/initialize').map(({ id }) => id);
  const initializedSent = (host) => host.sent.filter(({ method }) => method === 'ui/notifications/initialized').length;

  // Withheld: at the deadline the view stops loading and says so, with the disclosure and a Refresh.
  const withheld = start('withhold');
  await withheld.host.idle();
  withheld.timeouts.advance(view.CONNECT_TIMEOUT_MS - 1);
  assert.match(rendered(withheld.bridge), /aria-label="Loading accounts"/);
  withheld.timeouts.advance(1);
  await withheld.connected;
  assert.deepEqual([withheld.bridge.state().connectError, withheld.bridge.state().busy], [view.CONNECT_LATE, false]);
  let markup = rendered(withheld.bridge);
  assert.ok(textOf(markup).includes(view.CONNECT_LATE));
  assert.doesNotMatch(markup, /Loading accounts/);
  assert.deepEqual(buttonLabels(markup), ['Refresh']);
  assertDisclosure(markup);
  assert.deepEqual([initializedSent(withheld.host), withheld.host.calls], [0, []]);
  // Refresh (or R) sends ui/initialize again, busy while it waits.
  assert.equal(withheld.host.press('r'), true);
  assert.equal(withheld.bridge.state().busy, true);
  await withheld.host.idle();
  const [first, second] = initializeIds(withheld.host);
  assert.ok(second > first);
  // The first answer, late, still connects: initialized once, history read, the failure gone.
  withheld.host.deliver({ jsonrpc: '2.0', id: first, result: initializeResult('light') });
  await withheld.host.idle();
  assert.deepEqual([withheld.bridge.state().connectError, withheld.bridge.state().busy, withheld.bridge.state().theme], [null, false, 'light']);
  assert.deepEqual(withheld.bridge.state().history, fixtureHistory());
  // The second answer, and the second deadline, change nothing.
  withheld.host.deliver({ jsonrpc: '2.0', id: second, result: initializeResult('dark') });
  withheld.timeouts.advance(view.CONNECT_TIMEOUT_MS);
  await withheld.host.idle();
  assert.deepEqual([initializedSent(withheld.host), withheld.bridge.state().connectError, withheld.bridge.state().theme], [1, null, 'light']);
  assert.deepEqual(withheld.host.calls.map(({ name }) => name), ['usage_history']);
  await passToolResult({ mcp: session.mcp, host: withheld.host });
  assert.ok(rendered(withheld.bridge).includes('Main ChatGPT'));

  // Refused: the host's message shows; Refresh asks again, and an answer connects.
  const refused = start('refuse');
  await refused.host.idle();
  await refused.connected;
  assert.equal(refused.bridge.state().connectError, 'The host did not connect the usage view: Not now.');
  assert.match(rendered(refused.bridge), /role="alert">The host did not connect the usage view: Not now\./);
  refused.host.initialize = 'answer';
  await Promise.all([refused.bridge.refresh(), refused.host.idle()]);
  assert.deepEqual([refused.bridge.state().connectError, refused.bridge.state().busy, initializedSent(refused.host)], [null, false, 1]);
  assert.deepEqual(refused.host.calls.map(({ name }) => name), ['usage_history']);
  assert.equal(refused.timeouts.size(), 0);

  // An older ui/initialize's refusal after a newer one was sent does not show while the newer one waits.
  const raced = start('withhold');
  await raced.host.idle();
  raced.timeouts.advance(view.CONNECT_TIMEOUT_MS);
  await raced.connected;
  void raced.bridge.refresh();
  await raced.host.idle();
  raced.host.deliver({ jsonrpc: '2.0', id: initializeIds(raced.host)[0], error: { code: -32000, message: 'Too late.' } });
  await raced.host.idle();
  assert.deepEqual([raced.bridge.state().connectError, raced.bridge.state().busy], [view.CONNECT_LATE, true]);

  // Teardown while ui/initialize waits ends it: a later answer is not read and nothing more is sent.
  const tornDown = start('withhold');
  await tornDown.host.idle();
  tornDown.host.deliver({ jsonrpc: '2.0', id: 'teardown-1', method: 'ui/resource-teardown', params: {} });
  await tornDown.connected;
  const sent = tornDown.host.sent.length;
  tornDown.host.deliver({ jsonrpc: '2.0', id: initializeIds(tornDown.host)[0], result: initializeResult('dark') });
  tornDown.timeouts.advance(view.CONNECT_TIMEOUT_MS);
  await tornDown.host.idle();
  assert.deepEqual([tornDown.bridge.state().closed, tornDown.bridge.state().connectError, tornDown.host.sent.length, tornDown.timeouts.size()], [true, null, sent, 0]);
});

test('the R key the Refresh button advertises refreshes, only while Refresh is shown and never with a modifier or in a field', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  const statusCalls = () => host.calls.filter(({ name }) => name === 'usage_status').length;
  // Before the tool result there is no Refresh, so R does nothing.
  assert.equal(host.press('r'), false);
  await passToolResult({ mcp, host });
  assert.match(rendered(bridge), /<button[^>]*aria-keyshortcuts="r"/);
  for (const [key, options] of [['r', { metaKey: true }], ['r', { ctrlKey: true }], ['r', { altKey: true }], ['r', { inField: true }], ['x', {}]]) {
    assert.equal(host.press(key, options), false, `${key} ${JSON.stringify(options)}`);
  }
  await host.idle();
  assert.equal(statusCalls(), 0);

  assert.equal(host.press('r'), true);
  await host.idle();
  assert.deepEqual(host.calls.slice(-2).map(({ name }) => name), ['usage_status', 'usage_history']);
  assert.equal(statusCalls(), 1);
  // Teardown removes the key listener with the message listener.
  host.deliver({ jsonrpc: '2.0', id: 'teardown-1', method: 'ui/resource-teardown', params: {} });
  assert.equal(host.press('r'), false);
  assert.equal(statusCalls(), 1);
});

test('an error shows with a Refresh that reads usage_status again: success shows the dashboard, a failure keeps the error', async (t) => {
  const { host, bridge } = await connectedBridge(t);
  host.notify('ui/notifications/tool-input', { arguments: { provider: 'amp' } });
  host.notify('ui/notifications/tool-cancelled', {});
  let markup = rendered(bridge);
  assert.match(markup, /role="alert">The usage_status call was cancelled\./);
  assert.deepEqual(buttonLabels(markup), ['Refresh']);
  assert.match(markup, /<button[^>]*aria-keyshortcuts="r"[^>]*>Refresh<\/button>/);

  host.refuse = () => 'The user declined.';
  const before = host.calls.length;
  const failed = bridge.refresh();
  assert.match(rendered(bridge), /<button[^>]*disabled[^>]*>Checking<\/button>/);
  await Promise.all([failed, host.idle()]);
  assert.deepEqual([bridge.state().status, bridge.state().toolError, bridge.state().refreshError], [null, 'The usage_status call was cancelled.', 'The user declined.']);
  // A declined Refresh reads no history.
  assert.deepEqual(host.calls.slice(before).map(({ name }) => name), ['usage_status']);
  markup = rendered(bridge);
  assert.match(markup, /role="alert">The usage_status call was cancelled\./);
  assert.match(markup, /Could not refresh: The user declined\./);
  assert.match(markup, /<button(?![^>]*disabled)[^>]*>Refresh<\/button>/);

  host.refuse = null;
  assert.equal(host.press('r'), true);
  await host.idle();
  assert.deepEqual(host.calls.slice(-2), [{ name: 'usage_status', arguments: { provider: 'amp' } }, { name: 'usage_history', arguments: { hours: 168 } }]);
  assert.deepEqual([bridge.state().toolError, bridge.state().refreshError], [null, null]);
  assert.deepEqual(bridge.state().status.accounts.map(({ id }) => id), ['amp_cli']);
  markup = rendered(bridge);
  assert.ok(markup.includes('Amp CLI'));
  assert.doesNotMatch(markup, /role="alert"|Could not refresh/);
});

test('an error or unreadable tool result shows in place of the dashboard until a later result succeeds', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  host.notify('ui/notifications/tool-result', { isError: true, content: [{ type: 'text', text: 'usage_unavailable: Could not read the usage configuration.' }], structuredContent: { error: { code: 'usage_unavailable', message: 'Could not read the usage configuration.' } } });
  assert.equal(bridge.state().toolError, 'Could not read the usage configuration.');
  assert.match(rendered(bridge), /role="alert">Could not read the usage configuration\./);

  // A malformed error envelope still shows an error, with the text blocks it can read.
  for (const [content, message] of [[{}, 'The usage tool failed.'], [[null], 'The usage tool failed.'], [[null, 7, { type: 'text', text: 'Down.' }, { type: 'text', text: 3 }], 'Down.']]) {
    host.notify('ui/notifications/tool-result', { isError: true, content, structuredContent: [] });
    assert.deepEqual([bridge.state().status, bridge.state().toolError], [null, message], JSON.stringify(content));
  }

  host.notify('ui/notifications/tool-result', { content: [], structuredContent: { schemaVersion: 1, accounts: 'none' } });
  assert.equal(bridge.state().status, null);
  assert.match(bridge.state().toolError, /not a usage status/);

  await passToolResult({ mcp, host });
  assert.equal(bridge.state().toolError, null);
  assert.ok(rendered(bridge).includes('Main ChatGPT'));

  // A cancelled call shows only when there is no status to keep.
  host.notify('ui/notifications/tool-cancelled', {});
  assert.equal(bridge.state().toolError, null);
});

test('the view renders no write control: the page passes the dashboard none of its write props', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  await passToolResult({ mcp, host });
  const markup = rendered(bridge);
  assert.deepEqual(writeControls(markup), []);
  // The local sign-ins disclosure shows with the accounts, without any control for the setting.
  assertDisclosure(markup);
  assert.ok(!buttonLabels(markup).some((label) => /sign-in/i.test(label)), 'no local sign-ins control');
  // The check finds the write controls when the dashboard is given its write props.
  const status = fixtureStatus();
  const write = view.render(view.UsageDashboard, { props: { status, manageAccounts() {}, openAccount() {}, togglePin() {}, redeemReset: async () => '' } }).body;
  assert.deepEqual(writeControls(write).sort(), ['Fix', 'Manage accounts', 'Options for Amp CLI', 'Options for Main ChatGPT', 'Options for Work Claude']);

  // Redeeming a reset shows only in a dialog the user opens, so the props the page passes are checked too.
  globalThis.dashboardProps = [];
  // Rendering runs when the body is read.
  void stubbed.render(stubbed.McpApp, { props: { bridge } }).body;
  const [props] = globalThis.dashboardProps;
  for (const name of ['redeemReset', 'manageAccounts', 'openAccount', 'togglePin', 'toolbar', 'emptyAction', 'accountHint']) assert.equal(props[name], undefined, name);
  assert.deepEqual([props.sortMode, props.showTrends, props.percentMode], ['default', true, undefined]);
  // The dashboard's Refresh button runs the handler the page passes it: usage_status, then usage_history.
  const before = host.calls.length;
  props.refresh();
  await host.idle();
  assert.deepEqual(host.calls.slice(before).map(({ name }) => name), ['usage_status', 'usage_history']);
});

test('ui/resource-teardown ends the view: it answers, stops listening and sends nothing more', async (t) => {
  const { host, bridge, mcp } = await connectedBridge(t);
  await passToolResult({ mcp, host });
  host.deliver({ jsonrpc: '2.0', id: 'ping-1', method: 'ping' });
  host.deliver({ jsonrpc: '2.0', id: 'teardown-1', method: 'ui/resource-teardown', params: {} });
  await host.idle();
  assert.deepEqual(host.sent.slice(-2), [{ jsonrpc: '2.0', id: 'ping-1', result: {} }, { jsonrpc: '2.0', id: 'teardown-1', result: {} }]);
  assert.equal(bridge.state().closed, true);
  assert.equal(host.listening(), 0);
  const sent = host.sent.length;
  await bridge.refresh();
  bridge.sizeChanged(400, 300);
  assert.equal(host.sent.length, sent);
});

test('the view reports its size to the host once connected, and only when it changes', async (t) => {
  const session = await mcpSession(t);
  const host = fakeHost(session.mcp);
  const bridge = view.createBridge({ host: host.window, view: host.view, appInfo: { name: 'subset-usage-dashboard', version: '1.0.0' } });
  t.after(() => bridge.close());
  bridge.sizeChanged(600, 400);
  assert.equal(host.sent.filter((message) => message.method === 'ui/notifications/size-changed').length, 0);
  const connected = bridge.connect();
  await host.idle();
  await connected;
  bridge.sizeChanged(600, 400);
  bridge.sizeChanged(600, 520);
  assert.deepEqual(host.sent.filter((message) => message.method === 'ui/notifications/size-changed').map((message) => message.params), [{ width: 600, height: 400 }, { width: 600, height: 520 }]);
});
