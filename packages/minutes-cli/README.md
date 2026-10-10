# @subset.dev/minutes

`subset-minutes` sends a visible notetaker bot to a Google Meet or Zoom (web client) meeting and records the other participants' audio to a local WebM file. The bot runs in your installed Google Chrome. Nothing is sent to Subset.

> Status: prepared for npm, not published. Install from a tarball or the repository until a release is announced. No bot has joined a real meeting with this release candidate.

Everyone in the meeting sees the bot join under its name. Tell participants that you are recording, and follow the recording-consent rules that apply to you and to the meeting platform.

## Use

Requires Node.js 22 or later and Google Chrome (or Chromium) on macOS or Linux. No browser is downloaded.

Until the first release, install from the repository:

```sh
npm ci && npm run build                    # at the repository root
cd packages/minutes-cli && npm pack        # writes subset.dev-minutes-<version>.tgz
npm install -g ./subset.dev-minutes-*.tgz  # installs the subset-minutes command
subset-minutes doctor
subset-minutes join 'https://meet.google.com/abc-defg-hij'
```

After a release, `npx @subset.dev/minutes doctor` and `npm install -g @subset.dev/minutes` will work as well.

| Command | What it does |
| --- | --- |
| `join <link>` | Opens Chrome, joins, mutes the bot, and records until the meeting ends, the time limit passes, or you stop it. Options: `--out <dir>` (default `~/Documents/Minutes Recordings`), `--name <name>` (default `Minutes Notetaker`), `--max-minutes <n>` (default 240), `--profile <dir>`, `--json`, `--stop-on-stdin-close`, and `--link-from-stdin` (read the link from the first line of stdin instead of an argument). |
| `status` | Lists current and recent sessions, with state, recording path, and errors. It reads only and creates nothing. `--json` prints the `minutes.status` object. |
| `doctor` | Checks Node.js, Chrome, the bot profile's Google sign-in, whether Chrome has the profile open, and whether the output folder is writable. `--json` prints the `minutes.doctor` object. Exits 1 when a required check fails. |
| `sign-in` | Opens Chrome with the bot profile at accounts.google.com. Sign in with the bot's Google account once, then quit that window. Meet then admits the bot as that account instead of as a guest. |
| `--help`, `--version` | |

Exit status: `0` on success (including a stopped session), `1` when a session or required check fails, and `2` for an invalid command or meeting link.

### Stopping

The first Ctrl-C (SIGINT), SIGTERM, or SIGHUP makes the bot finalize the file: it stops the recorder, writes the last audio slice, closes the file, leaves the meeting, and closes Chrome. Then it exits `0` with `ended` reason `stopped`. A second signal exits immediately with status 130, which can cut the recording short. With `--stop-on-stdin-close`, closing stdin has the same effect as the first signal. The macOS app uses this, so quitting the app also finalizes the recording.

### JSON output for agents and apps

`join --json` streams one event per line using the [`@subset/minutes` contract](../minutes/README.md#event-contract-version-1), version 1. The event types are `started`, `state`, `status`, `recording`, `error`, and `ended`. The last line is always `ended`. An invalid link produces `error` with code `invalid_link`, then `ended` with reason `failed`, and the command exits `2`:

```sh
$ subset-minutes join https://example.com/x --json
{"v":1,"at":"…","session":null,"type":"error","code":"invalid_link","message":"Only Google Meet (meet.google.com) and Zoom (zoom.us) links are supported."}
{"v":1,"at":"…","session":null,"type":"ended","reason":"failed","path":null,"bytes":null}
```

An agent should use `status --json` and `doctor --json` to read state. `join` starts a recording of other people. An agent should run it only when the user explicitly asks for that meeting, and should not run it in the background without the user's knowledge.

## Data and permissions

- Recordings: `--out`, or `~/Documents/Minutes Recordings`. File names are `minutes-<platform>-<UTC time>.webm`, and files are created with mode 0600.
- Data folder: `~/Library/Application Support/Subset Minutes` on macOS, or `~/.local/share/subset/minutes` (or `$XDG_DATA_HOME/subset/minutes`) elsewhere. `SUBSET_MINUTES_DATA_DIR` overrides it. The folder holds `google-meet-bot-profile/` (the bot's Chrome profile; `--profile`, which must be inside the home folder, or `SUBSET_MINUTES_PROFILE_DIR` overrides it) and `sessions/<id>.json` (one record per session, mode 0600).
- `SUBSET_MINUTES_CHROME_PATH` selects a Chrome or Chromium binary.
- Output, logs, and session records show only the redacted meeting link (no query string), so a Zoom passcode is never printed or stored. `doctor` does not print the bot's Google account.
- The CLI records remote meeting audio only. The bot's camera and microphone are Chrome's fake devices (with a silent microphone), so it never opens this computer's real camera or microphone and needs no camera, microphone, or screen-recording permission for them. The bot also mutes itself.
- `join --link-from-stdin` reads the link from the first line of stdin, which keeps a Zoom passcode out of the process list. The macOS app uses it.

## Development

`npm run build` at the repository root builds `@subset/minutes`, then this package. The build bundles `src/` with rolldown (with `@subset/minutes` inlined) into `dist/`: `cli.mjs` plus a lazily loaded `chrome.mjs` chunk, so `status` and `doctor` never load Playwright. `playwright-core` stays an external, pinned runtime dependency, because it resolves files relative to its own install and does not survive bundling. The build also stages `app-runtime/`, which is `dist/` plus `node_modules/playwright-core`. The macOS app embeds that copy. It is gitignored and not part of the npm package.

`npm test --workspace=@subset.dev/minutes` runs the CLI tests: help, version, and usage errors; the structured `invalid_link` error; read-only `status --json`; `doctor --json`; and SIGINT, SIGTERM, and stdin-close stops. The stop tests use `test/fixtures/fake-cli.mjs`, which is the real entry point with a fake driver, so they never start Chrome.

## Release

Releases are tag-based and follow the `@subset.dev/usage` path. This package is listed in `release-packages.json`. Bump `version` here and merge. Then push a tag `minutes-v<version>`. `.github/workflows/publish-tag.yml` resolves the tag with `scripts/resolve-release-tag.mjs`, then installs, checks, builds, tests (`npm test --workspace=@subset.dev/minutes`), packs, and publishes. The workflow itself is unchanged.

No tag has been pushed and nothing is published. Before listing the CLI as available, verify `npx @subset.dev/minutes@<version> doctor`, then a real `join` in a meeting you control.
