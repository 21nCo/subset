# Minutes (macOS app)

Minutes sends a notetaker bot to a Google Meet or Zoom (web client) meeting and records the other participants' audio. This SwiftUI app is one host for the capability. It checks the local setup, accepts a meeting link, and runs the shared **`subset-minutes` CLI** ([`@subset.dev/minutes`](../../packages/minutes-cli/README.md)), which bundles the capability package [`@subset/minutes`](../../packages/minutes/README.md). The app shows the CLI's state (joining, in meeting, finished, failed) with a meeting timer and points to the finished audio file. The bot itself drives a visible Google Chrome window, mutes itself, and writes WebM/Opus audio.

The app owns only a lightweight link pre-check for the form. Strict link validation, the Meet and Zoom join flows, audio capture, the session lifecycle, and file naming all live in `@subset/minutes`. The app runs the CLI and reads its documented outputs: the versioned `join` NDJSON stream and the `doctor --json` report. It passes the meeting link on stdin (`--link-from-stdin`), so a Zoom passcode is not visible in the process list.

This app was ported from a proof of concept. It builds locally, but it does not transcribe or summarize. It is not released, and no surface is listed as available.

## Capability boundary

| | |
| --- | --- |
| User outcome | An audio recording of a Google Meet or Zoom meeting, made by a visible bot participant, without installing a meeting-platform SDK. |
| Source of truth | The meeting page as the bot's Chrome session observes it, reported by the CLI. The output is the `.webm` file in the chosen folder (default `~/Documents/Minutes Recordings`). The app keeps only the bot name and output folder in `UserDefaults`. |
| Bot identity | A dedicated Chrome profile at `~/Library/Application Support/Subset Minutes/google-meet-bot-profile`. This is the CLI's default on macOS unless `SUBSET_MINUTES_PROFILE_DIR` or `SUBSET_MINUTES_DATA_DIR` is set. The app always passes this path with `--profile`, so those overrides do not change the app's profile; without them, the app and a terminal session share one signed-in bot. |
| Network | Only the bot's Chrome session, which talks to the meeting platform. Neither the app nor the CLI makes other requests. |
| Not included | Transcription, speaker labels, notes, calendar integration, or upload. |

### Operations

| Operation | Trigger | Effect |
| --- | --- | --- |
| Check setup | On launch, on app activation, on choosing a folder, and on **Check Again** | Finds Node.js (Homebrew paths first, then the login shell with a 5-second limit, which covers nvm). Then it locates the CLI and runs `subset-minutes doctor --json --out <folder> --profile <profile>`. The checklist shows each doctor check: Chrome, the bot's Google sign-in (optional), whether the profile is in use, and the output folder. |
| Fill link | Type, **Paste**, or **Use Current Tab** | Pre-checks for an `https` link on a Google Meet or Zoom host. **Use Current Tab** reads the front tab of a running Chrome or Safari through Apple Events, only when clicked. The CLI does the strict validation. |
| Send bot | **Send Bot to Meeting** (⌘↩) | Runs `node <cli.mjs> join --link-from-stdin --json --stop-on-stdin-close --profile <profile> --name <name> --out <folder>` and writes the link to its stdin. |
| Stop | **Leave and Stop** (⌘.) | Sends SIGINT, which makes the CLI flush the recording, leave, and exit. If the CLI is still running after 15 seconds, the app sends SIGTERM to that same process. |
| Quit during a session | Quitting or a crash closes the CLI's stdin | With `--stop-on-stdin-close`, the CLI finalizes the recording as if it had been stopped. |
| Set up sign-in | **Set Up Google Sign-In…** | Runs `subset-minutes sign-in --profile <profile>`, which opens Chrome with the bot profile at accounts.google.com. Quit that window before you start the bot. |
| Inspect | **Details**, **Copy Log**, **Show in Finder**, **Open** | Shows and copies the session log, and reveals the audio file and its folder. |

### Contract with the CLI

The app decodes the `@subset/minutes` event contract (`MinutesCLI.swift`). `MinutesContract.supportedContractVersion` is `1`. Before decoding, the app checks each line's `v`. A line with an unknown version or type is shown as an error and is never guessed at. A non-JSON line is logged as plain text.

