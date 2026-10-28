# @subset.dev/usage

A local dashboard and CLI for AI subscription usage: ChatGPT (Codex), Claude, Cursor, Factory Droid, Amp, Devin, Antigravity, and logins stored by Pi, OpenCode, omp, and Hermes. It runs on your computer, binds only to `127.0.0.1`, and sends nothing to Subset.

> Status: prepared for npm, not yet published. Install from a tarball or the repository until a release is announced.

## Use

Requires Node.js 22 or later.

Until the first release, install from the repository:

```sh
npm ci && npm run build                     # at the repository root
cd packages/usage-cli && npm pack           # builds and writes subset.dev-usage-<version>.tgz
npm install -g ./subset.dev-usage-*.tgz        # installs the subset-usage command
subset-usage                                # open the dashboard
subset-usage status                         # current usage as JSON, read-only
```

After a release is published, the registry commands work too: `npx @subset.dev/usage`, or `npm install -g @subset.dev/usage`.

Collectors and status-line chaining use a POSIX shell script, so they are supported on macOS and Linux; reading the Cursor app sign-in is not supported on Windows.

| Command | What it does |
| --- | --- |
| `serve` (default) | Starts the dashboard on `127.0.0.1` (port 4174, or the next free port) and opens it. `--port <n>` requires that port; `--no-open` skips the browser. Ctrl-C stops it. |
| `status` | Prints the normalized usage status (`@subset.dev/usage-core` contract, schema version 1) and exits. It writes nothing: a signed-in default Claude account is shown without being saved, and no history is recorded. |
| `mcp` | Runs a read-only MCP server on stdin and stdout for an MCP host, until the host closes stdin. See [MCP server](#mcp-server). |
| `collect --account <id>` | Saves a quota snapshot from a Claude Code or Antigravity status line. Installed collectors call it through a shim; you rarely run it yourself. |
| `--help`, `--version` | |

## MCP server

`subset-usage mcp` is a local MCP server over stdio. It gives any MCP host the same answer as `status`, without the dashboard. Add it to a host as a stdio server whose command is `subset-usage` with the argument `mcp`. The server is `@mcpfn/core` 0.0.5 (`defineMcpFnServer`, `serveStdio()`), named `subset-usage` with the package version. Stdout carries only protocol frames; its one log line and any diagnostics go to stderr. It exits 0 when the host closes stdin, after answering the calls it already received (each gets up to 10 seconds; a call still running then is not answered).

| Tool | Input | Result |
| --- | --- | --- |
| `usage_status` | `provider` (optional): one of the providers in the usage contract | The usage status (schema version 1) as `structuredContent`, and the plain-text summary `usageText` as text. With `provider`, only that provider's accounts: those read through it, harness logins for its subscription, and cards it is also signed in to. |
| `usage_history` | `hours` (optional, 1–168, default 48), `accountId` (optional, an id from `usage_status`) | The history points the dashboard stored in that range, as `/api/history` returns them (observation time in epoch milliseconds and used percent per account and window), with the range as `from` and `to`, and a short text summary per window. |

- **Read-only:** both tools have `readOnlyHint: true`. Neither writes anything: `usage_status` reads as `status` does (the signed-in default Claude account is shown without being saved, and no history is recorded), and `usage_history` only reads the history file. A Claude sign-in change is kept in the server's memory for the session, never in `claude-identities.json`: snapshots collected before the change stay hidden, and those collected after it show on every later read. The server never changes the **Use local sign-ins** setting; a read uses whatever the user chose on the dashboard.
- **Open world:** both tools have `openWorldHint: true`. With local sign-ins on, `usage_status` calls the usage endpoints of the tools signed in on this computer; `usage_history` reads only the history file, whose points came from those reads.
- **Least data:** results pass through `agentUsageResult`, which removes the host-internal `workspaceId` and `retryAfterMs`. A sign-in email stays in `structuredContent`, as the contract allows, and out of the text.
- **Descriptions** of both tools say the data is local, list the providers configured when the server started, and say how to read stale (observed more than 5 minutes ago) and unavailable values; `usage_status` also covers snapshot and estimated values, and `usage_history` says a gap is not zero use.
- **Errors:** input that does not match a tool's schema returns `isError` with code `invalid_input` and the offending fields. A configuration that cannot be read, or a history file that exists but cannot be read or is not valid, returns `isError` with code `usage_unavailable` and a fixed message; the detail goes to stderr. No history file yet is an empty history. (The dashboard's `/api/history` still treats an unreadable file as empty.) A provider's failure is not a tool error: it appears in that account's `errors[]`, as in `status`.
- History exists only for the times the dashboard was open, because the dashboard records it as it reads usage.

The MCP server does not provide `ui://` view resources, write tools, or an HTTP transport. Behavior in a specific MCP host has not been verified yet.

## Data and permissions

- Configuration: `~/.config/subset/codex-profiles.json` (override with `SUBSET_USAGE_PROFILES_FILE`).
- Data: `~/.local/share/subset/` (override with `SUBSET_USAGE_DATA_DIR`): managed Codex homes, quota snapshots, usage history (times and percentages only), and the collector shim `bin/subset-usage-collect` (`bin/subset-usage-collect-<hash>` for a custom profiles file, so configurations sharing a data directory keep separate collectors).
- **Use local sign-ins** is off until you choose on the dashboard's first-run question. When on, the CLI reads, without changing or refreshing, the sign-ins Claude Code, Factory Droid, the Cursor app, Devin, Pi, OpenCode, omp, and Hermes keep on this computer, and calls the usage endpoints those tools use. Those endpoints are undocumented and may change. Tokens are never stored, logged, or sent to the page.
- Installing a collector edits that CLI's `settings.json` only when you ask, keeps a backup, and keeps your previous status line running.
- The local API accepts only same-origin requests carrying the dashboard's own header.

## Development

From the repository root, `npm run build` builds `@subset.dev/usage-core`, the `apps/usage` view, and this package: `dist/` (bundled with rolldown, no runtime dependencies) and `web/` (a copy of `apps/usage/dist`). `dist/cli.mjs` loads `dist/mcp-server.mjs`, which holds the MCP server and `@mcpfn/core`, only for `mcp`; code the two share is in `dist/common.mjs`. The build writes the name, version, licence and licence text of every bundled package to `dist/THIRD_PARTY_NOTICES.md`, which the package ships. `npm test --workspace=@subset.dev/usage` runs the CLI tests; `test/mcp.test.mjs` covers the MCP server with `@mcpfn/testing`'s in-memory client and with `subset-usage mcp` as a child process against a temp data directory. `npm run serve --workspace=@subset.dev/usage` runs the source without bundling.

## Release

Releases are tag-based. Bump `version` here, merge, then push a tag `usage-v<version>`; `.github/workflows/publish-tag.yml` installs, checks, builds, tests, packs, and publishes with the organization `NPM_TOKEN`. `scripts/resolve-release-tag.mjs` refuses a tag whose version or package name does not match. Verify the published package (`npx @subset.dev/usage@<version> --version`, then a real `serve`) before listing it as available anywhere.
