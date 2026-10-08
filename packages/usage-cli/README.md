# @sub-set/usage

A local dashboard and CLI for AI subscription usage: ChatGPT (Codex), Claude, Cursor, Factory Droid, Amp, Devin, Antigravity, and logins stored by Pi, OpenCode, omp, and Hermes. It runs on your computer, binds only to `127.0.0.1`, and sends nothing to Subset.

> Status: prepared for npm, not yet published. Install from a tarball or the repository until a release is announced.

## Use

Requires Node.js 22 or later.

```sh
npx @sub-set/usage            # open the dashboard
npm install -g @sub-set/usage # or install the subset-usage command
subset-usage serve --port 4174 --no-open
subset-usage status           # current usage as JSON, read-only
```

| Command | What it does |
| --- | --- |
| `serve` (default) | Starts the dashboard on `127.0.0.1` (port 4174, or the next free port) and opens it. `--port <n>` requires that port; `--no-open` skips the browser. Ctrl-C stops it. |
| `status` | Prints the normalized usage status (`@subset/usage` contract, schema version 1) and exits. It writes nothing: a signed-in default Claude account is shown without being saved, and no history is recorded. |
| `collect --account <id>` | Saves a quota snapshot from a Claude Code or Antigravity status line. Installed collectors call it through a shim; you rarely run it yourself. |
| `--help`, `--version` | |

## Data and permissions

- Configuration: `~/.config/subset/codex-profiles.json` (override with `SUBSET_USAGE_PROFILES_FILE`).
- Data: `~/.local/share/subset/` (override with `SUBSET_USAGE_DATA_DIR`): managed Codex homes, quota snapshots, usage history (times and percentages only), and the collector shim `bin/subset-usage-collect` (`bin/subset-usage-collect-<hash>` for a custom profiles file, so configurations sharing a data directory keep separate collectors).
- **Use local sign-ins** is off until you choose on the dashboard's first-run question. When on, the CLI reads, without changing or refreshing, the sign-ins Claude Code, Factory Droid, the Cursor app, Devin, Pi, OpenCode, omp, and Hermes keep on this computer, and calls the usage endpoints those tools use. Those endpoints are undocumented and may change. Tokens are never stored, logged, or sent to the page.
- Installing a collector edits that CLI's `settings.json` only when you ask, keeps a backup, and keeps your previous status line running.
- The local API accepts only same-origin requests carrying the dashboard's own header.

## Development

From the repository root, `npm run build` builds `@subset/usage`, the `apps/usage` view, and this package: `dist/cli.mjs` (bundled with rolldown, no runtime dependencies) and `web/` (a copy of `apps/usage/dist`). `npm test --workspace=@sub-set/usage` runs the CLI tests. `npm run serve --workspace=@sub-set/usage` runs the source without bundling.

## Release

Releases are tag-based. Bump `version` here, merge, then push a tag `usage-v<version>`; `.github/workflows/publish-tag.yml` installs, checks, builds, tests, packs, and publishes with the organization `NPM_TOKEN`. `scripts/resolve-release-tag.mjs` refuses a tag whose version or package name does not match. Verify the published package (`npx @sub-set/usage@<version> --version`, then a real `serve`) before listing it as available anywhere.
