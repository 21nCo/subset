import type { BrowserFacade } from '@extfn/core';
import type { Capture, SaveTarget } from '@subset.dev/link-capture';

const PREFIX = 'reference:capture:';
const MAX_SAVED = 100;

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

/**
 * Saves captures in this browser's `storage.local`, newest first, at most 100 links; a link saved again replaces its
 * entry.
 *
 * The popup and the background are separate instances writing the same storage, which has no transactions. So every
 * save writes a new key (`reference:capture:<time>:<random>`, ordered by time) and never rewrites another: two saves at
 * once both land. Clean-up afterwards removes only entries that are not the newest of their link or not among the 100
 * newest links, so whatever runs concurrently, it never removes a link's newest entry while that link is among the
 * 100 newest.
 */
export function createLocalTarget(browser: BrowserFacade): SaveTarget {
  let last = 0;

  /** Microseconds since the epoch, strictly increasing within this instance, so a later save sorts newer. */
  function stamp(): string {
    last = Math.max(Math.floor((performance.timeOrigin + performance.now()) * 1000), last + 1);
    return last.toString(36).padStart(12, '0');
  }

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

  return {
    id: 'reference-local',
    label: 'This device',
    async status() {
      return { state: 'connected' };
    },
    async save(capture, edits) {
      const existing = (await entries()).some((entry) => entry.value.capture.canonicalUrl === capture.canonicalUrl);
      const key = `${PREFIX}${stamp()}:${crypto.randomUUID()}`;
      await browser.call('storage.local.set', { [key]: { capture, ...edits } satisfies SavedCapture });
      const { stale } = sorted(await entries());
      if (stale.length) await browser.call('storage.local.remove', stale);
      return { ok: true, existing };
    },
    async suggestTags(prefix) {
      const key = prefix.toLowerCase();
      const tags = new Set(sorted(await entries()).kept.flatMap((entry) => entry.value.tags ?? []));
      return [...tags].filter((tag) => tag.toLowerCase().startsWith(key));
    }
  };
}

function isSaved(value: unknown): value is SavedCapture {
  const capture = (value as { capture?: { canonicalUrl?: unknown } } | null)?.capture;
  return typeof capture?.canonicalUrl === 'string';
}
