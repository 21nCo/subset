# @subset.dev/catalog

The directory's metadata (`src/index.ts`): every Subset capability, the surfaces proposed for it, and the surfaces whose artifact and route have been verified (`availableSurfaces`, AGENTS.md rule 4). `scripts/check-workspaces.mjs` checks the listings. The package is private; the directory app and the scripts below import its build (`npm run build --workspace=@subset.dev/catalog`).

## Catalog feed: `subset.catalog@1`

One JSON document says what Subset ships and where to get it. `subset` (the `subset.dev` launcher) and the Subset manager app for Mac read it; it is to be served at `https://subset.21n.dev/catalog/v1.json` (`SUBSET_CATALOG_URL` overrides that). Hosting the feed and reading it are separate issues; this package defines the contract.

- Schema: [`feed/catalog.schema.json`](feed/catalog.schema.json) (JSON Schema 2020-12).
- Generator: `node scripts/catalog-feed.mjs [--out <file>] [--recorded <responses.json>]`.

```json
{
  "schema": "subset.catalog@1",
  "generatedAt": "2026-11-12T00:00:00Z",
  "apps": [{
    "id": "timer", "name": "Timer", "summary": "…", "appName": "Timer", "bundleId": "dev.subset.timer",
    "helpers": [{ "command": "timer", "path": "Contents/Resources/timer-cli/dist/cli.mjs", "kind": "node" }],
    "channels": {
      "live": { "version": "0.1.0", "url": "https://github.com/21nCo/subset/releases/download/…/Timer-0.1.0.dmg", "sha256": "…", "releaseUrl": "https://github.com/21nCo/subset/releases/tag/…" },
      "beta": { "version": "0.1.1", "build": 2, "url": "…", "sha256": "…", "releaseUrl": "…" }
    }
  }],
  "tools": [{ "id": "usage", "package": "@subset.dev/usage", "bin": "subset-usage", "distTags": { "latest": "0.2.0", "beta": "0.2.1-beta.1" } }]
}
```

Where each part comes from:

| Field | Source |
| --- | --- |
| `apps[]` | Each catalog listing that proposes `macos`, has `native/<id>/macos-release.json`, and has a live or beta channel. |
| `name`, `summary` | The catalog listing. |
| `appName`, `bundleId`, `helpers` | `native/<id>/macos-release.json` (`app`, `bundleId`, `helpers`; `helpers` is `[]` when the app bundles no command). |
| `channels.live` | The listing's available `macos` surface. |
| `channels.beta` | The newest (by version, then build) published GitHub pre-release tagged `macos/<id>/v<x.y.z>-beta.<n>` that has the uploaded DMG `<App-Name>-<x.y.z>-beta.<n>.dmg` (the `appName` with each run of whitespace as a hyphen, as `scripts/release-macos.mjs` names it, so `Subset System` is `Subset-System-…`) and a `SHA256SUMS` line for it. `build` is `n`, the app's `CFBundleVersion`. Drafts, `-dev.<n>` builds, and releases missing the DMG, `SHA256SUMS` or its line are skipped. |
| `tools[]` | `release-packages.json` entries whose package has a bin, which must be the one bin `subset-<slug>` (the `subset.dev` launcher itself is not a tool), with the `latest` and `beta` dist-tags from `npm view <package>@latest dist-tags --json`. That prints nothing for a package with no `latest`, so the generator then asks `npm view <package>@beta dist-tags --json`, whose answer carries the same dist-tags. The tag is always named, so npm's configured `tag` does not matter, and npm 12's one-element array answer is read like npm 10's object. A tag whose version the schema does not allow (a `latest` that is a pre-release, a `beta` not named `x.y.z-beta.<n>`) is left out, and so is a package the registry does not have (E404 `Not Found`, or every version unpublished) or that has neither tag left (`No match found for version beta`). Any other npm failure, including an E404 it does not recognize, stops the build. |

The generator asks GitHub (the REST releases list, with `GITHUB_TOKEN` when set; the token goes only to `api.github.com`) and npm rather than predicting them. It stops, writing nothing, if a catalog download is not a checksummed `21nCo/subset` release download, if GitHub links a release's files or page anywhere else, if a `SHA256SUMS` lists one DMG twice with different checksums, or if GitHub's own `digest` of the DMG disagrees with `SHA256SUMS`. It validates the document by the reader rules below before writing it. `--recorded <file>` answers every request from a file of recorded responses (`{ "github": { "<url>": <body> }, "npm": { "<package>": <dist-tags> | null } }`) and fails on any other request, so the feed can be built offline; `scripts/fixtures/catalog-feed/recorded.json` holds the answers recorded on 2026-11-12.

