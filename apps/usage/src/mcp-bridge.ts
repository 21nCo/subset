// The Usage MCP App bridge (SET-105): JSON-RPC 2.0 over postMessage between the dashboard in the host's
// iframe and the host, as the MCP Apps extension (io.modelcontextprotocol/ui, 2026-01-26) defines it,
// following the bridge Timer chose in SET-80 (no `@modelcontextprotocol/ext-apps`; see the README). It
// sends `ui/initialize`, reads the theme from the host context, takes the `usage_status` result the host
// passes as the dashboard's `status`, reads `usage_history` once connected, and calls `usage_status`
// again only when the user presses Refresh or R: there is no polling. Every tool call has a deadline, so a
// reply the host never sends cannot leave Refresh busy, but a reply that comes later is still taken. It
// touches no DOM beyond the events it is given, so it runs under `node --test` with a fake host.
import { isUsageStatus, type UsageStatus } from '@subset.dev/usage-core';
import { isUsageHistory, type UsageHistory } from '@subset.dev/usage-core/history';

export const PROTOCOL_VERSION = '2026-01-26';
/**
 * How long Refresh stays busy waiting for usage_status. The deadline bounds the busy state, not the
 * server: at it, Refresh can be pressed again and a notice says the reply has not come, but the call stays
 * open and a valid status that arrives later is still shown (unless something newer was shown first).
 * The server's read has no overall bound. It reads every account at once and waits for the slowest, and
 * some paths are open-ended: a custom Claude config directory tries two spellings with two Keychain
 * lookups each (up to 60 s per prompt) before its credentials file; harnesses signed in to the same
 * account are read one after another as fallbacks, for as many profiles as are configured (up to 20); and
 * the host may hold the call for its own approval prompt. Three minutes covers a common slow read (a
 * Claude Code account with a Keychain prompt and four fallbacks, about 150 s), so Refresh does not invite a
 * second read, with a second Keychain prompt, while the first is still running.
 */
export const STATUS_TIMEOUT_MS = 180_000;
/** How long a usage_history read keeps the view waiting (the server reads one local file); a later reply is still taken. */
export const HISTORY_TIMEOUT_MS = 15_000;
/** The notice when usage_status has not replied by its deadline. */
export const STATUS_LATE = 'The host has not replied to usage_status yet; the status shows here when it does.';
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
  /** The latest Refresh failed or has not replied by its deadline; the dashboard keeps the last status. */
  refreshError: string | null;
  /** A Refresh is running. */
  busy: boolean;
  /** The host's theme; null follows `prefers-color-scheme`. */
  theme: Theme | null;
  /** The host tore the view down: nothing more is sent or read. */
  closed: boolean;
}

export interface MessageEventLike { source: unknown; data: unknown }
export interface KeyEventLike { key: string; metaKey: boolean; ctrlKey: boolean; altKey: boolean; target: unknown; preventDefault(): void }

/** The window the view runs in, as far as the bridge needs it: the host's messages and the user's key presses. */
export interface ViewWindow {
  addEventListener(type: 'message', listener: (event: MessageEventLike) => void): void;
  addEventListener(type: 'keydown', listener: (event: KeyEventLike) => void): void;
  removeEventListener(type: 'message', listener: (event: MessageEventLike) => void): void;
  removeEventListener(type: 'keydown', listener: (event: KeyEventLike) => void): void;
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
  /**
   * Calls usage_status, with the provider the agent's call named, then reads usage_history again. The
   * view's R key does the same once a status or tool error is shown, as the dashboard's Refresh advertises.
   * Settles once the reply is shown and history read, or at the deadline; a later reply is still shown.
   */
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
  // Every status source is numbered when it starts: a tool result the host passes when it arrives, a
  // Refresh when it is pressed. A reply is shown only if nothing numbered later has been shown, so a late
  // reply never replaces a newer status, and an earlier Refresh's reply never replaces a later one's.
  let statusOrder = 0;
  let statusShown = 0;
  let latestRefresh = 0;
  // The same order for usage_history reads.
  let historyOrder = 0;
  let historyShown = 0;
  let size: { width: number; height: number } | null = null;
  let sentSize: string | null = null;

  const send = (message: Record<string, unknown>) => host.postMessage({ jsonrpc: '2.0', ...message }, '*');

