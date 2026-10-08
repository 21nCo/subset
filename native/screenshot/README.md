# Screenshot (macOS)

Screenshot is a native macOS menu-bar app for capturing, annotating, and sharing what is on screen. It is a Subset capability in the `building` state: the source builds and its unit tests pass, but there is no signed, notarized download, no deployed share service, and no catalog availability.

## Capability boundary

**User outcome:** capture an area, window, display, scrolling region, or recording; mark it up; then copy, save, pin, or (optionally) share it, without leaving the current app.

**Source of truth:** the user's screen through ScreenCaptureKit and CoreGraphics. Captures are written to the chosen export folder (Desktop by default) and indexed in `~/Library/Application Support/dev.subset.screenshot/history.json` with thumbnails under `Media/`. Editable annotations are saved as `.ssproject` JSON files (UTType `dev.subset.screenshot.project`). Nothing leaves the Mac unless the user configures a share Worker and chooses Upload.

**Explicit operations**

| Operation | Kind | Entry points |
| --- | --- | --- |
| Capture area, window, fullscreen, previous area, scrolling, self-timer | read (screen) + local write | menu bar, global shortcuts, `subset-screenshot://` URLs |
| Record screen (MP4) or GIF | read (screen, optional mic/camera) + local write | menu bar, ⌥⇧R, URLs |
| Capture text (OCR via Vision) | read + clipboard write | ⌥⇧O, URL |
| Annotate (arrow, line, rectangle, ellipse, pencil, highlighter, text, pixelate, blur, spotlight, counter, crop, background) | local edit | Quick Access, History, menu |
| Copy, save, export, pin, restore last capture | local write | Quick Access, editor, History |
| Upload, update share (password, expiry, tags), delete hosted copy | **mutation on a remote service**; needs a user-configured Worker URL and upload token | Quick Access, History |

The native target owns screen-capture, microphone, camera, and Accessibility permissions. There is no shared TypeScript package yet: no web or agent consumer needs the capture contract today, so none was invented.

## Surfaces

| Surface | Status |
| --- | --- |
| macOS app (`native/screenshot`) | Proposed. Builds unsigned and unit tests pass locally; no signed/notarized artifact, no download. |
| Self-hosted share Worker (`share-worker/`) | Proposed. Typechecks only; not deployed anywhere. |
| iOS, web, embed, agent CLI/view | Not proposed for this port. |

Unverified: capture, recording, OCR, scrolling capture, and pinning were not exercised interactively in this port (they need an unlocked desktop and granted TCC permissions); signed distribution; Worker deployment and upload round trip; VoiceOver pass over the new accessibility labels.

## Layout

```text
native/screenshot/
  ProjectGenerator.rb        Regenerates Screenshot.xcodeproj (xcodeproj gem)
  Screenshot.xcodeproj       Generated project; scheme "Screenshot"
  MacApp/                    App entry, AppDelegate, Info.plist, asset catalog
  Sources/                   Editor, Models, Services, Views
  Tests/ScreenshotTests.swift
  share-worker/              Optional Cloudflare Worker for hosted links (not a workspace, not deployed)
```

The share Worker stays inside `native/screenshot/` rather than `apps/` because it is not a Subset-run host: adding it as a workspace would bring Wrangler/workerd into the root lockfile and CI before any Cloudflare deployment, residency, auth, cost, or rollback decision exists. See [share-worker/README.md](share-worker/README.md) for its known security gaps.

## Build and run

Requires macOS 14+ and Xcode 26.

```sh
cd native/screenshot
gem install --user-install xcodeproj   # only to regenerate the project
ruby ProjectGenerator.rb               # optional; the generated project is committed
xcodebuild -project Screenshot.xcodeproj -scheme Screenshot \
  -destination 'platform=macOS' -derivedDataPath .derived-data \
  CODE_SIGNING_ALLOWED=NO test
```

No `DEVELOPMENT_TEAM` is set. To run with stable TCC grants, open the project in Xcode and pick your own signing team. The app is an `LSUIElement` menu-bar app (viewfinder icon).

### Permissions

- **Screen Recording**: required for every capture and recording. macOS prompts on first capture; Settings > General links to System Settings.
- **Accessibility**: scrolling capture (synthetic scroll) and keystroke/click display while recording.
- **Microphone / Camera**: only when narration or the camera overlay is enabled in Recording settings.
- **Keychain**: the optional upload token is stored under service `dev.subset.screenshot.cloud`.

