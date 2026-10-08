# Breaks (iOS and iPadOS)

Breaks is a break reminder for iPhone and iPad. It runs focus intervals with short and long breaks, office hours, planned breaks, and limited snoozes. You can choose one of three enforcement levels. During a break it shows a full-screen ambient break view. With Screen Time authorization, it can shield chosen apps, categories, and websites while a break is running. It also has a Live Activity and Dynamic Island countdown, on-device history with a Screen Score, App Intents, Shortcuts actions, and a Focus Filter.

This is a port of a proof of concept. It is not signed, not released, and not listed as available.

## Capability boundary

| | |
| --- | --- |
| User outcome | Take regular, well-timed screen breaks, with optional system enforcement, without an account or a server. |
| Source of truth | `BreakEngine` state and settings, persisted by `BreakRepository`. Persistence uses the `group.dev.subset.breaks` app group defaults and container, so the app, the Device Activity monitor, and the shield extensions share the schedule, selection, and history. Nothing leaves the device. |
| Network | None. There is no analytics, advertising, or account. |

### Operations

| Operation | UI | Shortcut / intent |
| --- | --- | --- |
| Start a break now | **Start break** | ⌘B; App Intent “Start a Mindful Break” |
| Snooze 1, 5, or 15 minutes (daily limit) | **+1m / +5m / +15m** | ⌘1, ⌘5, ⌘0 |
| Pause / resume reminders | Header button | ⇧⌘P; “Pause/Resume Break Reminders” intents |
| End or skip an active break (depends on enforcement level) | Break screen | Return ends a break that can end early; Esc skips when allowed |
| Focus Filter | Settings > Focus | “Breaks Focus Filter” |
| Configure intervals, office hours, planned breaks, messages, backgrounds, sounds, haptics, Screen Time selection, and Shortcut automations | Settings | — |

### Targets and consuming surfaces

| Target | Bundle ID | Status |
| --- | --- | --- |
| `Breaks` (iPhone and iPad app) | `dev.subset.breaks` | Proposed. Swift sources compile for the iOS Simulator SDK; see Verification. |
| `BreakDeviceActivityMonitor` | `dev.subset.breaks.DeviceActivity` | Compiles. Applies shields at scheduled break times. |
| `BreakShieldConfiguration` | `dev.subset.breaks.ShieldConfiguration` | Compiles. Custom shield UI. |
| `BreakShieldAction` | `dev.subset.breaks.ShieldAction` | Compiles. Handles shield button actions. |
| `BreakLiveActivity` | `dev.subset.breaks.LiveActivity` | Compiles. Live Activity and Dynamic Island. |
| `BreaksTests` | `dev.subset.breaks.Tests` | Compiles. Not run on this host. |
| macOS, web, embed, agent surfaces | — | Not proposed. Screen Time shielding is iOS/iPadOS-specific. |

## Permissions and entitlements

- **Family Controls** (`com.apple.developer.family-controls`) on the app and the three Screen Time extensions. The app requests individual authorization. Shielding works only on a physical device. Distribution requires Apple to grant the Family Controls (Distribution) entitlement for each App ID.
- **App group** `group.dev.subset.breaks` on the app and all four extensions.
- **Notifications** for reminders. **Live Activities** with frequent updates.
- iOS does not allow a third-party overlay above other apps. Enforcement uses system shields and notifications.

## Build and run

Requires Xcode 26+ and the `xcodeproj` gem only to regenerate the project.

```sh
ruby ProjectGenerator.rb   # optional: regenerates Breaks.xcodeproj and its shared scheme
xcodebuild -project Breaks.xcodeproj -scheme Breaks -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Breaks.xcodeproj -scheme Breaks -destination 'platform=iOS Simulator,name=<device>' CODE_SIGNING_ALLOWED=NO test
```

Building the asset catalog needs the iOS Simulator runtime that matches the installed SDK. To run on a device, set a development team whose App IDs (app plus extensions) have the Family Controls and App Groups capabilities.

## UI/UX changes from the POC

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

Package/version used: none. Gap: there is no Superfunctions package for Screen Time (Family Controls, Managed Settings, Device Activity), Live Activities, or App Intents.

## Unverified

- **The full scheme build on this host.** The installed Xcode 26.4 has the iOS 26.4 SDK but only the iOS 18.3 Simulator runtime. `actool` therefore cannot compile `App/Assets.xcassets`. The original POC has the same catalog and is affected the same way. The app, the four extensions, and the test bundle were compiled from a scratch copy of the project with only that asset catalog omitted.
- **Unit tests** (`BreaksTests`: office-hours windows and Screen Score). They compile but did not run, because Xcode 26.4 offered no eligible simulator destination.
- **Screen Time.** Authorization, shields, and Device Activity schedules need a signed device build with Family Controls. They cannot be checked in Simulator.
- **Live Activity, notifications, sounds, haptics, App Intents, and the Focus Filter on device.**
- **Distribution.** Signing, the Family Controls distribution entitlement, TestFlight or App Store, and any release route.
