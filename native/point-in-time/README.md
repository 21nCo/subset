# pointInTime (macOS)

pointInTime is a menu-bar app that records which app, window, and website is in front while you work, and rolls that activity into three-minute blocks so you can see where your day went. Activity stays on the Mac.

This folder holds the capture and storage slice ([SET-19](https://linear.app/21n/issue/SET-19)) of the pointInTime outcome ([SET-18](https://linear.app/21n/issue/SET-18)). Classification with a user-supplied ChatGPT subscription or OpenRouter key (SET-20), the timeline and weekly reports (SET-21), the focus ring and companion (SET-22), and the read-only `status --json` agent command (SET-23) are later issues. None of them is implemented here.

## Capability boundary

| Owner | Responsibility |
| --- | --- |
| `Core/` (`PointInTimeCore`) | Activity and segment models, URL redaction, the capture policy (exclusions), the segment recorder state machine, three-minute block rollup, and the SQLite store with migrations and deletion. Pure Swift plus SQLite; no AppKit, no network. |
| `MacApp/` | The menu-bar host: macOS signals (frontmost app, sleep, lock, fast user switching, idle), Accessibility and Apple Events reads, settings, the status menu, and the welcome window. |

The store is the source of truth. Later slices read blocks from it and write classification results into the columns reserved for them. No other app, package, or product imports this code yet.

## What is recorded

While tracking is on and the Mac is awake, unlocked, active, and not idle, the app samples every five seconds:

- **App:** the frontmost app's name and bundle ID, from `NSWorkspace`. No permission needed.
- **Window title:** the focused window's title through Accessibility, only while `AXIsProcessTrusted()` is true. Titles are trimmed and capped at 300 characters.
- **Site:** for the Chromium browsers Chrome, Brave, Edge, and Arc (the set SET-19 lists), the active tab's URL through Apple Events, only after the user allows Automation for that browser. Only the scheme, host, and path are kept. Query strings, fragments, credentials, and ports are discarded before anything is stored.
- **Private windows in Chromium browsers:** the window title and site are kept only when the browser confirms the window is normal; otherwise only the browser's name is recorded. The reader asks for the front window's id, then addresses that window by id for its `mode`. Nothing about its tabs is requested unless the `mode` is `normal`, so a private window's title and URL are never read. The active tab is then resolved once to its id, and its title and URL are both read from that tab, so neither a window switch nor a tab switch mid-read can pair one title with another URL or with another window's privacy (titles still require Accessibility). Only a `mode` of `normal` confirms; missing Automation, an Apple Event error or timeout, a dictionary without `mode`, or a title with a private-mode marker keep only the app, and the URL is not read after such a title. Apple Events are sent with `NSAppleEventDescriptor`, which is safe off the main thread. The rule lives in `BrowserWindowReport` and `WindowPrivacy` in `Core/` and is unit-tested.
- **Listed Chromium browsers without Automation:** the app name only. Without Apple Events the window's `mode` cannot be confirmed, and the Accessibility title is never used for these browsers.
- **Every other browser:** the app name only, never a window title or URL (an owner decision recorded on SET-19 on 2026-10-17). Without a scriptable window mode a private window could be recognized only by its title, and browsers translate that title into every language they ship (Firefox's German "— Privater Modus", Chrome Canary's "Inkognito"), so a title rule would keep private titles in any language it missed. A browser is any app other than Safari whose Info.plist declares the `http` or `https` URL scheme (read on every sample), plus a built-in list that holds even if the Info.plist cannot be read: the Firefox family (Firefox, Beta, Developer Edition, Nightly, Tor Browser, Mullvad Browser, LibreWolf, Waterfox, Zen, Floorp), Chrome Beta, Dev and Canary, Chromium, Vivaldi, Aside, Edge Beta, Dev and Canary, Opera, Orion, DuckDuckGo, Safari Technology Preview, and others. iPhone and iPad apps are read from the Info.plist at the top of their bundle. An app whose Info.plist cannot be read counts as a browser. Some apps that are not browsers also declare a web scheme (on the development Mac, iTerm and ChatGPT); they are recorded by app name only as well. The rule is `BrowserSupport.forApp` in `Core/`.
- **Safari:** app and window title only, never a URL. Safari's scripting dictionary has no private-window property, so its URLs are not read in this issue (an owner decision recorded on SET-19 on 2026-10-13). A title is dropped when it carries an English private-mode marker (`Private Browsing`, `Incognito`, `InPrivate`) or when it matches Safari's private-window titles in any language Safari ships: the Accessibility title of a private window with a page ("%@, Private Browsing") and of a blank or locked one ("Private Browsing"), read from Safari's string tables with English built in. The title and its private-window evidence are one Accessibility string, so they always describe the same window.
- **Other apps** (apps that do not declare a web scheme): app and window title, never a URL, with the same private-title rule as Safari.

Samples become **segments**: a stretch of unchanged app, title, and site. A change, idle, or any gap closes the open segment. Idle means no input for 120 seconds; the segment ends when the idle period began (or when recording last resumed after sleep, lock, or pause, if that is later), and anything already stored after that moment (the open segment's last flush, or a segment closed by a title change while you were away) is removed, and the WAL is then checkpointed so the removed titles and URLs do not linger in it. Sleep, display sleep, screen lock, fast user switching, pause, tracking off, and pointInTime's own windows close the segment and record nothing. If samples stop arriving for more than 30 seconds (a suspended process or a clock change), the segment ends at its last confirmed sample instead of claiming the unobserved time. The app opts out of App Nap while recording, while idle, and during a timed pause, so neither the five-second sample nor the end of a pause is throttled. Titles and URLs are read off the main thread, so a read can finish after the front app changed: every app switch, pointInTime or lock-screen sample, excluded-app sample, and gap ends the open segment and voids reads still in flight, and only one read is in flight at a time, across apps, so a slow browser cannot queue up reads; a read that finishes after the front app changed is dropped and the app now in front is read at once. A late read therefore never records across time spent elsewhere.

**Blocks** are fixed three-minute buckets aligned to the Unix epoch. Every UTC offset in use is a multiple of 15 minutes, so buckets also start on local three-minute boundaries, including midnight. A block stores recorded seconds, anonymous excluded seconds, per-app seconds, and the dominant app with the title and site of its longest segment in the block.

**Excluded apps** are never read: no title or Apple Event request is made while they are in front. By default their time is kept as anonymous excluded time with no app name; the menu can switch to recording nothing at all.

## Storage

`~/Library/Application Support/pointInTime/activity.sqlite`. The folder is mode 0700 and the database is mode 0600 (the store refuses to open if it cannot set either mode); SQLite gives its WAL and shared-memory files the same mode. WAL mode, `secure_delete` on, and a `schema_version` table with forward-only migrations. A database written by a newer schema is refused rather than modified, and the menu reports that tracking is unavailable.

- **Delete Today's Data** removes everything since local midnight, then checkpoints the WAL. A segment that started before midnight keeps its part before midnight. Only buckets that hold stored data are rebuilt, so the open-ended range costs no more than the data it removes.
- **Delete All Data** removes every segment and block, then checkpoints the WAL and vacuums the file so deleted text no longer remains in the SQLite database or its WAL. This does not guarantee physical erasure from the disk: SSD wear leveling, APFS copy-on-write, and Time Machine or local snapshots can keep older copies. Settings and the excluded-apps list are kept.
- Both actions end the open segment first, so it cannot be written back after deletion.
- **Failed writes are retried, in order.** Every store write (a segment save, an idle retraction with its WAL checkpoint, a deletion) goes through `PendingWrites` in `Core/`. A write that fails, for example on a full disk, stays queued with everything after it and is retried on every five-second sample until it succeeds; nothing later runs ahead of it, so a retried save cannot bring back time that a later retraction or deletion removed, and Delete All drops queued writes it would erase anyway. The menu shows the error until the queue drains, so a later successful write cannot hide it. The queue lives in memory: quitting while a write is still failing loses the queued writes, including a pending idle retraction.

Settings (tracking, pause, excluded apps, exclusion mode, onboarding) live in the app's user defaults. Tracking is off until the welcome window's **Start Tracking**.

## Surfaces

| Surface | State |
| --- | --- |
| macOS app | Building. Local development builds only; no notarized download yet. |
| Agent CLI (`status --json`) | Planned in SET-23. |

The catalog lists `point-in-time` as `building` with no available surface.

## Build and run

The package builds and tests with Command Line Tools alone:

```sh
swift test --package-path native/point-in-time
native/point-in-time/scripts/build-app.sh              # ad hoc signed build/pointInTime.app
POINT_IN_TIME_SIGN_IDENTITY='Developer ID Application: …' native/point-in-time/scripts/build-app.sh
open native/point-in-time/build/pointInTime.app
```

Launch through Finder or `open`, not by running the executable from a terminal: a terminal-launched process inherits the terminal's Accessibility grant and gives a misleading result.

`PointInTime.xcodeproj` is generated by `ProjectGenerator.rb` (xcodeproj 1.27) from the same sources: a static `PointInTimeCore` library, the `pointInTime` app, and the `PointInTimeCoreTests` bundle. Regenerate it after adding or removing a source file; generation is reproducible, and CI fails if the committed project differs. `macos-release.json` opts the app into `scripts/release-macos.mjs` (see [docs/macos-release.md](../../docs/macos-release.md)).

`.github/workflows/point-in-time.yml` runs on macOS for changes here: package tests, the generated-project check, and an unsigned `xcodebuild build test`.

### Permissions

- **Accessibility** (optional): window titles. Request from the welcome window or the menu; grant in System Settings > Privacy & Security > Accessibility. Reset with `tccutil reset Accessibility dev.subset.point-in-time`.
- **Automation** (optional, per browser): sites. The welcome window asks macOS for consent; the app checks permission with `AEDeterminePermissionToAutomateTarget` without prompting before every read, so it never triggers a surprise prompt while you work. Reset with `tccutil reset AppleEvents dev.subset.point-in-time`.
- No App Sandbox: Apple Events to browsers and, in SET-20, launching the user's Codex CLI require it to be off. The hardened runtime is on, with only the Apple Events entitlement.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) on 2026-10-13.

- **datafn:** the Swift runtime (`datafn/swift`) targets a WebView and Core Data sync topology. pointInTime needs a local-only, single-writer SQLite store with deletion and redaction guarantees and no sync, so it was not used.
- **filefn:** remote file APIs and uploads; nothing is uploaded.
- **plugfn, authfn, billfn:** no accounts, third-party connections, or billing in this slice. SET-20's provider connections use the user's own Codex CLI login and a Keychain-stored key, and will repeat this check.
- **mcpfn, apifn:** no MCP server or API.
- **uifn, observability:** not applicable to a SwiftUI/AppKit app with no telemetry.

**Package/version used: none.** No Superfunctions code was copied or linked.

## Verification

`swift test` covers URL redaction, the exclusion policy, the private-window rule (the Chromium read order: no tab read unless `mode` is `normal`, title and URL from one tab id, unconfirmed windows; Safari's localized private-window titles including blank and locked windows; every other browser, including unlisted Chromium channels and apps whose Info.plist declares a web URL scheme, and listed Chromium browsers without Automation keeping the app name only), the recorder (content changes, idle and late gaps, idle beginning before a segment, missed samples, clock steps), the ordering of late reads against app switches, pointInTime's own windows and apps excluded with record nothing, block rollup across bucket and midnight boundaries, and the store (file modes, migrations and reopen, newer-schema refusal, open-segment extension and shrinking, retraction of flushed time after idle, excluded rows carrying no identity, day and range deletion including Delete Today's open-ended range, delete-all compaction).

Browsers checked on the development Mac (macOS 26.6.2, Safari 26.6.2): Chrome (normal windows store title and redacted URL; incognito windows store neither), Safari (normal windows store their title and no URL; a private window with a page and a blank private window store neither), and Firefox (at 298dc69: title only, private windows stored no title in English; since then Firefox-family browsers record the app name only, because localized private titles such as German "Privater Modus" were not recognized). Brave uses the same Chromium events as Chrome but was not exercised. Edge and Arc were not installed and are unverified; if one of them lacks the `mode` property, it records the browser's name only. Host behavior (permissions, browsers, menu controls) is checked on a Mac with the built app; see the PR for the observed run. Notarization and a fresh-Mac launch are verified with the dev build after the last pointInTime issue, not here.
