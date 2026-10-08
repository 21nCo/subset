# Minutes (macOS + local meeting bot)

Minutes sends a notetaker bot to a Google Meet or Zoom (web client) meeting and records the other participants' audio. The macOS app checks the local setup, accepts a meeting link, launches the bot as a child process, shows its state (joining, in meeting, finished, failed) with a meeting timer, and points to the finished audio file. The bot itself is the TypeScript/Playwright runtime in `BotRuntime/`. It drives a visible Google Chrome window, mutes itself, and writes WebM/Opus audio.

This is a port of a proof of concept. It builds locally, and the bot runtime type-checks. It does not transcribe or summarize, it is not released, and no surface is listed as available.

## Capability boundary

| | |
| --- | --- |
| User outcome | An audio recording of a Google Meet or Zoom meeting, made by a visible bot participant, without installing a meeting-platform SDK. |
| Source of truth | The meeting page as observed by the bot's Chrome session. The output is the `.webm` file in the chosen folder (default `~/Documents/Minutes Recordings`). The app keeps only the bot name and output folder in `UserDefaults`. |
| Bot identity | A dedicated Chrome profile at `~/Library/Application Support/Subset Minutes/google-meet-bot-profile`, passed to the runtime as `MEETING_BOT_PROFILE_DIR`. Signing that profile in to a Google account lets the bot join Meet without waiting as a guest. |
| Network | Only the bot's Chrome session, which talks to the meeting platform. The app makes no other requests. |
| Not included | Transcription, speaker labels, notes, calendar integration, or upload. The POC got these from a hosted bot server and a private desktop SDK; both were removed in this port (see Provenance). |

### Operations

| Operation | Trigger | Effect |
| --- | --- | --- |
| Check setup | On launch, on app activation, **Check Again** | Finds Node.js (Homebrew paths, then the login shell, which covers nvm), Google Chrome, `BotRuntime/src/index.ts`, and `BotRuntime/node_modules/tsx`. |
| Fill link | Type, **Paste**, or **Use Current Tab** | Validates an `https` Google Meet or `*.zoom.us` link. **Use Current Tab** reads the front tab of a running Chrome or Safari through Apple Events, only when clicked. |
| Send bot | **Send Bot to Meeting** (⌘↩) | Runs `node --import tsx src/index.ts <link> --platform=… --name=… --recording-dir=…` in `BotRuntime/`. |
| Stop | **Leave and Stop** (⌘.) | Sends SIGINT so the bot finishes the file and leaves; sends SIGTERM after 5 seconds if it is still running. |
| Set up sign-in | **Set Up Google Sign-In…** | Opens Chrome with the bot profile at accounts.google.com. Quit that window before starting the bot. |
| Inspect | **Details**, **Copy Log**, **Show in Finder**, **Open** | Shows and copies the bot's log, and reveals the audio file and folder. |

### Bot event protocol

The runtime writes one JSON object per line on stdout (`BotRuntime/src/status.ts`):

- `status` with `message`
- `joined` with `platform` and `url`
- `recording` with `path`
- `error` with `message`
- `ended` with `reason`

The app parses complete lines only. Non-JSON output and stderr are shown in the details log.

### Consuming surfaces

| Surface | Status |
| --- | --- |
| macOS app (`native/minutes`) | Proposed. Builds unsigned. Launched and quit in a smoke test. No bot was sent to a meeting. |
| Bot runtime CLI (`BotRuntime/`, `pnpm start <link>`) | Usable directly for development. Not packaged or published. |
| Web, embed, agent CLI or view | Not proposed. A future agent surface would need explicit consent and authorization rules for recording other people. |

`BotRuntime/` lives inside `native/minutes/` as the app's sidecar. It is not an npm workspace: it uses pnpm with its own lockfile and the `playwright-core` runtime, and it is not part of root `npm run check`. Its package is private (`subset-minutes-bot-runtime`).

## Requirements, permissions, and consent

- macOS 14+, Xcode 16+ (verified with 26.4), Node.js 18+, pnpm 10, Google Chrome, and the `xcodeproj` gem to regenerate the project.
- Apple Events (Automation) for Chrome or Safari, only when **Use Current Tab** is used.
- The app needs no microphone, camera, or screen-recording permission. The bot uses Chrome's fake media UI flags and mutes itself.
- The bot appears in the meeting under the chosen name. Tell participants that you are recording, and follow the recording-consent rules that apply to you and to the meeting platform.

## Build and run

