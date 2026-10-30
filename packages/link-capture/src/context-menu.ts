import type { BrowserFacade } from '@extfn/core';
import { captureLink, type CaptureOptions, type LinkCapture } from './capture.js';

/** The default id of the link context menu item. */
export const LINK_CONTEXT_MENU_ID = 'link-capture:save-link';

export interface LinkContextMenuOptions {
  /** The menu label, for example `Save link to Bookmarks`. */
  title: string;
  id?: string;
}

/** The parts of `contextMenus.OnClickData` a link capture reads. Chromium gives no `linkText`; Firefox does. */
export interface LinkMenuClick {
  menuItemId?: string | number;
  linkUrl?: string;
  linkText?: string;
}

/**
 * Adds a context menu item on http and https links. It replaces an item with the same id, so the background can call
 * it on every start: Chromium keeps items across service worker restarts and refuses a duplicate id.
 */
export async function registerLinkContextMenu(browser: BrowserFacade, options: LinkContextMenuOptions): Promise<void> {
  const id = options.id ?? LINK_CONTEXT_MENU_ID;
  try {
    await browser.call('contextMenus.remove', id);
  } catch {
    // Nothing to replace.
  }
  await browser.call('contextMenus.create', {
    id,
    title: options.title,
    contexts: ['link'],
    targetUrlPatterns: ['http://*/*', 'https://*/*']
  });
}

/**
 * The capture for a click on the link menu item, or undefined for another menu item. It reads only the click data: no
 * page access and no network. Throws `LinkCaptureError` `unsupported-page` for a link that is not http or https.
 */
export function captureFromContextMenu(
  info: LinkMenuClick,
  options: CaptureOptions & { id?: string } = {}
): LinkCapture | undefined {
  if (info.menuItemId !== (options.id ?? LINK_CONTEXT_MENU_ID)) return undefined;
  return captureLink(info.linkUrl ?? '', info.linkText, options);
}
