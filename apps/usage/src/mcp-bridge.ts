// The Usage MCP App bridge (SET-105): JSON-RPC 2.0 over postMessage between the dashboard in the host's
// iframe and the host, as the MCP Apps extension (io.modelcontextprotocol/ui, 2026-01-26) defines it,
// following the bridge Timer chose in SET-80 (no `@modelcontextprotocol/ext-apps`; see the README). It
// sends `ui/initialize`, reads the theme from the host context, takes the `usage_status` result the host
// passes as the dashboard's `status`, reads `usage_history` once connected, and calls `usage_status`
// again only when the user presses Refresh: there is no polling. Every tool call has a deadline, so a
// reply the host never sends cannot leave Refresh busy. It touches no DOM, so it runs under `node --test`
// with a fake host.
import { isUsageStatus, type UsageStatus } from '@subset.dev/usage-core';
import { isUsageHistory, type UsageHistory } from '@subset.dev/usage-core/history';

export const PROTOCOL_VERSION = '2026-01-26';
/** How long a tool call waits for the host's reply. */
export const READ_TIMEOUT_MS = 15_000;
/** The hours of history read: the dashboard's 7-day activity and trend ranges (usage_history's maximum). */
export const HISTORY_HOURS = 168;

export type Theme = 'light' | 'dark';

/** What the view shows; a new object on every change. */
export interface BridgeState {
  /** The dashboard's `status`: the tool result's `structuredContent`, then each Refresh. */
  status: UsageStatus | null;
  /** The dashboard's `history`, from usage_history; undefined until a read succeeds. */
  history: UsageHistory | undefined;
  /** The tool result the host passed was an error, or the call was cancelled before any status. */
  toolError: string | null;
  /** The latest Refresh failed; the dashboard keeps the last status. */
  refreshError: string | null;
  /** A Refresh is running. */
  busy: boolean;
  /** The host's theme; null follows `prefers-color-scheme`. */
  theme: Theme | null;
  /** The host tore the view down: nothing more is sent or read. */
  closed: boolean;
}

/** The window the view runs in, as far as the bridge needs it. */
export interface ViewWindow {
  addEventListener(type: 'message', listener: (event: { source: unknown; data: unknown }) => void): void;
  removeEventListener(type: 'message', listener: (event: { source: unknown; data: unknown }) => void): void;
}

/** The host's window: `window.parent`. */
export interface HostWindow {
  postMessage(message: unknown, targetOrigin: string): void;
}

export interface BridgeOptions {
  host: HostWindow;
  view: ViewWindow;
  appInfo: { name: string; version: string };
  setTimeout?: (callback: () => void, ms: number) => unknown;
  clearTimeout?: (handle: unknown) => void;
}

export interface Bridge {
  state(): BridgeState;
  /** Calls `listener` after every change; returns a function that removes it. */
  subscribe(listener: (state: BridgeState) => void): () => void;
  /** Sends `ui/initialize` and `ui/notifications/initialized`, then reads usage_history. */
  connect(): Promise<void>;
  /** Calls usage_status, with the provider the agent's call named, then reads usage_history again. */
  refresh(): Promise<void>;
  /** Tells the host the view's size, once connected and only when it changed. */
  sizeChanged(width: number, height: number): void;
  close(): void;
}

interface CallToolResult {
  content?: { type: string; text?: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
}

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);

const UNREADABLE = 'The usage_status result is not a usage status this view can show.';

/** A tool error's message: `structuredContent.error.message`, else its text blocks; the host's payload is unchecked. */
function failure(result: CallToolResult): string {
  const structured: unknown = result.structuredContent;
  const error = isObject(structured) ? structured.error : undefined;
  if (isObject(error) && typeof error.message === 'string') return error.message;
  const content: unknown = result.content;
  const blocks = Array.isArray(content) ? content : [];
  const text = blocks.map((block) => (isObject(block) && block.type === 'text' && typeof block.text === 'string' ? block.text : '')).join(' ').trim();
  return text || 'The usage tool failed.';
}

/** The status a usage_status result carries, or the message to show in its place. */
function statusOf(result: CallToolResult): { status: UsageStatus } | { error: string } {
  if (result.isError) return { error: failure(result) };
  return isUsageStatus(result.structuredContent) ? { status: result.structuredContent } : { error: UNREADABLE };
}

