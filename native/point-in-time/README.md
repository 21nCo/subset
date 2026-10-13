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
- **Site:** for Chrome, Brave, Edge, Arc, Vivaldi, and Aside, the active tab's URL through Apple Events, only after the user allows Automation for that browser. The script must read the front window's `mode` as `normal`; an incognito window, an error, or a browser whose dictionary lacks the property yields no URL and drops the title. Only the scheme, host, and path are kept. Query strings, fragments, credentials, and ports are discarded before anything is stored.
- **Safari and Firefox:** app and window title only. Safari's scripting dictionary cannot say whether a window is private, so its URL is never read. Firefox has no tab scripting. Titles in any app that carry a private-mode marker (`Private Browsing`, `Incognito`, `InPrivate`) are dropped.

Samples become **segments**: a stretch of unchanged app, title, and site. A change, idle, or any gap closes the open segment. Idle means no input for 120 seconds; the segment ends when the idle period began. Sleep, display sleep, screen lock, fast user switching, pause, tracking off, and pointInTime's own windows close the segment and record nothing. If samples stop arriving for more than 30 seconds (a suspended process or a clock change), the segment ends at its last confirmed sample instead of claiming the unobserved time.

**Blocks** are fixed three-minute buckets aligned to the Unix epoch. Every UTC offset in use is a multiple of 15 minutes, so buckets also start on local three-minute boundaries, including midnight. A block stores recorded seconds, anonymous excluded seconds, per-app seconds, and the dominant app with the title and site of its longest segment in the block.

**Excluded apps** are never read: no title or Apple Event request is made while they are in front. By default their time is kept as anonymous excluded time with no app name; the menu can switch to recording nothing at all.

## Storage

`~/Library/Application Support/pointInTime/activity.sqlite`. The folder is mode 0700 and the database is mode 0600; SQLite gives its WAL and shared-memory files the same mode. WAL mode, `secure_delete` on, and a `schema_version` table with forward-only migrations. A database written by a newer schema is refused rather than modified, and the menu reports that tracking is unavailable.

- **Delete Today's Data** removes everything since local midnight. A segment that started before midnight keeps its part before midnight.
- **Delete All Data** removes every segment and block, then checkpoints the WAL and vacuums the file so deleted text does not remain on disk. Settings and the excluded-apps list are kept.
- Both actions end the open segment first, so it cannot be written back after deletion.

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

`swift test` covers URL redaction, the exclusion policy, the recorder (content changes, idle and late gaps, missed samples, clock steps), block rollup across bucket and midnight boundaries, and the store (file modes, migrations and reopen, newer-schema refusal, open-segment extension, excluded rows carrying no identity, day and range deletion, delete-all compaction). Host behavior (permissions, browsers, menu controls) is checked on a Mac with the built app; see the PR for the observed run. Notarization and a fresh-Mac launch are verified with the dev build after the last pointInTime issue, not here.
