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

`subset-usage mcp` is a local MCP server over stdio. It gives any MCP host the same answer as `status`, without the dashboard. Add it to a host as a stdio server whose command is `subset-usage` with the argument `mcp`. The server is `@mcpfn/core` 0.0.5 (`defineMcpFnServer`, `serveStdio()`), named `subset-usage` with the package version. Stdout carries only protocol frames; its one log line and any diagnostics go to stderr. It exits 0 when the host closes stdin, after answering the calls it already received. Calls get up to 10 seconds. Then the server stops: it ends the provider subprocesses still running (such as `claude auth status` or `amp usage`), and their calls are answered with that provider's error. On SIGTERM or SIGINT it stops the same way at once, and a second signal skips the grace period. Stopping sends SIGTERM first, so a launcher such as a shell script or Node entrypoint can end the provider it started, then SIGKILL to any subprocess still running a second later. A subprocess a read starts while the server stops is ended as it starts. At 5 seconds, any subprocess still running, including one started just before, gets SIGKILL, and the server waits up to half a second more for it and its call; stopping takes at most 5.5 seconds and exits 0. No subprocess a read started outlives the server, except after SIGKILL of the server, and except a process started by a launcher that does not pass SIGTERM on to it: one that ignores SIGTERM, or that dies of it without forwarding it (a shell script that does not `exec` the provider or trap the signal). Then only the launcher ends.

| Tool | Input | Result |
| --- | --- | --- |
| `usage_status` | `provider` (optional): one of the providers in the usage contract | The usage status (schema version 1) as `structuredContent`, and the plain-text summary `usageText` as text. With `provider`, only that provider's accounts (every account is still read, so the call takes as long as without it): those read through it, harness logins for its subscription, and cards it is also signed in to; `usageText` summarizes just those, and is `No usage accounts are configured.` when the provider has none. |
| `usage_history` | `hours` (optional, 1–168, default 48), `accountId` (optional, an id from `usage_status`) | The history points the dashboard stored in that range, as `/api/history` returns them (observation time in epoch milliseconds and used percent per account and window, oldest first), with the range as `from` and `to`, and a short text summary per window. The tool declares this envelope as its `outputSchema`, and the server validates each result against it. |

- **Read-only:** both tools have `readOnlyHint: true`. Neither writes anything: `usage_status` reads as `status` does (the signed-in default Claude account is shown without being saved, and no history is recorded), and `usage_history` only reads the history file. A Claude sign-in change is kept in the server's memory for the session, never in `claude-identities.json`, from the moment a read first observes it: snapshots collected before the change stay hidden, and those collected after it show on every later read, including reads already running. The session's identity periods only move forward. A later period the dashboard records in `claude-identities.json` applies when a read binds the account, and the session keeps it. A sign-in answer queried before one the session already has, which arrives late, starts no period, and its read does not show the snapshot under that answer's email. Only an account with no recorded sign-in (no `claude-identities.json`, or no entry for it) adopts the snapshots already collected when the session first sees it. If the file cannot be read or parsed, or the account's entry is malformed or starts later than the current time, the session keeps the periods it has; for an account it has none for, the period starts at that read, so the snapshots collected before it stay hidden and those collected after it show. The server never changes the **Use local sign-ins** setting; a read uses whatever the user chose on the dashboard.
- **Open world:** both tools have `openWorldHint: true`. With local sign-ins on, `usage_status` calls the usage endpoints of the tools signed in on this computer; `usage_history` reads only the history file, whose points came from those reads.
- **Least data:** results pass through `agentUsageResult`, which removes the host-internal `workspaceId` and `retryAfterMs`. A sign-in email stays in `structuredContent`, as the contract allows, and out of the text.
- **Descriptions** of both tools say the data is local, list the providers configured when the server started, and say how to read stale (observed more than 5 minutes ago) and unavailable values; `usage_status` also covers snapshot and estimated values, and `usage_history` says a gap is not zero use.
- **Errors:** input that does not match a tool's schema returns `isError` with code `invalid_input` and the offending fields. A configuration that cannot be read, or a history file that exists but cannot be read or is not valid, returns `isError` with code `usage_unavailable` and a fixed message; the detail goes to stderr. No history file yet is an empty history. (The dashboard's `/api/history` still treats an unreadable file as empty.) Because `usage_history` declares an output schema, its errors carry the code and message in the text only (`usage_unavailable: …`); `usage_status` errors also have them in `structuredContent.error`. A provider's failure is not a tool error: it appears in that account's `errors[]`, as in `status`.
- History exists only for the times the dashboard was open, because the dashboard records it as it reads usage.

