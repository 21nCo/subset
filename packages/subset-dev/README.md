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
| `timer` | `subset-timer` from [`@subset.dev/timer`](../timer-cli) |
| `minutes` | `subset-minutes` from [`@subset.dev/minutes`](../minutes-cli) |

`subset --help` and `subset --version` show the launcher's own help and version.

## Commands

Besides the tools, `subset` has its own commands. Their names are reserved: no tool can be called `install`, `uninstall`, `update`, `list`, `help` or `version`.

| Command | Does |
| --- | --- |
| `subset list [--beta] [--json] [--refresh]` | Lists the Subset tools and Mac apps, installed and available ([below](#subset-list)) |
| `subset install <app> [--beta] [--user] [--dir <folder>]` | Installs a Subset Mac app after checking its checksum, signature, team and notarization ([below](#subset-install)) |
| `subset update [<app>...] [--beta] [--quit]` | Updates the installed Subset Mac apps (not available yet) |
| `subset uninstall <app>` | Moves a Subset Mac app to the Trash (not available yet) |
| `subset help [<command>]` | Shows the help, or a command's usage (also `subset <command> --help`) |
| `subset version` | Shows the subset.dev version |

In this version, `update` and `uninstall` only print `subset <command> is not available yet.` and exit with code 2; a later version adds them.

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

`SUBSET_APPLICATIONS_DIRS` is for tests only: two absolute folders, separated by `:`, that stand in for `/Applications` and `~/Applications`. `subset list` searches them and `subset install` installs into them instead; receipts still name the real folders.

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
3. It copies the app with `ditto` to a hidden staging name in the destination folder (`.<appName>.app.subset-install-<random>`).
4. It verifies the **staged copy**, so nothing changes between the checks and the install but the final rename:
   - `codesign --verify --deep --strict` accepts it (the *signature* check);
   - `codesign -d --verbose=2` reports `TeamIdentifier=SAZVPX4CAA` (the *team* check);
   - `spctl --assess --type execute -vv` accepts it with `source=Notarized Developer ID` (the *notarization* check);
   - its `Info.plist` (read with `plutil`) has the feed's `bundleId` as `CFBundleIdentifier` (the *bundle ID* check), the channel's version as `CFBundleShortVersionString` and, for a beta, its build as `CFBundleVersion` (the *version* check), and an `LSMinimumSystemVersion` no higher than the running macOS (`sw_vers -productVersion`, the *macOS version* check).
5. It renames the staged copy to `<appName>.app` (giving it the image's permissions, never group- or world-writable) and writes the [receipt](#installed-apps-macos), then detaches the image by its device (`hdiutil detach /dev/diskN`, then forced, up to 3 times until `hdiutil info` no longer lists it) and removes the private folder. If the image cannot be detached, it stays attached with the private folder, and `subset install` prints a warning naming them; a staged copy or private folder that cannot be removed gets a warning too.

Signature, team and notarization are what `codesign` and `spctl` report; `subset install` never parses the binary itself. It never uses `sudo` or asks for an administrator password.

**Destination.** `/Applications` when you can write to it, otherwise `~/Applications` (created if missing). `--user` always uses `~/Applications`; `--dir <folder>` installs into an existing folder (used by tests). `--beta` installs the beta channel. The receipt (`~/Library/Application Support/Subset/receipts/<bundleId>.json`, `subset.receipt@1`) is written for `/Applications` and `~/Applications` only: a `--dir` elsewhere, or a home folder outside `/Users` that the receipt schema cannot name, gets none. There is one receipt per app, so installing next to a copy in the other Applications folder moves the receipt to the new copy, and `subset install` says so (`subset: note: Breaks 0.1.0 is also installed in ~/Applications; the receipt now describes the copy in /Applications.`).

**Refusals.** It exits with code 1, installs nothing and writes no receipt when:

- `<appName>.app` already exists in the destination (changing its version is `subset update`), or a copy in `/Applications` or `~/Applications` is newer than the channel's version (or, for a beta of the same version, has a higher build): `subset install` never downgrades;
- any step or check fails. The message names it, for example `subset: Breaks 0.1.0 was not installed: the team check failed: it is not signed by the Subset team SAZVPX4CAA (TeamIdentifier: not set)`. The steps are *destination*, *download*, *checksum*, *image*, *copy*, *verify*, *install* and *receipt*, and the checks are *signature*, *team*, *notarization*, *bundle ID*, *version* and *macOS version*. A failed step removes the staged copy (making its read-only folders writable first), detaches the image and removes the private folder, warning about anything it could not remove or detach.

On Linux and Windows it exits with code 1 (`Mac apps can be installed only on macOS.`); an unknown option or a missing app is a usage error (exit code 2).

**Interruptions and concurrent installs.** A Ctrl-C, SIGTERM or hangup before the rename stops the install, removes the staged copy and the private folder, detaches the image and exits with 128 plus the signal number (130, 143 or 129), leaving the destination as it was. The tools (`plutil` too) run in their own process group, so a Ctrl-C reaches only `subset install`, which stops the running tool and waits for it to exit before cleaning up; the cleanup itself is not interrupted, and further signals are ignored until it ends. A signal after the rename changes nothing: the app and its receipt stay, the image is detached, and the install succeeds. The rename and the receipt happen together, without giving a signal handler a chance to run in between: the app is renamed only when its receipt is ready, and taken back out if the receipt cannot be put in place; if it cannot be taken back out either, it stays and the message tells you to remove it by hand. Of two `subset install` runs for the same app at once, the first to rename wins; `rename(2)` does not replace a folder that is not empty, so the other fails with `already exists` and removes its staged copy.

**Not covered.** Another program or local user replacing files in the staging folder between the checks and the rename, a compromised Developer ID key and a malicious root user are outside what `subset install` defends against (SET-240).

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

## Adding a tool

Add the published package and its bin to `src/tools.mjs`. `npm run check` fails if a published package with a `bin` is missing from the list, or if an entry names a package or bin that does not exist.

## Superfunctions packages evaluated

None apply: the launcher is a dispatcher with no auth, storage, MCP or UI. `subset list` reads one static JSON feed with Node.js's `fetch` and keeps one cache file; it validates the feed with its own small validator for the keywords the catalog schemas use, so the launcher keeps no dependencies. `subset install` downloads one file with `fetch` and asks the macOS tools (`hdiutil`, `ditto`, `codesign`, `spctl`, `plutil`, `sw_vers`) for everything else; `filefn` (uploads and storage adapters) does not cover verifying a signed macOS app.