```sh
cd BotRuntime && pnpm install --frozen-lockfile && cd ..
ruby ProjectGenerator.rb   # optional: regenerates Minutes.xcodeproj
xcodebuild -project Minutes.xcodeproj -scheme Minutes -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

A local build finds `BotRuntime/` next to its source files. To run the app from elsewhere, set `MINUTES_BOT_RUNTIME_DIR` to the runtime directory. The bot runtime is not bundled into the `.app`, so the app is not self-contained. To type-check the runtime, run `pnpm exec tsc --noEmit` in `BotRuntime/`.

## UI/UX changes from the POC

Reference products: [Granola](https://www.granola.ai) and [Otter](https://otter.ai).

1. **Setup checklist.** Node.js, Chrome, and runtime-dependency checks with exact fix-it text, plus **Set Up Google Sign-In…** for the bot profile. The POC only reported missing pieces after a failed start. (Otter's guided notetaker setup.)
2. **Link validation and Use Current Tab.** The link field reports the detected platform or why a link is rejected, and the start button stays disabled until the link is valid. **Paste** and **Use Current Tab** fill the link from the clipboard or from the front Chrome/Safari tab. (Granola's meeting detection, kept as an explicit action.)
3. **Session status instead of a raw log.** A status card shows Ready, Joining, In meeting (with a timer), Leaving, Finished, or Failed with the error. The process log moved into a collapsible **Details** section with **Copy Log**. The audio file appears as a card with **Show in Finder**.
4. **Consent notice.** The form states that participants will see the bot join under its name and that the user should tell them they are recording. (Otter's visible-notetaker disclosure.)
5. **Shortcuts, persistence, and accessibility.** ⌘↩ sends the bot and ⌘. stops it, with tooltips. The bot name and output folder persist. Setup rows, status, and the output file have VoiceOver labels.

## Provenance

Ported from `21nCo/21n`, branch `dev`, path `poc/ios/MeetingRecordingPOC`, last changed in `819ea89a3f22180fd99ef9db2961274d2c75d607`. `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when copied.

What changed in the port:

- **Removed a hardcoded hosted-bot API key and a plain-HTTP server IP address.** They were default values in the POC's `ContentView.swift`. The matching App Transport Security exception was also removed from `Info.plist`. Treat that key as exposed in the 21n repository history and rotate it.
- **Removed the dependency on the private `21nCo/super-functions.next` Swift package (branch `NPX-32`).** That package supplied `RecFnBotSDK` (`RecFnHostedBotController`, which drives a remote bot server) and `RecFnDesktopSDK` (`RecFnDesktopNotetaker`: ScreenCaptureKit, whisper.cpp transcription, and notes). A public repository cannot build against a private branch, and AGENTS.md disallows copying Superfunctions source. The hosted bot, transcript, and desktop notetaker panels are therefore not in this port.
- **Wrote a narrow `BotRuntimeController`.** It launches the `BotRuntime/` sidecar the POC README describes. The POC also referenced a `whisper.cpp` XCFramework search path and embed that this target no longer needs; those were dropped.
- **Changed `BotRuntime` as follows:**
  - The Chrome profile directory changed from `MeetingRecordingPOC` to `Subset Minutes`.
  - The package was renamed to `subset-minutes-bot-runtime`.
  - The runtime now emits the documented `joined` event after it joins. The protocol declared this event but the POC never sent it.
  - The platform join flows, audio capture, and lockfile are unchanged.
- **Renamed the app.** The project, target, scheme, and product are now `Minutes`. The bundle ID changed from `com.example.MeetingRecordingPOC.macOS` to `dev.subset.minutes`. The default output folder changed from `~/Desktop/MeetingRecordings` to `~/Documents/Minutes Recordings`.
- **Trimmed `Info.plist` usage strings.** Microphone, camera, screen-capture, and speech-recognition strings were removed because nothing in this target uses them. The Apple Events string remains for **Use Current Tab**.
- The source had no `xcuserdata`, `.DS_Store`, or build output.

## Superfunctions reuse review

Reviewed in `/Users/ar/dev/superfunctions` (local checkout at `9cf3812`, plus the `NPX-32` branch of its remote) and the npm registry on 2026-10-09.

| Package family | Evaluated | Result |
| --- | --- | --- |
| `recfn`: `@recfn/meet` 0.1.1, `@recfn/zoom` 0.1.0, `@recfn/browser-core` 0.1.2, `@recfn/core` 0.1.1 | Published browser-automation adapters for Meet and Zoom, with participant and chat tracking | Closest match to `BotRuntime/`, and the main gap to close next. Not adopted in this port. They depend on the full `playwright` package (managed browsers) rather than `playwright-core` with system Chrome, and their join behavior has not been verified against the POC flows. |
| `recfn` Swift SDKs (`RecFnBotSDK`, `RecFnDesktopSDK`) | The POC's dependency | Exist only on the private `super-functions.next` `NPX-32` branch, so they are unsuitable for this public repository until released. |
| `recfn` ASR adapters (`@recfn/whisper` 0.1.0, Deepgram, AssemblyAI) and `@recfn/server` 0.1.1 | Transcription and a hosted recording API | Candidates for a later transcription step. Not used, because this port records audio only. |
| `botfn` | Chat bots (Slack, Discord, GitHub, Linear) | Not a meeting-bot framework, so not applicable. |
| `filefn` (`@filefn/client` 0.1.1, `FileFnClient` Swift) | Uploading recordings | Recordings stay local; no upload surface exists. |
| `authfn`, `datafn`, `billfn`, `mcpfn`, `plugfn`, `apifn`, `uifn`, observability | Not applicable | No accounts, sync, billing, agent tools, connectors, web UI, or telemetry in this port. |

Package/version used: none.

## Unverified

- **Live meetings.** No bot joined a real Google Meet or Zoom meeting in this port, so the join flows and the bot's recorded audio (`RTCPeerConnection` interception) are unverified. Platform UI changes can break the selectors.
- **The app-to-bot path.** Launching the bot from the app, the `joined` state, stop via SIGINT/SIGTERM, and **Use Current Tab** Automation prompts were not exercised. The runtime's error path was checked from the CLI: an unsupported URL produced a JSON `error` event and exit status 1.
- **Distribution.** Signing, notarization, bundling Node.js and the runtime into the app, and any release route are all unverified.
