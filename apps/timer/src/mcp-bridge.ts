// The MCP App bridge (SET-80): JSON-RPC 2.0 over postMessage between the board view in the host's
// iframe and the host, as the MCP Apps extension (io.modelcontextprotocol/ui, 2026-01-26) defines it.
// It sends `ui/initialize`, reads the theme from the host context, takes the tool result the host
// passes as the board's `result`, and runs each board action as a `tools/call` of the matching Timer
// tool. It reads timer_list every 10 s while the view is visible, and stops for good on
// `ui/resource-teardown`. Every tool call has a deadline, so a reply the host never sends cannot stall
// the refresh or leave a control busy. It touches no DOM, so it runs under `node --test` with a fake host.
// `@modelcontextprotocol/ext-apps` 2.0.3 was evaluated and not used; see the README.
import type { OperationName, TimerBoardResult, TimerError } from '@subset/timer';
import type { TimerActionOutcome, TimerBoardActions } from '@subset/timer/view-model';

export const PROTOCOL_VERSION = '2026-01-26';
/** How often the bridge reads timer_list while the view is visible. */
export const REFRESH_MS = 10_000;
/** How long a read (timer_list, timer_get, timer_presets) waits for the host's reply. */
export const READ_TIMEOUT_MS = 15_000;
/** How long a change waits: long enough for the host to ask the user to approve it. Never retried. */
export const CHANGE_TIMEOUT_MS = 300_000;
export const CHANGE_TIMEOUT_MESSAGE = 'The host did not reply; the change may still have happened, and the next refresh shows it.';

export type Theme = 'light' | 'dark';

/** What the view shows; a new object on every change. */
export interface BridgeState {
  /** The board's `result`: the tool result's `structuredContent`, then each timer_list read. */
  result: TimerBoardResult | null;
  /**
   * The tool result the host passed was an error, or the call was cancelled before any board: shown in
   * place of the board until a later tool result or refresh succeeds.
   */
  toolError: string | null;
  /** The latest timer_list read failed; the board keeps the last result. */
  refreshError: string | null;
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
  setInterval?: (callback: () => void, ms: number) => unknown;
  clearInterval?: (handle: unknown) => void;
  setTimeout?: (callback: () => void, ms: number) => unknown;
  clearTimeout?: (handle: unknown) => void;
}

export interface Bridge {
  actions: TimerBoardActions;
  state(): BridgeState;
  /** Calls `listener` after every change; returns a function that removes it. */
  subscribe(listener: (state: BridgeState) => void): () => void;
  /** Sends `ui/initialize` and then `ui/notifications/initialized`; resolves once both are sent. */
  connect(): Promise<void>;
  /** Whether the view can be seen; refresh runs only while it can. */
  setVisible(visible: boolean): void;
  /** Tells the host the view's size, once connected and only when it changed. */
  sizeChanged(width: number, height: number): void;
  close(): void;
}

interface CallToolResult {
  content?: { type: string; text?: string }[];
  structuredContent?: Record<string, unknown>;
  isError?: boolean;
}

type ToolCall = { name: string; arguments: Record<string, unknown> };

const isObject = (value: unknown): value is Record<string, unknown> => typeof value === 'object' && value !== null && !Array.isArray(value);

/** The operations that only read; any other changes the timers. */
const READS: ReadonlySet<OperationName> = new Set<OperationName>(['list', 'presets.list', 'get']);

/** The tool for each operation the board runs on one timer by id. */
const ID_TOOLS: Partial<Record<OperationName, string>> = {
  get: 'timer_get', pause: 'timer_pause', resume: 'timer_resume', lap: 'timer_lap', skip: 'timer_skip', reset: 'timer_reset', remove: 'timer_remove'
};

class InputError extends Error {
  constructor(readonly path: string, message: string) {
    super(`${path}: ${message}`);
  }
}

/** Milliseconds as the tools' whole seconds; a fraction of a second cannot be sent. */
function wholeSeconds(ms: unknown, path: string): number {
  if (typeof ms !== 'number' || !Number.isInteger(ms / 1_000)) throw new InputError(path, 'the Timer tools take whole seconds');
  return ms / 1_000;
}

