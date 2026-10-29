/**
 * The title to show for a bookmark: the user's title, then the fetched page title, then the URL's host and path
 * (`example.com/a/b`; just the host for `/`). Blank titles are skipped.
 */
export function displayTitle(bookmark: { url: string; userTitle?: string | null; details?: { title?: string } | null }): string {
  const userTitle = bookmark.userTitle?.trim();
  if (userTitle) return userTitle;
  const pageTitle = bookmark.details?.title?.trim();
  if (pageTitle) return pageTitle;
  try {
    const url = new URL(bookmark.url);
    return url.pathname === '/' ? url.host : url.host + url.pathname;
  } catch {
    return bookmark.url;
  }
}