## UI/UX changes in this port

Informed by CleanShot X (Quick Access overlay with configurable auto-close, filterable history) and Shottr (editor keyboard shortcuts, fast OCR and pinning):

1. **First-run permission guidance.** On first launch without Screen Recording access, Settings opens to General with a "Get started" card that explains why, shows Screen Recording and Accessibility status, and links directly to the matching System Settings pane. Advanced settings rows gained the same links and a "Check Again" button.
2. **Hosted sharing is opt-in and honest.** The POC defaulted to a Nucleum-hosted URL. The default is now empty; Cloud settings show "Not set up" or "Ready to upload", explain self-hosting, and validate the URL (https, or http only for localhost). Quick Access and History offer "Set up hosted sharing" instead of an Upload button that would fail.
3. **Quick Access auto-close.** New Quick Access setting: never, 5, 10, or 30 seconds; hovering pauses the countdown. Each overlay button now has a tooltip and VoiceOver label/hint. The ambiguous "Save" (which revealed the file) is labelled "Show", and "Dismiss" uses a close icon instead of a trash can, because it does not delete anything.
4. **Editor keyboard shortcuts.** ⌘Z / ⇧⌘Z undo/redo, ⌘S save project, ⇧⌘C copy image, ⌘E export, ⌘⌫ delete the selected annotation, with tooltips and accessibility labels on icon-only controls and the selected-tool trait on the tool bar.
5. **Shortcut discoverability.** Settings > Shortcuts lists global shortcuts, editor shortcuts, and the `subset-screenshot://` automation URLs, and states that rebinding is not implemented.
6. **History empty states.** An empty history shows the capture shortcuts and a Capture Area button; a search or filter with no results offers "Clear Filters". Hover actions have labels and tooltips.

Global shortcut rebinding, a multi-display Quick Access position choice, and swipe gestures are competitor features that remain unimplemented.

## Superfunctions reuse review

Reviewed the local Superfunctions checkout `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) and npm versions on 2026-10-09.

- **filefn** (`@filefn/server@0.2.0`, `@filefn/client@0.1.1`, Swift `FileFnClient` in the monorepo `Package.swift`): the closest fit for uploads. It provides upload sessions, share links with revoke, and an R2 storage adapter (`@superfunctions/storage-r2`). Not adopted in this port because it needs an owned FileFn server with a DB adapter and auth, it does not cover share passwords, comments, or view counts that the POC exposes, and the Swift client is consumed from the monorepo without a versioned Swift tag. **Recommended replacement for `share-worker/` before any hosted deployment.**
- **authfn** (`authfn@0.4.0`, Swift `AuthFnClient`): would replace the single shared upload token with real accounts. Not used; there is no Subset-run service to authenticate against yet.
- **datafn** (`@datafn/client@0.1.1`): history sync across devices is not a goal of this port. Not used.
- **uifn**: web primitives; this is a SwiftUI/AppKit app. Not used.
- **@superfunctions/observability**: TypeScript runtime; no telemetry was added.

**Package/version used: none.** Gaps: no Swift-tagged release of FileFn/AuthFn clients; no FileFn equivalent for password-protected shares and comments.

## Provenance

Ported from the private `21nCo/21n` monorepo, branch `codex/screenshot-poc`, path `poc/ios/ScreenshotPOC`, commit `82997bdb233a20cd5871588071cf0728a0c25def` ("feat(poc): add Screenshot macOS POC with share backend").

Renames: `ScreenshotPOC` target/scheme/product → `Screenshot`; bundle ID `app.nucleum.ScreenshotPOC` → `dev.subset.screenshot`; URL scheme `screenshotpoc` → `subset-screenshot`; project UTType → `dev.subset.screenshot.project`; Keychain service → `dev.subset.screenshot.cloud`; Application Support folder → `dev.subset.screenshot`; Worker, R2, and D1 names → `subset-screenshot-*`. `Backend/` → `share-worker/`.

Removed or changed: the POC's Apple `DEVELOPMENT_TEAM` ID; the Worker's `ss.nucleum.app` custom-domain route and its account-specific D1 database ID (replaced by a placeholder); the default share URL `https://ss.nucleum.app` (now empty). No API keys, tokens, or passwords were present in the source. The app's own-window exclusion during window capture now matches by process ID instead of the app name, so it survives the rename. The app icon was replaced with the Subset pixel-art icon. A unit test for the opt-in sharing default and URL validation was added.
