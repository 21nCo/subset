import type { BrowserFacade } from '@extfn/core';
import type { Capture, SaveResult, SaveTarget } from '@subset.dev/link-capture';

const PREFIX = 'reference:capture:';
const MAX_SAVED = 100;
const MAX_SUGGESTIONS = 8;
const LOCK = 'link-capture:reference-local';
const NO_ROOM = 'There is no room on this device to save the link.';

interface SavedCapture {
  capture: Capture;
  title?: string;
  notes?: string;
  tags?: string[];
}

interface Entry {
  key: string;
  value: SavedCapture;
}

/** The part of the Web Locks `LockManager` the target uses; tests pass a fake. */
export interface ExclusiveLocks {
  request<T>(name: string, callback: () => Promise<T>): Promise<T>;
}

/**
 * Saves captures in this browser's `storage.local`, newest first, at most 100 links; a link saved again replaces its
 * entry.
 *
 * The popup and the background are separate instances writing the same storage, which has no transactions. Every
 * save and its clean-up run inside one exclusive Web Lock shared by every extension page and the background (same
 * origin), so saves are ordered by when they took the lock: the save that took it last is the one kept for its link,
 * whatever the instances' clocks say. Inside the lock the key's time is at least one past the newest stored key, so it
 * sorts after everything already saved. A saved entry is removed only after the entry replacing it is written: when
 * storage is full the save is refused (`ok: false`) and every saved capture is kept. `locks` defaults to
 * `navigator.locks`; without Web Locks, saves are serialized within this instance only.
 */
export function createLocalTarget(browser: BrowserFacade, locks: ExclusiveLocks | undefined = defaultLocks()): SaveTarget {
  let queue: Promise<unknown> = Promise.resolve();
  const exclusive = <T>(run: () => Promise<T>): Promise<T> => {
    if (locks) return locks.request(LOCK, run);
    const result = queue.then(run, run);
    queue = result.catch(() => undefined);
    return result;
  };

  async function entries(): Promise<Entry[]> {
    const items = (await browser.call<Record<string, unknown> | undefined>('storage.local.get', null)) ?? {};
    return Object.entries(items)
      .filter((entry): entry is [string, SavedCapture] => entry[0].startsWith(PREFIX) && isSaved(entry[1]))
      .map(([key, value]) => ({ key, value }))
      .sort((a, b) => (a.key < b.key ? 1 : a.key > b.key ? -1 : 0));
  }

  /** The newest entry of each link, newest first, and the keys that are kept by neither rule. */
  function sorted(all: Entry[]): { kept: Entry[]; stale: string[] } {
    const links = new Set<string>();
    const kept: Entry[] = [];
    const stale: string[] = [];
    for (const entry of all) {
      const link = entry.value.capture.canonicalUrl;
      if (links.has(link) || kept.length >= MAX_SAVED) stale.push(entry.key);
      else kept.push(entry);
      links.add(link);
    }
    return { kept, stale };
  }

  /** Runs under the lock. A failure before the write resolves `ok: false`; once written, the capture is saved. */
  async function saveLocked(capture: Capture, value: SavedCapture): Promise<SaveResult> {
    let all: Entry[];
    try {
      all = await entries();
    } catch (error) {
      return { ok: false, error: message(error) };
    }
    const existing = all.some((entry) => entry.value.capture.canonicalUrl === capture.canonicalUrl);
    const newest = all.length ? parseInt(all[0].key.slice(PREFIX.length), 36) || 0 : 0;
    const time = Math.max(Math.floor((performance.timeOrigin + performance.now()) * 1000), newest + 1);
    const key = `${PREFIX}${time.toString(36).padStart(12, '0')}:${crypto.randomUUID()}`;
    const { stale } = sorted([{ key, value }, ...all]);
    try {
      await browser.call('storage.local.set', { [key]: value });
    } catch (error) {
      // A failed set wrote nothing. Storage full is a refusal too: nothing saved is removed to make room, because a
      // removal before the new entry is written could not be undone if the popup closed or the write-back failed.
      return { ok: false, error: isQuotaError(error) ? NO_ROOM : message(error) };
    }
    // Saved. A failed clean-up leaves only stale entries, which the next save removes.
    if (stale.length) await browser.call('storage.local.remove', stale).catch(() => undefined);
    return { ok: true, existing };
  }

  return {
    id: 'reference-local',
    label: 'This device',
    async status() {
      return { state: 'connected' };
    },
    save(capture, edits) {
      return exclusive(() => saveLocked(capture, { capture, ...edits }));
    },
    async suggestTags(prefix) {
      const key = prefix.toLowerCase();
      const tags = new Set(sorted(await entries()).kept.flatMap((entry) => entry.value.tags ?? []));
      return [...tags].filter((tag) => tag.toLowerCase().startsWith(key)).slice(0, MAX_SUGGESTIONS);
    }
  };
}

function defaultLocks(): ExclusiveLocks | undefined {
  const locks = (globalThis as { navigator?: { locks?: LockManager } }).navigator?.locks;
  // The lock's promise settles with the callback's own result; the DOM types leave that promise unwrapped.
  return locks ? { request: <T>(name: string, callback: () => Promise<T>) => locks.request(name, { mode: 'exclusive' }, callback) as unknown as Promise<T> } : undefined;
}

/** Chromium rejects with `QUOTA_BYTES quota exceeded`, Firefox with a `QuotaExceededError`. */
function isQuotaError(error: unknown): boolean {
  const { name, message } = (error ?? {}) as { name?: unknown; message?: unknown };
  return name === 'QuotaExceededError' || (typeof message === 'string' && /quota/i.test(message));
}

function message(error: unknown): string {
  return error instanceof Error && error.message ? `The link was not saved: ${error.message}` : 'The link was not saved.';
}

function isSaved(value: unknown): value is SavedCapture {
  const capture = (value as { capture?: { canonicalUrl?: unknown } } | null)?.capture;
  return typeof capture?.canonicalUrl === 'string';
}
