# Record (macOS and iOS)

Record is a local audio recorder for macOS, iPhone, and iPad. Press Start Recording and Record captures the microphone to an AAC (`.m4a`) file on the device, draws a live waveform, and lists saved clips with scrubbable playback waveforms. On macOS a small always-on-top panel shows the timer and a stop button while recording. On iOS, recording continues in the background, and a Live Activity shows the timer and waveform on the Lock Screen and in the Dynamic Island.

This is a port of a proof of concept. It builds locally; it is not signed, released, or listed as available.

## Capability boundary

| | |
| --- | --- |
| User outcome | Capture a voice note or any audio quickly, see that it is recording, and play, share, reveal, or delete the clip afterwards. |
| Source of truth | The recordings folder on the device: `~/Documents/Subset Record` on macOS and the app's `Documents/Subset Record` on iOS (visible in the Files app because file sharing is enabled). The list is rebuilt from the folder; there is no database, sync, or upload. |
| Format | AAC in `.m4a`, 44.1 kHz mono. The list also shows `.caf`, `.wav`, and `.aac` files placed in the folder. |
| Network | None. |

### Operations

| Operation | Trigger | Effect |
| --- | --- | --- |
| Start / stop recording | **Start Recording** (⌘R with a keyboard); the stop button in the macOS floating panel | Requests the microphone if needed, records to a new timestamped file, and saves it on stop. |
| Play / stop playback | **Play** on a clip | Plays the clip; tapping or dragging horizontally on the playback waveform seeks (VoiceOver: swipe up or down to adjust). |
| Share (iOS) / Show in Finder (macOS) | Clip action buttons | Hands the file URL to the share sheet or Finder. |
| Delete | Trash button, then confirm | Permanently removes that clip's file. |
| Reset waveform | **Reset Waveform** | Clears the idle live waveform. |
| Refresh list | App becomes active | Re-reads the recordings folder, so clips added or removed in Finder or Files appear. |

If the system stops capture (an iOS call, alarm, or Siri interruption, an encoder error, or quitting the macOS app mid-recording), Record stops the session, saves the clip recorded so far, and says so instead of continuing to show a running timer. If iOS does not grant a Live Activity, the dashboard says it is unavailable.

### Consuming surfaces

| Surface | Status |
| --- | --- |
| macOS app (`RecordMac`, scheme `Record-macOS`) | Proposed. Builds unsigned; launched and quit in a smoke test. |
| iOS/iPadOS app with Live Activity widget (`RecordiOS` + `RecordWidgetExtension`, scheme `Record-iOS`) | Proposed. Swift sources and the embedded widget compile for the iOS Simulator SDK; see Verification for the asset catalog gap. Not run on a simulator or device. |
| Web, embed, agent CLI or view | Not proposed. |

No reusable `packages/` contract is extracted. A future consumer would most likely want the recordings folder and `RecordingItem` metadata, not the views.

## Permissions and entitlements

- Microphone (`NSMicrophoneUsageDescription`) on both platforms. If access is denied, the dashboard shows an **Open Settings** action.
- iOS: `UIBackgroundModes` `audio` to keep recording in the background, `NSSupportsLiveActivities` (with frequent updates), and `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace` so recordings appear in Files.
- macOS: no sandbox entitlement is set. Writing to `~/Documents` may trigger the system Documents folder prompt. `MacApp/Record-macOS.entitlements` grants `com.apple.security.device.audio-input`, which the hardened runtime (required for notarization) needs for microphone access.

## Build and run

Requires Xcode 16+ (verified with Xcode 26.4) and the `xcodeproj` gem only if you regenerate the project. From this directory:

