import type { BrowserFacade } from '@extfn/core';

/** A target's server and API token. */
export interface StoredToken {
  /** The server's base URL, for example `https://bookmarks.example.com/`, as `serverUrl` normalizes it. */
  serverUrl: string;
  token: string;
}

export interface TokenStore {
  /** The stored token, or undefined when there is none or the stored value is malformed. */
  get(): Promise<StoredToken | undefined>;
  set(value: StoredToken): Promise<void>;
  clear(): Promise<void>;
}

const KEY_PREFIX = 'link-capture:token:';

/**
 * Keeps one target's token in `storage.local`, which stays on this device. Never `storage.sync`: a synced token would
 * be copied to every browser signed in to the same account and kept by the browser vendor's sync service.
 */
export function createTokenStore(browser: BrowserFacade, targetId: string): TokenStore {
  if (typeof targetId !== 'string' || targetId.trim() === '') throw new TypeError('targetId must be a non-empty string');
  const key = `${KEY_PREFIX}${targetId}`;
  return {
    async get() {
      const items = await browser.call<Record<string, unknown> | undefined>('storage.local.get', key);
      return toStoredToken(items?.[key]);
    },
    async set(value) {
      const stored = toStoredToken(value);
      if (!stored) throw new TypeError('A token needs an http(s) server URL without credentials and a non-empty token');
      await browser.call('storage.local.set', { [key]: stored });
    },
    async clear() {
      await browser.call('storage.local.remove', key);
    }
  };
}

function toStoredToken(value: unknown): StoredToken | undefined {
  if (typeof value !== 'object' || value === null) return undefined;
  const { serverUrl: url, token } = value as Record<string, unknown>;
  if (typeof token !== 'string' || token.trim() === '' || typeof url !== 'string') return undefined;
  const normalized = serverUrl(url);
  return normalized ? { serverUrl: normalized, token } : undefined;
}

/**
 * An http(s) server URL without its query and fragment, or undefined for another scheme or a URL with credentials
 * (which would end up in storage and in every request's address).
 */
export function serverUrl(value: string): string | undefined {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    return undefined;
  }
  if ((url.protocol !== 'http:' && url.protocol !== 'https:') || url.username || url.password) return undefined;
  url.search = '';
  url.hash = '';
  return url.href;
}
