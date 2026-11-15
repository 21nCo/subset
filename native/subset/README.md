# Subset (macOS)

Subset is the manager app for Subset on the Mac: a menu bar app that will show which Subset apps are installed and install or update them from the same catalog feed, receipts and verification rules as the `subset` command ([SET-244](https://linear.app/21n/issue/SET-244)). It is a Subset capability in the `planned` state.

This folder holds its app shell ([SET-245](https://linear.app/21n/issue/SET-245)): a menu bar item whose menu opens the main window, a testable `SubsetCore` package, a generated Xcode project, macOS CI, and the release config that gives `macos/subset` signed betas. The main window lists the catalog's apps and the installed ones ([SET-246](https://linear.app/21n/issue/SET-246)); installing and updating them ([SET-247](https://linear.app/21n/issue/SET-247)) comes next, so the app installs nothing yet.

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
| Install or update an app | Write | Not started (SET-247) |

The menu is built from `MenuCommand` in `SubsetCore`, so the menu and its tests share one list. Above the commands it shows how many updates are available (**No updates available**, **1 update available**, **3 updates available**, or **Checking for updates…** and **Updates unavailable** before a catalog is loaded); choosing that line opens the window.

## The app list

The main window lists every app in the feed, in feed order: the installed app's icon (a generic one when it is not installed), its name and summary, the installed version and folder of each copy (for example `0.1.1-beta.4 beta in ~/Applications`), and the newest live version. **Show betas** in the toolbar (off by default, and remembered) adds the newest beta. **Update available** appears when some installed copy is older than the channel, by the rule `subset update` uses (`decideUpdate`): the live release, or with betas shown the live or beta release, whichever is newer. A copy whose receipt says it is a beta is offered the live release of its version and, with betas shown, a newer build of it; a copy newer than the channel, or whose version is not `x.y.z`, has no badge. **Refresh** fetches the feed again even when the cache is fresh.

`SubsetCore` holds all of it, so the tests cover it without the UI:

| Folder | What it does |
| --- | --- |
| `Core/Feed` | Reads the feed by the reader rules of [`packages/catalog`](../../packages/catalog/README.md#reader-rules), as `subset` does: at most 256 KiB as received, UTF-8 JSON, the closed `subset.catalog@1` schema (an unknown field anywhere refuses the feed), and unique app IDs, bundle IDs, helper commands and tool IDs. A refused feed is not used, whole, and each reason names the field. Fetches with an ephemeral URLSession, refusing redirects, within 20 seconds. |
| `Core/Installed` | Finds `<appName>.app` at the top level of `/Applications` and `~/Applications`, accepted only when its `Info.plist` has the feed's bundle ID (as `subset list` does; an app in a subfolder, under another name or behind a symbolic link is not found). Reads its version and build from that `Info.plist`, and its channel from a valid `subset.receipt@1` receipt in `~/Library/Application Support/Subset/receipts` that names the same path, version and build. A receipt is advisory: a missing or invalid one is ignored. |
| `Core/List` | The view model: rows, badges, the menu's count, and when to refresh. |

**Feed location.** `https://subset.21n.dev/catalog/v1.json`, unless the `SUBSET_CATALOG_URL` environment variable or the hidden `SubsetCatalogURL` default (`defaults write dev.subset.manager SubsetCatalogURL <url>`) names another; the environment wins. Only `https:` URLs on an allowed host (`subset.21n.dev`), without a user name or password, are used; any other is shown as an error rather than replaced by the default. An accepted URL gets four of the spelling rules `subset` applies (lowercase scheme and host, no `:443`, `/` for an empty path), so for these spellings both key the shared cache alike; other differences, such as `..` path segments, are not normalized.

**Refreshes and the cache.** The app refreshes when it launches, when the window opens and every 6 hours. A refresh within 5 minutes of a fetch uses the cached copy, `~/Library/Caches/Subset/catalog.json`, the file and format `subset` keeps, so the two share it. When the feed cannot be fetched, a copy cached less than 7 days ago is listed under a warning that says how old it is; an older copy, or none, is an error. **Refresh** always fetches, as `subset list --refresh` does, so when it cannot fetch it shows the error rather than the cached copy, and the list already shown stays while it is less than 7 days old. A refresh while another runs is skipped, and closing the window does not abandon one. The list, its status and the installed apps are updated together only when a refresh completes; if the task running a refresh is cancelled, the view model changes nothing (the app itself does not cancel its refreshes). A refused feed is an error and does not replace the cached copy, and the list loaded before stays while it is less than 7 days old.

`CatalogFeedTests` reads every fixture in [`packages/catalog/feed/fixtures`](../../packages/catalog/feed/fixtures) at test time, the files the `subset` command's tests read, and checks each valid one decodes and each invalid one is refused with its reason; it also checks the reader's patterns are the schemas' own. The tests never reach the network: fetches use recorded responses.

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
| macOS app (`Subset.app`) | Proposed. Builds unsigned in CI. On the development Mac (macOS 27) a launched Release build ran as an accessory app with no window open; the menu and the app list have not been reviewed on screen, or against the hosted feed, which is not served yet (SET-237, SET-250). No signed build or download. |

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

`.github/workflows/subset-macos.yml` runs on macOS 26 for changes here and in `packages/catalog/feed` (the fixtures and schemas both feed readers are tested against): package tests, the generated-project check, an unsigned Debug `xcodebuild build test`, an unsigned Release build, and the check of the built app's `Info.plist`.

`macos-release.json` describes the app for `scripts/release-macos.mjs` (see [docs/macos-release.md](../../docs/macos-release.md)), so the **Beta builds** workflow builds `macos/subset` betas, tagged `macos/subset/v<version>-beta.<n>`. Locally, from the repository root, `node scripts/release-macos.mjs subset --archive-only --archive-out /tmp/Subset.xcarchive.tar.gz` archives the app without signing credentials and writes the archive outside the repository.

## Superfunctions evaluated

Inspected `/Users/ar/Documents/dev/n/superfunctions` (`origin/dev`, commit `43f1e4d`) on 2026-11-15. The app has no accounts, billing, sync, upload, MCP server, third-party connection, web UI, or telemetry; it reads one public feed.

| Family | Version checked | Applies | Gap |
| --- | --- | --- | --- |
| authfn | `authfn` 0.6.0, `authfn/swift` | No | No accounts or sessions. |
| billfn | `@billfn/core` 0.4.0 | No | Nothing is sold or licensed. |
| datafn | `@datafn/core` 0.1.2, `datafn/swift` | No | Nothing is synced; the only stored data is the feed cache, in the file and format `subset` keeps. |
| filefn | `@filefn/server` 0.4.0, `filefn/swift` | No | Nothing is uploaded. Downloading and verifying app releases (SET-247) follows the catalog's own rules. |
| mcpfn | `@mcpfn/core` 0.0.6 | No | No MCP or agent surface is proposed. |
| plugfn | `plugfn` 0.2.1 | No | No third-party service connections. |
| apifn | `@apifn/core` 0.0.4 | No | No HTTP API is served; the feed contract is `packages/catalog`. |
| uifn | `@uifn/core` 0.0.3 (web components) | No | The UI is SwiftUI. |
| observability | `@superfunctions/observability` 0.0.3 | No | No telemetry. |

**Package/version used: none.** No Superfunctions code was copied or linked.
