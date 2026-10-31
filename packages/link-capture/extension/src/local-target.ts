import type { BrowserFacade } from '@extfn/core';
import type { Capture, SaveResult, SaveTarget } from '@subset.dev/link-capture';

const PREFIX = 'reference:capture:';
const MAX_SAVED = 100;
const MAX_SUGGESTIONS = 8;
const LOCK = 'link-capture:reference-local';
const NO_ROOM = 'There is no room on this device to save the link.';
const NO_LOCKS = 'This browser has no Web Locks (navigator.locks), so links cannot be saved on this device.';
/** Saving stops once this many replaced entries are left behind by failed removals, so they cannot fill the storage. */
const MAX_STALE = 10;
const NOT_REMOVED = 'Links replaced on this device could not be removed from its storage.';

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
 * storage is full the save is refused (`ok: false`) and every saved capture is kept.
 *
 * Entries already replaced (by a newer entry of the same link, or past the 100 newest links) are removed again before
 * each write and on each `status()`, under the same lock, so a removal that failed once is retried and their room is
 * freed before a full storage refuses the save. Fewer than 10 left behind change nothing: saves succeed and `status()`
 * is connected. Once 10 are left, `status()` reports an error and saves are refused (`ok: false`, nothing written)
 * until a removal works again. Both decide from the same check (`available`), so `status()` says whether a save can
 * succeed now.
 *
 * `locks` defaults to `navigator.locks`, which Chromium MV3 and Firefox MV3 provide to extension pages and the
 * background. Web Locks are required: without them nothing can order the instances' saves, so `status()` reports an
 * error and `save()` refuses without touching storage.
 */
export function createLocalTarget(browser: BrowserFacade, locks: ExclusiveLocks | undefined = defaultLocks()): SaveTarget {
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

  /**
   * Runs under the lock. Removes the entries already replaced, never a link's newest entry. Resolves the entries left
   * and how many replaced ones a failed removal left behind.
   */
  async function reclaim(all: Entry[]): Promise<{ all: Entry[]; stale: number }> {
    const { stale } = sorted(all);
    if (!stale.length) return { all, stale: 0 };
    try {
      await browser.call('storage.local.remove', stale);
    } catch {
      return { all, stale: stale.length };
    }
    const removed = new Set(stale);
    return { all: all.filter((entry) => !removed.has(entry.key)), stale: 0 };
  }

  /**
   * Runs under the lock; the one availability check of both `status()` and `save()`. Reclaims what it can, then a save
   * is refused only when the replaced entries left behind reached the bound.
   */
  async function available(): Promise<{ all: Entry[]; refused: boolean }> {
    const { all, stale } = await reclaim(await entries());
    return { all, refused: stale >= MAX_STALE };
  }

  /** Runs under the lock. A failure before the write resolves `ok: false`; once written, the capture is saved. */
  async function saveLocked(capture: Capture, value: SavedCapture): Promise<SaveResult> {
    let all: Entry[];
    try {
      const checked = await available();
      if (checked.refused) return { ok: false, error: `The link was not saved. ${NOT_REMOVED}` };
      all = checked.all;
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
      // A failed set wrote nothing. Storage full is a refusal too: no entry still kept (the one this save replaces
      // included) is removed to make room, because a removal before the new entry is written could not be undone.
      return { ok: false, error: isQuotaError(error) ? NO_ROOM : message(error) };
    }
    // Saved. A failed clean-up leaves only replaced entries, which the next save or status() removes again.
    if (stale.length) await browser.call('storage.local.remove', stale).catch(() => undefined);
    return { ok: true, existing };
  }

  return {
    id: 'reference-local',
    label: 'This device',
    async status() {
      if (!locks) return { state: 'error', message: NO_LOCKS };
      return locks.request(LOCK, async () => {
        try {
          return (await available()).refused ? { state: 'error', message: NOT_REMOVED } : { state: 'connected' };
        } catch (error) {
          return { state: 'error', message: `This device's storage is unavailable${error instanceof Error && error.message ? `: ${error.message}` : '.'}` };
        }
      });
    },
    async save(capture, edits) {
      if (!locks) return { ok: false, error: NO_LOCKS };
      return locks.request(LOCK, () => saveLocked(capture, { capture, ...edits }));
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
