# @subset.dev/link-capture (SET-182)

`@subset.dev/link-capture` is the browser-extension half of saving a link. It reads the current tab (URL, title, selected text and the link details in its `<head>`) or a link from the context menu, runs the popup flow, and hands the result to a pluggable **save target**. Bookmarks plugs in its target (SET-183) and Memotron can plug in its own (TIDY-469) instead of writing capture again. It imports no Bookmarks or product code; `scripts/check-workspaces.mjs` enforces that it depends only on `@subset.dev/links`, `@extfn/core` and `svelte`.

It targets `chromium-mv3` and `firefox-mv3` through extfn (`@extfn/core` 0.1.0, `@extfn/svelte` 0.1.0, `@extfn/vite` 0.1.2). The package is private (`0.1.0`) until SET-186. Social-post, video and page-region clipping, screenshots and Safari are out of scope.

## Wiring a host

```ts
// popup.ts
import { getRuntime } from '@extfn/core';
import { mountSveltePage } from '@extfn/svelte';
import { captureActiveTab } from '@subset.dev/link-capture';
import CapturePopup from '@subset.dev/link-capture/popup';

const { browser } = getRuntime();
mountSveltePage(CapturePopup, {
  props: { target: myTarget, capture: () => captureActiveTab(browser), onsetup: () => browser.call('runtime.openOptionsPage') }
});

// background.ts: add the listener first, while the worker's first run is synchronous
browser.call('contextMenus.onClicked.addListener', (info) => {
  const capture = captureFromContextMenu(info);
  if (capture) void myTarget.save(capture, {});
});
void registerLinkContextMenu(browser, { title: 'Save link to My App' });

// extfn.config.ts
export default defineExtension({ /* name, targets, background, popup */ manifest: linkCaptureManifest() });
```

`extension/` is a complete reference host that saves to `storage.local`. Its popup and background both write, so every save adds its own key and never rewrites another; clean-up keeps the newest entry of each of the 100 newest links. `npm run build` builds it for both targets into `dist-extension/` and `scripts/check-extension-build.mjs` checks the result.

## Capture

`captureActiveTab(browser, { now? })` takes extfn's `BrowserFacade` (`getRuntime().browser`). It queries the active tab of the current window and runs `readPage` in it with `scripting.executeScript`. The page returns `{ url, title, selectionText, html, lang, contentType }`, where `html` is `document.head.outerHTML` cut at 512 KB (`MAX_DOCUMENT_BYTES`) of UTF-8 between characters, and `lang` is `<html lang>`, which sits outside `<head>`, cut at 65 characters (`MAX_LANG_LENGTH` + 1). The extension keeps `lang` only when it is a language tag of at most 64 characters and cuts the head so that `<html lang="…">`, the head and `</html>` together stay within the 512 KB `parseLinkDetails` reads. The extension, not the page, runs `parseLinkDetails` from `@subset.dev/links` and returns a `TabCapture`:

```ts
type Capture = TabCapture | LinkCapture;
interface TabCapture {
  source: 'tab';
  url: string;            // the document's address (after any pushState), credentials removed
  canonicalUrl: string;   // canonicalizeUrl(url)
  title: string;          // tab title, else the details title, else the URL; whitespace collapsed, at most 500 characters
  selectionText?: string; // trimmed, at most 10,000 characters (MAX_SELECTION_LENGTH); omitted when empty
  details: LinkDetailsV1;
  capturedAt: string;     // ISO 8601
}
```

A tab whose URL is not http(s) (`chrome://`, `about:`, `file:`, `view-source:`) is refused before anything is injected. A document without `<head>` is still captured; a non-HTML one (an image, an SVG, or an XML feed or sitemap) gets only the URL, type and fallback icon, as `parseLinkDetails` decides. Failures reject with `LinkCaptureError` and a `code`: `no-active-tab`, `unsupported-page`, or `page-unavailable` (the browser refused to inject, as on its extension store, or the script returned something that is not a snapshot).

`captureLink(url, linkText?)` and `captureFromContextMenu(info, { id? })` build a `LinkCapture` (`source: 'link'`, no `details`) from the click data alone: no page access and no request, so the target's server reads the details. Chromium gives no link text, so the title is the URL there. `registerLinkContextMenu(browser, { title, id? })` adds one item on http(s) links (`contexts: ['link']`, `targetUrlPatterns`) and replaces an item with the same id, so it can run on every start.