### Reader rules

A reader refuses the whole document, keeping whatever it had before, when any of these fails:

1. The document is at most 262144 bytes (256 KiB) as received. Check the size before parsing.
2. It is JSON and valid against `catalog.schema.json`. The schema is closed: an unknown field anywhere is refused, so a new field needs a new schema version (`subset.catalog@2`).
3. Every `url` is a `.dmg` under `https://github.com/21nCo/subset/releases/download/` and every `releaseUrl` a page under `https://github.com/21nCo/subset/releases/tag/`, with plain path segments: no `.` or `..` segment, percent-escape, backslash, query or fragment, so the URL cannot resolve anywhere else. The schema's patterns encode this.
4. App IDs, bundle IDs, helper commands and tool IDs are each unique across the document (the schema cannot express this).

A reader then verifies a downloaded DMG against the entry's `sha256` before using it.

## Install receipt: `subset.receipt@1`

When `subset` or the manager app installs an app from the feed, it writes `~/Library/Application Support/Subset/receipts/<bundleId>.json`, valid against [`feed/receipt.schema.json`](feed/receipt.schema.json):

```json
{ "schema": "subset.receipt@1", "channel": "beta", "version": "0.1.0", "build": 2, "sha256": "…", "installedAt": "2026-11-12T09:30:00Z", "path": "/Applications/Timer.app" }
```

`build` is present exactly when `channel` is `beta`. `sha256` is the installed DMG's, as listed in the feed. `path` is the installed `.app` directly inside `/Applications` or a user's `~/Applications` (`/Users/<user>/Applications`), with no `.` or `..` segment, hidden app name or control character (U+0000–U+001F, U+007F–U+009F); any other folder is refused. `installedAt`, like the feed's `generatedAt`, is a UTC time to the second on a real calendar date. A receipt is advisory: what is installed is what the app's own `Info.plist` says, and a missing or invalid receipt never blocks an update.

## Fixtures

[`feed/fixtures/`](feed/fixtures) is the contract both readers test against; `scripts/catalog-feed.test.mjs` checks every file with the schema validator. A file named `<catalog|receipt>-valid-<case>.json` must be accepted and `<catalog|receipt>-invalid-<case>.json` refused:

| Fixture | Why |
| --- | --- |
| `catalog-valid-live-only` | Breaks with only a live channel. |
| `catalog-valid-live-and-beta` | Breaks live and beta, Timer beta only with a bundled command, and a tool. |
| `catalog-valid-tools-only` | No apps; one tool with both dist-tags and one with only `beta`. |
| `catalog-invalid-wrong-host` | A download URL on another host. |
| `catalog-invalid-dot-segment` | A download URL that starts with the right prefix but leaves it through `..` segments. |
| `catalog-invalid-missing-sha256` | A beta channel without `sha256`. |
| `catalog-invalid-unknown-field` | An app with a field the schema does not define. |
| `catalog-invalid-oversize` | An otherwise valid feed padded with whitespace to 262145 bytes. |
| `catalog-invalid-wrong-schema` | `"schema": "subset.catalog@2"`. |
| `catalog-invalid-duplicate-app` | The same app ID and bundle ID twice. |
| `catalog-invalid-impossible-date` | `generatedAt` on February 29 of a year that is not a leap year. |
| `receipt-valid-live`, `receipt-valid-beta` | A live receipt in `/Applications` and a beta receipt in `~/Applications`. |
| `receipt-invalid-live-with-build` | A live receipt with a `build`. |
| `receipt-invalid-beta-without-build` | A beta receipt without one. |
| `receipt-invalid-unknown-field` | A field the schema does not define. |
| `receipt-invalid-relative-path` | A `path` with a `..` segment. |
| `receipt-invalid-other-applications-folder` | An app in an `Applications` folder on another volume. |
| `receipt-invalid-parent-segment` | `/Users/../Applications/<app>.app`. |
| `receipt-invalid-control-character` | A `path` with a C1 control character (U+0085). |
| `receipt-invalid-impossible-date` | `installedAt` on April 31. |

## Superfunctions

Evaluated: none applies. The feed is a static JSON document built by a repository script; validation uses [Ajv](https://ajv.js.org) 8 (already in the workspace) with the JSON Schema 2020-12 draft.