- `state` drives the status card: `launching`/`joining` show as Joining, `in_meeting` starts the timer, and `stopping` shows as Leaving.
- `recording` sets the file card.
- `error` shows its `code` and `message` (for example, `[invalid_link] This Google Meet link has no meeting code…`).
- `ended` sets Finished (`meeting_ended`, `stopped`, `page_closed`, or `time_limit`) or keeps Failed.

`scripts/check-workspaces.mjs` fails if the Swift and TypeScript contract versions differ.

## How the app runs the CLI

`MinutesCLILocation.resolve()` checks these locations in order:

1. **`MINUTES_CLI_PATH`**, the path to a `cli.mjs`, for testing another build.
2. **Bundled:** `Minutes.app/Contents/Resources/minutes-cli/dist/cli.mjs`. The **Embed Minutes CLI** build phase copies `packages/minutes-cli/app-runtime/` (made by `npm run build` at the repository root: the CLI bundle plus `node_modules/playwright-core`, about 12 MB) into the app. A Release build fails if that folder is missing. A Debug build warns and falls through to the next location.
3. **Repository build:** `packages/minutes-cli/dist/cli.mjs`, resolved from the app's source location. This works only for a local development build.

For releases, the CLI is bundled in the app rather than installed separately with `npm install -g @subset.dev/minutes`. This was chosen because it is more robust:

- The app and the CLI ship as one versioned pair, so the contract versions cannot drift.
- There is no `PATH` or global-prefix discovery (nvm, Volta, Homebrew).
- It works before the npm package is published.

**Node.js is still required.** The app does not bundle a Node.js runtime, so the user needs Node.js 22 or later installed, and the setup checklist says so. Bundling a signed Node binary inside the app, so that it would be self-contained, is a follow-up that depends on signing and notarization.

## Requirements, permissions, and consent

- macOS 14 or later.
- Xcode 16 or later to build (verified with 26.4).
- Node.js 22 or later, and npm to build the CLI.
- Google Chrome.
- The `xcodeproj` gem, only to regenerate the project.
- Apple Events (Automation) permission for Chrome or Safari, requested only when **Use Current Tab** is used.
- No microphone, camera, or screen-recording permission. The bot uses Chrome's fake media UI and mutes itself.
- The bot appears in the meeting under the chosen name. Tell participants you are recording, and follow the recording-consent rules that apply to you and to the meeting platform.

## Build and run

```sh
npm ci && npm run build                 # repository root: builds @subset/minutes and stages packages/minutes-cli/app-runtime
cd native/minutes
ruby ProjectGenerator.rb                # optional: regenerates Minutes.xcodeproj
xcodebuild -project Minutes.xcodeproj -scheme Minutes -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
```

Controller smoke test. It uses the real controller and the real CLI, and joins no meeting:

```sh
cd native/minutes/MacApp
xcrun swiftc -swift-version 6 -o /tmp/minutes-controller-smoke MinutesCLI.swift MinutesController.swift ../Tests/ControllerSmoke/main.swift
SUBSET_MINUTES_DATA_DIR=/tmp/minutes-smoke-data /tmp/minutes-controller-smoke   # exits 0 when invalid_link reaches the controller
```

The app logs which CLI it uses and the `doctor` result to the unified log (subsystem `dev.subset.minutes`, category `cli`). It never logs the meeting link.

## UI/UX changes from the POC

