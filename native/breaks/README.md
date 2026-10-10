# Breaks (macOS, iOS, and iPadOS)

Breaks is a break reminder for Mac, iPhone, and iPad. It runs focus intervals with short and long breaks, office hours, planned breaks, and limited snoozes, with three discipline levels (Casual, Balanced, Hardcore).

- **macOS:** a menu bar app modelled on [LookAway](https://lookaway.com). It shows a countdown in the menu bar, a heads-up notice before each break, and a full-screen break overlay on every display that blurs or dims the screen. It pauses during calls, video playback, games, and chosen apps, and when you are away from the computer. It also shows blink and posture nudges and can open at login.
- **iOS and iPadOS:** a full-screen ambient break view. With Screen Time authorization it can shield chosen apps, categories, and websites during a break. It also has a Live Activity, App Intents, Shortcuts actions, and a Focus Filter.

Both platforms keep history and a Screen Score on the device.

This is a port of a proof of concept plus a new Mac target. The macOS app is released as [Breaks 0.1.0](https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0), signed with Developer ID and notarized; see [Release (macOS)](#release-macos). The iOS and iPadOS app is not signed, not released, and not listed as available.

## Capability boundary

| | |
| --- | --- |
| User outcome | Take regular, well-timed screen breaks, with optional system enforcement, without an account or a server. |
| Source of truth | `BreakScheduler` state (settings, snapshot, history), persisted by `BreakRepository`. On iOS, persistence uses the `group.dev.subset.breaks` app group defaults and container, so the app, the Device Activity monitor, and the shield extensions share the schedule, selection, and history. On macOS there are no extensions, and the app uses its own standard defaults (`dev.subset.breaks`). Nothing leaves the device. |
| Network | None. There is no analytics, advertising, or account. |

### Code layout: shared and platform code

| Path | Platforms | Contents |
| --- | --- | --- |
| `Shared/BreakModels.swift` | iOS, macOS, DeviceActivityMonitor, ShieldConfiguration | Settings model (including `DesktopSettings` for Mac-only options), snapshot, history records, Screen Score and stats (`BreakMath`). |
| `Shared/BreakScheduler.swift` | iOS, macOS | The schedule as a pure value type: intervals, heads-up, long-break cadence, planned breaks, office hours, snooze allowance, discipline rules, manual and timed pauses, smart pause with grace period, idle pause and reset, and blink and posture cadence. It returns events and does not touch UI or system APIs. |
| `Shared/BreakPersistence.swift` | iOS, macOS, DeviceActivityMonitor, ShieldConfiguration | `BreakRepository` and `SharedStore`. Uses the app group on iOS and standard defaults on macOS. |
| `Shared/BreakSoundCoordinator.swift` | iOS, macOS | Synthesized chimes (the `AVAudioSession` setup is iOS-only). |
| `Shared/BreakEngine.swift` and the other `Shared/*Coordinator.swift` files | iOS | Runs the scheduler and performs the iOS effects: Screen Time shields, notifications, the Live Activity, and Shortcuts. |
| `App/`, `DeviceActivityMonitor/`, `Shield*/`, `WidgetExtension/` | iOS | SwiftUI app and extensions. |
| `Mac/` | macOS | `MacBreakController` (runs the scheduler), `ActivitySignals` (idle and smart-pause signals), the break overlay, the heads-up and wellness panels, the menu bar, and Settings. |
| `Tests/` | iOS and macOS | `BreakSchedulerTests` and `BreaksTests`. The Mac test bundle compiles the shared sources directly and runs without a host app. |

The two platforms share the operations and the data model. They do not share views or enforcement. Screen Time shielding stays on iOS. It was not verified on macOS, so it is not used there. The Mac overlay window is Mac-only.

### Operations

| Operation | iOS / iPadOS | macOS |
| --- | --- | --- |
| Start a break now | **Start break**, ⌘B, App Intent “Start a Mindful Break” | Menu bar **Start break now** (⌘B while the menu is open); **Start now** on the heads-up notice |
| Snooze the next break 1, 5, or 15 minutes (daily limit) | **+1m / +5m / +15m**, ⌘1, ⌘5, ⌘0 | Menu bar **Snooze next break**; heads-up notice **Snooze** |
| Snooze a running break 1 or 5 minutes (not recorded as skipped) | — | Break overlay **Snooze**, when skipping is allowed (not for planned breaks) |
| Skip the next break (not in Hardcore) | — | Menu bar and heads-up notice **Skip** |
| Pause / resume reminders | Header button, ⇧⌘P, intents | Menu bar: for 30 minutes, 1 hour, 2 hours, or until resumed |
| End or skip an active break (depends on discipline) | Break screen: Return ends, Esc skips | Break overlay: Return ends, Esc skips |
| Focus Filter | Settings > Focus | Not implemented |
| Configure | Settings | Settings window (General, Reminders, Smart Pause, Schedule, Stats) |

### Targets and consuming surfaces

| Target | Bundle ID | Status |
| --- | --- | --- |
| `Breaks` (iPhone and iPad app) | `dev.subset.breaks` | Proposed. Swift sources compile for the iOS Simulator SDK; see Verification. |
| `BreakDeviceActivityMonitor` | `dev.subset.breaks.DeviceActivity` | Compiles. Applies shields at scheduled break times. |
| `BreakShieldConfiguration` | `dev.subset.breaks.ShieldConfiguration` | Compiles. Custom shield UI. |
| `BreakShieldAction` | `dev.subset.breaks.ShieldAction` | Compiles. Handles shield button actions. |
| `BreakLiveActivity` | `dev.subset.breaks.LiveActivity` | Compiles. Live Activity and Dynamic Island. |
| `BreaksTests` | `dev.subset.breaks.Tests` | Compiles. Not run on this host. |
| `BreaksMac` (macOS menu bar app, product `Breaks.app`, module `BreaksMac`) | `dev.subset.breaks` | Available: [0.1.0](https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0), Developer ID signed and notarized, universal (Apple silicon and Intel), macOS 14 or later. See [Release (macOS)](#release-macos). |
| `BreaksMacTests` | `dev.subset.breaks.MacTests` | 36 tests pass (scheduler and shared model). |
| Web, embed, agent surfaces | — | Not proposed. |

The Mac and iOS apps share the bundle identifier `dev.subset.breaks`, as separate platform apps would for a universal purchase. Separate identifiers are not needed until a store route is chosen.

## macOS features

Modelled on LookAway's [site](https://lookaway.com) and [docs](https://lookaway.app/docs/introduction).

| Feature | Status | How |
| --- | --- | --- |
| Menu bar app with countdown | Implemented | `MenuBarExtra`, no Dock icon (`LSUIElement`). Shows the time to the next break, the break time left, “Paused”, or “Off hours”. The countdown text can be turned off. |
| Heads-up notice before a break | Implemented | A floating, non-activating panel at the top of the display under the pointer. It shows a countdown with **Start now**, **Snooze** (1, 5, or 15 minutes, with the daily allowance), **Skip** (except Hardcore), and dismiss. You can set the lead time and position. |
| Full-screen break overlay on all displays | Implemented | One borderless window per display at screen-saver level, on all Spaces and over full-screen apps. Blur (`NSVisualEffectView`, behind-window) or dim. It shows a countdown, a message, and progress. Displays are rebuilt when they change during a break. |
| Discipline levels on the overlay | Implemented | Casual: skip and snooze anytime. Balanced: skip and snooze after 5 seconds. Hardcore: no skip or snooze. **End break** unlocks at 80% when early end is allowed. |
| Smart pause: meetings and calls | Implemented | Another process is capturing microphone input (per-process Core Audio `kAudioProcessPropertyIsRunningInput`, macOS 14.2+; on 14.0–14.1, any input-only device such as the built-in microphone running, so calls on a duplex headset are missed there), or any camera is running (`kCMIODevicePropertyDeviceIsRunningSomewhere`). Breaks records nothing and needs no microphone or camera permission. |
| Smart pause: video playback | Implemented, approximate | Another process holds a display-sleep power assertion (`IOPMCopyAssertionsByProcess`). Video players and browsers playing video do this. So do presentation apps, call apps, and keep-awake utilities such as `caffeinate`, which also pause reminders. |
| Smart pause: games | Implemented, approximate | The frontmost app declares a games `LSApplicationCategoryType`. Full-screen state is not checked. |
| Smart pause: chosen apps | Implemented | The frontmost app's bundle ID is on your list (Settings > Smart Pause > Add App…). |
| Smart pause grace period | Implemented | Reminders resume after the signal has been gone for the grace period (default 1 minute). The remaining focus time is kept. |
| Idle detection | Implemented | `CGEventSource.secondsSinceLastEventType` (no Input Monitoring permission). After 1 minute away the timer pauses, and the time already counted is given back. After 5 minutes away it starts a fresh interval when you return. Both thresholds are adjustable. A running call or video takes priority over idle. |
| Blink and posture reminders | Implemented | Short, non-interactive notes that fade after 6 seconds and do not take focus. They are also announced to VoiceOver. They wait while paused, during breaks, and near the next break. |
| Launch at login | Implemented, unverified for release | `SMAppService.mainApp`. Shows the “requires approval” state with a link to Login Items. Registration depends on a signed app in a stable location, which was not tested. |
| Settings | Implemented | Intervals, long breaks, discipline, snoozes, early end, overlay style, sound and volume, menu bar countdown, login item, heads-up, blink and posture, messages, smart pause, idle, office hours, planned breaks, today's stats, and recent history. Smart Pause also shows the signals detected right now. |
| Planned breaks, office hours, long breaks, stats | Implemented | Shared scheduler and model. |
| Reduce Motion | Implemented | Overlay and panel fades and the countdown transition are skipped when Reduce Motion is on. |
| Screen sharing or screen recording detection | Not implemented | macOS has no public API that reports another app capturing the screen. Calls that share the screen still pause through the microphone or camera signal. |
| Calendar events, Focus mode / Focus Filter | Not implemented on macOS | Hidden in Mac Settings. |
| Floating countdown that follows the pointer, global keyboard shortcuts | Not implemented | — |
| Custom break images or wallpapers, custom sounds | Not implemented on macOS | The Mac uses blur or dim and the synthesized sounds. |
| AppleScript or Shortcuts at break start or end | Not implemented on macOS | — |
| Live Activity, sync with iPhone or iPad | Not implemented | Each device keeps its own schedule and history. |
| Per-app exclusions for meeting detection | Not implemented | — |
| Onboarding, Notification Center alerts | Not implemented on macOS | The Mac uses its own panels instead of notifications. |

## Permissions and entitlements

### macOS

- **No privacy permissions.** Idle time, microphone, camera, and power-assertion state, and the frontmost app are read through public APIs that need no TCC prompt. Breaks never opens an audio or video stream and does not read window contents.
- **No entitlements and no App Sandbox** for now (direct distribution like LookAway, which installs through Homebrew). Hardened Runtime is on so the app can be notarized later. Before choosing the Mac App Store, the signals above must be verified under the sandbox.
- **Login item** through `SMAppService`. The user can approve or remove it in System Settings > General > Login Items.

### iOS and iPadOS

- **Family Controls** (`com.apple.developer.family-controls`) on the app and the three Screen Time extensions. The app requests individual authorization. Shielding works only on a physical device. Distribution requires Apple to grant the Family Controls (Distribution) entitlement for each App ID.
- **App group** `group.dev.subset.breaks` on the app and all four extensions.
- **Notifications** for reminders. **Live Activities** with frequent updates.
- iOS does not allow a third-party overlay above other apps. Enforcement uses system shields and notifications.
- **Device Activity** cannot monitor intervals shorter than 15 minutes, so planned breaks on iOS last at least 15 minutes. When a break starts, the app also registers a one-off Device Activity interval that ends with the break, so the monitor extension lifts the shields on time even if the app is suspended. Neither has been verified on a device.

## Build and run

Requires Xcode 26+ and the `xcodeproj` gem only to regenerate the project.

```sh
ruby ProjectGenerator.rb   # optional: regenerates Breaks.xcodeproj and the Breaks and BreaksMac schemes

# macOS
xcodebuild -project Breaks.xcodeproj -scheme BreaksMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Breaks.xcodeproj -scheme BreaksMac -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

# iOS
xcodebuild -project Breaks.xcodeproj -scheme Breaks -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Breaks.xcodeproj -scheme Breaks -destination 'platform=iOS Simulator,name=<device>' CODE_SIGNING_ALLOWED=NO test
```

The Mac app is the `Breaks.app` product of the `BreaksMac` scheme. It appears only in the menu bar. Building the iOS asset catalog needs the iOS Simulator runtime that matches the installed SDK. To run on a device, set a development team whose App IDs (app plus extensions) have the Family Controls and App Groups capabilities.

## iOS UI/UX changes from the POC

Reference products: [LookAway](https://lookaway.app), [Time Out by Dejal](https://www.dejal.com/timeout/), and [Stretchly](https://hovancik.net/stretchly/).

1. **Keyboard control on iPad.** With a hardware keyboard you can control breaks without touching the screen, and the shortcuts appear in the iPadOS ⌘ shortcut overlay. (Time Out and Stretchly provide keyboard control for postponing and skipping breaks.)

   | Action | Shortcut |
   | --- | --- |
   | Start a break | ⌘B |
   | Snooze 1, 5, or 15 minutes | ⌘1, ⌘5, ⌘0 |
   | Pause or resume | ⇧⌘P |
   | Start now (heads-up sheet) | Return |
   | End a break that can end early | Return |
   | Skip, when the enforcement level allows it | Esc |

2. **Visible snooze allowance.** The POC silently disabled the snooze buttons once the daily limit was used. The dashboard and the heads-up sheet now say how many snoozes are left, or explain that the limit is reached and resets tomorrow. (Time Out and Stretchly make postpone limits explicit.)
3. **VoiceOver labels.** The countdowns now read as spoken durations (“Break starts in 4 minutes, 30 seconds”) and update as they change. The snooze buttons read as “Snooze 5 minutes” with the remaining count. Pause and skip have hints, and the focus progress bar has a label.
4. **Reduce Motion.** The continuously drifting ambient gradient behind every screen freezes when Reduce Motion is on. This is calmer for motion-sensitive users and stops the per-frame redraws. (LookAway's calm, low-distraction break screens.)

## Changes to shared behavior with the Mac target

Moving the schedule into `BreakScheduler` fixed two findings from the automated review of the iOS port. Both platforms get the fixes:

- **Long-break cadence.** After the first long break, every later break was long. The counter now resets after a long break, so with “every 3 breaks” the order is short, short, long, then repeats. This is covered by a test.
- **Start now from the heads-up sheet** starts the scheduled kind (short or long). Before, it always started a short break.

Fixes from the automated review of this PR, on both platforms unless noted:

- Planned breaks run at their time outside office hours, as the Office Hours screen says. A planned break missed while the host was asleep or suspended still starts, for the time left, until its scheduled end. A running planned break cannot be snoozed, because the snooze would replace it with an interval break.
- A heads-up is withdrawn when office hours end, and shown again after a relaunch if it still applies. A break that ended while the app was not running is recorded as completed. A Focus pause survives a relaunch.
- After a smart pause, idle time is credited only for time the timer actually counted. On the Mac, time asleep counts as time away, so a long sleep starts a fresh interval.
- Longest and typical stretch, and focused time, are measured from the focus time before each break (stored with new records), not from midnight. Overnight office hours belong to the day they start. Countdowns of an hour or more show hours.
- iOS: tapping a notification only opens the app; Start and Snooze are explicit actions. Repeating blink and posture notifications are rescheduled only when their settings change. Settings edits refresh Screen Time schedules and notifications only when a relevant setting changed. The Live Activity no longer builds an invalid timer range after its end. Controls that had no effect on iOS (calendar, media, and app smart pauses, overtime nudges, reminder presentation) were removed from iOS Settings, and the haptics toggle now works.

Snoozing now resets the daily allowance before checking it, so the first snooze on a new day is not refused. Settings saved by earlier builds still decode: missing keys fall back to their defaults instead of discarding the stored settings.

## Provenance

Ported from `21nCo/21n`, branch `codex/break-reminder-poc`, path `poc/ios/BreakReminderPOC`, commit `27f1b3ea33b2ddfa896c62ec355d66c42767562e` (“feat(poc): add BreakReminder iOS POC”). The POC was not merged to `dev` when copied.

Renames:

| Item | POC | Breaks |
| --- | --- | --- |
| Project | `BreakReminderPOC.xcodeproj` | `Breaks.xcodeproj` (regenerated) |
| App target and module | `BreakReminderPOC` | `Breaks` |
| Test target | `BreakReminderPOCTests` | `BreaksTests` |
| Bundle ID prefix | `com.21n.BreakReminderPOC` | `dev.subset.breaks` |
| App group | `group.com.21n.breakreminderpoc` | `group.dev.subset.breaks` |
| Display name | Break Reminder | Breaks |
| Focus Filter | — | Breaks Focus Filter |
| Entitlements file | — | `App/Breaks.entitlements` |
| Custom asset folder | — | `Breaks/CustomAssets` |

Other changes: the generator now adds a shared `Breaks` scheme with the test target. The POC's app icon was replaced with the Subset pixel-art icon; the ambient break artwork is unchanged. No secrets, credentials, `xcuserdata`, `.DS_Store`, or build output were present.

## Superfunctions reuse review

Reviewed in `/Users/ar/dev/superfunctions` (local checkout at `9cf3812`) and the npm registry on 2026-10-09.

| Package family | Evaluated | Result |
| --- | --- | --- |
| `datafn` (Swift package; `@datafn/client` 0.1.1) | Syncing settings and break history across devices | Breaks keeps state on the device and shares it with its extensions through an app group. There is no sync requirement. Not used; revisit if cross-device history is added. |
| `authfn` (`AuthFnClient` Swift) | Accounts | No account by design. Not used. |
| `billfn` | Paid tiers | No billing. Not used. |
| `filefn`, `mcpfn`, `plugfn`, `apifn`, `uifn`, observability | Not applicable | No uploads, agent tools, connectors, web UI, or telemetry, which matches the privacy stance. |

Package/version used: none. Gap: there is no Superfunctions package for Screen Time (Family Controls, Managed Settings, Device Activity), Live Activities, App Intents, or the macOS activity signals (idle time, device-in-use, power assertions). The macOS target adds no dependencies.

## Release (macOS)

`macos-release.json` opts the `BreaksMac` scheme into the signed macOS release flow; see [docs/macos-release.md](../../docs/macos-release.md).

### Breaks 0.1.0 for macOS

- Release: [macos/breaks/v0.1.0](https://github.com/21nCo/subset/releases/tag/macos/breaks/v0.1.0), built by the **Release macOS app** workflow (run 38075115184) from the tag at commit `313b064`.
- Download: [Breaks-0.1.0.dmg](https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/Breaks-0.1.0.dmg). The release also has `Breaks-0.1.0.zip` (the stapled app) and `SHA256SUMS`.
- DMG SHA-256: `5ce3e8c78fcb273a738cdc72eec829716b5da3e945ad5ce45fe26f10d4fbd92e`. The same value is in the release's [SHA256SUMS](https://github.com/21nCo/subset/releases/download/macos/breaks/v0.1.0/SHA256SUMS) and in `@subset/catalog`.
- Version 0.1.0, bundle ID `dev.subset.breaks`, macOS 14 or later, universal binary (arm64 and x86_64).
- Signed by Developer ID Application: Blank labs private limited (SAZVPX4CAA), with the hardened runtime. The DMG and the app are notarized, and both have stapled tickets.

To install:

1. Download `Breaks-0.1.0.dmg` and, optionally, check it: `shasum -a 256 Breaks-0.1.0.dmg` must print the SHA-256 above (or run `shasum -a 256 -c SHA256SUMS --ignore-missing` next to the downloaded `SHA256SUMS`).
2. Open the DMG and drag **Breaks** to **Applications**.
3. Open Breaks from Applications and confirm the standard notice for an app downloaded from the internet. The app is notarized, so there is no unidentified-developer warning. Breaks has no Dock icon; it appears in the menu bar.
4. Optional: turn on **Open Breaks at login** in Breaks Settings > General. macOS may ask you to allow it in System Settings > General > Login Items.

Release check for 0.1.0: the release is published (not a draft); the assets were downloaded anonymously and match `SHA256SUMS`; with the DMG quarantined, `spctl` reports "Notarized Developer ID" for the DMG and the app, and both stapled tickets validate; `codesign` shows the Developer ID signature with the hardened runtime; and the app launched, ran, and quit without errors or crash reports. The catalog lists macOS as the only available Breaks surface; iOS remains proposed.

## Verification

On this host (Xcode 26.4, macOS 26):

- `BreaksMac` builds with `xcodebuild` (`CODE_SIGNING_ALLOWED=NO`), including its asset catalog and app icon.
- `BreaksMacTests` passes 36 tests: 31 scheduler tests and 5 model and repository tests. The scheduler tests cover the heads-up, break start and completion, long-break cadence, office hours, planned breaks, discipline levels, early end, snooze allowance and day rollover, snoozing a running break, skipping, timed pauses, idle pause and reset, smart pause with grace period, manual pause overriding signals, wellness cadence, restore after relaunch (including expired breaks, heads-up, and Focus pauses), late and off-hours planned breaks, idle credit after a smart pause, legacy settings decoding, and the history cap. The model tests cover overnight office hours, stretch statistics, and hour-long countdowns.
- The built app launched from DerivedData and quit through `osascript` without a crash. A break restored from saved state completed and was recorded. An idle pause was then recorded correctly while the host had no input.
- The iOS app, its four extensions, and `BreaksTests` compiled for the iOS Simulator SDK from a scratch copy without `App/Assets.xcassets` (see below).

## Unverified

- **macOS on screen:** the overlay's look on several displays and over full-screen apps, the heads-up and nudge panels, keyboard handling on the overlay, the menu bar label, and the Settings window were not inspected visually. Each smart-pause signal against real calls, video, and games. The login item with a signed build. Behavior under App Sandbox.
- **macOS distribution:** the 0.1.0 Developer ID download is verified (see [Release (macOS)](#release-macos)). The login item in the released build and any Mac App Store route are not.
- **The full iOS scheme build on this host.** The installed Xcode 26.4 has the iOS 26.4 SDK but only the iOS 18.3 Simulator runtime. `actool` therefore cannot compile `App/Assets.xcassets`. The original POC has the same catalog and is affected the same way. The app, the four extensions, and the test bundle were compiled from a scratch copy of the project with only that asset catalog omitted.
- **iOS unit tests.** `BreaksTests` and `BreakSchedulerTests` compile for iOS but did not run there, because Xcode 26.4 offered no eligible simulator destination. The same test sources pass on macOS against the shared code.
- **iOS behavior after the scheduler refactor.** `BreakEngine` now delegates to `BreakScheduler`. It compiles, but it was not exercised on a device or simulator.
- **Screen Time.** Authorization, shields, and Device Activity schedules need a signed device build with Family Controls. They cannot be checked in Simulator.
- **Live Activity, notifications, sounds, haptics, App Intents, and the Focus Filter on device.**
- **Distribution.** Signing, the Family Controls distribution entitlement, TestFlight or App Store, and any release route.