```sh
ruby ProjectGenerator.rb   # optional: regenerates Record.xcodeproj and its shared schemes
xcodebuild -project Record.xcodeproj -scheme Record-macOS -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Record.xcodeproj -scheme Record-iOS -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

Building the iOS asset catalog needs the iOS Simulator runtime that matches the installed iOS SDK.

### Release (macOS)

`macos-release.json` opts the `Record-macOS` scheme into the Developer ID signing and notarization script; see [docs/macos-release.md](../../docs/macos-release.md). A signed build with `--skip-notarize` was produced and verified locally on 2026-10-10 (`codesign --verify --deep --strict` passed, audio-input entitlement present). It has not been notarized or published, so there is no download.

## UI/UX changes from the POC

Reference products: [Just Press Record](https://www.openplanetsoftware.com/just-press-record/) and Apple Voice Memos.

1. **No silent deletion; explicit delete instead.** The POC kept only the five newest files and silently deleted older recordings on every refresh. That cap is gone. Each clip has a trash button with a confirmation dialog. (Voice Memos and Just Press Record keep everything until the user deletes it.)
2. **Stop from the floating panel.** The macOS always-on-top panel now has a stop button with an accessibility label, so a recording can be ended without finding the main window. (Just Press Record's always-available record and stop control.)
3. **Keyboard shortcut.** ⌘R starts and stops recording, and a tooltip shows the shortcut.
4. **User-facing copy and a permission recovery path.** The header now reads “Record” and explains where clips are stored, instead of developer notes about targets and the “Surface” status pill. A denied microphone shows an **Open Settings** button, and recording errors are shown inline.
5. **Dark mode and accessibility.** Hard-coded light RGB colors were replaced with semantic system colors, so the dashboard follows light and dark appearance. Icon-only Share, Show in Finder, and Delete buttons now have accessibility labels, and the live waveform reports its state and elapsed time.

## Provenance

Ported from `21nCo/21n`, branch `dev`, path `poc/ios/AudioPOC`, last changed in `73f7655e7cb93a3cc906a474fd62d307a0150dfb`; `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when copied.

Renames: project `AudioPOC.xcodeproj` → `Record.xcodeproj`; targets `AudioPOCiOS`/`AudioPOCMac`/`RecordingWidgetExtension` → `RecordiOS`/`RecordMac`/`RecordWidgetExtension` (both apps' product name is `Record`); bundle IDs `com.example.AudioPOC.iOS`/`.macOS`/`.iOS.RecordingWidget` → `dev.subset.record.ios`, `dev.subset.record`, `dev.subset.record.ios.widget`; app types `AudioPOCiOSApp`/`AudioPOCMacApp` → `RecordiOSApp`/`RecordMacApp`; recordings folder `AudioPOC Recordings` → `Subset Record`; error domains and user-facing strings renamed. The generator now adds shared schemes, asset catalogs (app icon and accent color), and an explicit widget dependency. No secrets, credentials, `xcuserdata`, `.DS_Store`, or build output were present in the source. The checked-in `.pbxproj` from the POC was not copied; it is regenerated.

## Superfunctions reuse review

Reviewed in `/Users/ar/dev/superfunctions` (local checkout at `9cf3812`) and the npm registry on 2026-10-09.

| Package family | Evaluated | Result |
| --- | --- | --- |
| `filefn` (`FileFnClient`/`FileFnSwiftUI` Swift products; `@filefn/client` 0.1.1) | Storing or uploading recordings | Built around uploads to a FileFn server. Record keeps files on the device and has no server. Not used; a candidate if cloud backup is added. |
| `datafn` (Swift package; `@datafn/client` 0.1.1) | Syncing recording metadata across devices | No sync requirement or backend. Not used. |
| `recfn` (`@recfn/desktop` 0.1.x) | Capture and recorder | TypeScript/Node desktop capture SDK for meeting recordings with server upload; not usable from a SwiftUI app. Not used. |
| `authfn`, `billfn`, `mcpfn`, `plugfn`, `apifn`, `uifn`, observability | Not applicable: no accounts, billing, agent tools, connectors, web UI, or telemetry. |

Package/version used: none. Gap: no Superfunctions package provides native audio capture, Live Activities, or a local recordings store for Swift.

## Unverified

- Recording, playback, seeking, and deletion were not exercised in this port (no microphone session was started).
- The iOS app and Live Activity were not run on a simulator or device. On the verification host, the iOS 26.4 Simulator runtime was not installed (only iOS 18.3), so `actool` could not compile the iOS asset catalog. The iOS and widget Swift sources were compiled with a scratch copy of the project that omitted only that catalog.
- Background recording duration limits, the interruption and system-stop handling (calls, Siri, encoder errors), and Live Activity updates on device.
- The macOS floating panel's placement, focus behavior, and quit-while-recording finalization were compiled but not exercised interactively.
- Signing, sandboxing, notarization, App Store/TestFlight distribution, and any download route.
