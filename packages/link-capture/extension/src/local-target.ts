import type { BrowserFacade } from '@extfn/core';
import type { Capture, SaveTarget } from '@subset.dev/link-capture';

const KEY = 'reference:captures';
const MAX_SAVED = 100;

interface SavedCapture {
  capture: Capture;
  title?: string;
  notes?: string;
  tags?: string[];
}

/** Saves captures in this browser's `storage.local`, newest first, at most 100; a link saved again replaces its entry. */
export function createLocalTarget(browser: BrowserFacade): SaveTarget {
  async function list(): Promise<SavedCapture[]> {
    const items = await browser.call<Record<string, unknown> | undefined>('storage.local.get', KEY);
    const saved = items?.[KEY];
    return Array.isArray(saved) ? (saved as SavedCapture[]) : [];
  }

  return {
    id: 'reference-local',
    label: 'This device',
    async status() {
      return { state: 'connected' };
    },
    async save(capture, edits) {
      const saved = await list();
      const others = saved.filter((entry) => entry.capture?.canonicalUrl !== capture.canonicalUrl);
      await browser.call('storage.local.set', { [KEY]: [{ capture, ...edits }, ...others].slice(0, MAX_SAVED) });
      return { ok: true, existing: others.length !== saved.length };
    },
    async suggestTags(prefix) {
      const key = prefix.toLowerCase();
      const tags = new Set((await list()).flatMap((entry) => entry.tags ?? []));
      return [...tags].filter((tag) => tag.toLowerCase().startsWith(key));
    }
  };
}
