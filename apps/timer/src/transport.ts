// The page's transport to `subset-timer serve`: each operation is POST /api/ops/<name>, and the daemon's
// state arrives as a server-sent event stream from /api/events. Every request carries the header
// X-Subset-Timer: 1, which the server requires on /api/*. EventSource cannot send a header, so the
// stream is read with fetch.
import type { TimerBoardResult } from '@subset/timer';
import type { TimerActionOutcome, TimerBoardActions } from '@subset/timer/view-model';

const API_HEADERS = { 'X-Subset-Timer': '1' };
/** The first wait before reopening a stream that failed; it doubles after each failure, up to the maximum. */
export const RETRY_MIN_MS = 1_000;
export const RETRY_MAX_MS = 15_000;
/** The daemon sends a heartbeat every 15 s; a stream silent for three of them is reopened. */
export const STALE_MS = 45_000;

export type Connection = 'connecting' | 'live' | 'unavailable';

function errorMessage(body: unknown): string | null {
  const error = body && typeof body === 'object' ? (body as { error?: { message?: unknown } }).error : undefined;
  return typeof error?.message === 'string' ? error.message : null;
}

export const actions: TimerBoardActions = {
  async invoke(operation, input) {
    const response = await fetch(`/api/ops/${encodeURIComponent(operation)}`, {
      method: 'POST',
      headers: { ...API_HEADERS, 'content-type': 'application/json' },
      body: JSON.stringify(input)
    });
    const body: unknown = await response.json().catch(() => null);
    // A 503 means the daemon did not run the operation (unreachable or shutting down). Throwing tells
    // the board the change may never have reached the daemon, so it does not read the board after it.
    if (response.status === 503 || !body || typeof body !== 'object') {
      throw new Error(errorMessage(body) ?? `The Timer daemon is unavailable (HTTP ${response.status}).`);
    }
    return body as TimerActionOutcome;
  }
};

/** One `event:`/`data:` block of the stream, with `data` parsed as JSON; null when it is not one. */
function parseFrame(block: string): { event: string; data: unknown } | null {
  let event = 'message';
  const data: string[] = [];
  for (const line of block.split('\n')) {
    if (line.startsWith('event: ')) event = line.slice(7);
    else if (line.startsWith('data: ')) data.push(line.slice(6));
  }
  if (!data.length) return null;
  try {
    return { event, data: JSON.parse(data.join('\n')) };
  } catch {
    return null;
  }
}

/**
 * Follows the daemon's state: calls `onState` with each `state` event's `structuredContent` and
 * `onConnection` as the stream opens and fails. A failed, ended or silent stream is reopened after
 * a wait that grows from 1 s to 15 s and starts again at 1 s once a state arrives. Returns a stop function.
 */
export function followState({ onState, onConnection }: { onState(result: TimerBoardResult): void; onConnection(connection: Connection): void }): () => void {
  let stopped = false;
  let controller: AbortController | null = null;
  let retryHandle: ReturnType<typeof setTimeout> | undefined;
  let delay = RETRY_MIN_MS;

  async function open() {
    const current = new AbortController();
    controller = current;
    let staleHandle: ReturnType<typeof setTimeout> | undefined;
    const touch = () => {
      clearTimeout(staleHandle);
      staleHandle = setTimeout(() => current.abort(), STALE_MS);
    };
    try {
      touch();
      const response = await fetch('/api/events', { headers: API_HEADERS, cache: 'no-store', signal: current.signal });
      if (!response.ok || !response.body) throw new Error(`HTTP ${response.status}`);
      const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
      let buffer = '';
      for (;;) {
        const { value, done } = await reader.read();
        if (done) break;
        touch();
        buffer += value;
        let end;
        while ((end = buffer.indexOf('\n\n')) >= 0) {
          const frame = parseFrame(buffer.slice(0, end));
          buffer = buffer.slice(end + 2);
          if (frame?.event !== 'state') continue;
          delay = RETRY_MIN_MS;
          onConnection('live');
          onState((frame.data as { structuredContent: TimerBoardResult }).structuredContent);
        }
      }
    } catch {
      // A refused, failed or aborted stream is retried below.
    } finally {
      clearTimeout(staleHandle);
    }
    if (stopped) return;
    onConnection('unavailable');
    retryHandle = setTimeout(open, delay);
    delay = Math.min(delay * 2, RETRY_MAX_MS);
  }

  void open();
  return () => {
    stopped = true;
    clearTimeout(retryHandle);
    controller?.abort();
  };
}
