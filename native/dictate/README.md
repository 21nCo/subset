# Dictate (macOS)

Dictate is a macOS push-to-talk dictation app. Hold `fn`, speak, and release: Dictate transcribes the audio on the Mac with [whisper.cpp](https://github.com/ggml-org/whisper.cpp) and inserts the text into the field that had focus in the frontmost app. It lives in the menu bar, shows a small floating capsule while it listens, and keeps the last transcript in memory so it can be copied again until the app quits.

This is a port of a proof of concept. It builds locally; no signed or notarized build has been released (a signed, un-notarized build was only verified locally), and the catalog lists no available surface.

## Capability boundary

| | |
| --- | --- |
| User outcome | Text appears where the cursor is, without typing, and without sending audio to a server. |
| Source of truth | The microphone stream for the current session, and local whisper.cpp output. Settings and the current session state are stored in the `group.dev.subset.dictate` `UserDefaults` suite on the Mac; a transcript inserted into another app is cleared from that store, and the copyable last transcript lives only in memory. No transcript history is kept. |
| Model files | Downloaded on demand from the upstream `ggerganov/whisper.cpp` Hugging Face repository into `~/Documents/WhisperModels` (default `base.en`, plus its Core ML encoder). They are not bundled or committed. |
| Network | Model downloads only. The `CloudDictationBackend` and `MockDictationBackend` types are inherited scaffolds: the cloud backend sends nothing and only emits placeholder events, and the manager pins the backend to local whisper.cpp. Neither is reachable from the UI. |

### Operations

| Operation | Trigger | Effect |
| --- | --- | --- |
| Start dictation | Hold `fn`; ⌘↩ or **Start Dictation** in the window; menu bar item | Captures the focused insertion target, requests the microphone if needed, prepares the model, and streams partial transcripts. |
| Stop and insert | Release `fn` | Finalizes the transcript and inserts it into the remembered target. Insertion tries the Accessibility selected-text API first, then synthetic typing, then a clipboard paste that restores the previous clipboard string, with System Events fallbacks. Known rich web and document editors skip the Accessibility path and go straight to paste or System Events. |
| Stop (keep in Dictate) | ⌘↩ or **Stop Dictation** in the window or menu | Finalizes the transcript without inserting it elsewhere. |
| Cancel | `esc` while holding `fn` | Ends the session and discards its transcript; nothing is inserted. |
| Copy last transcript | ⇧⌘C, the copy button, or the menu bar item | Writes the last final transcript to the general pasteboard. |
| Clear | ⌘K | Clears the transcript buffer. |
| Prepare model | **Download** in Setup | Downloads the selected model and Core ML encoder. |

### Consuming surfaces

| Surface | Status |
| --- | --- |
| macOS app (`native/dictate`) | Proposed. Builds locally unsigned; launched and quit in a smoke test. Dictation, insertion, and permissions were not exercised end to end in this port. |
| iOS, keyboard extension, web, embed, agent CLI or view | Not proposed. Global hotkeys and cross-app text insertion need macOS Accessibility; a browser cannot provide them. |

No reusable `packages/` contract is extracted yet. If another surface needs dictation results, the stable seam would be the `TranscriptionEvent` stream and `SharedTranscriptState` model rather than the AppKit views.

## Permissions

| Permission | Why | When |
| --- | --- | --- |
| Microphone | Record speech | First dictation, or **Allow…** in Setup |
| Accessibility | Observe `fn` and `esc` globally, read the focused element, insert text | **Allow…** in Setup, or the first insertion |
| Automation (System Events) | Fallback paste or typing for editors that reject the other methods | Only when a fallback path runs |
| Documents folder | Models are stored in `~/Documents/WhisperModels` | First model download, if macOS asks |

`scripts/reset-permissions.sh` resets Microphone, Accessibility, and Apple Events grants for `dev.subset.dictate`. If `fn` opens the emoji picker or Apple Dictation, set System Settings > Keyboard > “Press 🌐 key to” to “Do Nothing”. Some external keyboards do not send `fn`.

## Build and run

Requires macOS 14+ and Xcode 16+ (verified with Xcode 26.4). From this directory:

```sh
./scripts/setup-whispercpp.sh   # downloads whisper.cpp v1.8.1 XCFramework (~40 MB) into .build/, checksum-pinned
xcodebuild -project Dictate.xcodeproj -scheme Dictate -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Dictate.xcodeproj -scheme Dictate -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

`DictateTests` covers the `fn` press/release state machine, abandoning a start that is still waiting for permission, settings decoding, and clipboard preservation around paste insertion. Microphone capture, transcription, and insertion into other apps still need manual checks.

### Release

`macos-release.json` opts the `Dictate` scheme into the signed Developer ID flow in [docs/macos-release.md](../../docs/macos-release.md). The hardened-runtime build carries `MacApp/Dictate.entitlements` (microphone input and Apple Events for the System Events fallback; neither needs a provisioning profile). A signed, un-notarized build was verified locally; nothing has been notarized or published.

`.build/` is gitignored. Set `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if Command Line Tools is the active developer directory. The project is generated by `ruby ProjectGenerator.rb` (requires the `xcodeproj` gem); edit the generator rather than the `.pbxproj` when adding files. A local unsigned build may need its Accessibility grant renewed after every rebuild because the code signature changes.

The headers in `whisper/vendor/` match whisper.cpp v1.8.1 and are used only for indexing; `whisper/vendor/LICENSE` carries the upstream MIT license. The build links the framework headers from the XCFramework.

## UI/UX changes from the POC

Reference products: [Wispr Flow](https://wisprflow.ai) and [superwhisper](https://superwhisper.com).

1. **Menu bar item.** The POC was an accessory app with no Dock icon, so closing its window left no way back short of relaunching. Dictate now has a menu bar item whose icon reflects idle, listening, and transcribing, with Start/Stop, Copy Last Transcript, Open Dictate, and Quit. (superwhisper's menu bar and status states.)
2. **Transcribing state in the floating capsule.** After `fn` is released, the capsule shows a spinner and “Transcribing” instead of flat level bars, and it has a VoiceOver label for each state. (superwhisper's processing indicator.)
3. **Cancel with `esc`.** Pressing `esc` while holding `fn` discards the session instead of inserting it.
4. **Setup checklist.** The window shows Microphone, Accessibility, and model status, each with an action (**Allow…**, **Open Settings**, **Download**, **Show in Finder**), and re-checks when the app becomes active. The POC showed raw status strings and never prompted for Accessibility until the first insertion. (Wispr Flow's permission-first onboarding.)
5. **Shortcuts and copy.** Window shortcuts (⌘↩ start/stop, ⇧⌘C copy, ⌘K clear) with tooltips, a visible shortcut legend including the Globe-key conflict, a copy button on the transcript, selectable text, and an empty state that explains what to do. The last transcript remains available after it is inserted. (Wispr Flow's paste-last-transcript action.)

## Provenance

Ported from `21nCo/21n`, branch `dev`, path `poc/ios/DictationPOC`, last changed in `a87f1c66d902e034b2ccebbc46af99af56ac14f4` (“NPX-7: Audio transcription - for dictation - macOS POC (#21)”); `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when copied.

Changes in the port:

- Renamed the project, target, scheme, and product to `Dictate`; bundle ID `com.example.DictationPOC.macOS` → `dev.subset.dictate`; defaults suite `group.com.example.DictationPOC` → `group.dev.subset.dictate`; bridging header, preprocessor flag, dispatch queue labels, and user-facing strings renamed.
- `setup-whispercpp.sh` no longer clones whisper.cpp into the 21n repository tree or builds it from source. It downloads the pinned upstream v1.8.1 XCFramework into `.build/`, verifies its SHA-256, and checks the vendored headers.
- `ProjectGenerator.rb` now produces the checked-in project, including the XCFramework reference, embed phase, asset catalog, and shared scheme. The POC's checked-in project had drifted from its generator.
- Added an app icon and accent color. No secrets, API keys, credentials, `xcuserdata`, `.DS_Store`, or build output were present in the source; `https://example.com/transcribe` remains as the inert cloud scaffold default.

## Superfunctions reuse review

Reviewed in `/Users/ar/dev/superfunctions` (local checkout at `9cf3812`) and the npm registry on 2026-10-09.

| Package family | Evaluated | Result |
| --- | --- | --- |
| `recfn` (`@recfn/desktop`, `@recfn/whisper` adapter, 0.1.x) | Desktop capture SDK and a whisper.cpp ASR adapter | TypeScript/Node, and the adapter shells out to a `whisper.cpp` CLI binary on finished files. Dictate needs in-process, low-latency streaming in a Swift app. Not used. |
| `filefn` (`FileFnClient` Swift product, `@filefn/client` 0.1.1) | Model download and storage | Targets uploads to a FileFn server. Dictate only downloads public model files. Not used. |
| `datafn` (Swift package, `@datafn/client` 0.1.1) | Syncing settings or transcripts | Dictate keeps one local transcript and has no sync requirement. Not used. |
| `authfn` (`AuthFnClient` Swift, `@authfn/client` 0.2.1) | Accounts for a cloud backend | No account or hosted backend exists. Revisit if the cloud backend becomes real. |
| `billfn`, `mcpfn`, `plugfn`, `apifn`, `uifn`, observability | Not applicable to a local native dictation app with no billing, agent, connector, web UI, or telemetry surface. |

Package/version used: none. Gap: there is no Superfunctions Swift package for on-device speech-to-text or cross-app text insertion.

## Unverified

- End-to-end dictation (microphone capture, model download, whisper.cpp transcription, insertion into other apps) in this port. The build links whisper.cpp, and the app launched and quit, but no audio was recorded and no model was downloaded during verification.
- Global `fn` and `esc` monitoring under Accessibility and Input Monitoring on a fresh Mac, external keyboards, and Intel Macs.
- Notarization, sandboxing, and any download or release route. A Developer ID-signed, hardened-runtime build was produced locally but not notarized or run on another Mac.