/** Connects the view to its host. Call `connect()` once the view listens to `subscribe`. */
export function createBridge({
  host,
  view,
  appInfo,
  setTimeout: after = globalThis.setTimeout,
  clearTimeout: cancel = globalThis.clearTimeout as (handle: unknown) => void
}: BridgeOptions): Bridge {
  let current: BridgeState = { status: null, history: undefined, toolError: null, refreshError: null, busy: false, theme: null, closed: false };
  const listeners = new Set<(state: BridgeState) => void>();
  const update = (change: Partial<BridgeState>) => {
    current = { ...current, ...change };
    for (const listener of listeners) listener(current);
  };

  let nextId = 0;
  const pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void; deadline: unknown }>();
  let ready = false;
  // The provider the agent's usage_status call named, so Refresh shows the same accounts.
  let provider: string | undefined;
  // Bumped by each tool result the host passes, so a Refresh issued before it cannot replace it.
  let generation = 0;
  let historyRead = 0;
  let size: { width: number; height: number } | null = null;
  let sentSize: string | null = null;

  const send = (message: Record<string, unknown>) => host.postMessage({ jsonrpc: '2.0', ...message }, '*');

  /** Sends a request and waits for its reply; with `timeoutMs`, no reply by then rejects and is forgotten. */
  function request(method: string, params: Record<string, unknown>, timeout?: { ms: number; message: string }): Promise<unknown> {
    if (current.closed) return Promise.reject(new Error('The host closed the usage view.'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const deadline = timeout
        ? after(() => {
            if (pending.delete(id)) reject(new Error(timeout.message));
          }, timeout.ms)
        : null;
      pending.set(id, { resolve, reject, deadline });
      send({ id, method, params });
    });
  }

  async function callTool(name: string, args: Record<string, unknown>): Promise<CallToolResult> {
    const result = await request('tools/call', { name, arguments: args }, { ms: READ_TIMEOUT_MS, message: `The host did not reply to ${name}.` });
    if (!isObject(result)) throw new Error('The host returned no tool result.');
    return result as CallToolResult;
  }

  /** Reads usage_history; trends are optional, so a failure keeps the history already shown. */
  async function loadHistory() {
    const read = ++historyRead;
    try {
      const result = await callTool('usage_history', { hours: HISTORY_HOURS });
      if (read !== historyRead || current.closed || result.isError || !isUsageHistory(result.structuredContent)) return;
      const { schemaVersion, series } = result.structuredContent;
      update({ history: { schemaVersion, series } });
    } catch {
      // No history leaves the trends empty, as in the standalone dashboard.
    }
  }

  async function refresh() {
    if (current.busy || current.closed || !ready) return;
    const issued = generation;
    update({ busy: true });
    try {
      const result = statusOf(await callTool('usage_status', provider === undefined ? {} : { provider }));
      // A tool result the host passed meanwhile is newer than this read.
      if (current.closed || issued !== generation) return;
      if ('status' in result) update({ status: result.status, toolError: null, refreshError: null });
      else update({ refreshError: result.error });
    } catch (error) {
      if (!current.closed && issued === generation) update({ refreshError: error instanceof Error ? error.message : String(error) });
    } finally {
      if (!current.closed) update({ busy: false });
    }
    await loadHistory();
  }

  function readHostContext(context: unknown) {
    if (!isObject(context) || !('theme' in context)) return;
    update({ theme: context.theme === 'light' || context.theme === 'dark' ? context.theme : null });
  }

  /** The usage_status result the host passed: the dashboard's `status`, or the error shown in its place. */
  function takeToolResult(params: unknown) {
    if (!isObject(params)) return;
    generation += 1;
    const result = statusOf(params as CallToolResult);
    if ('status' in result) update({ status: result.status, toolError: null, refreshError: null });
    else update({ status: null, toolError: result.error, refreshError: null });
  }

  function takeToolInput(params: unknown) {
    const args = isObject(params) ? params.arguments : undefined;
    provider = isObject(args) && typeof args.provider === 'string' ? args.provider : undefined;
  }

  function onRequest(id: unknown, method: string) {
    if (method === 'ping') return send({ id, result: {} });
    if (method === 'ui/resource-teardown') {
      send({ id, result: {} });
      return close();
    }
    send({ id, error: { code: -32601, message: `Method not found: ${method}` } });
  }

  function onNotification(method: string, params: unknown) {
    if (method === 'ui/notifications/tool-result') takeToolResult(params);
    else if (method === 'ui/notifications/tool-input') takeToolInput(params);
    else if (method === 'ui/notifications/host-context-changed') readHostContext(params);
    else if (method === 'ui/notifications/tool-cancelled' && !current.status) update({ toolError: 'The usage_status call was cancelled.' });
  }

  function onResponse(message: Record<string, unknown>) {
    const waiting = typeof message.id === 'number' ? pending.get(message.id) : undefined;
    if (!waiting) return;
    pending.delete(message.id as number);
    if (waiting.deadline !== null) cancel(waiting.deadline);
    if ('error' in message) {
      const error = message.error;
      waiting.reject(new Error(isObject(error) && typeof error.message === 'string' ? error.message : 'The host refused the request.'));
    } else {
      waiting.resolve(message.result);
    }
  }

  const listener = (event: { source: unknown; data: unknown }) => {
    // Only the host's own messages count; anything else in the page, or not JSON-RPC, is ignored.
    if (event.source !== host || current.closed) return;
    const message = event.data;
    if (!isObject(message) || message.jsonrpc !== '2.0') return;
    if (typeof message.method === 'string') {
      if ('id' in message) onRequest(message.id, message.method);
      else onNotification(message.method, message.params);
    } else if ('id' in message) {
      onResponse(message);
    }
  };
  view.addEventListener('message', listener);

  function sendSize() {
    if (!ready || !size || current.closed) return;
    const key = `${size.width}x${size.height}`;
    if (key === sentSize) return;
    sentSize = key;
    send({ method: 'ui/notifications/size-changed', params: size });
  }

  function close() {
    if (current.closed) return;
    view.removeEventListener('message', listener);
    update({ closed: true, busy: false });
    for (const waiting of pending.values()) {
      if (waiting.deadline !== null) cancel(waiting.deadline);
      waiting.reject(new Error('The host closed the usage view.'));
    }
    pending.clear();
  }

  return {
    state: () => current,
    subscribe(next) {
      listeners.add(next);
      return () => listeners.delete(next);
    },
    async connect() {
      const result = await request('ui/initialize', { protocolVersion: PROTOCOL_VERSION, appInfo, appCapabilities: {} });
      if (current.closed) return;
      if (isObject(result)) readHostContext(result.hostContext);
      send({ method: 'ui/notifications/initialized' });
      ready = true;
      sendSize();
      await loadHistory();
    },
    refresh,
    sizeChanged(width, height) {
      size = { width, height };
      sendSize();
    },
    close
  };
}
