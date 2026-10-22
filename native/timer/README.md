# Timer (macOS daemon client)

`TimerCore` is the Swift library the Timer macOS menu bar app (SET-81) builds on. It is a native client of the per-user Timer daemon, the same one the `subset-timer` CLI, its MCP server and the web board use ([`@subset.dev/timer`](../../packages/timer-cli/README.md)). It runs the CLI with Node.js 22.13 or later (the CLI's `engines`) and does not bundle Node.

Status: the library builds and passes its tests. The menu bar app, its embedded CLI runtime and its Xcode project come in the next slice (SET-154). Nothing here is signed or released, and no surface is listed as available.

## Capability boundary

| | |
| --- | --- |
| Source of truth | The daemon's `state.json`, in `~/.local/share/subset/timer` (or `SUBSET_TIMER_DATA_DIR`). The library holds no timer state. It decodes what the daemon publishes and works out the time left from the timestamps. |
| Writes | Only through daemon operations (`POST /v1/ops/<name>`). The library never writes the store. |
| Network | None. It talks to the daemon over its Unix socket only. |

## Daemon client (TimerCore)

`TimerCore` is the Swift library under `Core/`. It uses Foundation and Network only, not AppKit:

- **`DaemonClient`** sends HTTP/1.1 requests over `daemon.sock` with `NWConnection` and a Unix endpoint. Each request opens its own connection (`Connection: close`) and is limited to 10 seconds. A missing or refusing socket is `DaemonError.notListening`. A daemon's error reply (`{ "error": { code, message } }`) becomes `.rejected`, or `.shuttingDown` for its 503. A board whose `schemaVersion` is not 1 is refused (`.unsupportedSchema`).
- **`HTTPResponseParser`** and **`ServerSentEventParser`** are incremental. They handle bodies with `content-length`, chunked bodies (the event stream), and frames split anywhere, including inside a CRLF or a UTF-8 character.
- **`EventSubscription`** keeps `/v1/events` open. When the stream ends or fails, it reconnects with exponential backoff (0.5 seconds doubling to 10). The wait resets once a connection succeeds. A stream that stays silent for 45 seconds (three missed heartbeats) is treated as dropped.
- **`DaemonLauncher`** starts `node cli.mjs daemon run` the way the CLI's own client does. The daemon runs in its own session (`POSIX_SPAWN_SETSID`), its output goes to `daemon.log` (keeping one previous log of up to 1 MiB), and `SUBSET_TIMER_DATA_DIR` is set. A client calls `ensureRunning` before it subscribes or runs an operation. If no daemon answers, `ensureRunning` launches one and waits up to 3 seconds for its socket.
- **Models** (`Models.swift`) are `Codable` types for the SET-74 contract, schema version 1. **`Projection`** and **`TimerFormat`** port `project`, `formatDuration` and `timerLine` from `@subset/timer`. Time left rounds up, so a countdown shows `0:01` until it ends.
- **`RuntimeLocator`** finds Node.js and then the CLI:
  - **Node.js:** `/opt/homebrew/bin/node`, then `/usr/local/bin/node`, then `command -v node` in the login shell (`$SHELL -ilc`, limited to 5 seconds), which covers nvm, fnm and similar managers. An older Node in one place does not hide a newer one elsewhere.
  - **CLI:** `SUBSET_TIMER_CLI_PATH` first, and an override that names a missing file is reported rather than skipped. Otherwise `timer-cli/dist/cli.mjs` in the app bundle's Resources.

## Build

```sh
npm ci && npm run build      # at the repository root; builds packages/timer-cli/dist/cli.mjs
cd native/timer
swift test                   # TimerCore tests (Command Line Tools are enough)
SUBSET_TIMER_CLI_PATH=$PWD/../../packages/timer-cli/dist/cli.mjs swift test   # adds the real-daemon test
```

## Verification

`swift test` covers:

- **HTTP parser:** replies with `content-length` and chunked streams, fed in pieces from 1 byte to whole, plus chunk extensions, streams that run until close, and malformed, truncated and oversized replies.
- **Server-sent events:** CRLF, CR and LF line endings, comments, multi-line data, frames without data, unknown fields, heartbeats, and frames split anywhere.
- **Reconnect:** backoff, the reset after connecting, and a stream that ends or fails.
- **Contract fixtures:** every file in `packages/timer/fixtures/contract-v1` decodes into the Swift models and re-encodes without loss. Every valid input survives the app's encoding.
- **Projection and formatting:** the Swift projection reproduces every fixture projection, and `TimerFormat.line` reproduces the agent result's text exactly. Also covered: time left from timestamps, the soonest-running choice, `until` countdowns, and duration parsing.
- **`RuntimeLocator` order:** checked with a fake file system and process runner.
- **Integration (only when `SUBSET_TIMER_CLI_PATH` is set):** launches a real daemon in a temporary folder, starts a Tabata over the socket, receives the `state` events, checks a rejected operation, and shuts the daemon down.

The **Timer macOS** workflow (`.github/workflows/timer.yml`, `macos-26`) runs `npm ci && npm run build`, then `swift test` with `SUBSET_TIMER_CLI_PATH` set.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) on 2026-10-22. Swift packages exist only for `authfn`, `datafn`, `filefn` and `searchfn`. None of them provides a Unix-socket HTTP client, a server-sent-event parser or a local daemon client. `mcpfn` is TypeScript and serves agents, not this client. **Package/version used: none.** No Superfunctions code was copied or linked.
