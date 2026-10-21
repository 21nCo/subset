# @subset.dev/timer

The `subset-timer` command: countdowns, stopwatches and interval workouts (Tabata, EMOM, HIIT, Pomodoro, AMRAP and your own) for people and shell-capable agents, with sounds and notifications on macOS and Linux and an agent skill. Timers run in a per-user daemon on your computer, so they keep running after the command exits. Timer is local only: it opens no network connection and sends nothing anywhere.

> Status: prepared for npm as version 0.1.0, not yet published. The first release (`timer-v0.1.0`) is an owner decision after acceptance on a real Mac (SET-85 to SET-87). Install from a tarball or the repository until then. No Timer surface is listed as available.

## Use

Requires Node.js 22.13 or later on macOS or Linux (not Windows).

```sh
npm ci && npm run build                     # at the repository root
cd packages/timer-cli && npm pack           # builds and writes subset.dev-timer-0.1.0.tgz
npm install -g ./subset.dev-timer-*.tgz     # installs the subset-timer command
subset-timer start 25m --name Tea           # Tea (t_ab12cd34): running · 25:00 left / Ends at 17:25:00.
subset-timer start tabata
subset-timer                                # one line per timer
```

After a release, `npx @subset.dev/timer` and `npm install -g @subset.dev/timer` work too.

