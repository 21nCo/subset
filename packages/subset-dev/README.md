# subset.dev

A launcher for the Subset command-line tools. `npx subset.dev usage` runs `@subset.dev/usage`, so you do not have to type the scoped package name. Installed, its command is `subset`.

> Status: 0.1.0 is published on npm. Later versions are released with a `subset-dev-v<version>` tag.

## Use

Requires Node.js 22 or later.

```sh
npx subset.dev                      # list the tools
npx subset.dev usage                # same as npx @subset.dev/usage
npx subset.dev usage status         # arguments after the tool name go to the tool unchanged
npx subset.dev timer --help         # the tool's own help
npx subset.dev usage@beta           # latest, beta, next or an exact version (default: latest)
```

With `npm install -g subset.dev`, the same commands are `subset usage`, `subset usage status`, and so on. Note that `npx subset` (without `.dev`) runs a different, unrelated npm package.

| Tool | Runs |
| --- | --- |
| `usage` | `subset-usage` from [`@subset.dev/usage`](../usage-cli) |
| `timer` | the Timer app's CLI, or `subset-timer` from [`@subset.dev/timer`](../timer-cli) |
| `minutes` | the Minutes app's CLI, or `subset-minutes` from [`@subset.dev/minutes`](../minutes-cli) |
| `system` | `subset-system` from the Subset System app (macOS) |
| `point-in-time` | `point-in-time` from the pointInTime app (macOS) |

