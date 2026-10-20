# Timer daemon and command line (SET-76)

This private package (`@subset.dev/timer`, version 0.0.0) holds the per-user Timer daemon: the only writer of timer state. It runs the `@subset/timer` (SET-74) operations sent over a private Unix socket, writes state atomically, and schedules alerts at step changes, final-second ticks and finishes. The `subset-timer` command, real sound and notification sinks and the agent skill come in SET-77; nothing here is published and no Timer surface is available yet.

## Data directory

`~/.local/share/subset/timer`, or `SUBSET_TIMER_DATA_DIR`. The daemon creates it with mode `0700` (tightening an existing one) and refuses a directory another user owns, a symbolic link, or a path too long for a Unix socket (103 bytes for `daemon.sock`).

| File | Purpose |
| --- | --- |
| `state.json` | The SET-74 store (schema version 1). Each write goes to a temp file beside it (looping until every byte is written; a failed or short write removes the temp file, keeps the old file and fails the operation), is fsynced and renamed over it, and the directory is fsynced (once the rename succeeded, a failed directory fsync is logged and the change stands). A file that is not JSON or fails `parseStore` is moved to `state.corrupt-<epoch ms>.json`, logged, and the daemon starts with no timers. Temp files a crash left are removed at start. |
| `scheduler.json` | `{ version: 1, marks }`: for each running stretch, the time through which its alerts were delivered. It is written after each delivery (a save that fails is retried at every later run, at least once a minute), and before `state.json` whenever an operation begins a stretch (start, resume or skip), so a restarted daemon, even one killed mid-operation, reports only what it missed. A mark for a stretch that never began is dropped. |
| `daemon.lock` | Created with `O_EXCL`, holding the pid. |
| `daemon.sock` | The socket, mode `0600`. It is bound under a short temporary name (`.ds-<hex>`) and renamed into place. |
| `daemon.log` | The output of a daemon a client started (one previous log of up to 1 MiB is kept as `daemon.log.1`). |

## Single writer

- A daemon takes `daemon.lock` before reading `state.json`. A second daemon exits with code 3 and `already running (pid N)`.
- The lock is taken only once the whole pid is written and fsynced and the path still names the file this daemon created. A creator held up past the 2 s grace, whose empty lock another daemon replaced, does not take it. A pid write that fails removes the file while it is still the creator's own.
- A lock whose pid is not alive is stale and replaced. A lock with no pid yet is being written and is stale only after 2 s. The check and the removal happen under a `daemon.lock.takeover` marker, itself created with `O_EXCL` and removed only while it is still the one this process created, so processes starting together never remove a lock another has just taken.
- A live pid is a pid the system reused after the daemon died only when nothing answers on the socket and that process started more than 2 s after the lock was written. The start is a lower bound: the clock is read before `ps -o etime` runs and its 1 s rounding is subtracted, so a slow `ps` never makes a live daemon look reused; that lock is replaced too. A live daemon keeps its lock however old it is and whether or not its socket is there.
- Before every write, before removing leftover sockets at startup, before publishing its socket, and on every scheduler run (at least once a minute), heartbeat and request, the daemon checks that `daemon.lock` is still the file it created. One that lost it never writes, publishes or alerts again: it ends its event streams, answers `503 daemon_unavailable` and exits 1, or, still starting, removes only its own bound socket and exits 1.
- A daemon removes the lock, and the socket, on exit only while each is still the file it created.

## Socket API

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

A subscriber that has not yet drained a frame, however large, gets the frames after it once it does: the latest `state` and `heartbeat` (an older queued one is replaced) and every `alert`, in order. One that leaves a frame undrained for more than 30 s, or queues more than 1 MiB of alerts, has stopped reading and is dropped. Destructive operations are not gated here: hosts must have the user's explicit request before sending `reset`, `remove` or `presets.remove` (see `OPERATION_WRITE_CLASS`).

## Alerts and the scheduler

An `alert` is `{ timerId, kind, at, segment?, secondsLeft?, missed? }`, where `kind` is `segment` (an interval step began; `segment` is that step), `tick` (`secondsLeft` 3, 2 or 1 before a step or countdown ends, when `countdownTicks` is on), `finish`, or `missedWhileAway`.

- The scheduler arms one timeout for the earliest upcoming transition across running timers, from SET-74 `transitionsBetween`, and looks again at least every 60 s so a changed wall clock is noticed. It re-arms after every change. Before a change it delivers the alerts already due against the timers as they were.
- Each running stretch (from a start, resume or skip) has a mark: the time through which its transitions were handled. An operation and the scheduler runs around it use one reading of the clock, and a new stretch is marked from that moment, so a skip never fires what it jumped over. Each run handles the transitions since each mark. Those more than 2 s late, for example after sleep or while the daemon was not running, collapse into one `missedWhileAway` alert per timer (`missed` counts them; `segment` is the current step), ahead of the ones on time. The timer's state is computed from its timestamps as always.
- The next timeout is armed from each mark rather than from the clock after the run, so a transition that falls due while a run delivers and saves fires as itself at once.
- A mark only moves forward, so after the clock is set back nothing fires twice; what is still ahead fires once the clock reaches it. A stretch begun after the step back is marked from its own start.
- When a timer finishes the daemon records it as finished and sends `state`. If that save fails it is retried at every later run (at least every 60 s), and the idle exit is re-evaluated after each run.
- Restarting keeps a running timer running from its timestamps; nothing is paused automatically.