/** timer_start's arguments for the board's `create` input: `{ preset, name? }` or `{ timer }`. */
function startArguments(input: Record<string, unknown>): Record<string, unknown> {
  const spec = input.timer;
  if (!isObject(spec)) return { ...input };
  const name = spec.name ?? input.name;
  const settings = {
    ...(name === undefined ? {} : { name }),
    ...(spec.sound === undefined ? {} : { sound: spec.sound }),
    ...(spec.countdownTicks === undefined ? {} : { ticks: spec.countdownTicks })
  };
  if (spec.kind === 'stopwatch') return { stopwatch: true, ...settings };
  if (spec.kind === 'countdown') {
    const laps = spec.lapsEnabled === undefined ? {} : { laps: spec.lapsEnabled };
    if (spec.until !== undefined) return { until: spec.until, ...laps, ...settings };
    return { durationSeconds: wholeSeconds(spec.durationMs, 'duration'), ...laps, ...settings };
  }
  if (spec.kind === 'interval') {
    const segments = Array.isArray(spec.segments) ? spec.segments : [];
    const interval = {
      rounds: spec.rounds,
      ...(spec.prepMs === undefined ? {} : { prep: wholeSeconds(spec.prepMs, 'prep') }),
      ...(spec.cooldownMs === undefined ? {} : { cooldown: wholeSeconds(spec.cooldownMs, 'cooldown') }),
      segments: segments.map((segment: Record<string, unknown>, index) => ({
        label: segment.label,
        phase: segment.phase,
        seconds: wholeSeconds(segment.durationMs, `segments.${index}.duration`)
      }))
    };
    return { interval, ...settings };
  }
  throw new InputError('timer.kind', 'must be countdown, stopwatch or interval');
}

/** The tool call that runs `operation` with the board's `input`. */
function toolCall(operation: OperationName, input: Record<string, unknown>): ToolCall {
  if (operation === 'list') return { name: 'timer_list', arguments: {} };
  if (operation === 'presets.list') return { name: 'timer_presets', arguments: {} };
  if (operation === 'create') return { name: 'timer_start', arguments: startArguments(input) };
  if (operation === 'start') return { name: 'timer_start', arguments: { id: input.id } };
  const name = ID_TOOLS[operation];
  if (!name) throw new Error(`${operation} is not available in this view.`);
  return { name, arguments: { id: input.id } };
}

/** The text of a tool result, for an error with no `structuredContent.error`. */
const resultText = (result: CallToolResult) =>
  (result.content ?? []).map((block) => (block.type === 'text' ? block.text ?? '' : '')).join(' ').trim();

/** A tool error as the board's `{ error }`. */
function toolFailure(result: CallToolResult): { error: TimerError } {
  const error = result.structuredContent?.error;
  if (isObject(error) && typeof error.message === 'string') return { error: error as unknown as TimerError };
  return { error: { code: 'internal', message: resultText(result) || 'The Timer tool failed.' } as unknown as TimerError };
}

/** The board a Timer tool returned: its `structuredContent` without the write's `affectedTimerId`. */
function boardOf(structured: Record<string, unknown>): TimerBoardResult {
  const { affectedTimerId: _affected, ...board } = structured;
  return board as unknown as TimerBoardResult;
}

/**
 * The operation's result from the tool's: the board for `list`, the presets for `presets.list`, and for
 * a change to one timer `{ timer, observedAt }` (`{ removedId, observedAt }` for remove), taken from the
 * board the tool read after it. The board checks each against the Timer contract.
 */
function operationResult(operation: OperationName, input: Record<string, unknown>, result: CallToolResult): TimerActionOutcome {
  if (result.isError) return toolFailure(result);
  const structured = result.structuredContent;
  if (!isObject(structured)) throw new Error('The Timer tool returned no structured result.');
  if (operation === 'list') return boardOf(structured) as unknown as TimerActionOutcome;
  if (operation === 'presets.list') return structured;
  const { observedAt, timers } = structured as { observedAt?: unknown; timers?: unknown };
  const id = operation === 'get' ? input.id : structured.affectedTimerId;
  if (operation === 'remove') return { removedId: id, observedAt };
  const timer = Array.isArray(timers) ? timers.find((each) => isObject(each) && isObject(each.definition) && each.definition.id === id) : undefined;
  return { timer, observedAt };
}

