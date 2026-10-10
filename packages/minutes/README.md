# @subset/minutes

The Minutes capability: send a visible notetaker bot to a Google Meet or Zoom (web client) meeting in the system Google Chrome and record the other participants' audio to a local WebM file. This private workspace owns the domain logic and the contract. The `subset-minutes` CLI ([`@subset.dev/minutes`](../minutes-cli/README.md)) bundles it, and the [macOS app](../../native/minutes/README.md) runs that CLI. There is one implementation.

Status: building. No bot has joined a real meeting since this package was extracted (see [Unverified](#unverified)).

## Capability boundary

| | |
| --- | --- |
| User outcome | An audio recording of a Google Meet or Zoom meeting, made by a bot participant that everyone can see, without a meeting-platform SDK or a hosted service. |
| Source of truth | The meeting page as the bot's Chrome session observes it. The output is one `.webm` file per session, written by the bot. Session records (`<data dir>/sessions/<id>.json`) hold state for `status`. |
| Operations | `parseMeetingLink` (validate), `runMeetingSession` (join, record, and finalize), `readStatus` (read-only), and `runDoctor` (read-only prerequisite checks). |
| Consumers | The `subset-minutes` CLI (terminal and shell-capable agents) and the macOS app (through the CLI's `--json` stream). |
| Not included | Transcription, speaker labels, notes, upload, calendar integration, or any network service of Subset's. |

## Modules

| Export | Contents |
| --- | --- |
| `contract` | `MINUTES_CONTRACT_VERSION` (1), the event, status, and doctor types, and validators: `isMinutesEvent`, `parseEventLine`, `isSessionRecord`, `isMinutesStatus`, and `isMinutesDoctor`. |
| `link` | `parseMeetingLink`: `https` only, `meet.google.com/<abc-defg-hij>` or `/lookup/<id>`, and `zoom.us` or `*.zoom.us` `/j/`, `/s/`, or `/wc/` links with a meeting number. It rejects credentials, ports, and other hosts. A Zoom link becomes its `/wc/join/<id>` web-client URL, so the native Zoom app never opens. |
| `paths` | Default directories and file naming. Recordings are named `minutes-<platform>-<UTC time>.webm`, with a `-2`, `-3`, and so on suffix when the name is taken. The name leaves out the meeting code. |
| `session` | The state machine (`transition`, `canTransition`) and `runMeetingSession`. |
| `driver` | The `MeetingDriver` / `MeetingPage` interface, which is the browser seam, plus `MinutesError`, which carries a contract error code. |
| `store` | `writeSessionRecord` (atomic, mode 0600) and `readStatus`. |
| `doctor` | `runDoctor` and `findChrome`. Filesystem access goes through an injectable probe. |
| `@subset/minutes/chrome` | `createChromeDriver`: playwright-core with the system Chrome, the Meet and Zoom adapters, and audio capture. This is the only module that imports Playwright. Import it only when a session runs. |

### Session states

```text
launching ─▶ joining ─▶ in_meeting ─▶ stopping ─▶ ended
    │           │            │            │
    └───────────┴────────────┴────────────┴──────▶ failed
launching / joining ─▶ stopping   (stop requested before the bot is in)
```

`ended` and `failed` are terminal. Every session emits exactly one `ended` event as its last line. Its `reason` is one of `meeting_ended`, `stopped` (SIGINT, SIGTERM, or stdin close), `page_closed`, `time_limit` (default 4 hours), or `failed`. When a session fails, an `error` event with a code comes first.

The session always finalizes, even when it fails. It stops the recorder, waits for the last 4-second slice to reach Node, closes the file, then leaves the meeting and closes Chrome.

### Event contract (version 1)

`join --json` writes one JSON object per line. Every event has `v: 1`, an ISO `at` time, and a `session` id (`null` when the command failed before a session existed).

| `type` | Fields |
| --- | --- |
| `started` | `platform` (`google-meet` \| `zoom`), `meeting` (redacted link), `displayName`, `outputDirectory` |
| `state` | `state` (one of the session states) |
| `status` | `message` (progress text) |
| `recording` | `path` (the WebM file, created before the join) |
| `error` | `code` (`usage`, `invalid_link`, `chrome_not_found`, `profile_in_use`, `join_rejected`, `join_failed`, `capture_failed`, `output_unwritable`, `internal`), `message` |
| `ended` | `reason`, `path` (or `null`), `bytes` (or `null`) |

`status --json` prints `{ v, kind: "minutes.status", observedAt, stateDirectory, sessions[], unreadable }`. Sessions are listed most recent first, at most 20. Each session has its record fields plus `alive` and `stale`. `stale` marks an active record whose process has exited. `doctor --json` prints `{ v, kind: "minutes.doctor", observedAt, ok, chromePath, profileDirectory, outputDirectory, checks[] }`. The checks are `node`, `chrome`, `profile`, `profile_lock`, and `output_directory`. Each check has `ok`, `required`, `detail`, and `fix`.

The validators accept only these shapes and reject unknown fields. A reader must reject a `v` it does not know. The macOS app checks `v` before decoding, and `scripts/check-workspaces.mjs` fails if the app's supported version differs from `MINUTES_CONTRACT_VERSION`.

### Privacy and secrets

- Events, session records, and logs carry only the **redacted** meeting link: the origin and path, without the query or fragment. URLs inside error messages (for example a browser navigation error) are redacted the same way, and the validators reject a `meeting` field that still has a query. The full link, including any Zoom `pwd` passcode, is passed to Chrome to join. The CLI can read it from stdin (`--link-from-stdin`) so it is not in the process list.
- `doctor` reports whether the bot profile has a Google account signed in. It reads Chrome's `Local State` for this but never returns or prints the account name.
- No credentials are read, stored, or sent. The bot's Google sign-in lives only in its Chrome profile.

## Browser behavior

The Chrome driver launches the installed Google Chrome (or `SUBSET_MINUTES_CHROME_PATH`) with `--use-fake-ui-for-media-stream`, `--use-fake-device-for-media-stream` with a silent fake microphone, and `--autoplay-policy=no-user-gesture-required`. The bot's camera and microphone are therefore Chrome's fake devices: it never captures this computer's real camera or microphone, even if a mute click fails. Chrome runs with its sandbox (`chromiumSandbox: true`; Playwright otherwise adds `--no-sandbox`). Playwright's own signal handlers are turned off, so a stop request can finalize the file before Chrome closes.

- Meet uses a persistent profile (default `~/Library/Application Support/Subset Minutes/google-meet-bot-profile` on macOS; elsewhere `$XDG_DATA_HOME/subset/minutes/google-meet-bot-profile`, or `~/.local/share/subset/minutes/google-meet-bot-profile` when `XDG_DATA_HOME` is unset). Zoom uses a fresh context.
- Audio capture is an init script that hooks `RTCPeerConnection` track events, mixes the remote audio tracks with a silent source, and records with `MediaRecorder` (WebM/Opus). Only the top-level document records, and recording starts after the join. The file therefore holds a single WebM stream, and pages loaded during the join flow add nothing. If the meeting page reloads after the join, the session logs that later audio is missing rather than appending a second stream.
- The join flows wait up to 10 minutes to be admitted. A rejected or never-admitted bot fails with `join_rejected` or `join_failed` instead of reporting that it joined. Meet rejections are noticed while waiting, and a page that closes is reported as such rather than as a timeout.
- The session reserves the recording file name atomically, removes the empty file if capture never began or produced no data, and reports `capture_failed` (with the bytes on disk) when the recording could not be flushed completely (including when the meeting page closed before the recorder handed over its last slice) or no remote audio track ever reached the recorder (for example, a meeting client that does not deliver audio through `RTCPeerConnection` tracks).

## Tests

`npm test --workspace=@subset/minutes` builds the package, then runs `node --test`:

- `link.test.mjs`: accepted and rejected links, the Zoom web-client mapping, and passcode redaction.
- `contract.test.mjs`: every event shape, rejection of unknown versions, types, values, and extra fields, and the status and doctor validators.
- `session.test.mjs`: the full transition table, file naming, and `runMeetingSession` with a fake driver. The fake covers a meeting that ends, a stop while in the meeting, a stop while joining, the time limit, a join failure, and a launch failure. Each case checks persisted records and `readStatus` staleness.
- `doctor.test.mjs`: required versus optional checks, a signed-in profile that is never revealed, a profile lock, and environment overrides.

No test needs Chrome. The driver is the seam.

## Provenance

The join flows and the capture hook come from the `BotRuntime/` sidecar in this PR's first commit, which was ported from `21nCo/21n` `poc/ios/MeetingRecordingPOC` at commit `819ea89`. The extraction changed the following, prompted mostly by review findings on that commit:

- Zoom now loads once. The old flow navigated twice, which started two recorders on one file.
- Recording now starts after the join, in the top-level document only, so the file holds a single stream.
- On stop, the final recorder slice is flushed before the file is closed.
- A silent source keeps the `AudioContext` timeline running, and autoplay is allowed.
- The Meet end check no longer matches the in-call **Leave call** button.
- Meet and Zoom joins can fail instead of always reporting success.
- The Zoom mute and camera selectors match only label prefixes, so they cannot unmute the bot.
- `--no-sandbox` and `--disable-setuid-sandbox` were removed.
- Playwright's signal handlers are turned off.
- Errors now carry codes.

## Superfunctions reuse review

Reviewed on 2026-10-09 against the local Superfunctions reference checkout (commit `9cf3812`) and the npm registry.

| Package | Version | What it offers | Decision and gap |
| --- | --- | --- | --- |
| `@recfn/meet` | 0.1.1 (MIT) | `MeetAdapter` on `@recfn/browser-core`: join, participant and chat tracking, and audio as a `ReadableStream<AudioChunk>` | **Not adopted.** Its audio comes from `getDisplayMedia` tab capture, not remote-track interception, so it needs a capture-permission flow that this bot avoids. It depends on the full `playwright` package with its managed-browser downloads, while Minutes uses `playwright-core` with system Chrome. Its join flow is a narrower version of the Meet flow here, with no guest name, mute, or rejection detection. Revisit if recfn adds a remote-track audio source and a `playwright-core` peer. |
| `@recfn/browser-core` | 0.1.2 | Shared browser session, join behavior, and tracker hooks | Not adopted, for the same reasons. Its `BrowserJoinBehavior` hooks are close to `PlatformAdapter` here, so a later migration could map one onto the other. |
| `@recfn/zoom` | 0.1.0 | `ZoomAdapter` over an injected `ZoomMeetingSdk` (init with `sdkKey`/`sdkSecret`, raw audio and video frames) | **Not applicable.** It wraps the Zoom Meeting SDK, which needs Zoom app credentials and a native SDK binding. Minutes joins through the Zoom **web client** with no Zoom credentials. |
| `@recfn/core` | 0.1.1 | `PlatformAdapter`, `BotConfig`, `AudioChunk`, and error types | Not adopted. Minutes' contract is a versioned NDJSON event stream for a CLI and a native host. Taking recfn's in-process adapter types would not replace that seam. |
| `@recfn/teams` | 0.1.0 | Microsoft Teams browser adapter | Out of scope. Minutes supports Meet and Zoom only. |
| `@recfn/whisper`, `@recfn/server` | 0.1.0, 0.1.1 | Transcription and a hosted recording API | Later candidates if Minutes adds transcription. Minutes records audio only. |
| `RecFnBotSDK` / `RecFnDesktopSDK` (Swift) | private `NPX-32` branch | The proof of concept's hosted bot and desktop notetaker | Unsuitable until released publicly. |
| `@clifn/core` | 0.1.0 | Parser-agnostic CLI runner and output helpers | Not used. The CLI has four commands and uses `node:util` `parseArgs`, matching the `@subset.dev/usage` decision. |
| `filefn`, `authfn`, `datafn`, `mcpfn`, `plugfn`, `apifn`, `uifn`, observability | — | — | Not applicable. There is no upload, account, sync, MCP tool, connector, web view, or telemetry. |

Package and version used: none from Superfunctions. The external runtime dependency is `playwright-core@1.59.1`, the version the proof of concept's lockfile resolved.

## Unverified

- **Live meetings.** No bot joined a real Google Meet or Zoom meeting after the extraction. The selectors, the admission wait, end detection, and remote-audio capture in a real call are unverified, and platform UI changes can break them.
- **Remote-track capture.** With the system Chrome (headless), the capture script installed, recorded a valid WebM (EBML header) from the silent source, and flushed on stop. A local WebRTC loopback in that environment never connected (ICE stayed `new`), so mixing a remote track was not observed.
- **Linux and Windows.** The defaults include Linux Chrome paths, but only macOS was exercised. `@subset.dev/minutes` declares `darwin` and `linux`.