## Save targets

```ts
interface SaveTarget {
  readonly id: string;
  readonly label: string;
  status(): Promise<{ state: 'connected' } | { state: 'needs-setup'; message?: string } | { state: 'error'; message: string }>;
  save(capture: Capture, edits: { title?: string; notes?: string; tags?: string[] }): Promise<
    { ok: true; existing?: boolean; openUrl?: string } | { ok: false; error: string }
  >;
  suggestTags?(prefix: string): Promise<string[]>;
}
```

Link capture owns reading the page and the popup; the target owns its server, credentials and validation (for example Bookmarks' own length limits). Each edit is the user's whole value, never merged with the capture: an omitted `title` keeps `capture.title`; omitted or empty `notes` and `tags` mean none. A target never fills notes from `capture.selectionText`: the popup offers the selection as the starting notes, so empty notes mean the user removed it. `existing` means the link was already saved; `openUrl` must be http(s) or the popup drops it. A thrown `save`, `status` or `suggestTags` is handled like a refusal.

## Popup flow

`popupTransition(state, event)` is the pure state machine `idle → capturing → editing → saving → saved | error`:

| From | Event | To |
| --- | --- | --- |
| `idle` | `start` | `capturing` |
| `capturing` | `captured` | `editing`, the draft taken from the capture (selected text starts the notes) |
| `capturing` | `captureFailed`, `targetUnavailable` | `error` (`capture` or `target`; `needsSetup` for `needs-setup`) |
| `editing` | `edit` | `editing` |
| `editing` | `save` | `saving` |
| `saving` | `saved` | `saved` (`existing`, `openUrl`) |
| `saving` | `saveFailed` | `error` (`save`), keeping the capture and draft |
| `error` (`save`) | `retry` / `back` | `saving` / `editing` |
| `error` (`capture`, `target`) | `retry` | `capturing` |

Any other event returns the same state object, so a second `save` while saving or a late result does nothing. `createCapturePopupController({ target, capture })` runs the effects: it checks the target and captures at once, and a target that is not connected wins over a successful capture. `draftEdits` trims fields, always sends `notes` and `tags` (empty when cleared), omits an empty title and splits tags on commas (whitespace collapsed, repeats ignoring case dropped). `@subset.dev/link-capture/popup` is a Svelte 5 view of the controller with labelled fields, tag suggestions from the target (trimmed, each once), and one status and one alert region that stay mounted so each change is announced. When the state changes, focus moves to its main control: the title field, the Save button (kept focusable while saving), the Open link or heading, or Set up or Try again.

## Permissions and tokens

**Decision:** the manifest asks for `activeTab`, `contextMenus`, `scripting` and `storage` only (`LINK_CAPTURE_PERMISSIONS`). There are no host permissions. `optional_host_permissions` lists `http://*/*` and `https://*/*` because a self-hosted server can be anywhere; `requestServerAccess(browser, serverUrl)` asks for just that server's origin when a target connects (during a click, as browsers require), and `hasServerAccess` and `removeServerAccess` check and give it back. Match patterns have no port, so access covers every port of the host. A server URL must have a literal host: `https://*/` or `https://*.example.com/`, which `URL` accepts but a match pattern reads as a wildcard, is refused by `serverUrl`, the token store and all three access functions.

`createTokenStore(browser, targetId)` keeps `{ serverUrl, token }` in `storage.local` under `link-capture:token:<targetId>`. It never uses `storage.sync`, which would copy the token to every browser on the same account. A URL with credentials, another scheme or a wildcard host, or an empty token, is refused; a malformed stored value reads as no token.

## extfn prerequisite check

`@extfn/*` 0.1.x provides what this package uses: the browser facade (`createBrowserFacade`, `getRuntime().browser`), script injection through it (`scripting.executeScript`), the popup mount (`mountSveltePage`) and a build per target (`@extfn/vite` writes `dist/chromium-mv3` and `dist/firefox-mv3`). Gaps, reported on SFO-44 (extfn 0.2.0), each with a narrow workaround here:

- `@extfn/core`'s only entry also exports its Node-only config loader, which imports `node:fs/promises`, `node:path` and `node:url`, so a browser bundle of `getRuntime` fails. The package source imports only extfn types; the reference build stubs those three imports inside `@extfn/core` (`extension/vite.config.ts`), and the loader is tree-shaken away. Hosts need the same plugin until extfn has a browser entry.
- The Firefox build writes only `background.service_worker`, which Firefox does not run. `linkCaptureManifest()` adds `background.scripts`, which Chromium 121 and later ignore next to `service_worker`.
- extfn names a page by the file name of its entry, so the popup's HTML sits at the extension root.
- There is no fake browser in 0.1.0. The tests wrap a recording fake in extfn's real `createBrowserFacade`.

`@extfn/vite` 0.1.2 accepts Vite 5 to 7, so this package builds with Vite 7 while the apps use Vite 8.

## Risk and evidence

| Boundary | Failure mode | Evidence |
| --- | --- | --- |
| Reading the tab | Wrong page, oversized message, a character split at the cut, `<html lang>` used to inject markup | `test/capture.test.mjs`: the injected function rebuilt from its source in a fresh scope (as a browser does), the exact facade calls, the 512 KB cut between four-byte characters, a tag past the cut not read, a hostile or 600 KB `lang`, credentials removed, title and selection fallbacks and caps, headless, non-HTML, SVG and XML documents, on both targets |
| Refusals | Injecting into browser pages, unclear errors | Browser, file and view-source tabs refused without injection; a hidden tab URL with a `data:` document; no tab; an injection refusal kept as the cause; malformed results |
| Context menu | Page access or a duplicate item on restart | `test/context-menu.test.mjs`: no facade call at all for a click, repeated registration, other items kept, non-http links refused |
| Popup flow | Double save, lost draft, an unsafe link, a stuck state | `test/popup-state.test.mjs`: every transition, every other (state, event) pair unchanged, an existing bookmark, `openUrl` schemes. `test/popup-controller.test.mjs`: the full flow from a tab, cleared notes reaching the target empty, one save under a double press, refused and thrown saves with retry and back, target needs-setup, failing or malformed `status`, each capture error (including from another copy of the package), suggestions |
| Tokens | A token synced or stored malformed | `test/storage.test.mjs`: `storage.sync` throws if touched; only `storage.local` calls are made; invalid values, including wildcard hosts, refused before writing |
| Permissions | A host permission or content script slips in | `test/manifest.test.mjs`: each target's manifest built by `@extfn/vite` equals the reviewed snapshot (`test/manifest.*.json`) with no host permissions; server access uses only the origin and refuses wildcard hosts |
| Build | A target does not build, or misses a file | `npm run build` builds both targets; `scripts/check-extension-build.mjs` compares each built manifest to its snapshot, checks every named file exists, checks the package is bundled once, and starts the background in a bare worker scope (no `window`) with that target's global, which must add the click listener synchronously and register the menu |
| Reference target | Overlapping popup and background saves losing one | `test/local-target.test.mjs`: two instances saving different links at once both kept, a repeat save reported as existing with one entry, the 100-link cap under overlapping saves, tag suggestions |
| Popup view | Type or accessibility regressions, a view checked against a stale or missing `dist` | `svelte-check --fail-on-warnings`, including Svelte's accessibility warnings, with the package name mapped to `src` so it passes on a fresh checkout. Announcements and focus in a live browser and screen reader are SET-191 and SET-193 |

Run `npm run check`, `npm test` and `npm run build` with `--workspace=@subset.dev/link-capture`; the root `npm run check` and `npm run build` run them. Live browsers, the popup in a real browser, Firefox's handling of `optional_host_permissions` (Firefox 128 and later) and both browsers' acceptance of `background.scripts` next to `service_worker` are deferred to SET-191 and not claimed here. No server, Railway Postgres, Cloudflare Preview or provider sandbox is involved.

## Superfunctions reuse

extfn is the Superfunctions extension framework and is used as above. `@datafn/extfn` 0.2.0 syncs datafn data between extension contexts; capture keeps no synced data, and the token must stay out of sync, so it is not used. `authfn` issues the tokens a target stores, on the target's server, so this package only keeps them. No other Superfunctions package covers page capture. Used: `@extfn/core` 0.1.0 (runtime types; the reference host uses its runtime), `@extfn/svelte` 0.1.0 and `@extfn/vite` 0.1.2 (reference host build).