A tool that comes with a Subset Mac app runs from the installed app ([below](#commands-bundled-in-mac-apps)).

`subset --help` and `subset --version` show the launcher's own help and version.

## Commands

Besides the tools, `subset` has its own commands. Their names are reserved: no tool can be called `install`, `uninstall`, `update`, `list`, `help` or `version`.

| Command | Does |
| --- | --- |
| `subset list [--beta] [--json] [--refresh]` | Lists the Subset tools and Mac apps, installed and available ([below](#subset-list)) |
| `subset install <app> [--beta] [--user] [--dir <folder>]` | Installs a Subset Mac app after checking its checksum, signature, team and notarization ([below](#subset-install)) |
| `subset update [<app>...] [--beta] [--quit]` | Updates the installed Subset Mac apps, with the checks of `subset install` ([below](#subset-update)) |
| `subset uninstall <app> [--quit]` | Moves a Subset Mac app to the Trash and deletes its receipt; fails if the receipt cannot be deleted ([below](#subset-uninstall)) |
| `subset help [<command>]` | Shows the help, or a command's usage (also `subset <command> --help`) |
| `subset version` | Shows the subset.dev version |

## subset list

`subset list` shows every Mac app and tool in the Subset catalog feed, what is installed and what is available:

```console
$ subset list --beta
APP     INSTALLED                    LIVE   BETA
breaks  0.1.0 (live, /Applications)  0.1.0  0.1.1-beta.4
timer   -                            -      0.1.0-beta.2

TOOL   LIVE   BETA
usage  0.2.0  0.2.1-beta.1
```

- `--beta` adds the BETA column (a Mac app's beta is shown as `<version>-beta.<build>`, a tool's as its `beta` dist-tag).
- `--json` prints the `subset.list@1` document below instead of the table.
- `--refresh` fetches the catalog even when the cached copy is fresh, and never falls back to the cached copy.

In the table, and in the messages on stderr, a control character or a line or paragraph separator in a value (for example in an installed app's `Info.plist` version, or a property name in a refused feed) is shown as a `\xNN` or `\uNNNN` escape, so it cannot change the terminal or add a line; `--json` keeps the values as they are.

It exits with code 0, with 1 when the catalog cannot be used (or `SUBSET_APPLICATIONS_DIRS` is not two absolute folders), and with 2 for an option it does not know or any other argument. A cache that cannot be written or read is not an error: the catalog is listed and fetched again next time.

### Installed apps (macOS)

For each app in the feed, `subset list` looks for `<appName>.app` directly inside `/Applications` and `~/Applications` (not in subfolders, and not through a symbolic link), reads its `Contents/Info.plist` with `/usr/bin/plutil -convert json -o -`, and counts it only if its `CFBundleIdentifier` is the feed's `bundleId`; an app with the same name and another bundle ID is not a Subset app. Its version is `CFBundleShortVersionString` and its build `CFBundleVersion`. An app found in both folders is listed twice. Apps installed anywhere else are not detected.

When `~/Library/Application Support/Subset/receipts/<bundleId>.json` is a valid `subset.receipt@1` receipt for that copy (the same path and version, and for a beta the same build), INSTALLED shows its channel: `0.1.0 (live, /Applications)` or `0.1.1-beta.4 (beta, ~/Applications)`. Receipts are advisory: a missing, invalid or mismatched receipt only means no channel is shown.

On Linux and Windows, the apps are listed with INSTALLED `unsupported` (`"installed": null` in JSON), followed by the tools and the line `Mac apps can be installed only on macOS.`

### The catalog feed and its cache

The feed is `https://subset.21n.dev/catalog/v1.json` ([`subset.catalog@1`](../catalog/README.md#catalog-feed-subsetcatalog1)). `SUBSET_CATALOG_URL` replaces it with another `https:` URL, or a `file:` URL (for tests and the manager app); any other URL, or one with a user name or password, is refused. The launcher refuses redirects, stops reading after 256 KiB, and validates the feed by the reader rules (size, the closed schema, unique IDs) with a copy of `catalog.schema.json` in `src/schemas` (its tests check that the copy is unchanged and agrees with the schema's Ajv validation). An invalid feed is an error: none of it is used, and it does not replace the cached copy.

A valid feed is cached in `~/Library/Caches/Subset/catalog.json` (Linux: `$XDG_CACHE_HOME/subset` or `~/.cache/subset`; Windows: `%LOCALAPPDATA%\Subset\Cache`) with the URL and time it was fetched:

- younger than 5 minutes, it is used without asking the network (unless `--refresh`);
- otherwise the feed is fetched again; if that fails (no network, a timeout after 20 seconds, an HTTP error), a cached copy younger than 7 days is used with a warning on stderr, and an older one is an error.

### JSON: `subset.list@1`

```json
{
  "schema": "subset.list@1",
  "catalog": { "url": "https://subset.21n.dev/catalog/v1.json", "generatedAt": "2026-11-12T00:00:00Z", "fetchedAt": "2026-11-13T12:00:00.000Z", "cached": false },
  "platform": "darwin",
  "appDetection": "supported",
  "apps": [
    {
      "id": "breaks", "name": "Breaks", "appName": "Breaks", "bundleId": "dev.subset.breaks",
      "installed": [{ "path": "/Applications/Breaks.app", "folder": "/Applications", "version": "0.1.0", "build": "1", "channel": "live" }],
      "live": { "version": "0.1.0" },
      "beta": { "version": "0.1.1", "build": 4, "label": "0.1.1-beta.4" }
    }
  ],
  "tools": [{ "id": "usage", "package": "@subset.dev/usage", "bin": "subset-usage", "live": "0.2.0", "beta": "0.2.1-beta.1" }]
}
```

Every key is always present. `platform` is Node.js's `process.platform`. `appDetection` is `supported` on macOS and `unsupported` elsewhere, where every `installed` is `null`; on macOS `installed` lists the copies found (`[]` for none), with `folder` `/Applications` or `~/Applications`, `version` and `build` from `Info.plist` (`null` when missing) and `channel` `live`, `beta` or `null` (no matching receipt). `live` and `beta` are `null` when the feed has no such channel; the document always has both, whatever `--beta` says. A tool's `live` and `beta` are its `latest` and `beta` dist-tags, or `null`. `cached` is true when the cached copy was used, and `fetchedAt` is when that copy was fetched.

`SUBSET_APPLICATIONS_DIRS` is for tests only: two absolute folders, separated by `:`, that stand in for `/Applications` and `~/Applications`. `subset list`, `subset update` and `subset uninstall` search them and `subset install` installs into them instead; receipts still name the real folders.

## subset install

`subset install <app>` installs a Subset Mac app from the [catalog feed](#the-catalog-feed-and-its-cache), and only after proving that it is ours:

```console
$ subset install breaks
Downloading Breaks 0.1.0 from https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg
Verifying Breaks.app
Installed Breaks 0.1.0 in /Applications/Breaks.app
```

1. It downloads the channel's disk image over HTTPS (following at most 5 redirects, each to an `https:` URL) into a new private folder (`mkdtemp`, mode 0700), and checks that its SHA-256 is the feed's. The feed's download URL must start with `https://github.com/21nCo/subset/releases/download/`; the feed schema enforces this, and `subset install` checks it again.
2. It attaches the image read-only and hidden (`hdiutil attach -readonly -nobrowse -noautoopen -mountrandom <private folder>`) and requires one volume with exactly one `.app` at its root, named `<appName>.app`.
3. It copies the app with `ditto` to a hidden staging name in the destination folder (`.<appName>.app.subset-install-<random>`), and clears the user file flags (`uchg`, `uappnd`) and ACLs `ditto` copied from the image (`find -P <copy> -exec chflags -h nouchg,nouappnd {} +`, then `chmod -h -N`), so nothing in the copy is protected against removal. Symbolic links are never followed: a link in the app to a file elsewhere leaves that file as it is.
4. It verifies the **staged copy**, so nothing changes between the checks and the install but the final rename:
   - `codesign --verify --deep --strict` accepts it (the *signature* check);
   - `codesign -d --verbose=2` reports `TeamIdentifier=SAZVPX4CAA` (the *team* check);
   - `spctl --assess --type execute -vv` accepts it with `source=Notarized Developer ID` (the *notarization* check);
   - its `Info.plist` (read with `plutil`) has the feed's `bundleId` as `CFBundleIdentifier` (the *bundle ID* check), the channel's version as `CFBundleShortVersionString` and, for a beta, its build as `CFBundleVersion` (the *version* check), and an `LSMinimumSystemVersion` no higher than the running macOS (`sw_vers -productVersion`, the *macOS version* check).
5. It renames the staged copy to `<appName>.app` (giving it the image's permissions, never group- or world-writable) and writes the [receipt](#installed-apps-macos) (its `installedAt` is that moment), then detaches the image by its device (`hdiutil detach /dev/diskN`, then forced, up to 3 times until `hdiutil info` no longer lists it) and removes the private folder. If the image cannot be detached, it stays attached with the private folder, and `subset install` prints a warning naming them; a staged copy or private folder that cannot be removed gets a warning too.

Signature, team and notarization are what `codesign` and `spctl` report; `subset install` never parses the binary itself. It never uses `sudo` or asks for an administrator password.

**Destination.** `/Applications` when you can write to it, otherwise `~/Applications` (created if missing). `--user` always uses `~/Applications`; `--dir <folder>` installs into an existing folder (used by tests). `--beta` installs the beta channel. The receipt (`~/Library/Application Support/Subset/receipts/<bundleId>.json`, `subset.receipt@1`) is written for `/Applications` and `~/Applications` only: a `--dir` elsewhere, or a home folder outside `/Users` that the receipt schema cannot name, gets none. There is one receipt per app, so installing next to a copy in the other Applications folder moves the receipt to the new copy, and `subset install` says so (`subset: note: Breaks 0.1.0 is also installed in ~/Applications; the receipt now describes the copy in /Applications.`).

**Refusals.** It exits with code 1, installs nothing and writes no receipt when:

- `<appName>.app` already exists in the destination (changing its version is `subset update`), or a copy in `/Applications` or `~/Applications` is newer than the channel's version (or, for a beta of the same version, has a higher build): `subset install` never downgrades;
- any step or check fails. The message names it, for example `subset: Breaks 0.1.0 was not installed: the team check failed: it is not signed by the Subset team SAZVPX4CAA (TeamIdentifier: not set)`. The steps are *destination*, *download*, *checksum*, *image*, *copy*, *verify*, *install* and *receipt*, and the checks are *signature*, *team*, *notarization*, *bundle ID*, *version* and *macOS version*. A failed step removes the staged copy (clearing its flags and ACLs again, for a copy stopped part-way, and making its read-only folders writable first), detaches the image and removes the private folder, warning about anything it could not remove or detach.

Versions and builds are compared as whole numbers, whatever their size. In every message, a control character in the feed's app name, an installed copy's version, a path or a tool's output is shown as a `\xNN` or `\uNNNN` escape, as in `subset list`.

On Linux and Windows it exits with code 1 (`Mac apps can be installed only on macOS.`); an unknown option or a missing app is a usage error (exit code 2).

**Interruptions and concurrent installs.** A Ctrl-C, SIGTERM or hangup before the rename stops the install, removes the staged copy and the private folder, detaches the image and exits with 128 plus the signal number (130, 143 or 129), leaving the destination as it was. The tools (`plutil` too) run in their own process group, so a Ctrl-C reaches only `subset install`, which stops the running tool's whole process group (also when the tool has exited and a process it started still runs), with SIGTERM and then SIGKILL 5 seconds later, and starts cleaning up only once no process is left in that group (if one is still there 5 seconds after the SIGKILL, it goes on and the tool's output says so); the cleanup itself is not interrupted, and further signals are ignored until it ends. A signal after the rename changes nothing: the app and its receipt stay, the image is detached, and the install succeeds. The rename and the receipt happen together, without giving a signal handler a chance to run in between: the app is renamed only when its receipt is ready, and taken back out if the receipt cannot be put in place; if it cannot be taken back out either, it stays and the message tells you to remove it by hand. Of two `subset install` runs for the same app at once, the one holding the app's lock installs it and the other fails without changing anything ([One at a time](#subset-update)); the rename itself never replaces a folder that is not empty, so an install into a `--dir` where the app appeared meanwhile fails with `already exists` and removes its staged copy.

**Not covered.** Another program or local user replacing files in the staging folder between the checks and the rename, a compromised Developer ID key and a malicious root user are outside what `subset install` defends against (SET-240).

## subset update

`subset update [<app>...]` updates the named Mac apps, or every Subset Mac app installed in `/Applications` and `~/Applications`, to the newest release of the live channel (`--beta`: the beta channel), and replaces each copy where it is:

```console
$ subset update
Downloading Breaks 0.1.1 from https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.1/Breaks-0.1.1.dmg
Verifying Breaks.app
Updated Breaks 0.1.0 to 0.1.1 in /Applications/Breaks.app
Moved Breaks 0.1.0 to the Trash: /Users/me/.Trash/Breaks 2026-11-14 10.32.05.app
```

**Which release is newer.** The installed copy's `CFBundleShortVersionString` is compared with the channel's version, as whole numbers. A newer channel version is installed. At the same version, a copy whose [receipt](#installed-apps-macos) says `beta` moves to the live release; with `--beta`, a beta copy (per its receipt) moves to a higher beta build. Otherwise an equal version is up to date (`Breaks 0.1.0 is up to date (/Applications).`, exit code 0); a copy without a receipt counts as current at an equal version. A copy newer than the channel is never downgraded.

**How a copy is replaced.** The new release goes through every step and check of [`subset install`](#subset-install): download, checksum, image, a staged copy beside the installed one, signature, team, notarization, bundle ID, version and macOS version. If any of them fails, the installed app stays exactly as it was. Then, in one step that no signal can split:

1. the installed `<appName>.app` is renamed to a hidden backup name in the same folder, and must still be the copy that was checked (same device and inode); if another `subset install`, `update` or `uninstall` changed it in the meantime, it is renamed back and this update fails (`... was changed or removed while it was being updated`);
2. the verified copy is renamed to `<appName>.app` (if that fails, the backup is renamed back);
3. the backup, now the replaced copy, is renamed to a hidden name for old copies (`.<appName>.app.subset-old-<pid>-*`), which is never put back;
4. the receipt is rewritten for the new version and channel, only while the new copy is still at `<appName>.app` (otherwise a warning says it was not written; if it cannot be, the old receipt is deleted with a warning; the app stays updated);
5. the old copy is renamed into the Trash as `~/.Trash/<appName> <date> <time>.app`. When the Trash is on another volume, it is copied there with `ditto` after the update and then removed; a copy that fails is removed from the Trash and the old copy stays, under its hidden name, with a warning naming it.

So either the old app or the new verified one is always there. A Ctrl-C, SIGTERM or hangup before step 1 stops the update and leaves the old app untouched (exit code 128 plus the signal number); one after it changes nothing.

**One at a time.** `subset install`, `update` and `uninstall` each hold the app's lock (a file `<key>.<pid>.<random>.lock` in `~/Library/Application Support/Subset/locks`, where the key is the SHA-256 of the bundle ID in hex, so the name is short for any bundle ID) from before they put back an interrupted copy until its receipt is written or removed. Another of them for the same app meanwhile changes nothing and fails (`another subset (pid 123) is installing, updating or uninstalling Breaks; run this again once it has finished ...`); with no apps named, `subset update` updates the others. Two that start at the same moment may both fail; running one again works. A lock whose `subset` no longer runs (a `SIGKILL` or a power loss) is removed by the next one (when it cannot be removed, that app is not changed and the message names the lock file to remove by hand; with no apps named, `subset update` updates the others); if its pid has since been reused by another process (after a restart, say), the message names the lock file to remove by hand. The lock is per user (it is in your home folder): `subset` run by another user on the same `/Applications` is not kept out by it, only by the checks of the copy's device and inode before it is replaced or moved. `subset list` takes no lock. Only a `SIGKILL` or power loss between steps 1 and 2 can leave `<appName>.app` missing, and then both copies are still in the folder under hidden names (`.<appName>.app.subset-update-<pid>-*` is the old one, `.<appName>.app.subset-install-*` the new, possibly unverified, one). The next `subset install`, `update` or `uninstall` of that app renames the old one back to `<appName>.app` (`subset: note: Breaks was put back at /Applications/Breaks.app: ...`) when it is the only one and the `subset` that set it aside (its pid) no longer runs; otherwise it names the hidden copies and leaves them. `subset list` names them too, without changing anything. A copy that is no longer the installed one is never put back: an old copy (`subset-old`) that could not reach the Trash, or one that was being removed, stays hidden and is named as a previous copy that can be moved to the Trash (`subset: note: a previous copy of Breaks that subset did not move to the Trash is at ...`); a backup left beside an `<appName>.app` that is in place (a `SIGKILL` right after step 2) is renamed to such an old name by the next `subset install`, `update` or `uninstall`. So a later uninstall followed by an install never brings an old version back.

**Which copy is updated.** The copy's device and inode are recorded before and after its `Info.plist` is read; if another `subset install` or `update` replaced it in between, it is not updated (`... was replaced while its version was read ...; run subset update again.`), so a version decided for one copy is never applied to another.

**Running apps.** A running app is never replaced. The processes whose executable is inside the bundle (`ps -axww -o pid=,comm=`, so a helper inside the app counts too) are looked for. Without `--quit`, that happens before the download and again once the new copy is verified, and `subset update` refuses (`Breaks is running (pid 123); quit it, or use subset update --quit to quit and reopen it`). With `--quit`, they are looked for only once the new copy is verified: it sends them SIGTERM then, waits up to 10 seconds for every process inside the bundle to exit, and refuses if any remains; an app quit this way is reopened with `open -b <bundleId>` afterwards, whether the update succeeded or not. The processes are found by path, so they are quit only while that path is still the copy checked (same device and inode); otherwise the update of that app refuses (`... was replaced since it was checked ..., so it was not quit or updated`) without quitting or reopening anything. If `ps` fails, whether the app runs cannot be told, and it is refused too.

**With no apps named**, every installed app is updated. A copy that cannot be updated (newer than the channel, an unreadable version, no release in that channel) is then only a note on stderr and does not fail the command; for a named app it is a failure. If nothing is installed, it says `No Subset Mac apps are installed.` It also asks the npm registry for `subset.dev`'s `latest` version (`https://registry.npmjs.org/subset.dev/latest`), and when that is newer than the running launcher prints the command to update it: `subset.dev 0.3.0 is available (this is 0.2.0); update it with: npm install -g subset.dev@latest`. That check is silent when it fails.

It exits with code 0 when every app is updated or up to date, 1 when one is not (the message names it and the failed step or check, as for `subset install`), and 2 for a usage error. On Linux and Windows it exits with code 1 (`Mac apps can be updated only on macOS.`). It never uses `sudo`.

**Not covered.** A helper process an app leaves running from its old bundle path (for example a daemon that keeps running the old code until it restarts), and other programs writing into the app folder while it is replaced (SET-240).

## subset uninstall

`subset uninstall <app>` moves every copy of the app in `/Applications` and `~/Applications` to the Trash, under the same names as above, and deletes its receipt:

```console
$ subset uninstall breaks
Moved Breaks 0.1.0 (/Applications) to the Trash: /Users/me/.Trash/Breaks 2026-11-14 10.40.12.app
```

The app's data (its preferences, `~/Library/Application Support` folder and containers) stays. It holds the app's lock, as `subset update` does ([One at a time](#subset-update)). Only the copy whose `Info.plist` was read is moved: its device and inode are recorded before and after the read, and the copy taken (into the Trash, or to a hidden name beside it) must still be that copy, otherwise it is renamed back and the uninstall fails (`... was replaced since it was checked ..., so it was left in place`). A copy is never deleted outright: on the Trash's volume it is renamed there in one step, otherwise it is first renamed to a hidden name beside it (`.<appName>.app.subset-trash-<pid>-*`) and copied with `ditto` into a private hidden folder in the Trash, which is renamed to its Trash name once complete, and the hidden copy beside the app is renamed to an old copy's name (`.<appName>.app.subset-old-<pid>-*`, never put back, so a removal stopped half-way never comes back as the app) and removed only then. A copy that fails or is interrupted is removed from the Trash and the app is renamed back. A `SIGKILL` or a power loss during the copy leaves the app under its hidden name, which the next `subset install`, `update` or `uninstall` renames back, and the incomplete private folder in the Trash (`.<appName>.app.subset-copy-<pid>-*`), which the next `subset update` or `uninstall` of the app removes (`subset: note: an incomplete copy of Breaks that an interrupted subset left in the Trash was removed (...)`) once that `subset` no longer runs; nothing else in the Trash is touched. Nothing already in the Trash, an empty folder included, is replaced or removed: a Trash name where anything is counts as taken. A running app is not moved: without `--quit` it refuses, naming the processes, and with `--quit` it sends them SIGTERM and waits up to 10 seconds, as `subset update` does, but does not reopen the app. Every copy is checked (and quit, with `--quit`) before any is moved, and again just before it is moved; a signal stops it between copies. After the moves, the receipt is decided from `<appName>.app` in every Applications folder, each looked at once, so one cannot hide another. If a new copy appears at the app's path while the old one is moved (anything there at a moved copy's path, a new or changed file or folder at the other folder's, or another one in place of the one whose `Info.plist` was read), its receipt stays (`subset: note: ... was installed again while Breaks was uninstalled, so its receipt stays.`). What was already there, unchanged, keeps the receipt when it may be the app, and the uninstall then exits 1 with one line per such copy (`subset: ... was not uninstalled: it may be Breaks (<reason>), so the receipt ... stays; remove the receipt by hand if that is not Breaks.`): a bundle folder whose `Info.plist` cannot be read, a bundle folder whose readable `Info.plist` names this app's bundle ID, or a path that cannot be looked into at all (an Applications folder or `Contents` folder that cannot be searched, say). Another app of the same name, a link, a file or a folder without an `Info.plist` does not keep it, and nothing there at all does not either, even when what was there is removed while its `Info.plist` is read.

It exits with code 0 when every copy is in the Trash and the receipt is deleted, or when a copy installed meanwhile keeps the receipt (with the note above), and 1 when the app is not installed, another `subset` is working on it, it is running, a copy could not be moved (the receipt then stays), a copy left in an Applications folder may be the app (the receipt then stays), or the receipt could not be deleted (the app stays in the Trash; the message names the receipt). `SUBSET_TRASH_DIR` (tests only) is an absolute folder that stands in for `~/.Trash`.

## How it works

`subset <tool>[@<version>] [arguments...]` first asks npm for the tool: `npm exec --yes --package=@subset.dev/<tool>@<version>` fetches it into npm's cache (or uses a local install that satisfies the version) and reports the `PATH` it would run it with. The launcher takes the tool's bin from the first `node_modules/.bin` folder on that `PATH` that holds the package, and loads that ES module into its own Node.js process, as if Node.js had been started on it. The launcher has no dependencies, so `npx subset.dev usage` downloads only the launcher and the one tool you run, and npm caches both.

npm runs as the `npm-cli.js` of the npm that started the launcher (through `npm_execpath`), or otherwise as `npm` from `PATH`; on Windows it is always `npm-cli.js` (from the first `PATH` folder that holds both `npm.cmd` and `node_modules\npm\bin\npm-cli.js`, or else the npm installed with Node.js), never `cmd.exe`. No shell is involved, so arguments such as `%PATH%` or a path ending in `\` reach the tool unchanged.

Because the tool runs in the launcher's own process, there is no second process to pass signals on: Ctrl-C, a hangup or a SIGTERM reaches the tool once, whether it is sent to the process or to its whole process group, and the tool reads the terminal and sets the exit code itself.

The version is a dist-tag the release workflow publishes (`latest`, `beta`, `next`) or an exact version (`0.2.0`, `0.2.0-beta.3`). The launcher refuses ranges (including tag-like ones such as `x` or `v1`) and other npm specs, so an argument cannot turn into an npm option or a file, URL or git dependency. Unknown tools and commands exit with code 2 without starting npm.

When npm cannot fetch the tool, the launcher asks the registry once (`npm dist-tag ls <package> --json`, for at most 30 seconds; unlike `npm view`, it lists the dist-tags of a package that has no `latest`) and exits with code 1 and one of these messages:

- `<tool> is not on npm yet.` when the registry has no such package;
- `<tool> has no live release yet; try subset <tool>@beta` when the default version was asked for and the package has a `beta` dist-tag but no `latest`;
- `npm could not fetch <package>@<version>.` otherwise, for example when the registry cannot be reached.

The registry is asked only after a failed fetch, never when the tool runs.

Before loading the tool, the launcher sets `SUBSET_COMMAND` in its environment to `subset <tool>` (for example `subset usage`, whatever version was asked for), so a tool can name the command that started it in its messages. It is informational: a tool must not behave differently because of it, only print a different command name.

## Commands bundled in Mac apps

Some Subset Mac apps bundle a command, declared in the app's `helpers` (see [docs/macos-release.md](../../docs/macos-release.md#opting-an-app-in)). On macOS, `subset <tool>` runs it from the installed app:

| Command | Runs |
| --- | --- |
| `subset system ...` | `Subset System.app/Contents/Helpers/subset-system ...` |
| `subset point-in-time ...` | `pointInTime.app/Contents/Helpers/point-in-time ...` |
| `subset timer ...` | `Timer.app/Contents/Resources/timer-cli/dist/cli.mjs`, loaded like an npm tool |
| `subset minutes ...` | `Minutes.app/Contents/Resources/minutes-cli/dist/cli.mjs`, loaded like an npm tool |

So the command matches the version of the installed app (and of the daemon Timer runs). The order is:

1. An explicit version (`subset timer@beta`, `subset timer@latest`) always runs the npm package.
2. Otherwise, the installed app's command: the first `<App>.app` at the top level of `/Applications`, then `~/Applications`, whose `CFBundleIdentifier` is the app's bundle ID. Apps elsewhere are not looked for.
3. Otherwise (no such app, or an older app without the command), the npm package.
4. For a command that comes only with an app (`system`, `point-in-time`), `subset: system comes with the Subset System app. Install it with: subset install system` (exit 1); an installed app without the command is to be updated (`subset update <id>`), and elsewhere than macOS the command says the app runs only on macOS. It takes no version (exit 2).

The table of these commands is in `src/tools.mjs`, so running one asks no network; `npm run check` fails when it and the apps' `helpers` declarations disagree.

Before running a command, `subset` checks its signature with `codesign --verify --strict` and `codesign -d --verbose=2`, which must report `TeamIdentifier=SAZVPX4CAA`: a native command's own signature, and for a Node.js command (a resource of the app, with no signature of its own) the app's, whose seal covers the file. The command's path must be a file inside the app (a link may point only within it). A command that fails is not run, and the npm package is not run instead: `subset: <app> was not run: <reason>.` (exit 1).

A native command runs as a child process with the launcher's standard input, output and error. It runs in its own process group, and `subset` passes each SIGINT, SIGTERM and SIGHUP it gets on to it, so the command gets each signal once, whether it was sent to `subset` or to its process group (Ctrl-C at a terminal). `subset` then exits with the command's exit code, or ends by the signal that ended it. Being outside the terminal's foreground process group, a native command can write to the terminal but not read from it; Subset's commands do not. A Node.js command is loaded into the launcher's own process, as an npm tool is. `SUBSET_COMMAND` is set for both. `PATH` is left as it is.

## Adding a tool

Add the published package and its bin to `src/tools.mjs`. `npm run check` fails if a published package with a `bin` is missing from the list, or if an entry names a package or bin that does not exist. For a command an app bundles, add the app (`id`, `appName`, `bundleId`, `helper`, `kind`) to the tool, as declared in the app's `helpers`.

## Superfunctions packages evaluated

None apply: the launcher is a dispatcher with no auth, storage, MCP or UI. `subset list` reads one static JSON feed with Node.js's `fetch` and keeps one cache file; it validates the feed with its own small validator for the keywords the catalog schemas use, so the launcher keeps no dependencies. `subset install` downloads one file with `fetch` and asks the macOS tools (`hdiutil`, `ditto`, `find`, `chflags`, `chmod`, `codesign`, `spctl`, `plutil`, `sw_vers`) for everything else; `filefn` (uploads and storage adapters) does not cover verifying a signed macOS app. `subset update` and `subset uninstall` add `ps`, `open` and the Trash, which no Superfunctions package covers.
