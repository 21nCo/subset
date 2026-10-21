// Whether the MCP App view can be seen (SET-80): the page is shown and the view is on screen. The
// bridge refreshes only while it can. A hidden page runs no rendering updates, so no
// IntersectionObserver callback comes while it stays hidden: the first answer is given at once, from
// the page's visibility, before the bridge connects. It takes the page and observer as arguments, so it
// runs under `node --test` with fakes.

/** The document, as far as visibility needs it. */
export interface VisibilityPage {
  readonly visibilityState: string;
  addEventListener(type: 'visibilitychange', listener: () => void): void;
}

/** Calls `callback` with each change of whether the view is on screen (an IntersectionObserver). */
export type WatchOnScreen = (callback: (entries: readonly { isIntersecting: boolean }[]) => void) => void;

/** Calls `setVisible` now and after each change of whether the view can be seen. */
export function watchVisibility(setVisible: (visible: boolean) => void, page: VisibilityPage, watchOnScreen: WatchOnScreen): void {
  let pageShown = page.visibilityState === 'visible';
  let onScreen = true;
  const visibility = () => setVisible(pageShown && onScreen);
  page.addEventListener('visibilitychange', () => {
    pageShown = page.visibilityState === 'visible';
    visibility();
  });
  watchOnScreen((entries) => {
    onScreen = entries.some((entry) => entry.isIntersecting);
    visibility();
  });
  visibility();
}