/** Connects the view to its host. Call `connect()` once the view listens to `subscribe`. */
export function createBridge({
  host,
  view,
  appInfo,
  setInterval: every = globalThis.setInterval,
  clearInterval: stopEvery = globalThis.clearInterval as (handle: unknown) => void,
  setTimeout: after = globalThis.setTimeout,
  clearTimeout: cancel = globalThis.clearTimeout as (handle: unknown) => void
}: BridgeOptions): Bridge {
  let current: BridgeState = { result: null, toolError: null, refreshError: null, theme: null, closed: false };
  const listeners = new Set<(state: BridgeState) => void>();
  const update = (change: Partial<BridgeState>) => {
    current = { ...current, ...change };
    for (const listener of listeners) listener(current);
  };

  let nextId = 0;
  const pending = new Map<number, { resolve(value: unknown): void; reject(error: Error): void; deadline: unknown }>();
  let ready = false;
  let visible = true;
  let refreshHandle: unknown = null;
  let refreshing = false;
  // Bumped by each tool result the host passes, so a read issued before it cannot replace it.
  let generation = 0;
  let size: { width: number; height: number } | null = null;
  let sentSize: string | null = null;

  const send = (message: Record<string, unknown>) => host.postMessage({ jsonrpc: '2.0', ...message }, '*');

  /**
   * Sends a request and waits for its reply. With a `timeout`, no reply by then rejects with its
   * message and forgets the request, so a reply that comes later has no effect.
   */
  function request(method: string, params: Record<string, unknown>, timeout?: { ms: number; message: string }): Promise<unknown> {
    if (current.closed) return Promise.reject(new Error('The host closed the Timer view.'));
    const id = ++nextId;
    return new Promise((resolve, reject) => {
      const deadline = timeout
        ? after(() => {
            if (!pending.delete(id)) return;
            reject(new Error(timeout.message));
          }, timeout.ms)
        : null;
      pending.set(id, { resolve, reject, deadline });
      send({ id, method, params });
    });
  }

  async function callTool(call: ToolCall, read: boolean): Promise<CallToolResult> {
    const timeout = read
      ? { ms: READ_TIMEOUT_MS, message: `The host did not reply to ${call.name}.` }
      : { ms: CHANGE_TIMEOUT_MS, message: CHANGE_TIMEOUT_MESSAGE };
    const result = await request('tools/call', call, timeout);
    if (!isObject(result)) throw new Error('The host returned no tool result.');
    return result as CallToolResult;
  }

  /**
   * Reads timer_list into `result`; a failure keeps the last result and says so. A read the host
   * answers after passing a newer tool result is dropped: that result is the newer board.
   */
  async function refresh() {
    if (refreshing || current.closed || !ready) return;
    refreshing = true;
    const issued = generation;
    const stillNewest = () => !current.closed && issued === generation;
    try {
      const result = await callTool({ name: 'timer_list', arguments: {} }, true);
      if (!stillNewest()) return;
      if (result.isError || !isObject(result.structuredContent)) update({ refreshError: toolFailure(result).error.message });
      else update({ result: boardOf(result.structuredContent), toolError: null, refreshError: null });
    } catch (error) {
      if (stillNewest()) update({ refreshError: error instanceof Error ? error.message : String(error) });
    } finally {
      refreshing = false;
    }
  }

  function schedule() {
    const wanted = ready && visible && !current.closed;
    if (wanted && refreshHandle === null) refreshHandle = every(() => void refresh(), REFRESH_MS);
    if (!wanted && refreshHandle !== null) {
      stopEvery(refreshHandle);
      refreshHandle = null;
    }
  }

  function readHostContext(context: unknown) {
    if (!isObject(context) || !('theme' in context)) return;
    update({ theme: context.theme === 'light' || context.theme === 'dark' ? context.theme : null });
  }

  /** The tool result the host passed: the board's `result`, or the error it reports in place of the board. */
  function takeToolResult(params: unknown) {
    if (!isObject(params)) return;
    generation += 1;
    const result = params as CallToolResult;
    if (result.isError) update({ result: null, toolError: toolFailure(result).error.message });
    else if (isObject(result.structuredContent)) update({ result: boardOf(result.structuredContent), toolError: null });
    else update({ result: null, toolError: 'The Timer tool returned no structured result.' });
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
    else if (method === 'ui/notifications/host-context-changed') readHostContext(params);
    else if (method === 'ui/notifications/tool-cancelled' && !current.result) update({ toolError: 'The tool call was cancelled.' });
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
    update({ closed: true });
    schedule();
    for (const waiting of pending.values()) {
      if (waiting.deadline !== null) cancel(waiting.deadline);
      waiting.reject(new Error('The host closed the Timer view.'));
    }
    pending.clear();
  }

  const actions: TimerBoardActions = {
    async invoke(operation, input) {
      let call: ToolCall;
      try {
        call = toolCall(operation, input);
      } catch (error) {
        if (!(error instanceof InputError)) throw error;
        // The form's input has no tool equivalent; the board shows it as the action's failure.
        return { error: { code: 'invalid_input', message: error.message, issues: [{ path: error.path, message: error.message }] } };
      }
      return operationResult(operation, input, await callTool(call, READS.has(operation)));
    }
  };

  return {
    actions,
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
      schedule();
      sendSize();
    },
    setVisible(next) {
      const shown = next && !visible;
      visible = next;
      schedule();
      // Shown again: read at once, since the timers may have changed while the view was hidden.
      if (shown) void refresh();
    },
    sizeChanged(width, height) {
      size = { width, height };
      sendSize();
    },
    close
  };
}