An `AlertSink` is `{ name, alert(alert, timerDefinition) }`. The daemon never waits for it, and a sink that throws or rejects is logged and ignored. A sink honours the timer's `sound` flag. The default is `createRecordingSink()`, which records alerts in memory; the macOS and Linux sinks are SET-77.

A real computer's timers stop while it sleeps, so after a wake the daemon notices within 60 s at the latest (earlier when a transition was due sooner). Real sleep and wake on a Mac is checked in SET-85.

## Idle exit

After 10 minutes with no running or paused timer, no `/v1/events` subscriber and no request, the daemon removes its socket and lock and exits 0. It does not start at login; a client starts it on first use.

## Client

`createClient({ dataDir?, cliPath?, spawn? })` from `@subset.dev/timer/daemon` connects to the socket. When the socket is missing or refuses, it spawns `node <cliPath> daemon run` detached and unreferenced (its output goes to `daemon.log`), and waits up to 3 s for the socket. A daemon that answers `503 daemon_unavailable` is shutting down and did not run the request: the client waits for it to release the lock, starts a new daemon (respawning one that exited because the old lock was still held) and sends the request there. Otherwise it rejects with a `DaemonUnavailableError` whose `code` is `daemon_unavailable`. `cliPath` defaults to `src/daemon/main.mjs`, which only runs `daemon run`, until the SET-77 CLI passes its own. The client offers `request`, `op`, `timers`, `presets`, `events`, `status` and `shutdown`; `status` and `shutdown` never start a daemon.

`startDaemon({ dataDir, clock, sink, log })` runs a daemon in-process, and `runDaemonCommand({ sink })` is the foreground `daemon run`. `clock` is `{ now, setTimeout, clearTimeout }`: production uses `Date.now()` and `setTimeout`; `createFakeClock()` keeps timeouts on a monotonic timeline apart from the wall clock, as Node does, for tests.

Excluded: CLI commands, real sinks, TCP or a web host, MCP, launchd and Windows named pipes.

## Superfunctions

The SET-73 reuse check (see `packages/timer/README.md`) covers this package. The daemon is local process infrastructure (a Unix socket, a lock file and a JSON file), which no Superfunctions package provides; it uses only Node.js built-ins and `@subset/timer`. `@mcpfn/core` is used by the later MCP host (SET-79), not here.

## Verification

`npm test --workspace=@subset.dev/timer` runs `node --test test/daemon/*.test.mjs` with temporary data directories against a real socket:

- **Lock:** a second holder is refused; a dead pid's lock, an empty lock older than 2 s, and a live pid that started after its lock are taken over; a live holder that started before its lock (suspended before listening, or with its socket removed) is never taken over, and a slow `ps` never moves its start later; release leaves a lock another process has created; a daemon that lost its lock never writes or alerts again and leaves its successor's socket; one with only a paused timer or none and a subscriber notices the lock removed or replaced within a minute and ends the stream; a daemon whose lock is taken over after locking or binding leaves its successor reachable; a creator held up before its pid write does not acquire; a failed pid write leaves no lock and a short one is completed; four concurrent `daemon run` processes, with and without a stale lock, leave exactly one daemon and the others exit 3 with `already running (pid N)`.
- **Store:** a process killed between the write and the rename leaves the previous store; a directory fsync failing after the rename keeps the change; a write taken a few bytes at a time completes, and one a full disk cuts short fails with the previous file intact; invalid JSON, an empty file and a store that fails validation are moved aside and logged.
- **Socket:** `0700` and `0600` modes and no TCP address; every route's success and error codes; a refused write is not applied; a finish the disk refused is recorded at a later run, sent as `state`, and the daemon then idles out.
- **Events:** `state`, `alert` and `heartbeat` arrive in order; a reading subscriber gets every state frame of a valid store over 1 MiB; one that stops reading is dropped after 30 s and the daemon carries on; a request or read after lock loss, or a request still arriving at shutdown, gets 503 and is not applied.
- **Scheduler (fake clock):** a Tabata run fires each of its 68 step, tick and finish alerts once at its own time; pause suppresses them and resume continues without repeats; skip re-arms and fires the same alerts with a clock that moves between reads; a clock set back 1.5 s, 5 s or an hour repeats nothing; a timer started after a step back still finishes; a clock set forward is noticed within 60 s; a sleep produces one `missedWhileAway` per timer with the state still correct; the 2 s boundary; a restart reports only what it missed; a checkpoint the disk refused after an alert is saved at a later run, so a restart reports nothing; a transition that falls due while another is delivered fires as itself; after a skip, resume or start a restart (graceful, or a real daemon process killed right after a skip) fires nothing until the next transition, which fires once.
- **Idle exit:** after 10 fake minutes with nothing running, cancelled by a subscriber and by running or paused timers.
- **Auto-spawn:** a client starts a daemon and later clients reuse it; concurrent clients end up on one daemon; a request that meets a daemon shutting down, or a real daemon that lost its lock, runs on the daemon started after it; a daemon that never starts is `daemon_unavailable`.

Not verified here: real sleep and wake on a Mac (SET-85), real sinks (SET-77), and Windows.