The MCP server has no write tools and no HTTP transport. Behavior in a specific MCP host has not been verified yet.

## MCP App (SET-105)

In hosts with the MCP Apps extension (`io.modelcontextprotocol/ui`), a `usage_status` result opens the Usage dashboard inside the conversation: accounts, quota windows, reset times, freshness, the 48-hour trend charts and 7-day activity, and a Refresh button. Hosts without the extension ignore the view and get the same text and `structuredContent` as before; no result carries view data. `usage_history` returns no view.

- **Resource:** `ui://subset-usage/dashboard@1`, MIME type `text/html;profile=mcp-app`, made with `@mcpfn/core`'s `createMcpAppResource()` in `src/mcp-app.mjs`. Its `_meta.ui` has `prefersBorder: true` and a CSP with empty `connectDomains`, `resourceDomains` and `frameDomains`: the view loads nothing and reaches the server only through the host. The HTML is `mcp-app/dashboard.html`, which the package ships and the server reads on each `resources/read`. The URI is versioned: a breaking change to the view's props is `dashboard@2`, and `dashboard@1` keeps serving.
- **Tool metadata:** `mcpAppToolMetadata()` sets `_meta.ui.resourceUri` (visibility `model` and `app`) on `usage_status`, plus the older flat key `_meta["ui/resourceUri"]`, which `@modelcontextprotocol/ext-apps` also sets for hosts that read only that one. mcpfn's `assertMcpAppContracts()` checks the link when the server is declared.
- **Build:** `apps/usage/mcp-app.html` with `src/mcp-app.ts` is a second Vite entry (`vite.mcp-app.config.ts`) that inlines every script and style into one file, `apps/usage/dist/mcp-app/dashboard.html`, including the lazily loaded ECharts trend chart (`UsageTrend.svelte`): the dynamic import is bundled into the one script, so nothing loads later. The view uses the system font stack, not `@21n/fonts`. This package's build copies the file to `mcp-app/dashboard.html` (and leaves it out of `web/`), and `--check` refuses to pack without it. Measured on 2026-10-29: 815 KB (264 KB gzipped), under the 1.5 MB limit, so trend charts are on by default.
- **Bridge:** `apps/usage/src/mcp-bridge.ts`, JSON-RPC 2.0 over `postMessage` with the host window (protocol `2026-01-26`), the bridge Timer chose in SET-80: `@modelcontextprotocol/ext-apps` is not used, for the reasons in [Timer's MCP App notes](../timer-cli/README.md#mcp-app-set-80). Messages from any other source are ignored. It sends `ui/initialize` and `ui/notifications/initialized`, answers `ping` and `ui/resource-teardown`, and sends `ui/notifications/size-changed` as the content's height changes. The `structuredContent` of `ui/notifications/tool-result` becomes the dashboard's `status` once it passes `isUsageStatus`; an error result, a result that is not a usage status, or `ui/notifications/tool-cancelled` before any status, shows a message in place of the dashboard until a later result succeeds.
- **History:** once connected, the view calls `usage_history` with `hours: 168`, so the dashboard's 7-day activity and trend ranges have the points the server holds (48 hours is the trend charts' default range). A failed read leaves the trends empty.
- **Refresh:** only when the user presses Refresh; there is no polling. It calls `usage_status` with the `provider` of the agent's call (from `ui/notifications/tool-input`), so the view keeps showing the same accounts, then reads `usage_history` again. Every call fails after 15 seconds without a reply, so Refresh cannot stay busy. A failed Refresh keeps the dashboard and says why above the accounts. A reply that arrives after the host passed a newer tool result is dropped.
- **Read-only:** the view passes the dashboard none of its write props (`redeemReset`, `manageAccounts`, `openAccount`, `togglePin`), so it shows no Manage accounts, account menu, Fix or Set up link, or reset redemption. Percent mode is the dashboard's default (used). Sort and trend charts start at their defaults; a change is kept in the iframe's local storage when the host allows it, and otherwise lasts while the view is open.
- **Theme:** the host context's `theme` (`light` or `dark`, also from `ui/notifications/host-context-changed`) is set as `data-theme` and `color-scheme` on the page's root, which the dashboard and its charts follow; with none, `prefers-color-scheme` decides.
- **Tests:** `test/mcp-app.test.mjs` reads the resource, runs mcpfn's link validation, scans the built HTML for any `src`, `href` or `url(` that is not inline data or a fragment, `<script src>`, dynamic `import(` and leftover Vite placeholders, and drives the bridge with a fake host on `postMessage` over the real server: the initial render from the fixture status, Refresh calling `usage_status`, history loading, deadlines, teardown, and no write control in the server-rendered markup, checked against the dashboard's own control labels.
- **Excluded:** write controls, account management, clearing history, remote hosting, and ChatGPT's `window.openai` extras. Rendering inside real hosts is checked in SET-107, and visual, keyboard and focus checks in a running host in SET-37; neither is claimed here.

