# Subset (macOS)

Subset is the manager app for Subset on the Mac: a menu bar app that will show which Subset apps are installed and install or update them from the same catalog feed, receipts and verification rules as the `subset` command ([SET-244](https://linear.app/21n/issue/SET-244)). It is a Subset capability in the `planned` state.

This folder holds its app shell ([SET-245](https://linear.app/21n/issue/SET-245)): a menu bar item whose menu opens the main window, a testable `SubsetCore` package, a generated Xcode project, macOS CI, and the release config that gives `macos/subset` signed betas. The main window lists the catalog's apps and the installed ones ([SET-246](https://linear.app/21n/issue/SET-246)), and installs, updates and moves them to the Trash by the rules of the `subset` command ([SET-247](https://linear.app/21n/issue/SET-247)).

## Capability boundary

**User outcome:** see which Subset apps are on this Mac, and install or update them without a terminal.

**Sources of truth:**

| Data | Source | Issue |
| --- | --- | --- |
| What Subset ships | The catalog feed, `https://subset.21n.dev/catalog/v1.json` (`SUBSET_CATALOG_URL` names another https URL on `subset.21n.dev`; see **Feed location** below) | SET-246 |
| What is installed | Apps at the top level of `/Applications` and `~/Applications`, by bundle ID, and each app's own `Info.plist`; receipts are advisory | SET-246 |

**Explicit operations**

| Operation | Kind | State |
| --- | --- | --- |
| Open Subset (⌘O), About Subset, Quit Subset (⌘Q) from the menu bar item | App shell | Implemented (SET-245) |
| List catalog apps and installed apps, with Update available badges and the menu's update count | Read | Implemented (SET-246) |
| Install, Update and Move to Trash on each app row, with progress, Cancel and a plain message when it ends | Write | Implemented (SET-247); not yet tried on a clean Mac account or against the hosted feed (SET-250) |

The menu is built from `MenuCommand` in `SubsetCore`, so the menu and its tests share one list. Above the commands it shows how many updates are available (**No updates available**, **1 update available**, **3 updates available**, or **Checking for updates…** and **Updates unavailable** before a catalog is loaded); choosing that line opens the window.

## The app list

The main window lists every app in the feed, in feed order: the installed app's icon (a generic one when it is not installed), its name and summary, the installed version and folder of each copy (for example `0.1.1-beta.4 beta in ~/Applications`), and the newest live version. **Show betas** in the toolbar (off by default, and remembered) adds the newest beta. **Update available** appears when some installed copy is older than the channel, by the rule `subset update` uses (`decideUpdate`): the live release, or with betas shown the live or beta release, whichever is newer. A copy whose receipt says it is a beta is offered the live release of its version and, with betas shown, a newer build of it; a copy newer than the channel, or whose version is not `x.y.z`, has no badge. **Refresh** fetches the feed again even when the cache is fresh.

`SubsetCore` holds all of it, so the tests cover it without the UI:

| Folder | What it does |
| --- | --- |
| `Core/Feed` | Reads the feed by the reader rules of [`packages/catalog`](../../packages/catalog/README.md#reader-rules), as `subset` does except in the two cases below where the app is stricter: at most 256 KiB as received, UTF-8 JSON as `JSON.parse` reads it (no byte order mark, trailing comma, NUL byte, or UTF-16 or UTF-32 text, which Foundation alone would read; `StrictJSON` checks this before Foundation parses, for the feed, its cached copy and receipts, and, stricter than `subset`, also refuses a property name given twice in one object and a `\u` escape of an unpaired UTF-16 surrogate such as `\uD800`), the closed `subset.catalog@1` schema (an unknown field anywhere refuses the feed), and unique app IDs, bundle IDs, helper commands and tool IDs. A refused feed is not used, whole, and each reason names the field. Fetches with an ephemeral URLSession, refusing redirects, within 20 seconds. |
| `Core/Installed` | Finds `<appName>.app` at the top level of `/Applications` and `~/Applications`, accepted only when its `Info.plist` has the feed's bundle ID (as `subset list` does; an app in a subfolder, under another name or behind a symbolic link is not found). Reads its version and build from that `Info.plist` (shown with any control character, U+2028, U+2029 and bidirectional formatting character replaced by U+FFFD; compared as read), and its channel from a valid `subset.receipt@1` receipt in `~/Library/Application Support/Subset/receipts` that names the same path, version and build. A receipt is advisory: a missing or invalid one is ignored. |
| `Core/List` | The view model: rows, badges, the menu's count, and when to refresh. |
| `Core/Install` | Install, update and move to the Trash (below), and `AppActions`, the rows' buttons, progress and messages. |

**Feed location.** `https://subset.21n.dev/catalog/v1.json`, unless the `SUBSET_CATALOG_URL` environment variable or the hidden `SubsetCatalogURL` default (`defaults write dev.subset.manager SubsetCatalogURL <url>`) names another; the environment wins. Only `https:` URLs on an allowed host (`subset.21n.dev`), without a user name or password, are used; any other is shown as an error rather than replaced by the default. An accepted URL gets four of the spelling rules `subset` applies (lowercase scheme and host, no `:443`, `/` for an empty path), so for these spellings both key the shared cache alike; other differences, such as `..` path segments, are not normalized.

**Refreshes and the cache.** The app refreshes when it launches, when the window opens and every 6 hours. A refresh within 5 minutes of a fetch uses the cached copy, `~/Library/Caches/Subset/catalog.json`, the file and format `subset` keeps, so the two share it. When the feed cannot be fetched, a copy cached less than 7 days ago is listed under a warning that says how old it is; an older copy, or none, is an error. **Refresh** always fetches, as `subset list --refresh` does, so when it cannot fetch it shows the error rather than the cached copy, and the list already shown stays while it is less than 7 days old. A refresh while another runs is skipped, and closing the window does not abandon one. The list, its status and the installed apps are updated together only when a refresh completes; if the task running a refresh is cancelled, the view model changes nothing (the app itself does not cancel its refreshes). A refused feed is an error and does not replace the cached copy, and the list loaded before stays while it is less than 7 days old.

`CatalogFeedTests` reads every fixture in [`packages/catalog/feed/fixtures`](../../packages/catalog/feed/fixtures) at test time, the files the `subset` command's tests read, and checks each valid one decodes and each invalid one is refused with its reason; it also checks the reader's patterns are the schemas' own. The tests never reach the network: fetches use recorded responses.

## Install, update and Move to Trash

Each row has **Install** (when the app is not installed), **Update** (when Update available shows) and **Move to Trash** (when it is installed). While one runs the row shows its step (downloading with a progress bar, verifying, quitting, installing, moving to the Trash) and **Cancel**; when it ends, a plain sentence such as `Breaks was not installed: the checksum step failed: …`. An update or Move to Trash that stops after changing something (one of two copies updated or moved, or the app quit) says `only partly` and lists what it changed. Install takes the live release, or with **Show betas** on the newer of the live release and the beta; Update takes the release the badge offers.

`AppInstaller` follows `subset install`, `subset update` and `subset uninstall` ([SET-230](https://linear.app/21n/issue/SET-230), [SET-231](https://linear.app/21n/issue/SET-231)) step for step:

1. download the image over HTTPS (only from `https://github.com/21nCo/subset/releases/download/`, at most 5 redirects, each https, at most 1 GiB, no data for 60 seconds fails) into a new private folder (mode 0700), and check its SHA-256 against the feed;
2. attach it with `hdiutil attach -readonly -nobrowse -noautoopen -mountrandom`, and require exactly one volume holding exactly one `.app`, named `<appName>.app`;
3. copy it with `ditto` to a hidden staging name in the destination, and clear the ACLs and user flags copied from the image;
4. verify the staged copy: the Security framework checks the signature (strict, every architecture, nested code: `codesign --verify --deep --strict`) and the Developer ID requirement for team `SAZVPX4CAA`; `spctl --assess --type execute` must report `source=Notarized Developer ID`; then the bundle ID, version (and a beta's build) and `LSMinimumSystemVersion` from its `Info.plist`;
5. install: rename it to `<appName>.app` (never over anything, `RENAME_EXCL`) and rename its `subset.receipt@1` receipt into place, byte for byte the text `subset` writes; update: rename the installed copy aside (it must still be the copy checked, by device and inode), rename the new copy into place, write the receipt, and only then move the old copy to the Trash.

Step 5 runs without a suspension point, so the old app or the new verified one is always in place. A failure or Cancel before it removes the staged copy, writes no receipt, detaches the image and removes the private folder. A crash between an update's two renames leaves the old copy under the hidden name `subset` uses (`.<appName>.app.subset-update-<pid>-<random>`), and the next install, update or move to the Trash, here or by `subset`, renames it back. The destination is `/Applications` when it is writable, otherwise `~/Applications`; there is no `sudo`, no downgrade (an installed copy newer than the release refuses it), and nothing is deleted: Move to Trash uses the user's Trash (`FileManager.trashItem`) and removes the receipt only when no copy is left, keeping it (and saying so) while an `<appName>.app` may still be the app, decided as `subset uninstall` decides: a bundle folder (not a link) whose folder, `Contents` or `Info.plist` cannot be read, or whose `Info.plist` names the bundle ID, keeps it; a link, a file, or a folder without `Contents/Info.plist` is another app; the app's data stays (removing it is [SET-243](https://linear.app/21n/issue/SET-243)). The tools (`hdiutil`, `ditto`, `spctl`, `find`) run in their own process group, as `runTool` in the command does: a timeout, Cancel or quitting Subset stops the group (SIGTERM, then SIGKILL), and a process a tool started that still holds its output 2 seconds after the tool exits is stopped too, so none of them hangs an operation. A tool that exits is reaped only once its result is settled, so its pid and group ID cannot be reused while it may still be signalled, and past 1 MiB of output nothing more is kept and the pipes close. A running copy is found by every process whose executable is inside it, by its path or real path, naming each process as libproc does or, when it cannot (an executable deleted or replaced since it started), by the path it was started with, as `ps` does for `subset`; one of the user's processes that still runs and cannot be named either way refuses the operation. Only apps are asked to quit (`terminate()`), and a cancel asks no further one: a helper process still running refuses with its pid, and only an app that quit is reopened. Quitting Subset withdraws a pending quit question and starts no new operation while it waits for the running ones.

The app takes the same per-app lock files as `subset` (`~/Library/Application Support/Subset/locks/<sha256 of the bundle ID>.<pid>.<random>.lock`), so an install, update or uninstall by the command, another copy of the app or a second click is refused with a message until the first ends. A running app (any process whose executable is inside the bundle, this one included) is never replaced or moved, a copy holding this running Subset app is refused before anything changes (quitting it would end the operation; the `subset` command can update or remove it), and when the list of processes cannot be read, or one of this user's processes cannot be named by its executable or the path it was started with (matched as it resolves now, and with only its folder resolved when its file has been replaced by a link), the operation is refused rather than taken as not running (another user's process, classified from the kernel's process record as `ps` does, is not this user's app): Subset asks first, and only after the user agrees, and once the new copy is verified, asks it to quit with `NSRunningApplication.terminate()` (never a force quit, and only an app that is the process found, by pid and start time, whose own executable is still in the copy checked, so a reused pid or a replaced copy is never asked), waits up to 10 seconds, and reopens it after an update only from the copy that was quit or the verified one put in place, never something put at that path meanwhile. The window's looks for installed apps run one after another (a look held up by a stalled folder holds the next up for 10 seconds at most), so a later look never loses to an earlier one, an operation's message shows once it has cleaned up while its row's buttons wait for that look, and quitting Subset waits for running operations to clean up but not for the look that follows them.

Not claimed here: files replaced in the staging folder by another program or local user between verification and rename, a compromised signing key or a malicious root user ([SET-252](https://linear.app/21n/issue/SET-252)).

`AppInstallerTests` runs every step with injected download, image, verifier and running-app fakes: a bad checksum, an HTTP error, a URL outside the releases, no, two or a misnamed app in the image, two volumes, an unsigned, wrong-team or unnotarized app, a wrong bundle ID, version, beta build or minimum macOS, a cancel during the download, hashing, attach, copy (with an immutable, deny-delete staged copy to remove) and verification, once the copy is verified (nothing quit), while a running app quits for an update (reopened) or a Move to Trash (nothing moved, receipt kept) and during the first of two quits (no second one), a helper alone, beside an app or gone before the quit, a cancel while apps are asked to quit, a copy left under its hidden name in the Trash, hidden copies beside an app path that is a file or link, lock names outside the shared grammar (a combining mark in the nonce included), a process started from a file since replaced by a link, a reused pid, a copy replaced just before its app is quit or reopened, a copy put back before a refusal (reported as a change), a lock held by `subset` or by this app, an app put in place meanwhile, an update replaced meanwhile, a running app with and without consent, an app that does not quit, a process list that cannot be read, a copy that is this running Subset app, an interrupted update put back, a real process started by a non-canonical path whose executable is then deleted, an update that fails or a Move to Trash cancelled after one of two copies (reported as partly done), and a copy that may be the app keeping the receipt while a link, file or folder without an `Info.plist` does not. `ToolRunnerTests` runs real processes: a helper holding a tool's output after it exits, a timeout and a Cancel (with a helper that keeps or closes the output) each stop the tool's whole group promptly, a writer that ignores SIGTERM is cut off at 1 MiB, an exited tool keeps its pid until its result is settled, and a stop racing the tool's exit settles. Each refusal leaves no staged copy, private folder, attached image, lock or receipt, and each failed update leaves the old copy (same device and inode) and its receipt. `RealInstallTests` refuses an ad-hoc signed app at the team requirement with the real `hdiutil` and Security framework, leaves its own image detached after an attach cancelled at any moment, and in CI (`SUBSET_LIVE_INSTALL=1`) installs the immutable Breaks 0.1.0 release asset into temporary folders, verifies it and moves it to a test Trash folder. `packages/catalog/feed/fixtures/receipt-valid-written-by-install.json` is the receipt both this app and `subset install` write for the same install; the tests of both read it.

## App identity

| | |
| --- | --- |
| Name | Subset (`Subset.app`, scheme `Subset`) |
| Bundle ID | `dev.subset.manager` |
| Version | `MARKETING_VERSION` 0.1.0 |
| Requires | macOS 14 or later |
| Dock icon | None: `LSUIElement` is set, so the menu bar item opens the window and reopens it after it is closed |

The bundle ID is declared in `SubsetCore` (`SubsetIdentity.bundleID`), `macos-release.json`, and the generated project; `SubsetIdentityTests` checks they agree, and that `MacApp/Info.plist` sets `LSUIElement` and takes its identifier, version and minimum macOS from the project. CI checks the built Release app's `Info.plist` too.

The app is a SwiftUI `App`: a `MenuBarExtra` (the first scene, so launching shows only the menu bar item) and a `Window` scene that **Open Subset** opens. It runs with the hardened runtime and has no App Sandbox; `MacApp/Subset.entitlements` is intentionally empty. There is no app icon yet.

## Surfaces

| Surface | State |
| --- | --- |
| macOS app (`Subset.app`) | Proposed. Builds unsigned in CI. On the development Mac (macOS 27) a launched Release build ran as an accessory app with no window open; the menu, the app list and its Install, Update and Move to Trash buttons have not been reviewed on screen, or against the hosted feed, which is not served yet (SET-237, SET-250). No signed build or download. |

The catalog lists `subset` as `planned` with no available surface. Not yet verified: a signed beta (SET-250), VoiceOver and keyboard use (SET-249).

## Build and test

Requires macOS 14 or later. The package builds and tests with Command Line Tools or Xcode 26:

```sh
swift test --package-path native/subset
swift run --package-path native/subset Subset   # unbundled executable, for quick local runs
```

`Subset.xcodeproj` is generated by `ProjectGenerator.rb` (xcodeproj 1.27) from the same sources (each subfolder of `Core` a group of its own): the static `SubsetCore` library, the `Subset` app, and the `SubsetCoreTests` bundle, which the app does not host. Regenerate it after adding or removing a source file; generation is reproducible, and CI fails if the committed project differs. Regenerating replaces only `project.pbxproj` and the shared `Subset` scheme, so breakpoints, personal schemes and workspace state in `xcuserdata` stay, and a failed or interrupted regeneration puts the previous files back; `Tests/project-generator.sh` checks that. The generator needs exactly xcodeproj 1.27.0:

```sh
gem install --user-install xcodeproj -v 1.27.0
cd native/subset
ruby ProjectGenerator.rb
xcodebuild -project Subset.xcodeproj -scheme Subset -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build test
```

`.github/workflows/subset-macos.yml` runs on macOS 26 for changes here and in `packages/catalog/feed` (the fixtures and schemas both feed readers are tested against): package tests (with the ad-hoc signed app refused at the team requirement), the Breaks 0.1.0 install with the real tools, the generated-project check, an unsigned Debug `xcodebuild build test`, an unsigned Release build, and the check of the built app's `Info.plist`.

`macos-release.json` describes the app for `scripts/release-macos.mjs` (see [docs/macos-release.md](../../docs/macos-release.md)), so the **Beta builds** workflow builds `macos/subset` betas, tagged `macos/subset/v<version>-beta.<n>`. Locally, from the repository root, `node scripts/release-macos.mjs subset --archive-only --archive-out /tmp/Subset.xcarchive.tar.gz` archives the app without signing credentials and writes the archive outside the repository.

## Superfunctions evaluated

Inspected `/Users/ar/Documents/dev/n/superfunctions` (`origin/dev`, commit `43f1e4d`) on 2026-11-15. The app has no accounts, billing, sync, upload, MCP server, third-party connection, web UI, or telemetry; it reads one public feed.

| Family | Version checked | Applies | Gap |
| --- | --- | --- | --- |
| authfn | `authfn` 0.6.0, `authfn/swift` | No | No accounts or sessions. |
| billfn | `@billfn/core` 0.4.0 | No | Nothing is sold or licensed. |
| datafn | `@datafn/core` 0.1.2, `datafn/swift` | No | Nothing is synced; the only stored data is the feed cache, in the file and format `subset` keeps. |
| filefn | `@filefn/server` 0.4.0, `filefn/swift` | No | Nothing is uploaded. Downloading and verifying app releases (SET-247) follows the catalog's and `subset`'s own rules. |
| mcpfn | `@mcpfn/core` 0.0.6 | No | No MCP or agent surface is proposed. |
| plugfn | `plugfn` 0.2.1 | No | No third-party service connections. |
| apifn | `@apifn/core` 0.0.4 | No | No HTTP API is served; the feed contract is `packages/catalog`. |
| uifn | `@uifn/core` 0.0.3 (web components) | No | The UI is SwiftUI. |
| observability | `@superfunctions/observability` 0.0.3 | No | No telemetry. |

**Package/version used: none.** No Superfunctions code was copied or linked.