  /**
   * Sends a request; the promise settles with the host's reply whenever it comes. With `timeout`, `expired`
   * runs if no reply came by then, and the request stays open: only its reply or teardown ends it.
   */
  function request(method: string, params: Record<string, unknown>, timeout?: { ms: number; expired(): void }): Promise<unknown> {
    if (current.closed) return Promise.reject(new Error('The host closed the usage view.'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const entry = { resolve, reject, deadline: null as unknown };
      if (timeout) {
        entry.deadline = after(() => {
          entry.deadline = null;
          if (pending.has(id)) timeout.expired();
        }, timeout.ms);
      }
      pending.set(id, entry);
      send({ id, method, params });
    });
  }

  async function callTool(name: string, args: Record<string, unknown>, timeout: { ms: number; expired(): void }): Promise<CallToolResult> {
    const result = await request('tools/call', { name, arguments: args }, timeout);
    if (!isObject(result)) throw new Error('The host returned no tool result.');
    return result as CallToolResult;
  }

  /**
   * Reads usage_history; trends are optional, so a failure keeps the history already shown. Settles at the
   * reply or the deadline; a later reply is shown unless a read started after it was shown first.
   */
  function loadHistory(): Promise<void> {
    const read = ++historyOrder;
    return new Promise((done) => {
      callTool('usage_history', { hours: HISTORY_HOURS }, { ms: HISTORY_TIMEOUT_MS, expired: done })
        .then((result) => {
          if (read < historyShown || current.closed || result.isError || !isUsageHistory(result.structuredContent)) return;
          historyShown = read;
          const { schemaVersion, series } = result.structuredContent;
          update({ history: { schemaVersion, series } });
        })
        .catch(() => {
          // No history leaves the trends empty, as in the standalone dashboard.
        })
        .finally(done);
    });
  }

  /** A Refresh's reply: shown unless something newer was; returns whether it was taken. */
  function takeRefresh(order: number, result: { status: UsageStatus } | { error: string }): boolean {
    if (current.closed) return false;
    const latest = order === latestRefresh;
    if (latest && current.busy) update({ busy: false });
    if (order < statusShown) return false;
    if ('status' in result) {
      statusShown = order;
      update({ status: result.status, toolError: null, refreshError: null });
      return true;
    }
    // An earlier Refresh's failure says nothing about the one now running or shown.
    if (!latest) return false;
    update({ refreshError: result.error });
    return true;
  }

  function refresh(): Promise<void> {
    if (current.busy || current.closed || !ready) return Promise.resolve();
    const order = ++statusOrder;
    latestRefresh = order;
    update({ busy: true });
    return new Promise((done) => {
      const expired = () => {
        // Refresh works again; the call stays open, and its reply still shows if nothing newer has.
        if (!current.closed && order === latestRefresh && current.busy) update({ busy: false, ...(order > statusShown ? { refreshError: STATUS_LATE } : {}) });
        done();
      };
      callTool('usage_status', provider === undefined ? {} : { provider }, { ms: STATUS_TIMEOUT_MS, expired })
        .then(statusOf, (error: unknown) => ({ error: error instanceof Error ? error.message : String(error) }))
        .then((result) => (takeRefresh(order, result) ? loadHistory() : undefined))
        .finally(done);
    });
  }

  function readHostContext(context: unknown) {
    if (!isObject(context) || !('theme' in context)) return;
    update({ theme: context.theme === 'light' || context.theme === 'dark' ? context.theme : null });
  }

  /** The usage_status result the host passed: the dashboard's `status`, or the error shown in its place. */
  function takeToolResult(params: unknown) {
    if (!isObject(params)) return;
    statusShown = ++statusOrder;
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

  const listener = (event: MessageEventLike) => {
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

  // R refreshes, with the guards of the standalone dashboard (App.svelte): no modifier, and not while
  // typing in a field or a dialog. It works only where a Refresh button is shown: with a status or an error.
  const onKey = (event: KeyEventLike) => {
    const target = event.target as { closest?: (selectors: string) => unknown } | null;
    if (event.key !== 'r' || event.metaKey || event.ctrlKey || event.altKey) return;
    if (typeof target?.closest === 'function' && target.closest('input, textarea, select, dialog')) return;
    if (!current.status && !current.toolError) return;
    event.preventDefault();
    void refresh();
  };
  view.addEventListener('keydown', onKey);

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
    view.removeEventListener('keydown', onKey);
    update({ closed: true, busy: false });
    // Every call still open, past its deadline or not, ends here: a reply after teardown is never read.
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