## Data and permissions

- Configuration: `~/.config/subset/codex-profiles.json` (override with `SUBSET_USAGE_PROFILES_FILE`).
- Data: `~/.local/share/subset/` (override with `SUBSET_USAGE_DATA_DIR`): managed Codex homes, quota snapshots, usage history (times and percentages only), and the collector shim `bin/subset-usage-collect` (`bin/subset-usage-collect-<hash>` for a custom profiles file, so configurations sharing a data directory keep separate collectors).
- **Use local sign-ins** is off until you choose on the dashboard's first-run question. When on, the CLI reads, without changing or refreshing, the sign-ins Claude Code, Factory Droid, the Cursor app, Devin, Pi, OpenCode, omp, and Hermes keep on this computer, and calls the usage endpoints those tools use. Those endpoints are undocumented and may change. Tokens are never stored, logged, or sent to the page.
- Installing a collector edits that CLI's `settings.json` only when you ask, keeps a backup, and keeps your previous status line running.
- The local API accepts only same-origin requests carrying the dashboard's own header.

## Development

From the repository root, `npm run build` builds `@subset.dev/usage-core`, the `apps/usage` view, and this package: `dist/` (bundled with rolldown, no runtime dependencies), `web/` (a copy of `apps/usage/dist`) and `mcp-app/dashboard.html` (the MCP App view). `dist/cli.mjs` loads `dist/mcp-server.mjs`, which holds the MCP server and `@mcpfn/core`, only for `mcp`; code the two share is in `dist/common.mjs`. The build writes the name, version, licence and licence text of every bundled package to `dist/THIRD_PARTY_NOTICES.md`, which the package ships. `npm test --workspace=@subset.dev/usage` runs the CLI tests; `test/mcp.test.mjs` covers the MCP server with `@mcpfn/testing`'s in-memory client and with `subset-usage mcp` as a child process against a temp data directory, from the source and from the built `dist/cli.mjs`, and `test/mcp-app.test.mjs` covers the MCP App view (so run `npm run build` first). `npm run serve --workspace=@subset.dev/usage` runs the source without bundling.

## Release

Releases are tag-based. Bump `version` here, merge, then push a tag `usage-v<version>`; `.github/workflows/publish-tag.yml` installs, checks, builds, tests, packs, and publishes with the organization `NPM_TOKEN`. `scripts/resolve-release-tag.mjs` refuses a tag whose version or package name does not match. Verify the published package (`npx @subset.dev/usage@<version> --version`, then a real `serve`) before listing it as available anywhere.
