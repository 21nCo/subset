# Timer (macOS menu bar app)

**Timer** shows the running timer that ends soonest in the menu bar and lists every timer with its controls. From the menu you can start presets and countdowns and open the web board. It is a native client of the per-user Timer daemon, the same one the `subset-timer` CLI, its MCP server and the web board use ([`@subset.dev/timer`](../../packages/timer-cli/README.md)). The app embeds the CLI runtime, as [Minutes](../minutes/README.md) does, so it needs no separate `npm install`. **Node.js 22.13 or later must be installed** (the CLI's `engines`). The app does not bundle Node.

Status: builds and passes its tests. It is not signed or released, and no surface is listed as available. Using it on a real Mac and the visual review are deferred to SET-85, VoiceOver to SET-86, and the signed beta to SET-87. While it is allowed to post notifications, the app plays Timer's alerts itself (see [Alerts](#alerts)); the real permission prompt, audible sounds, visible notifications and the locked screen are checked in SET-85, not here.

## Capability boundary

| | |
| --- | --- |
| User outcome | See at a glance how long the next timer has left, and control every timer from the menu bar. |
| Source of truth | The daemon's `state.json`, in `~/.local/share/subset/timer` (or `SUBSET_TIMER_DATA_DIR`). The app holds no timer state. It shows what the daemon last published and works out the time left from the timestamps. |
| Writes | Only through daemon operations (`POST /v1/ops/<name>`). The app never writes the store. |
| Network | None. The app talks to the daemon over its Unix socket only. **Download Node.js** opens nodejs.org in the browser, and only when you choose it. |
| Not included | Launch at login, iOS, bundling Node.js, editing interval sequences (the web board does that), signing and releases. For alerts: Focus or Do Not Disturb overrides, critical alerts and custom sounds. |

### Menu

| Item | Effect |
| --- | --- |
| Status item | The running timer that ends soonest, as `m:ss` (`h:mm:ss` from an hour), counted from its timestamps. Stopwatches never end, so they are not shown there. When no timer is running, it shows the `timer` glyph from the app icon. |
| One row per timer | Name, state and time left, as the CLI prints them: for example `Tabata — running · round 3/8 · work · 0:12 left · next rest 0:10`. Its submenu has the controls that apply now: **Start** (idle), **Pause** or **Resume**, **Lap** (running stopwatches and countdowns with laps), **Skip** (running or paused interval timers), **Reset…** (not idle) and **Remove…**. Reset and Remove ask for confirmation first. |
| Start ▸ | The built-in presets, then the saved ones, from `GET /v1/presets`. Choosing one runs `start` with that preset. |
| New Countdown… | A small window with a duration field (`90s`, `25m`, `1h30m`, `1:30` or `1:02:03`, from 1 second to 24 hours, checked as the CLI checks it) and an optional name. **Start** stays disabled until the duration is valid, and the daemon's own errors appear in the window. The fields take the usual Command-X, C, V, A and Z. |
| Open Board | Runs `node cli.mjs serve --json`, which starts the local web board and opens it in the browser. While that server starts or runs, choosing Open Board again starts no second server; once it is serving, it reopens its URL. If `serve` fails, the app shows the CLI's error. Quitting the app stops the server. |
| About Timer | The standard About panel, with the Node.js and CLI the app uses, the socket path, the connection state, whether the app or the daemon plays alerts, and any timer state the app could not read, or the setup problem. |
| Daemon problems | While the event stream is down, the menu shows **Reconnecting to the Timer daemon…** and the error. A `state` event the app cannot read (another schema version or a malformed body) shows its error without that heading, until a readable one arrives. |
| Setup problems | Without a supported Node.js, the menu shows "Node.js 22.13 or later is required" and **Download Node.js from nodejs.org…**. A missing CLI shows its path. **Check Again** searches again. |

While the menu is closed, only the status item updates, about once a second, at the moment its shown second changes. While the menu is open, the timer rows update with it, and a row whose timer finishes gets the controls of a finished timer. Quitting the app does not stop the daemon or the timers.

## Alerts

When the app runs and may post notifications, it owns Timer's alerts; otherwise the daemon's own sink (`osascript` and `afplay`, see the [CLI alerts](../../packages/timer-cli/README.md#alerts)) plays them. Each alert plays exactly once, through the daemon's [alert handler protocol](../../packages/timer-cli/README.md#alert-handler).

- **Permission:** at launch the app asks for permission to post notifications. macOS shows the prompt only until the user answers; after that it returns their answer. The app checks again whenever it becomes active and whenever its menu opens, so a change in System Settings takes effect then. Outside an app bundle (`swift run`) there is no notification center, so the app leaves alerts to the daemon.
- **Ownership:** each `/v1/events` stream starts with a `subscriber` event. While permission is granted, the app registers that stream with `POST /v1/alert-handlers`, and when permission is revoked it unregisters with `DELETE`. A dropped stream is unregistered by the daemon. When the stream reconnects, the app registers the new stream. If another handler is already registered (409), the About panel says so, and the app tries again at the next check. A register or unregister request the daemon does not answer (a timeout or a dropped connection) may still have taken effect, so the app sends it again every 2 seconds and at each check until the daemon answers: a revoked app never stays the handler while its stream is open.
- **Ack, then play:** for each alert with `ackRequired`, the app first sends `POST /v1/alerts/<alertId>/ack`. It plays the alert only if the daemon answers 200. A 410 means the daemon already played it after 2 seconds without an ack, so the app plays nothing. A failed request is retried once; a repeated ack gets the same answer. Alerts without `ackRequired` belong to the daemon.
- **What plays:** the daemon sends each handed-over alert with its timer's name and `sound` as they were when it fell due, so a timer removed meanwhile still plays as itself (from a daemon that does not, the app takes them from its timers when the alert arrives). When the timer's `sound` is on, a tick plays Tink, a new step plays Pop and the finish plays Glass three times, one after another (`NSSound`, built-in sounds only). A finish or a `missedWhileAway` alert also posts a notification titled with the timer's name, with the daemon's wording ("Finished.", "Missed 3 alerts while away. Now: Work."). The notification uses the normal interruption level, so Focus applies, and has no sound of its own.
- **Actions:** **Restart** runs `reset`, then `start` (only if the reset succeeded), on the notification's timer, and shows a failure as any other operation's. An action that launches the app waits until Node.js and the CLI are found, then runs; if they are not found, it shows that setup problem. **Dismiss** just closes the notification.
- **About Timer** shows whether alerts are played by the app or by the daemon.

## Daemon client (TimerCore)

`TimerCore` is the Swift library under `Core/`. It uses Foundation and Network only, not AppKit:

- **`DaemonClient`** sends HTTP/1.1 requests over `daemon.sock` with `NWConnection` and a Unix endpoint. Each request opens its own connection (`Connection: close`) and is limited to 10 seconds. A missing or refusing socket is `DaemonError.notListening`. A daemon's error reply (`{ "error": { code, message } }`) becomes `.rejected`, or `.shuttingDown` for its 503. A board whose `schemaVersion` is not 1 is refused (`.unsupportedSchema`).
- **`HTTPResponseParser`** and **`ServerSentEventParser`** are incremental. They handle bodies with `content-length`, chunked bodies (the event stream), and frames split anywhere, including inside a CRLF or a UTF-8 character.
- **`EventSubscription`** keeps `/v1/events` open. When the stream ends or fails, it reconnects with exponential backoff (0.5 seconds doubling to 10). The wait resets once a connection succeeds. A stream that stays silent for 45 seconds (three missed heartbeats) is treated as dropped. Both it and `DaemonClient.openEvents` read only as their consumer asks. When the consumer stops reading, the bytes stay with the daemon, which keeps only the latest state for a subscriber that stops reading and drops one stalled for 30 seconds.
- **`DaemonLauncher`** starts `node cli.mjs daemon run` the way the CLI's own client does. The daemon runs in its own session (`POSIX_SPAWN_SETSID`), its output goes to `daemon.log` (keeping one previous log of up to 1 MiB), and `SUBSET_TIMER_DATA_DIR` is set. Before it writes anything, it checks the data folder as the CLI does: the folder must not be a symbolic link or belong to another user, and the socket path must be at most 103 bytes. It also tightens the folder to 0700. Before it subscribes or runs an operation, the app calls `ensureRunning`. If no daemon answers, `ensureRunning` launches one and waits up to 3 seconds, on a monotonic clock, for its socket. A daemon that is still shutting down makes the new one exit with "already running". Once that child has exited and no live process holds `daemon.lock`, `ensureRunning` launches again, at most 3 times in all.
- **Models** (`Models.swift`) are `Codable` types for the SET-74 contract, schema version 1. **`Projection`** and **`TimerFormat`** port `project`, `formatDuration` and `timerLine` from `@subset/timer`. Time left rounds up, so a countdown shows `0:01` until it ends.
- **`RuntimeLocator`** finds Node.js and then the CLI:
  - **Node.js:** `/opt/homebrew/bin/node`, then `/usr/local/bin/node`, then `command -v node` in the login shell (`$SHELL -ilc`, limited to 5 seconds), which covers nvm, fnm and similar managers. An older Node in one place does not hide a newer one elsewhere.
  - **CLI:** `SUBSET_TIMER_CLI_PATH` first, and an override that names a missing file is reported rather than skipped. Otherwise the bundled `Timer.app/Contents/Resources/timer-cli/dist/cli.mjs`.

## Build

```sh
npm ci && npm run build      # at the repository root; stages packages/timer-cli/app-runtime
cd native/timer
swift test                   # TimerCore, board and menu state tests (Command Line Tools are enough)
SUBSET_TIMER_CLI_PATH=$PWD/../../packages/timer-cli/dist/cli.mjs swift test   # adds the real-daemon test
ruby ProjectGenerator.rb     # after adding or removing a source file (xcodeproj gem 1.27.0); keeps your xcuserdata
xcodebuild -project Timer.xcodeproj -scheme Timer -configuration Release -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
swift scripts/render-icon.swift   # redraws the app icon
```

The `@subset.dev/timer` build stages `packages/timer-cli/app-runtime`, a link to a complete copy of `dist`, `web`, `mcp-app` and `skills` that the build never changes once published. It is not part of the npm package. The **Embed Timer CLI** build phase copies what the link names to `Timer.app/Contents/Resources/timer-cli`, and copies again if another build replaced it meanwhile. A Release build fails if it is missing. A Debug build warns, and that app then runs the CLI only from `SUBSET_TIMER_CLI_PATH`.

The app target is named `Timer` and its bundle ID is `dev.subset.timer` (`LSUIElement`, `MARKETING_VERSION` 0.1.0). Its Swift module is `TimerApp`, because a module named `Timer` would shadow Foundation's `Timer`. `macos-release.json` lists the npm workspaces a release builds before archiving: `@subset/timer`, `@subset/timer-web` and `@subset.dev/timer`. `@subset/timer-web` is there because the CLI build copies the built board from `apps/timer`.

## Verification

`swift test` covers:

- **HTTP parser:** replies with `content-length` and chunked streams, fed in pieces from 1 byte to whole, plus chunk extensions, streams that run until close, and malformed, truncated and oversized replies.
- **Server-sent events:** CRLF, CR and LF line endings, comments, multi-line data, frames without data, unknown fields, heartbeats, and frames split anywhere.
- **Reconnect:** backoff, the reset after connecting, and a stream that ends or fails.
- **Contract fixtures:** every file in `packages/timer/fixtures/contract-v1` decodes into the Swift models and re-encodes without loss. Every valid input survives the app's encoding.
- **Projection and formatting:** the Swift projection reproduces every fixture projection, and `TimerFormat.line` reproduces the agent result's text exactly. Also covered: time left from timestamps, the soonest-running choice, `until` countdowns, and duration parsing.
- **`RuntimeLocator` order:** checked with a fake file system and process runner.
- **Board process and menu state:** with a fake `serve`, Open Board while the server starts launches no second process, Quit stops it, and a `serve --json` failure shows the CLI's error. A `state` event the app cannot read (an unsupported schema or a malformed body) shows as its own problem, not as reconnecting, until a readable one arrives; a disconnect shows reconnecting until the stream connects again.
- **Alert handler (`AlertHandlerTests`, fake daemon):** the ack comes before the play; nothing plays after a 410, after a 409 or for an alert without `ackRequired`; a failed ack is retried once and plays only on the daemon's 200; the app registers only while permitted and unregisters when permission is revoked, after which it acks nothing; a new event stream is registered without unregistering the closed one; a refused registration is reported and retried at the next check; the daemon's alert JSON decodes.
- **Alerts in the app (`AlertTests`, fake notification center and sound player):** Tink, Pop and Glass ×3 by kind; notifications for the finish and missed alerts name the timer, or "Timer" for one the app has not seen; a timer with sound off only notifies; Restart runs `reset` then `start` and stops after a failed reset, and Dismiss runs nothing; through `TimerController`, the launch asks for permission, registers the stream from its `subscriber` event, acks before it plays, plays nothing after a 410, and unregisters and stops acking once permission is revoked; a denied app never registers.
- **Integration (only when `SUBSET_TIMER_CLI_PATH` is set):** launches a real daemon in a temporary folder, starts a Tabata over the socket, receives the `state` events, checks a rejected operation, and shuts the daemon down. A second run checks the alert handler routes against the real daemon: two streams get their subscriber ids, the second registration is refused 409, an ack within 2 seconds is accepted, and one sent after 2.5 seconds gets 410.

The **Timer macOS** workflow (`.github/workflows/timer.yml`, `macos-26`) runs `npm ci --ignore-scripts && npm run build`, `swift test` with `SUBSET_TIMER_CLI_PATH` set, the project-regeneration check, and an unsigned Release `xcodebuild`, then checks that the embedded runtime is present.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) on 2026-10-22. Swift packages exist only for `authfn`, `datafn`, `filefn` and `searchfn`. None of them provides a Unix-socket HTTP client, a server-sent-event parser or a local daemon client. `mcpfn` is TypeScript and serves agents, not this app. **Package/version used: none.** No Superfunctions code was copied or linked.