| Command | What it does |
| --- | --- |
| `list` (default) | One line per timer, the SET-74 agent text, or with `--json` the agent result `{ structuredContent, text, viewId }`. Reads only, but starts the daemon if needed. |
| `status <ref>` | One timer: its line and, while it runs, when it ends; `--json` gives the `get` result `{ timer, observedAt }`. |
| `start <spec>` | Creates and starts a timer. `<spec>` is a duration (`90s`, `25m`, `1h30m`, `1:30` as m:ss, `1:02:03` as h:mm:ss; 1 second to 24 hours; a bare number is refused because its unit would be a guess), `stopwatch`, a preset id or name (`tabata`, `emom`, `hiit` for `hiit-40-20`, `pomodoro`, `amrap`, or a saved one, ignoring case), `interval --work 40s [--rest 20s] --rounds 10 [--prep 10s] [--cooldown 60s]`, or the id of an idle timer (to run it again after `reset`). `--until 17:30` (or `17:30:15`, or an ISO time with an offset) instead of a spec counts down to the next such local time. `--name N` names it; `--no-sound` turns its sounds off (for a preset, the CLI sends the preset's timer with `sound: false`). |
| `pause`, `resume`, `lap`, `skip`, `reset`, `rm` `<ref>` | The SET-74 operations of the same names (`rm` is `remove`). `reset` and `rm` are destructive: the agent skill runs them only at the user's explicit request. |
| `presets` | Built-in and saved presets, one line each, or `{ presets }`. |
| `preset save <name>` | Saves an interval preset from `--work`, `--rest`, `--rounds`, `--prep`, `--cooldown` and `--no-sound`. |
| `preset rm <ref>` | Removes a saved preset; a built-in one is `invalid_state`. |
| `daemon run` | Runs the daemon in the foreground with the platform's alert sink. Other commands start it this way, detached, when it is not running. |
| `daemon status` | `pid`, `data dir`, `socket`, `alerts` (the sink: `macos`, `linux (…)`, `unavailable` or `off`) and `started`. Never starts a daemon; when none runs it reports `daemon_unavailable` (exit 3). |
| `daemon stop` | Asks the daemon to shut down and waits up to 5 s for it to go. Timers keep their timestamps and continue when it starts again. |
| `skill path` | The absolute path of the bundled `skills/subset-timer` folder. |
| `mcp` | Runs the MCP server on stdin and stdout for an MCP host until the host closes stdin, then exits 0. See [MCP server](#mcp-server-set-79). |
| `serve` | Serves the Timer board on `http://127.0.0.1:4175` (or the next free port) and opens it in the browser, until Ctrl-C. `--port <n>` requires that port (a taken one is exit 2); `--no-open` only prints the URL; `--json` prints `{ url, port }`. See [Web host](#web-host-set-78). |
| `--help`, `--version` | |

- **`<ref>`:** an exact id, else a unique name ignoring case. Several matches are `ambiguous` (exit 2) and list the candidates (`candidates` in JSON).
- **Exit status:** 0 ok, 2 invalid input or ambiguous, 3 daemon unavailable (also when it could not save a change), 4 not found, invalid state or a limit reached.
- **`--json`:** the result as one line of JSON on stdout; a failure is `{ "error": { "code", "message" } }` on stdout too, with `issues` for invalid input and `candidates` for an ambiguous ref. Without `--json`, failures go to stderr as `subset-timer: <message>`.

## Alerts

`daemon run` picks a sink implementing the `AlertSink` below:

| Platform | Sink | Sound (only when the timer's `sound` is on) | Notification |
| --- | --- | --- | --- |
| macOS, with `/usr/bin/afplay` and `/usr/bin/osascript` | `macos` | `afplay` with the built-in `Tink` for ticks, `Pop` for a new step, `Glass` three times for the finish | `osascript` for the finish and for alerts missed while away |
| Linux, with `notify-send` on `PATH`, or `paplay` there and at least one of its sound files | `linux (notify-send, paplay)` | `paplay` with the freedesktop theme's `audio-volume-change`, `message` and `complete` (×3) sounds, when the files exist | `notify-send` for the finish and missed alerts |
| Anything else | `unavailable` | none | none |

`SUBSET_TIMER_ALERTS=off` selects a silent sink named `off`. Sinks start each tool with an argument array and never through a shell, play only those fixed system sound files (no path comes from a timer or a user), and stop a tool after 10 s. A timer's name reaches `osascript` only as an `argv` item of a fixed `on run argv` script, after `--`, so it is never part of the script text or read as an option; `notify-send` gets it after `--` as well.

## Agent skill

`skills/subset-timer/SKILL.md` teaches a shell-capable agent when to use Timer, to always pass `--json`, to report the timer id and end time, that timers keep running after its turn, that `reset` and `rm` need the user's explicit request, and that `serve` is only for a user who asks for the browser board and does not exit by itself. `subset-timer skill path` prints its folder, for example to copy or link it into an agent's skills directory. Its use by a real agent is checked in SET-84.

## Web host (SET-78)

`subset-timer serve` is the standalone local web surface: the board from `@subset/timer/view` in the private Vite app `apps/timer` (`@subset/timer-web`), whose build `scripts/build.mjs` copies into `web/`. It is not a deployed site. `src/serve.mjs` holds no timer state; it serves `web/` and proxies to the daemon socket with the same client as every other command, so the first page request starts the daemon if it is not running, and a page left open keeps it from idling out.

- **Listening:** `127.0.0.1` only, never `0.0.0.0` or `::`, whatever the flags. Port 4175, else each next port up to 20 tries; `--port <n>` takes only that port. Ctrl-C or SIGTERM ends the open event streams and connections and exits 0; the daemon and its timers keep running.
- **API:** `GET /api/timers` and `GET /api/presets` relay `/v1/timers` and `/v1/presets`; `POST /api/ops/<operation>` relays a known operation's JSON body (up to 1 MiB) to `/v1/ops/<operation>`; `GET /api/events` relays the daemon's `state` and `heartbeat` events (alerts stay with the daemon). The daemon's status and body pass through unchanged. A daemon that cannot be reached or started is `503 daemon_unavailable`, a body that is not JSON `400 invalid_input`, an unknown operation or path `404`, another method `405`.
- **Guard:** a request must name the server as its `Host` (`127.0.0.1:<port>` or `localhost:<port>`), else 403. `/api/*` also needs the header `X-Subset-Timer: 1`, an `Origin`, if any, equal to the server's, and no `Sec-Fetch-Site` of `cross-site` or `same-site`; a `POST` must carry the server's `Origin`. Anything else gets 403. The server sends no CORS headers, so a cross-origin page can neither send the header (its preflight is refused) nor read a reply. Responses are `no-store` with a `default-src 'self'` Content Security Policy and `frame-ancestors 'none'`.
- **Page:** titled "Timer" with a favicon. It mounts `TimerBoard` with `capabilities: { create: true, destructive: true }` (the person at the keyboard is the user) and `density: 'full'`; each action is a `POST /api/ops/<operation>`, and a 503 counts as the action not reaching the daemon. The state comes from `/api/events`. Because `EventSource` cannot send the required header, the page reads the event stream with `fetch`. While the stream cannot be opened, or has ended or been silent for 45 s (three heartbeats), the page shows "Daemon unavailable — retrying…" and reopens it after 1 s, doubling to at most 15 s, back to 1 s once a state arrives.
- **Excluded:** alerts in the browser, Web Push, a service worker, PWA install, any deployment, auth and MCP.

## MCP server (SET-79)

`subset-timer mcp` is a local MCP server over stdio for any MCP host. It is a client of the daemon like every other command: it holds no timer state, starts the daemon on the first tool call if it is not running, and exits 0 when the host closes stdin, while the daemon and its timers keep running. Stdout carries only protocol frames; its one log line and any diagnostics go to stderr. The server is `@mcpfn/core` 0.0.5 (`defineMcpFnServer`, `serveStdio()`), named `subset-timer` with the package version.

| Tool | Class | Input |
| --- | --- | --- |
| `timer_list` | read-only | none |
| `timer_get` | read-only | `id` |
| `timer_presets` | read-only | none |
| `timer_start` | write | exactly one of `preset` (id, or a unique name ignoring case, or `hiit` when no saved preset has that name, resolved as `start <spec>` does), `durationSeconds`, `until` (`HH:MM`, `HH:MM:SS` or ISO 8601 with an offset), `stopwatch: true` and `interval { work, rest?, rounds, prep?, cooldown? }` or `interval { segments: [{ phase, seconds, label? }], rounds, prep?, cooldown? }`, with optional `name`, `sound`, `ticks` and (countdowns only) `laps`; or `id` alone, which starts an idle timer (one that was reset) as it is |
| `timer_pause`, `timer_resume`, `timer_lap`, `timer_skip` | write | `id` |
| `timer_reset`, `timer_remove` | destructive | exactly one of `id` and `name` (a unique timer name, ignoring case) |
| `timer_preset_remove` | destructive | exactly one of `id` and `name`; a built-in preset is `invalid_state` |
| `timer_preset_save` | write | `name`, the interval fields above at the top level, optional `sound` |

- **Schemas:** ids, names, labels, phases and rounds use the SET-74 `schemas`; durations are whole seconds from 1 to 86,400. Every input schema is an object with `additionalProperties: false` and no top-level `oneOf`, `anyOf`, `allOf` or `not`, which some hosts refuse, so the tools check "exactly one of" themselves.
- **Annotations:** `readOnlyHint: true` on the three reads, `destructiveHint: true` on `timer_reset`, `timer_remove` and `timer_preset_remove` (false on the other writes), and `openWorldHint: false` on all. The server adds no confirmation of its own; hosts apply their approval to write tools. Each description says that timers run locally and keep running after the conversation ends and asks the model to report the timer id and end time (the preset tools ask for the preset id, then the timer id and end time once a timer starts from it); the destructive ones say to run them only at the user's explicit request.
- **Results:** `timer_list` returns the SET-74 agent result as `structuredContent` and its text. `timer_get` returns the same shape holding only that timer. A timer write returns the agent result read after the operation plus `affectedTimerId`, with text that starts with the change and, while the timer runs, when it ends (`Started Tea (t_ab12cd34). Ends at 17:25:00 (2026-10-21T17:25:00+02:00).`), then the board's lines. The preset tools return `{ presets }` (plus `affectedPresetId` on writes) and one line per preset.
- **Errors:** `isError: true`, with `<code>: <message>` as text and `structuredContent.error` `{ code, message, issues?, candidates? }`. Codes are SET-74's (`invalid_input`, also for input that fails the schema, with SET-74 style `issues` such as `{ path: "durationSeconds", message: "must be >= 1" }`; `not_found`; `invalid_state`; `limit_reached`), `ambiguous` for a name that matches several timers or presets, and the daemon's (`daemon_unavailable`, `storage_failed`, `internal`). A daemon that cannot be reached or started gets a fixed message; the detail, which names the data directory, goes to stderr. When a write succeeded but reading the board afterwards failed, the error's message starts with the change that was made and carries `affectedTimerId` (or `affectedPresetId`), so the model does not repeat it.
- **Ids, not paths:** the model receives timer and preset ids, never the data directory, the socket or any other path.
- **Excluded:** remote or HTTP transport, auth and any hosted server. The `ui://` board view is the [MCP App](#mcp-app-set-80) below.

### Host configuration

The host starts the command, so `subset-timer` must be on the `PATH` the host sees (or give its absolute path, from `which subset-timer`). Claude Desktop (`claude_desktop_config.json`):

```json
{ "mcpServers": { "subset-timer": { "command": "subset-timer", "args": ["mcp"] } } }
```

VS Code (`.vscode/mcp.json` in a workspace):

```json
{ "servers": { "subset-timer": { "type": "stdio", "command": "subset-timer", "args": ["mcp"] } } }
```

The macOS app (SET-81) will bundle a copy of the CLI; the path of that copy for the `command` is documented once SET-81 ships it. Use in real hosts is checked in SET-84, not here.

## MCP App (SET-80)

In hosts with the MCP Apps extension (`io.modelcontextprotocol/ui`), the results of `timer_start`, `timer_list` and `timer_get` open the Timer board inside the conversation: the SET-75 board with live countdowns and working controls, each of which calls the server's tools through the host. Hosts without the extension ignore the view and get the same text and `structuredContent` as before; no result carries view data.

- **Resource:** `ui://subset-timer/board@1`, MIME type `text/html;profile=mcp-app`, made with `@mcpfn/core`'s `createMcpAppResource()` in `src/mcp/app.mjs`. Its `_meta.ui` has `prefersBorder: true` and a CSP with empty `connectDomains`, `resourceDomains` and `frameDomains`: the view loads nothing and reaches the server only through the host. The HTML is `mcp-app/board.html`, the single-file build of `apps/timer/mcp-app.html` (every script and style inlined, no `src` or `href`), which the package ships and the server reads on each `resources/read`. The URI is versioned: a breaking change to the view's props is `board@2`, and `board@1` keeps serving.
- **Tool metadata:** `mcpAppToolMetadata()` sets `_meta.ui.resourceUri` (visibility `model` and `app`) on `timer_start`, `timer_list` and `timer_get` only, plus the older flat key `_meta["ui/resourceUri"]`, which `@modelcontextprotocol/ext-apps` also sets for hosts that read only that one. Pause, resume, lap, skip, reset, remove and the preset tools return no view. mcpfn's `assertMcpAppContracts()` checks every link when the server is declared.
- **Bridge:** `apps/timer/src/mcp-bridge.ts`, JSON-RPC 2.0 over `postMessage` with the host window (protocol `2026-01-26`); messages from any other source are ignored. It sends `ui/initialize` and `ui/notifications/initialized`, answers `ping` and `ui/resource-teardown`, and sends `ui/notifications/size-changed` as the content's height changes. The `structuredContent` of `ui/notifications/tool-result`, without a write's `affectedTimerId`, is the board's `result`: the view receives nothing that is not in the agent result (no paths, pid or data directory). A tool result that is an error, or `ui/notifications/tool-cancelled`, is shown in place of the board.
- **Actions:** `actions.invoke(operation, input)` is a `tools/call`: `pause`, `resume`, `lap`, `skip`, `reset`, `remove` and `get` call the tool of that name with `{ id }`; `start` (an idle timer) calls `timer_start { id }`; `create` calls `timer_start` with the create form's timer in the tools' terms (seconds, `laps`, `ticks`), so a timer made in the view starts at once, and a duration with a fraction of a second fails in the view without a call; `list` calls `timer_list` and `presets.list` `timer_presets`. The tool's result becomes the operation's (`{ timer, observedAt }` from the board the tool read after the change, `{ removedId, observedAt }` for remove), which the board checks against the SET-74 contract; a tool error is the action's inline error, and a call the host refuses (a declined approval) fails with the host's reason. Destructive tools still go through the host's approval, and the board asks for its own second press first.
- **Refresh:** every 10 s while the view can be seen, the bridge reads `timer_list` into `result`; the board itself reads `timer_list` after each action. While the page is hidden or the view is scrolled out of sight, refresh stops, and it reads once at once when shown again; countdowns project from their timestamps throughout. After `ui/resource-teardown` nothing more is read or sent. A failed read keeps the board and says so above it.
- **Board settings:** `density: 'compact'`, `capabilities: { create: true, destructive: true }`. Alerts stay with the daemon; the view plays no sounds and shows no notifications.
- **Theme:** the host context's `theme` (`light` or `dark`, also from `ui/notifications/host-context-changed`) is set as `data-theme` and `color-scheme` on the page's root, which the board's palette follows; with none, `prefers-color-scheme` decides.
- **ext-apps evaluation:** `@modelcontextprotocol/ext-apps` 2.0.3's `App` has the bridge this needs (connect, tool input and result, `callServerTool`, host context, auto-resize), but it is not used. Its entry imports `@modelcontextprotocol/core` and `@modelcontextprotocol/client` 2.x (required peer dependencies, the MCP SDK under its 2.x names) and `zod`; adding them would add the SDK directly, which this package does not do, and its `app-with-deps` build that inlines them is 418 KB minified, more than twice the whole board view. The view needs four host messages and one request, so `mcp-bridge.ts` implements those from the published specification, with the same message shapes, source check and size measurement as ext-apps.
- **Excluded:** remote or HTTP hosting, ChatGPT's `window.openai` extras, A2UI and AG-UI adapters, and alerts in the iframe. Rendering and actions inside Claude Desktop and VS Code are checked in SET-84, not here.

## Release

`release-packages.json` lists the package as `timer` with inputs `packages/timer-cli`, `packages/timer` and `apps/timer`. Setting `private: false` and that entry publish nothing: a live release is a pushed `timer-v<version>` tag, and the beta pipeline skips an npm package that was never released. Verify the published package (`npx @subset.dev/timer@<version> --version`, then a real timer with sound and notifications) before listing it anywhere.

## Daemon (SET-76)

### Data directory

`~/.local/share/subset/timer`, or `SUBSET_TIMER_DATA_DIR`. The daemon creates it with mode `0700` (tightening an existing one) and refuses a directory another user owns, a symbolic link, or a path too long for a Unix socket (103 bytes for `daemon.sock`).

| File | Purpose |
| --- | --- |
| `state.json` | The SET-74 store (schema version 1). Each write goes to a temp file beside it (looping until every byte is written; a failed or short write removes the temp file, keeps the old file and fails the operation), is fsynced and renamed over it, and the directory is fsynced (once the rename succeeded, a failed directory fsync is logged and the change stands). A file that is not JSON or fails `parseStore` is moved to `state.corrupt-<epoch ms>.json`, logged, and the daemon starts with no timers. Temp files a crash left are removed at start. |
| `scheduler.json` | `{ version: 1, marks }`: for each running stretch, the time through which its alerts were delivered. It is written after each delivery (a save that fails is retried at every later run, at least once a minute), and before `state.json` whenever an operation begins a stretch (start, resume or skip), so a restarted daemon, even one killed mid-operation, neither repeats what a saved mark covers nor reports it as missed. Delivery is at least once: a daemon killed after an alert reached the sink but before its mark was saved delivers it again, or reports it as missed, after the restart. A mark for a stretch that never began is dropped. |
| `daemon.lock` | Created exclusively, holding the pid, a random token of this acquisition and the process birth. |
| `daemon.sock` | The socket, mode `0600`. It is bound under a short temporary name (`.ds-<hex>`) and renamed into place. |
| `daemon.log` | The output of a daemon a client started (one previous log of up to 1 MiB is kept as `daemon.log.1`). |

### Single writer

- A daemon takes `daemon.lock` before reading `state.json`. A second daemon exits with code 3 and `already running (pid N)`.
- The pid, token and birth are written and fsynced to a file of their own, which is then hard-linked to `daemon.lock` (the link fails when the lock exists), so nobody ever sees the lock empty or half written. A failed write leaves no lock. The token, not the pid or inode, tells one acquisition from the next: a daemon in the same process, or a new file given the inode of a removed one (as Linux often does), is a different holder.
- A holder's birth is a string fixed for the life of its process that a process later given the pid does not share: on Linux the boot id and the start time in clock ticks since boot (`/proc/<pid>/stat` field 22), elsewhere the start `ps -o lstart` reports (recorded by the kernel at fork, to the second, read in UTC). A holder is gone when its pid is not alive, or when the live process with that pid was born otherwise: the system gave the pid of a holder that died to another process. Births are only compared for equality; the wall clock, file times and ages play no part, so setting the clock either way never makes a live holder look gone. When either birth cannot be read, the holder is taken to be alive. Errors only ever keep a lock: a pid that macOS gives to another process within the same second as its holder started reads as the same birth, so that lock is kept until the other process exits, and never has two holders.
- A lock whose holder is gone, or that holds no valid pid, is stale and replaced at once. Every removal of the lock (a takeover or a release) is made holding `daemon.lock.takeover.<generation>`, a marker for that one lock file (its token, or a digest of its content when it has none), created the same way and naming its process. The holder checks that the lock is still that generation and removes it. Generations are never reused and only the marker's holder can end one, so whatever another process saw earlier, it can never remove or replace the lock between that check and the removal, and processes starting or releasing together never remove a lock another has just taken. A marker is abandoned only when its process is gone (as above); a live process stopped mid-takeover keeps it however long, so nobody acts in its place. An abandoned marker is removed the same way, under the marker for its own generation. Every marker sits beside the lock under that one name, so names keep the same bounded length however many processes died while removing abandoned markers, and the whole chain is followed and recovered at once. A marker for a generation that no file holds is never acted on again; those and the files a crashed process left beside the lock are removed by the next daemon that takes it. A daemon that removes a stale lock always tries to create its own, and exits 3 only for a live holder, or when another process kept a takeover for 1 s.
- A live daemon keeps its lock however old it is, whether or not its socket is there and however the wall clock moves.
- Before every write, before removing leftover sockets at startup, before publishing its socket, and on every scheduler run (at least once a minute), heartbeat and request, the daemon checks that `daemon.lock` still holds its token. One that lost it never writes, publishes or alerts again: it ends its event streams, answers `503 daemon_unavailable` and exits 1, or, still starting, removes only its own bound socket and exits 1.
- A daemon removes the lock on exit only while it still holds its token, and the socket only while it is still the file it bound.

### Socket API

HTTP/1.1 with JSON bodies over `daemon.sock` only; there is no TCP listener and no token. Only the owning user can reach the socket (`0600` in a `0700` directory).

| Route | Result |
| --- | --- |
| `GET /v1/timers` | The SET-74 agent result `{ structuredContent, text, viewId }`. |
| `GET /v1/presets` | `{ presets }`, built-ins first. |
| `POST /v1/ops/<operation>` | Runs a SET-74 operation (`create`, `start`, `pause`, `resume`, `lap`, `skip`, `reset`, `remove`, `list`, `get`, `presets.list`, `presets.save`, `presets.remove`) on the JSON body; an empty body means `{}`. 200 with the operation's result, or `{ error: { code, message, issues? } }`: 400 `invalid_input` (also for a body that is not JSON), 404 `not_found` (also for an unknown operation or route), 409 `invalid_state` or `limit_reached`, 405 for another method, 413 for a body over 1 MiB, 500 `storage_failed` when the change could not be saved (it is then not applied). |
| `GET /v1/events` | Server-sent events: `state` (the agent result, once on connect and after every change), `alert` and `heartbeat` (`{ at }` every 15 s). |
| `GET /v1/daemon` | `{ pid, dataDir, socket, alerts, startedAt }`, where `alerts` names the sink. |
| `POST /v1/shutdown` | Answers `{ ok: true }`, then removes the socket and lock and exits 0. |

The daemon saves a change before it answers or sends `state`, so nothing reports a change the disk does not hold. A request that reaches a daemon that is shutting down or has lost its lock is not applied and is answered `503 daemon_unavailable` before its connection closes (connections still open 1 s into shutdown are closed then).

A subscriber that has not yet drained a frame, however large, gets the frames after it once it does: the latest `state` and `heartbeat` (an older queued one is replaced) and every `alert`, in order. One that leaves a frame undrained for more than 30 s (measured on a monotonic clock, so a changed wall clock moves it neither way), or queues more than 1 MiB of alerts, has stopped reading and is dropped. Destructive operations are not gated here: hosts must have the user's explicit request before sending `reset`, `remove` or `presets.remove` (see `OPERATION_WRITE_CLASS`).

### Alerts and the scheduler

An `alert` is `{ timerId, kind, at, segment?, secondsLeft?, missed? }`, where `kind` is `segment` (an interval step began; `segment` is that step), `tick` (`secondsLeft` 3, 2 or 1 before a step or countdown ends, when `countdownTicks` is on), `finish`, or `missedWhileAway`.

- The scheduler arms one timeout for the earliest upcoming transition across running timers, from SET-74 `transitionsBetween`, and looks again at least every 60 s so a changed wall clock is noticed. It re-arms after every change. Before a change it delivers the alerts already due against the timers as they were.
- Each running stretch (from a start, resume or skip) has a mark: the time through which its transitions were handled. An operation and the scheduler runs around it use one reading of the clock, and a new stretch is marked from that moment, so a skip never fires what it jumped over. Each run handles the transitions since each mark. Those more than 2 s late, for example after sleep or while the daemon was not running, collapse into one `missedWhileAway` alert per timer (`missed` counts them; `segment` is the current step), ahead of the ones on time. The timer's state is computed from its timestamps as always.
- The next timeout is armed from each mark rather than from the clock after the run, so a transition that falls due while a run delivers and saves fires as itself at once.
- A mark only moves forward, so after the clock is set back nothing fires twice; what is still ahead fires once the clock reaches it. A stretch begun after the step back is marked from its own start.
- When a timer finishes the daemon records it as finished and sends `state`. If that save fails it is retried at every later run (at least every 60 s), and the idle exit is re-evaluated after each run.
- Restarting keeps a running timer running from its timestamps; nothing is paused automatically.

An `AlertSink` is `{ name, alert(alert, timerDefinition) }`. The daemon never waits for it, and a sink that throws or rejects is logged and ignored. A sink honours the timer's `sound` flag. `startDaemon` defaults to `createRecordingSink()`, which records alerts in memory, keeping only the latest 1,000 (`RECORDING_LIMIT`, or its `limit`) however long the daemon runs; `subset-timer daemon run` passes the platform sink (see Alerts).

A real computer's timers stop while it sleeps, so after a wake the daemon notices within 60 s at the latest (earlier when a transition was due sooner). Real sleep and wake on a Mac is checked in SET-85.

### Idle exit

After 10 minutes with no running or paused timer, no `/v1/events` subscriber and no request, the daemon removes its socket and lock and exits 0. It does not start at login; a client starts it on first use.

### Client

`createClient({ dataDir?, cliPath?, spawn? })` from `src/daemon/index.mjs` connects to the socket. When the socket is missing or refuses, it spawns `node <cliPath> daemon run` detached and unreferenced (its output goes to `daemon.log`), and waits up to 3 s, measured on a monotonic clock, for the socket, retrying its read-only probe after any socket error until then. A daemon that answers `503 daemon_unavailable` is shutting down and did not run the request: the client waits for it to release the lock, starts a new daemon (respawning one that exited because the old lock was still held) and sends the request there. Otherwise it rejects with a `DaemonUnavailableError` whose `code` is `daemon_unavailable`. The CLI passes its own file (`src/cli.mjs`, or `dist/cli.mjs` when installed) as `cliPath`; it defaults to `src/daemon/main.mjs`, which only runs `daemon run`. The client offers `request`, `op`, `timers`, `presets`, `events`, `status` and `shutdown`; `status` and `shutdown` never start a daemon.

`startDaemon({ dataDir, clock, sink, log })` runs a daemon in-process, and `runDaemonCommand({ sink })` is the foreground `daemon run`. `clock` is `{ now, monotonic, setTimeout, clearTimeout }`: production uses `Date.now()`, `performance.now()` and `setTimeout`; `createFakeClock()` keeps timeouts on a monotonic timeline apart from the wall clock, as Node does, for tests.

Excluded: TCP on the daemon itself (`serve` and `mcp` are separate processes that are its clients), launchd and Windows named pipes.

## Superfunctions

The SET-73 reuse check (see `packages/timer/README.md`) covers this package. The daemon is local process infrastructure (a Unix socket, a lock file and a JSON file), which no Superfunctions package provides; it uses only Node.js built-ins and `@subset/timer`. The CLI parses arguments with Node's `util.parseArgs` and the sinks run the platform's own tools; no Superfunctions package covers either. The MCP server uses `@mcpfn/core` 0.0.5 for the tool registry, input validation and the stdio transport, and for the MCP App resource and tool metadata (`createMcpAppResource`, `mcpAppToolMetadata`, `assertMcpAppContracts`), and its tests use `@mcpfn/testing` 0.0.5 (the in-memory `McpFnTestClient`, `assertManifestContract` and `validateMcpFnSchemaPortability`); the package does not depend on `@modelcontextprotocol/sdk` directly. The gap the SET-73 check recorded stands: mcpfn bundles SDK 1.29.0, while 1.32.1 is current. The build bundles `@subset/timer`, `zod` and `@mcpfn/core` (with the SDK it inlines, Ajv and `@cfworker/json-schema`) with `rolldown` 1.2.11, as `@subset.dev/usage` does, so both are development dependencies and the published package still installs nothing: `dist/cli.mjs` loads `dist/mcp-server.mjs` only for `subset-timer mcp`, and code the two share is in `dist/common.mjs`. The build writes the name, version, licence and licence text of every bundled package (MIT, and BSD-3-Clause for `fast-uri`) to `dist/THIRD_PARTY_NOTICES.md`, which the package ships.

## Verification

`npm test --workspace=@subset.dev/timer` builds `dist/cli.mjs`, copies the built board (run `npm run build --workspace=@subset/timer-web` first, which also writes `mcp-app/board.html`) and runs `node --test test/daemon/*.test.mjs test/cli/*.test.mjs test/serve.test.mjs test/mcp/*.test.mjs` with temporary data directories against a real socket. CI runs it in **Verify** on Linux; it also runs on macOS. The CLI tests (`test/cli`) cover:

- **Durations:** the parser table (`90s`, `25m`, `1h30m`, `1:30`, `1:02:03`, the 1 s and 24 h bounds) and invalid forms (bare numbers, `1h30`, units out of order or repeated, decimals, negatives, `1:60`), and `--until` today or tomorrow.
- **Commands:** with the SET-74 fixture store loaded into an in-process daemon (fake clock, recording sink), `list`, `status`, `start`, `pause`, `resume`, `lap`, `skip`, `reset`, `rm`, `presets` and `preset rm` print the fixture's text and, with `--json`, the fixture's result; daemon refusals keep the fixture's code and message. `start` covers each `<spec>` form, aliases, `--no-sound` (which reaches the sink as the timer's `sound`) and `--until`; `preset save`; `daemon status`, `daemon stop`, `daemon run`, `skill path`, `--help` and `--version`.
- **`<ref>` and exit codes:** exact ids, unique names ignoring case, `ambiguous` with its candidates for timers and presets, and exit statuses 0, 2, 3 (a daemon that cannot start, and `daemon status` with none) and 4.
- **Skill:** `--help` lists every command `SKILL.md` uses and `SKILL.md` uses only commands that exist, with the rules the skill must state.
- **Sinks:** a recording `spawn` shows each name of the closed injection set (`"`, `\`, `'`, `$( )`, backticks, `;`, newlines, 60 emoji, `end tell`, `do shell script`, `-e`, `--`) reaching `osascript` only as an argv item after `--` of the fixed script, and `notify-send` after `--`, never through a shell; only the fixed sounds play, none with `sound` off; a failing or hanging tool rejects and is stopped; the silent sink is chosen when the tools are absent or the platform is neither macOS nor Linux.
- **Package:** the manifest, the release entry, a bundle importing only Node built-ins and its own chunks (only `subset-timer mcp` loading the MCP runtime), `node dist/cli.mjs --version` printing 0.1.0, `dist/THIRD_PARTY_NOTICES.md` naming every bundled package and its licence, `npm pack` holding only `dist/cli.mjs`, `dist/common.mjs`, `dist/mcp-server.mjs`, `dist/THIRD_PARTY_NOTICES.md`, the built board (`web/index.html`, `web/favicon.svg` and its hashed assets), the MCP App view `mcp-app/board.html`, `skills/subset-timer/SKILL.md`, `README.md` and `package.json`, and the built CLI starting its daemon on first use, reporting it and stopping it.

The web host tests (`test/serve.test.mjs`) run against a daemon on a real socket in a temp data directory:

- **Listening:** the server is bound to `127.0.0.1`; a taken first port moves to a later one, while a required one fails; `serve --port` with a taken port, `0`, `65536`, `abc` or `80.5` exits 2, also from the built CLI.
- **Guard:** no header, a cross-origin `Origin`, a cross-site `Sec-Fetch-Site`, another `Host`, a `POST` without or with another `Origin`, a preflight and an event stream without the header all get 403 with no CORS headers and change nothing; unknown API paths and operations are 404 and another method 405.
- **Proxy:** `start`, `pause` and `remove` through the API change the daemon's store; `/api/timers` and `/api/presets` relay; the daemon's `not_found` and a body that is not JSON come back as they are; with no daemon to reach, `/api/timers`, `/api/presets` and `/api/events` are 503 `daemon_unavailable`.
- **Events:** the stream opens with a `state`, carries one with the new timer after an operation and no alerts, and releases the daemon subscription when the page leaves or the host closes.
- **Static files and the command:** `/` is the board's `index.html` with its title, favicon and Content Security Policy, its assets have their types, and unknown, traversing, directory and malformed paths are 404; `serve` prints its URL (`--json`: `{ url, port }`), opens the browser unless `--no-open` and stops when asked; the built CLI serves the board, starts the daemon on the page's first change, and exits 0 on SIGINT with a stream open while the daemon keeps the timer running.

The MCP tests (`test/mcp`) cover, with `@mcpfn/testing`'s in-memory client against an in-process daemon (fake clock, recording sink, optionally the SET-74 fixture store) and with the built `subset-timer mcp` as a child process against a daemon in a temp data directory:

- **Tools:** `tools/list` matches the server manifest and holds exactly the 12 tools, each with an object input schema without top-level combinators that passes mcpfn's portability check, the SET-74 id, name and phase schemas, the annotations above, a title and the descriptions' local-and-keeps-running and report-the-id-and-end sentences; the server reports `subset-timer` and the package version.
- **Success paths:** `timer_list` and `timer_get` return the daemon's agent result and the fixture text, with the end time for a running timer; `timer_start` in every mode (duration, `HH:MM` and ISO `until`, stopwatch, work and rest, segments, presets by id, name and alias, `sound: false`; a saved preset named HIIT wins over the `hiit` alias and two of them are `ambiguous`) creates a running timer in the daemon, which then finishes it and alerts its sink; pause, resume, skip, lap, reset by id and name, remove by name and id, and saving, starting and removing a preset each change the daemon's store and return the board with `affectedTimerId` or `affectedPresetId`.
- **Errors:** two start modes, none, work with segments, a negative, too long or fractional duration, an unknown field, a missing `rounds`, a bad `until`, a name with a line break, malformed ids and both `id` and `name` are `invalid_input` with SET-74 issue paths; an unknown id, timer, preset or saved preset is `not_found`; pausing a paused timer, resuming a running one, a lap on an interval, a skip on a stopwatch and removing a built-in preset are `invalid_state`; the 51st timer is `limit_reached`; a name matching two timers is `ambiguous` with both candidates; none of these change the store. A daemon that cannot start is `daemon_unavailable` with no path in the result; a start whose later read fails reports the timer it started; no result carries the data directory.
- **`timer_start` by id, `laps` and `ticks`:** an idle timer starts by id and keeps its definition; `laps` and `ticks` reach the countdown, preset and interval definitions; `id` with a new timer's field and `laps` on a stopwatch are `invalid_input`, a running timer's id `invalid_state` and an unknown one `not_found`, none changing the store.
- **MCP App (`test/mcp/app.test.mjs`):** `resources/list` and `resources/read` return `ui://subset-timer/board@1` with its MIME type, CSP metadata and the built HTML; the three view tools carry `_meta.ui.resourceUri` and pass `assertMcpAppContracts`, which refuses them without the resource, and the others have no `_meta`; a static scan of `mcp-app/board.html` finds one inline module script, the inlined styles and no `src`, `href`, stylesheet link, CSS import or URL import. The bridge and `McpApp.svelte`, bundled from their sources with rolldown and the Svelte compiler (server rendering), run against a fake host on `postMessage` that answers `ui/initialize` and runs each `tools/call` on the Timer server over the fixture daemon: the handshake and theme, the tool result rendered as a compact board with the create form, a message from another source ignored; every board action calling its tool with the right arguments, with a reply the board's own contract check accepts, and a fractional duration failing without a call; a tool error as the board's inline error text, a host refusal as a failed action and an error or cancelled tool result shown instead of the board; refresh every 10 s, none while hidden, one read when shown again, a failed read kept as a notice, `ping`, an unknown request refused, and after teardown no reads, messages or actions; the size sent once connected and only when it changes.
- **Stdio:** over a real child process, initialize, `tools/list`, `resources/read` of the board (the packaged `mcp-app/board.html`) and two calls (the first starting the daemon) put only complete JSON-RPC frames on stdout and the log on stderr; closing stdin exits 0 while the daemon keeps running and the timer is still listed; closing stdin at once exits 0 without starting a daemon; `mcp` with an argument exits 2, and `--help` lists it.

The daemon tests (`test/daemon`) cover:

- **Lock:** a second holder is refused; a dead pid's lock, a lock without a valid pid, and one whose live pid now belongs to a process born otherwise are taken over at once, while one naming its live holder's birth or no birth is kept; a holder's birth is read exactly on Linux and elsewhere and stays the same for its life; a lock created again at the same path by the same process is a different holder; a takeover marker of a dead process is removed at once with the files it left and markers nobody acts on again, one of a live process is kept however old, and one whose pid now belongs to a process born otherwise is recovered at once; with real processes stopped at chosen file calls, one that recovers an abandoned marker after another process has claimed the takeover never lets a third take the lock from under it, a live owner releasing while another takes over its reused pid never removes the new lock, and a marker abandoned while an abandoned marker was being removed is recovered within the 3 s client budget; a chain of twelve markers, each abandoned by a process that died while removing the one before, is recovered within that budget, and no file name the lock creates exceeds 255 bytes; a lock file that cannot be written reports that error even when its cleanup fails too; a process that removes a stale lock on its last try still creates its own; a sweep of leftovers that fails after the lock is created still returns a lock that can be released and taken again; a running daemon whose socket was removed keeps its lock, also when the starting daemon's wall clock is set forward a minute or an hour; a process whose wall clock was set forward a minute never judges a live takeover abandoned; release leaves a lock another process has created; a daemon that lost its lock never writes or alerts again and leaves its successor's socket; one with only a paused timer or none and a subscriber notices the lock removed or replaced within a minute and ends the stream; a daemon whose lock is taken over after locking or binding leaves its successor reachable; the lock is never seen before its content is complete; a failed write leaves no lock and a short one is completed; four concurrent `daemon run` processes, with and without a stale lock, leave exactly one daemon and the others exit 3 with `already running (pid N)`.
- **Store:** a process killed between the write and the rename leaves the previous store; a directory fsync failing after the rename keeps the change; a write taken a few bytes at a time completes, and a write that a full disk cuts short fails with the previous file intact; invalid JSON, an empty file and a store that fails validation are moved aside and logged.
- **Socket:** `0700` and `0600` modes and no TCP address; every route's success and error codes; a refused write is not applied; a finish the disk refused is recorded at a later run, sent as `state`, and the daemon then idles out.
- **Events:** `state`, `alert` and `heartbeat` arrive in order; a reading subscriber gets every state frame of a valid store over 1 MiB; one that stops reading is dropped after 30 s, however the wall clock moves, and the daemon carries on; a request or read after lock loss, or a request still arriving at shutdown, gets 503 and is not applied.
- **Scheduler (fake clock):** a Tabata run fires each of its 68 step, tick and finish alerts once at its own time; pause suppresses them and resume continues without repeats; skip re-arms and fires the same alerts with a clock that moves between reads; a clock set back 1.5 s, 5 s or an hour repeats nothing; a timer started after a step back still finishes; a clock set forward is noticed within 60 s; a sleep produces one `missedWhileAway` per timer with the state still correct; the 2 s boundary; a restart reports only what it missed; a checkpoint the disk refused after an alert is saved at a later run, so a restart reports nothing; a transition that falls due while another is delivered fires as itself; after a skip, resume or start a restart (graceful, or a real daemon process killed right after a skip) fires nothing until the next transition, which fires once.
- **Idle exit:** after 10 fake minutes with nothing running, cancelled by a subscriber and by running or paused timers.
- **Auto-spawn:** a client starts a daemon and later clients reuse it; concurrent clients end up on one daemon; a request that meets a daemon shutting down, or a real daemon that lost its lock, runs on the daemon started after it; a start that meets a socket resetting its connections, as a closing daemon's does, keeps waiting for the daemon after it; the 3 s wait is neither cut short nor stretched when the wall clock is set an hour forward or back; a daemon that never starts is `daemon_unavailable`.

Not verified here: the MCP server and its MCP App view in a real host such as Claude Desktop or VS Code, including the iframe, theme, sizing and approval of destructive tools (SET-84); the board in a real browser, including keyboard use and visual review (SET-85); audible sounds and visible notifications from the real sinks, and sleep and wake, on a real Mac (SET-85); the skill used by a real agent (SET-84); a published package (after SET-87); and Windows, which is not supported.