Reference products: [Granola](https://www.granola.ai) and [Otter](https://otter.ai).

1. **Setup checklist.** It shows Node.js, the Minutes CLI and where it was found, and each `doctor` check with its fix-it text, plus **Set Up Google Sign-In…** for the bot profile. Optional checks such as sign-in show as advice, not blockers. The POC reported missing pieces only after a failed start. (Modeled on Otter's guided notetaker setup.)
2. **Link pre-check and Use Current Tab.** The link field shows the detected platform or why a link is rejected. **Paste** and **Use Current Tab** fill the link from the clipboard or from the front Chrome or Safari tab. (Modeled on Granola's meeting detection, kept as an explicit action.)
3. **Session status instead of a raw log.** A status card shows Ready, Joining, In meeting (with a timer), Leaving, Finished, or Failed with the coded error. The process log moved into a collapsible **Details** section with **Copy Log**. The audio file appears as a card with **Show in Finder**.
4. **Consent notice.** The form states that participants will see the bot join under its name (in Google Meet, under the bot's Google account name when it is signed in), and that the user should tell them they are recording. (Modeled on Otter's visible-notetaker disclosure.)
5. **Shortcuts, persistence, and accessibility.** ⌘↩ sends the bot and ⌘. stops it, and both have tooltips. The bot name and output folder persist. Setup rows, the status card, and the output file have VoiceOver labels.

## Provenance

Ported from `21nCo/21n`, branch `dev`, path `poc/ios/MeetingRecordingPOC`, last changed in `819ea89a3f22180fd99ef9db2961274d2c75d607`. `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when it was copied.

- **Removed a hardcoded hosted-bot API key and a plain-HTTP server IP address.** They were default values in the POC's `ContentView.swift`. The matching App Transport Security exception was also removed from `Info.plist`. Treat that key as exposed in the 21n repository history and rotate it.
- **Removed the dependency on the private `21nCo/super-functions.next` Swift package (branch `NPX-32`).** It supplied `RecFnBotSDK` (a hosted bot server) and `RecFnDesktopSDK` (ScreenCaptureKit, whisper.cpp transcription, and notes). A public repository cannot build against a private branch, and AGENTS.md disallows copying Superfunctions source. The hosted bot, transcript, and desktop notetaker panels are therefore not in this port.
- **Moved the bot runtime out of the app.** The first commit of this PR kept the POC's TypeScript `BotRuntime/` as a pnpm sidecar inside `native/minutes`. It is now the `@subset/minutes` package and the `@subset.dev/minutes` CLI. `BotRuntime/` and its lockfile were removed, so there is one implementation. The package README lists the fixes made during the extraction.
- **Renamed the app.** The project, target, scheme, and product are now `Minutes`, and the bundle ID is `dev.subset.minutes`. The default output folder changed from `~/Desktop/MeetingRecordings` to `~/Documents/Minutes Recordings`.
- **Trimmed `Info.plist` usage strings.** Only the Apple Events string remains, for **Use Current Tab**.

## Superfunctions reuse review

See [`packages/minutes/README.md`](../../packages/minutes/README.md#superfunctions-reuse-review). That review re-evaluated `@recfn/meet` 0.1.1, `@recfn/browser-core` 0.1.2, `@recfn/zoom` 0.1.0, `@recfn/core` 0.1.1, `@clifn/core` 0.1.0, and the private RecFn Swift SDKs. No Superfunctions package is used, and the review records each gap.

## Release (macOS)

`macos-release.json` opts the `Minutes` scheme into the signed macOS release flow; see [docs/macos-release.md](../../docs/macos-release.md). Run `npm ci && npm run build` first, because a Release build embeds `packages/minutes-cli/app-runtime`. A Developer ID-signed, not notarized, build of 0.1.0 with this manifest was produced locally, with the CLI embedded and the hardened runtime on. Node.js is still a separate install. Nothing has been released, and the catalog lists no available surface.

## Verified

- `xcodebuild` (Debug, unsigned) succeeds, and the build embeds `Resources/minutes-cli` (`dist/` plus `playwright-core`).
- The app was launched and quit. On launch, the unified log showed it using the **bundled** CLI and `doctor --json: ok=true`.
- The controller smoke test passed with both the repository build and the app's bundled copy (through `MINUTES_CLI_PATH`). Readiness came through `doctor --json`, and a join with `https://meet.google.com/not-a-meeting-code` spawned the CLI and ended as Failed with `[invalid_link]` in the log. The CLI exited with status 2.

## Unverified

- **Live meetings.** No bot joined a real Google Meet or Zoom meeting through the app or the CLI. The join flows, admission, end detection, recorded audio, and the in-meeting stop are unverified.
- **The UI flow.** The controller path was exercised headless (see above). Typing a link and pressing ⌘↩ in the window, and the **Use Current Tab** Automation prompt, were not driven.
- **Distribution.** Signing, notarization, Gatekeeper behavior of the embedded JavaScript, bundling Node.js, and any release route are all unverified.
