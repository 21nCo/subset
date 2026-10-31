import type { BrowserFacade } from '@extfn/core';
import { captureLink, type CaptureOptions, type LinkCapture } from './capture.js';
import type { SaveTarget } from './target.js';

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

/**
 * What happened to a link saved from the menu: `saved`; `not-saved` when the capture or the target refused before
 * anything was written; `unknown` when the target failed without saying (it rejected), so the link may be saved.
 */
export type LinkMenuOutcome =
  | { state: 'saved'; existing: boolean; message: string }
  | { state: 'not-saved' | 'unknown'; message: string };

const BADGES: Record<LinkMenuOutcome['state'], string> = { saved: '✓', 'not-saved': '!', unknown: '?' };

/**
 * Handles a click on the link menu item: captures the link, saves it to `target` and reports the outcome on the
 * toolbar button (badge and tooltip; no extra permission). Resolves undefined for another menu item and never rejects,
 * so the background can call it from the click listener without losing a failure.
 */
export async function saveFromContextMenu(
  browser: BrowserFacade,
  target: SaveTarget,
  info: LinkMenuClick,
  options: CaptureOptions & { id?: string } = {}
): Promise<LinkMenuOutcome | undefined> {
  let outcome: LinkMenuOutcome;
  try {
    const capture = captureFromContextMenu(info, options);
    if (!capture) return undefined;
    outcome = await saveOutcome(target, capture);
  } catch {
    outcome = { state: 'not-saved', message: 'Only web pages (http and https) can be saved.' };
  }
  // Each channel on its own, so a badge the browser refuses still leaves the tooltip, and the reverse; through then(),
  // so a call that throws instead of rejecting is contained too. The outcome is returned to the caller either way.
  const update = (path: string, details: object) => Promise.resolve().then(() => browser.call(path, details));
  await Promise.allSettled([update('action.setBadgeText', { text: BADGES[outcome.state] }), update('action.setTitle', { title: outcome.message })]);
  return outcome;
}

async function saveOutcome(target: SaveTarget, capture: LinkCapture): Promise<LinkMenuOutcome> {
  let result: unknown;
  try {
    result = await target.save(capture, {});
  } catch (error) {
    const reason = error instanceof Error && error.message ? `: ${error.message}` : '.';
    return { state: 'unknown', message: `The link may not have been saved to ${target.label}${reason}` };
  }
  const { ok, existing, error } = (typeof result === 'object' && result !== null ? result : {}) as Record<string, unknown>;
  if (ok === true) {
    return { state: 'saved', existing: existing === true, message: `${existing === true ? 'Already in' : 'Saved to'} ${target.label}.` };
  }
  return { state: 'not-saved', message: typeof error === 'string' && error ? error : 'The link was not saved.' };
}
