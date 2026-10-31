import type { BrowserFacade } from '@extfn/core';
import { serverUrl } from './storage.js';

/**
 * The only install-time permissions. `activeTab` and `scripting` read the current tab on a user action, `storage` keeps
 * the token and `contextMenus` adds the link item. There are no host permissions.
 */
export const LINK_CAPTURE_PERMISSIONS = ['activeTab', 'contextMenus', 'scripting', 'storage'] as const;

/**
 * Any http(s) site may be requested at runtime, because a self-hosted server can be anywhere; only the origin of the
 * server the user connects is ever granted (`requestServerAccess`).
 */
export const LINK_CAPTURE_OPTIONAL_HOST_PERMISSIONS = ['http://*/*', 'https://*/*'] as const;

/**
 * The manifest keys link capture needs, for `defineExtension({ manifest })` of `@extfn/core`. `background.scripts`
 * repeats extfn's `background.js` for Firefox: extfn 0.1 writes only `service_worker`, which Firefox does not run,
 * and Chromium 121 and later ignore `scripts` next to `service_worker`.
 * TEMPORARY until extfn 0.2.0 (SFO-44) writes `background.scripts` for Firefox itself.
 */
export function linkCaptureManifest() {
  return {
    permissions: [...LINK_CAPTURE_PERMISSIONS],
    optional_host_permissions: [...LINK_CAPTURE_OPTIONAL_HOST_PERMISSIONS],
    background: { scripts: ['background.js'] }
  };
}

/** The match pattern for a server's origin, for example `https://bookmarks.example.com/*`. Ports are not part of a match pattern. */
export function serverOriginPattern(url: string): string {
  const normalized = serverUrl(url);
  if (!normalized) throw new TypeError('The server URL must be an http(s) URL without credentials');
  const { protocol, hostname } = new URL(normalized);
  return `${protocol}//${hostname}/*`;
}

/**
 * Asks the user to let the extension reach the server, when a target connects. Browsers allow the request only during
 * a user action (a click in the popup or options page). Resolves to whether access was granted.
 */
export async function requestServerAccess(browser: BrowserFacade, url: string): Promise<boolean> {
  return (await browser.call<boolean>('permissions.request', { origins: [serverOriginPattern(url)] })) === true;
}

export async function hasServerAccess(browser: BrowserFacade, url: string): Promise<boolean> {
  return (await browser.call<boolean>('permissions.contains', { origins: [serverOriginPattern(url)] })) === true;
}

/** Gives the access back, for example when the target disconnects. */
export async function removeServerAccess(browser: BrowserFacade, url: string): Promise<boolean> {
  return (await browser.call<boolean>('permissions.remove', { origins: [serverOriginPattern(url)] })) === true;
}
