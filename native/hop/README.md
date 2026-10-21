# Hop (macOS)

Hop is a menu-bar app for switching between individual windows from the keyboard: hold a shortcut to see the open windows with their app icons and titles, optionally with live previews, and release to bring one to the front. It is a Subset capability in the `planned` state.

This folder holds the app shell ([SET-90](https://linear.app/21n/issue/SET-90)) of the Hop outcome ([SET-89](https://linear.app/21n/issue/SET-89)): a menu-bar app with a status menu and an empty Settings window, a testable `HopCore` package, a generated Xcode project, macOS CI, and a check that fails the build if Hop links a private macOS API. [SET-91](https://linear.app/21n/issue/SET-91) adds the Accessibility onboarding and the hold-to-switch shortcut (see [Shortcut and permission](#shortcut-and-permission)). [SET-92](https://linear.app/21n/issue/SET-92) adds the window list: Accessibility enumeration, the closed inclusion rules, and the recency order (see [Window list](#window-list)). [SET-93](https://linear.app/21n/issue/SET-93) adds the operations on a listed window: focus, minimize, close, hide its app, and quit its app (see [Window operations](#window-operations)). [SET-94](https://linear.app/21n/issue/SET-94) adds the switcher and the hold-⌥-Tab flow end to end: the panel, its grid, the keys and the mouse, and committing to focus (see [Switcher](#switcher)). With it Hop works as a window switcher. [SET-95](https://linear.app/21n/issue/SET-95) adds the Settings window: the shortcut, which windows are shown, excluded apps, launch at login, and the Accessibility status (see [Settings](#settings)). Search, the same-app shortcut and previews are SET-96 and SET-97.

## Capability boundary

**User outcome:** move to any open window, not just any app, from the keyboard.

**Sources of truth:**

| Data | Source | Issue |
| --- | --- | --- |
| Windows, titles, and their apps | The Accessibility API (`AXUIElement`) of each running app, under the user's Accessibility permission | SET-92 (implemented) |
| Recency order | The window server's front-to-back order at launch, then focus changes Hop observes while it runs, kept in memory | SET-92 (implemented) |
| The hold-to-switch shortcut | A keyboard event tap, under the Accessibility permission; the shortcut itself from user defaults | SET-91 (implemented) |
| Live previews (opt-in) | ScreenCaptureKit, under the user's Screen Recording permission | SET-97 |
| Settings | The app's user defaults, under `dev.subset.hop.settings` | SET-95 (implemented) |

Hop uses public macOS APIs only: no private CoreGraphics or SkyLight functions (`CGS*`, `SLS*`) and no `_AXUIElementGetWindow`. That rules out replacing ⌘Tab and means nothing is guaranteed about windows on other Spaces. Window titles are never logged, written to disk, or sent anywhere; only settings persist.

**Explicit operations**

| Operation | Kind | State |
| --- | --- | --- |
| Settings…, About Hop, Quit Hop | App shell | Implemented here |
| Ask for Accessibility and install the hold-to-switch shortcut | Permission | Implemented (SET-91) |
| List switchable windows in recency order | Read | Implemented (SET-92); the switcher reads it when it opens and after an operation |
| Focus, minimize, or close a window, or hide or quit its app | Mutation of another app's window | Implemented (SET-93); releasing the shortcut focuses, and ⌘M, ⌘W, ⌘H and ⌘Q in the switcher call the others (SET-94) |
| Show the switcher while the shortcut is held and switch on release | Read, then focus | Implemented (SET-94) |
| Change the shortcut, shown windows, excluded apps, and launch at login | Settings | Implemented (SET-95) |
| Type to filter; switch between one app's windows with ⌥` | Read, then focus | Planned (SET-96) |
| Show live window previews, after Screen Recording consent | Read | Planned (SET-97) |

| Owner | Responsibility |
| --- | --- |
| `Core/` (`HopCore`) | Domain logic in pure Swift: no AppKit, SwiftUI, or ApplicationServices imports (`CoreBoundaryTests` checks this). It holds the app identity, the status menu's command list, the switch session state machine (`SwitchSession`), the shortcut (`Shortcut`), the settings and their store (`Settings`, `ShownWindows`, `SettingsStore`), how the Settings window shows launch at login (`LoginItemStatus`), the event classifier (`EventClassifier`, `ShortcutRecognizer`), the permission state (`AccessibilityGate`), and the window list: its model (`WindowEntry`, `AppEntry`, `WindowRef`), the `WindowSource` protocol and `FixtureWindowSource`, the inclusion rules (`WindowFilter`), the recency order (`RecencyTracker`), the list builder (`WindowLister`), the focus subscription retry state and observer ownership (`FocusSubscription`, `FocusObservers`), and the window operations: their API (`WindowOperation`, `OperationResult`, `WindowOperator`, `RecordingWindowOperator`) and their sequencing over Accessibility and app adapters (`AccessibilityWindowOperator`, `WindowAccessibility`, `AppControl`), and the switcher's state: its cells (`SwitcherItem`, a window or a windowless app, filtered by `SwitcherFilter`), its grid (`SwitcherLayout`, `SwitcherMetrics`) and its list, selection, scroll position and messages (`SwitcherViewModel`). Geometry uses CoreGraphics value types only. |
| `MacApp/` | The menu-bar host: the status item, the Settings window and the model behind it (`SettingsWindowController`, `SettingsModel`, with launch at login through `MainAppLoginItem`), the About panel, the onboarding window, the Accessibility check, the keyboard event tap (`EventTap`, driven by `SwitchShortcutController`) and the layout lookup for its operation keys (`KeyLayout`), the live window source (`AXWindowSource`) with its focus observers (`WindowListController`), the live window operator (`AXWindowOperator`), and the switcher: its panel and SwiftUI grid (`SwitcherPanel`, `SwitcherContentView`) and the controller that runs it (`SwitcherController`). SET-97 puts the ScreenCaptureKit bridge here. |

No other app, package, or product imports this code.

## Surfaces

| Surface | State |
| --- | --- |
| macOS app (`Hop.app`) | Proposed. Builds unsigned; the status menu was checked on the development Mac. No signed build or download. |

The catalog lists `hop` as `planned` with no available surface. Not yet verified: a signed or notarized build and owner acceptance (SET-100), compatibility with real apps, displays, and Spaces (SET-98), and VoiceOver and keyboard use (SET-99).

## Build and test

Requires macOS 14 or later. The package builds and tests with Command Line Tools or Xcode 26:

```sh
swift test --package-path native/hop
swift run --package-path native/hop Hop   # unbundled executable, for quick local runs
```

`swift test` runs two test targets: `HopCoreTests` (the core, also in the Xcode project) and `HopAppTests`, which imports the app module to inspect the switcher panel's accessibility tree and to run `SwitcherController` against a scripted window list and `RecordingWindowOperator`, the tap handler of `SwitchShortcutController` (`SwitchShortcutTests`), the Settings window's model with a fake login item (`SettingsModelTests`), and the operation keys against installed keyboard layouts (`KeyLayoutTests`). `HopAppTests` exists only in the package; the Xcode project's test bundle covers `HopCore`.

`Hop.xcodeproj` is generated by `ProjectGenerator.rb` (xcodeproj 1.27) from the same sources: a static `HopCore` library, the `Hop` app (scheme `Hop`), and the `HopCoreTests` bundle. Regenerate it after adding or removing a source file; generation is reproducible, and CI fails if the committed project differs. Regenerating replaces only `project.pbxproj` and the shared `Hop` scheme, so breakpoints, personal schemes and workspace state in `xcuserdata` stay; `Tests/project-generator.sh` checks that. The generator needs exactly xcodeproj 1.27.0:

```sh
gem install --user-install xcodeproj -v 1.27.0
cd native/hop
ruby ProjectGenerator.rb
xcodebuild -project Hop.xcodeproj -scheme Hop -destination 'platform=macOS' \
  -derivedDataPath build CODE_SIGNING_ALLOWED=NO build test
sh scripts/check-private-symbols.sh build/Build/Products/Debug/Hop.app build/Build/Products/Debug/libHopCore.a
```

`scripts/check-private-symbols.sh` lists the undefined symbols (`nm -u`) of every Mach-O file in the app bundle (a Debug build keeps the app's code in `Contents/MacOS/Hop.debug.dylib`, not in `Contents/MacOS/Hop`) and of `libHopCore.a`, and exits 1 if any is a `CGS…` or `SLS…` function or `_AXUIElementGetWindow`, with any number of leading underscores (the C function `_CGSDefaultConnection` is `__CGSDefaultConnection` in `nm`). A forbidden name continues with an uppercase letter, so public functions such as `CGShadingRelease` and `CGSessionCopyCurrentDictionary` pass. It exits 2, never 0, when a listing, a file, or any folder in the bundle cannot be read, or when a path in the bundle contains a newline. A function looked up at run time with `dlsym` is not an undefined symbol, so the check cannot see it; review covers that. `Tests/private-symbols.sh` compiles small object files that call forbidden and public functions and checks the results, including unreadable listings, files, and folders and names containing a newline, and checks that the recorded listing of the shell (`Tests/Fixtures/shell-undefined-symbols.txt`) passes and fails once `_CGSCopyWindowProperty` is added.

The app is `LSUIElement` (menu bar only, no Dock icon), runs with the hardened runtime, and has no App Sandbox. `MacApp/Hop.entitlements` is intentionally empty. There is no network access, privileged helper, or telemetry, and Hop is free: no billing or license checks. The bundle ID is `dev.subset.hop`. `MARKETING_VERSION` is 0.1.0, the first version; there is no app icon yet.

`.github/workflows/hop.yml` runs on macOS 26 for changes here: package tests, the private-symbol check's tests, the generated-project check, an unsigned `xcodebuild build test`, and the private-symbol check on the built app and `libHopCore.a`. `macos-release.json` describes the app for `scripts/release-macos.mjs` (see [docs/macos-release.md](../../docs/macos-release.md)). Hop is not opted out of beta builds: betas are built only on request, and the first Hop beta is built by the beta handoff after the last Hop issue is merged. A manual **Beta builds** run with `only` empty would also build Hop once this folder is on `dev`.

## Permissions

Hop asks for Accessibility (see [Shortcut and permission](#shortcut-and-permission)). The permissions Hop needs:

| Permission | Why | Issue |
| --- | --- | --- |
| Accessibility | Read windows and their titles, focus and act on them, and receive the shortcut through an event tap | SET-91, SET-92, SET-93 |
| Screen Recording | Live window previews, only after the user turns them on | SET-97 |

The default mode needs only Accessibility.

## Shortcut and permission

**Permission.** The event tap is created only while `AXIsProcessTrusted()` is true. Hop samples trust at launch, whenever it becomes active, every 2 seconds while the onboarding window is open, and when the system disables the tap; it never polls otherwise. When trust is granted, Hop installs the tap and closes the onboarding window; when it is revoked, Hop removes the tap (cancelling any switch in progress) and the status item shows a warning symbol, "Hop: needs Accessibility access" as its label and tooltip, and an **Allow Accessibility Access…** item at the top of its menu. Any sample that finds trust held closes the onboarding window. If Hop is trusted but the system refuses the tap, the status item shows the warning symbol with "Hop: shortcut unavailable", offers no permission item, and retries at the next sample. Revoking access while Hop is in the background is noticed at the next of those samples.

**Onboarding.** The onboarding window opens by itself only on the first launch without trust (the `onboarding.shown` user default records that it has), and otherwise from **Allow Accessibility Access…**. It says that Hop needs Accessibility to see and raise windows and to notice its shortcut, and that nothing leaves the Mac. **Open Privacy & Security** calls `AXIsProcessTrustedWithOptions` with the prompt option, the public way to add Hop to the Accessibility list (macOS may show its own permission alert as well), and opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`.

**Shortcut.** Hold ⌥ and press Tab to start a switch forward, or ⌥⇧Tab to start it backward. The shortcut is a setting (see [Settings](#settings)): ⌥ or ⌃ held with Tab or `, with ⇧ for the backward direction; ⌘ is refused, because taking over ⌘Tab needs a private API. Below, ⌥ stands for the holding modifier and Tab for the key.

**Event tap.** `CGEvent.tapCreate` at `.cgSessionEventTap`, inserted at the head, for key-down, key-up and flags-changed events, on the main run loop in the common modes. Every event goes through `ShortcutRecognizer`, which is pure and unit-tested, and the tap does only what it returns:

| Input | Idle | Switch active |
| --- | --- | --- |
| The shortcut (⌥Tab) | Swallowed; opens the switcher on the previous window (index 1, or 0 with one window; "No windows" with none) | Swallowed; next window |
| The shortcut with ⇧ (⌥⇧Tab) | Swallowed; opens the switcher on the previous window too (index 1, or 0) | Swallowed; previous window |
| → / ← with the holding modifier, optionally plus ⇧ | Passes | Swallowed; next / previous window |
| ↓ / ↑ with the holding modifier, optionally plus ⇧ | Passes | Swallowed; the window below / above in the grid |
| M, W, H or Q with the holding modifier and ⌘ (⌥⌘M, ⌥⌘W, ⌥⌘H, ⌥⌘Q) | Passes | Swallowed; minimizes or closes the selected window, or hides or quits its app; the switcher stays open |
| Esc with the holding modifier, optionally plus ⇧ | Passes | Swallowed; cancels |
| Release of the holding modifier | Passes | Passes; commits the selection |
| Any other key, or the shortcut, an arrow, Esc or an operation key with other modifiers (⌃Tab, ⌘⌥Tab, ⌃⌥Tab, ⌘⌥→, ⌥⇧⌘W) | Passes | Passes; changes nothing while the holding modifier is down (⌘⌥Tab, ⌃⌥Tab, ⌘⌥→, ⌥⇧⌘W) |
| Any key event without the holding modifier | As above | Commits the selection, because the modifier's release was missed; a new key-down passes, and a repeat or key-up keeps its press's disposition |
| Auto-repeat and key-up of a held key | Swallowed exactly when the press's first key-down was, even after the switch ended, unless the tap was disabled or removed in between | Same; repeats of a swallowed Tab or arrow keep moving the selection, other repeats (including an operation key's) change nothing |
| The tap disabled by the system (timeout or user input) | Re-enabled at once | Re-enabled at once; cancels |

Modifier changes always pass, so no app sees a modifier stuck down. Each physical press is decided once, at its first key-down: an app receives all of a press (its key-down, repeats and key-up) or none of it, so a key held from before a switch keeps working in its app and never steps or cancels the switch, and a Tab held after ⌥ is released never reaches the app. The exception is an interruption: when the system disables the tap or Hop removes it, Hop forgets the presses in progress, because their key-ups may have been missed, so a key-up whose key-down was swallowed can then reach an app. A repeat never starts or cancels a switch, and holding an operation key acts once. A key event that arrives without the holding modifier while a switch is active means its release was missed, so the switch commits; the event passes if it is a new key-down and otherwise keeps its press's disposition. If the system disables the tap and trust is gone, the tap is removed instead of re-enabled.

The operation keys match the character the current keyboard layout gives the key with ⌘ held, as menu key equivalents do (`KeyLayout`: the current input source's `kTISPropertyUnicodeKeyLayoutData` translated with `UCKeyTranslate` and the ⌘ modifier). So ⌥⌘W closes on AZERTY too; Hebrew, Greek and Russian, which give the Latin letters under ⌘, operate on those; and on "Dvorak - QWERTY ⌘" the QWERTY W key closes. A key whose ⌘ character is ASCII punctuation is no operation key and passes, even on the US M, W, H or Q position (AZERTY's comma, Dvorak's comma and apostrophe); only a key with no ASCII ⌘ character (or none at all) matches by its US position instead. What the session's events do to the list and the selection is the switcher's (see [Switcher](#switcher)).

**Not verified here.** Creating the tap needs a trusted process, so the tap itself, the permission prompt and System Settings link, revocation while running, and behavior with real apps, displays and Spaces are checked in SET-98; VoiceOver and keyboard-only use of the onboarding window in SET-99. Unit tests cover the session, the classifier (including the row and operation keys and their layout matching), the shortcut's validation and the permission state; `KeyLayoutTests` runs the operation keys through the installed US, French, Dvorak, Dvorak - QWERTY ⌘, Hebrew, Greek and Russian layouts.

## Window list

`WindowLister.refresh()` builds the list the switcher shows: one `WindowEntry` per switchable window of every regular app, most recently used first. An entry has an opaque `WindowRef` (assigned by the source and never shown), the app's pid, bundle ID and name, the window's title (possibly empty), whether it is minimized, whether its app is hidden, whether it is full screen, its frame, and the display it overlaps most. A regular app that answers but has no switchable window gets an `AppEntry` (pid, bundle ID, name, whether it is hidden) for the Apps with no open windows option (see [Settings](#settings)). The list is rebuilt only when `refresh()` is called, which the switcher does when it opens and after an operation; in between, notifications only update the recency order.

**Enumeration.** `AXWindowSource` reads each running app with the `.regular` activation policy: its `kAXWindowsAttribute`, then each window's `kAXTitle`, `kAXSubrole`, `kAXMinimized`, `kAXPosition`, `kAXSize` and `AXFullScreen` in one request. Each app has 0.25 s, from the start of the refresh, for all of its requests together: before each one the messaging timeout (`AXUIElementSetMessagingTimeout`) is set to the time the app has left, so an app with many slow windows costs that budget, not a timeout per window. Every app is read at the same time on its own thread, and the refresh stops waiting 50 ms after the budget, so `refresh()` takes at most 0.3 s however many apps are slow (up to twice that if it starts while the launch seed is reading the apps). An app that runs out of time or fails is left out of that refresh, reported in `WindowList.skippedApps`, and counted in `WindowLister.skippedAppCount` (logged at debug level with the other counts), and the other apps are listed. A window ref lasts as long as Accessibility reports an equal element for the window, whatever order reads and focus changes finish in (`WindowRefRegistry`): each ref records when its window was last confirmed present (by a read, as of the read's start, or by a focus change, as of that change), a read drops only the refs last confirmed before it began that it did not see, and a read that began before the app's last completed read or before the app quit keeps no ref and changes nothing. So a window focused after a read began keeps its ref through that read, whichever read first listed it. So a closed window's ref is dropped by the next completed read of its app, and all of an app's refs when it quits.

**Inclusion rules** (`WindowFilter`, closed; each has a test vector):

| Rule | Result |
| --- | --- |
| Subrole `AXStandardWindow` or `AXDialog` | Included |
| Subrole `AXFloatingWindow`, `AXSystemDialog`, any other subrole, or none | Excluded |
| Narrower or shorter than 40 pt, or size unreadable | Excluded |
| Hop's own windows (its process, or the `dev.subset.hop` bundle ID) | Excluded |
| App activation policy not `.regular` | Excluded |
| Minimized windows; windows of hidden apps | Included, flagged `isMinimized` / `isAppHidden` |

Anything outside these rules is out of scope here and belongs to SET-102.

**Recency.** `RecencyTracker` orders windows by `WindowRef`. When Hop gains Accessibility access (at launch, if it has it), it seeds the order from the front-to-back order of `CGWindowListCopyWindowInfo(.optionOnScreenOnly)`, matching each normal-layer window to a listed window of the same process whose frame is equal within 1 pt; when two windows of one app have the same frame, the first on-screen match takes the first in source order. Minimized windows and windows of hidden apps are not on screen, so they are never matched. Only owners, layers and bounds are read, never window names. After that, an app's activation (`NSWorkspace.didActivateApplicationNotification`) brings its focused window to the front (or, if that cannot be read, its most recent known window), and so does a `kAXFocusedWindowChangedNotification` or `kAXMainWindowChangedNotification` from the frontmost app, observed per app. Hop subscribes to these notifications before it seeds, and once the frontmost app's subscription is in place it reads that app's focused window again, so a window the user moved to while Hop was starting comes first. An app that does not answer when Hop subscribes to one of these notifications keeps the ones it accepted and is asked for the rest when it is next activated. Windows never seen focused follow the known ones in source order. A refresh drops windows that are no longer listed, except those of an app skipped in that refresh, whose windows are unknown rather than closed.

**Threads.** The keyboard tap runs on the main thread, so the only Accessibility requests made there are `refresh()`'s, bounded as above. Seeding, the focus notifications' callbacks, and the focused-window reads after an activation run on a dedicated thread with its own run loop; a lock serializes their recency updates with `refresh()`. Subscribing to and removing the notifications are requests an app may not answer for the messaging timeout, so they run on a worker queue, every app's at once, and never hold up the callbacks or stopping; a subscription that completes after Hop stopped tracking or after its app quit is removed again (`FocusObservers`).

**Spaces.** Hop lists what the public Accessibility API reports. Windows on other Spaces may be missing, and full-screen windows in their own Space may be too. Hop does no Space switching beyond what activating an app does.

**Not verified here.** The live source needs a trusted process and real apps, so enumeration, timeouts, focus notifications and seeding against real third-party apps, displays and Spaces are checked in SET-98. Unit tests cover the rules, the list builder with a fixture source (including apps that time out or overrun their deadline, more slow apps than CPU cores costing one budget, a seed that reads each app once, and a 200-window list, which must build in under 50 ms and logs its time), the recency order, and the retry of a focus subscription an app did not answer.

## Window operations

`WindowOperator.perform(_:on:)` acts on a `WindowEntry` and returns an `OperationResult`, so the switcher can show a failure instead of silently doing nothing: `.done`, `.windowGone` (the window no longer exists; its app runs), `.appGone` (the app exited, or another app now has its pid), `.refused(reason)` (a short reason that never contains a window title), or `.notPermitted` (Hop is not trusted). `AccessibilityWindowOperator` (in `HopCore`) sequences each operation over two adapters, `WindowAccessibility` and `AppControl`; the host's `AXWindowOperator` gives it the live ones, which reach a window through the element `AXWindowSource` keeps for its ref, so a ref whose window a read found closed is `.windowGone`. `RecordingWindowOperator` stands in for it in tests of the switcher (`SwitcherControllerTests`).

| Operation | What Hop does | Done when |
| --- | --- | --- |
| focus | Unhides the app if it is hidden; sets `kAXMinimized` false if the window is minimized; `AXRaise`; sets `kAXMain` true; `NSRunningApplication.activate(options: [])`; sets the app's `kAXFrontmost` true. A step the window does not support is skipped, and a window without a readable `kAXMinimized` (such as a dialog) is taken as not minimized. | Within 0.5 s, the app's `kAXFrontmost` reads back true and its `kAXFocusedWindow` reads back as the window; the focused window alone is not enough, since a background app's can already be the window (read every 25 ms; no read starts after 0.5 s and a read answering after it does not count). Otherwise one read of the window's `kAXRole` decides: `.windowGone` if the window has closed, else `.refused("did not come to front")` |
| minimize | Sets `kAXMinimized` true | The request succeeds; otherwise `.refused("can't be minimized")` |
| close | Presses the window's `kAXCloseButton` | The press succeeds. If the app then asks to save, Hop does not answer: the result is `.done` and the prompt stays. No close button is `.refused("can't be closed")` |
| hideApp | `NSRunningApplication.hide()` | The request is delivered, or the app is already hidden; otherwise `.refused("did not hide")` |
| quitApp | `NSRunningApplication.terminate()`, a normal quit the app may answer with a prompt. Hop never force-quits, and Finder is never quit: `.refused("Finder can't be quit")` | The request is delivered; otherwise `.refused("did not quit")` |

Every operation first checks `AXIsProcessTrusted()` (`.notPermitted` with no request made otherwise) and that the app still runs with the entry's bundle ID (`.appGone` otherwise). The app's hidden and the window's minimized state are read when the operation runs, not taken from the list, which may be older. A failed request is `.windowGone` if the window's element is invalid or Hop no longer knows its ref while the app runs, `.appGone` if the app has exited, `.notPermitted` if trust was lost meanwhile, and `.refused("not responding")` if the app did not answer in time; an app that does not answer ends the operation at that request.

**Threads.** `perform` is `async`: operations run in order on one serial queue of their own, never on the main thread, so the switcher is not blocked while an app answers. Every Accessibility request has the 0.25 s messaging timeout. Nothing about a window, and never a title, is logged.

**Not verified here.** Acting on real third-party apps' windows needs a trusted process, so focus, minimize, close, hide and quit against real apps, displays and Spaces (including whether activation from a background Hop is honored, and how apps with save prompts behave) are checked in SET-98. Unit tests with fake Accessibility and app adapters cover the exact request order for focus on a normal, minimized, and hidden-app window, the read-back and its refusal (including a confirmation that arrives after the deadline, an app whose focused window is the window but that does not come to the front, a slow read that is retried, and a window that closes before it reads back), a window whose minimized state cannot be read, a window that closed, an app that exited before or during an operation, missing or lost trust (no request made), each operation's request and refusal, Finder's refusal, the absence of any force-quit, and that operations run off the main thread without blocking it.

## Switcher

Hold ⌥ and press Tab: the switcher opens on the previous window. Tab and ⇧Tab move the selection, and releasing ⌥ brings the selected window forward.

**Opening.** The tap's callback must return quickly, so the trigger only marks the switcher to open on the next pass of the main run loop, and the callback never reads the window list. What the session does before then (steps, operation keys, the release, Esc) is held and applied in order once the switcher has opened, so every key applies to the list it was meant for; a switch cancelled before then never opens. Opening reads the window list (`WindowListController.refresh()`, at most 0.3 s), applies the Shown-windows settings and excluded apps to it (see [Settings](#settings)), builds a `SwitcherViewModel`, and shows the panel. If Hop has lost the Accessibility permission, the trigger shows the onboarding window instead and the switcher does not open.

**Panel** (`SwitcherPanel`). A borderless, non-activating `NSPanel` at the `.popUpMenu` level that joins all Spaces and full-screen spaces (`.canJoinAllSpaces`, `.fullScreenAuxiliary`, plus `.stationary` and `.ignoresCycle`). It never becomes key or main and never activates Hop, so the frontmost app keeps its focus. It is centered on the usable area (without the menu bar and Dock) of the screen that contains the pointer, and hidden on commit or cancel.

**Grid** (`SwitcherLayout`, `SwitcherMetrics.standard`). Cells are 152 × 112 pt with 8 pt between them and 16 pt of padding. There are as many columns as fit 90% of the screen's usable width, filled row by row in recency order; the last row may be shorter and starts at the leading edge. At most 5 rows show (fewer if 90% of the usable height holds fewer, never less than 1), and the rest scroll: the selection is kept in view with the least scrolling, and the scroll wheel or trackpad scrolls by whole rows. A cell shows the app's icon at 64 pt and the window's title on one line, truncated in the middle, or the app's name when the title is empty. A minimized window and a window of a hidden app get a badge on the icon (a minus and a crossed-out eye) and a dimmed icon. The selection is a rounded highlight in the accent color with a 2 pt border; with Increase Contrast the fill is stronger and the border is 3 pt in the primary color. It moves with a 0.12 s animation, or none with Reduce Motion. An empty list shows "No windows".

**Keys** (through the event tap; see [Shortcut and permission](#shortcut-and-permission) for exactly which presses count):

| Key, with ⌥ held | Effect |
| --- | --- |
| Tab or →; ⇧Tab or ← | Next or previous window, wrapping around |
| ↓ or ↑ | The same column in the next or previous row. When that row is the ragged last row and stops short of the column, its last cell. Past the last or first row it wraps to the other end; with one row it stays put |
| ⌘M, ⌘W, ⌘H, ⌘Q | Minimize or close the selected window, or hide or quit its app; the switcher stays open |
| Esc | Cancel: hide the switcher and change nothing |
| Releasing ⌥ | Commit: bring the selected window forward |

**Mouse.** Hovering over a cell selects it, and a click commits it: the press records the window under the pointer, and the release commits that window only if the cell under the pointer still shows it, so a list that changed in between (after an operation or a refresh) drops the click rather than commit another window. Hover counts only once the pointer has moved since the panel appeared, so a panel opening under a resting pointer keeps the keyboard's selection. A click ends the session, so the later release of ⌥ does nothing. The panel is never key and Hop is not active, so `SwitcherContentView` receives the pointer through an always-active tracking area, takes every click and scroll itself, and finds the cell from `SwitcherLayout`; the SwiftUI grid only draws.

**Operations** (⌘M, ⌘W, ⌘H, ⌘Q). The operation runs on the selected window off the main thread while the switcher stays open. When it is done, the switcher shows its effect at once (a minimized window or a hidden app's windows get their badge; a window or app the operation found gone leaves the list), then reads the list again 0.25 s later and whenever an app quits while it is open. A delivered close or quit removes nothing before that read: the app may be asking to save, so its window stays listed and selected until a read no longer lists it. The selection stays on its window wherever the list moves it; if the window is gone, the selection moves to the window that followed it (or, with none after it, the one before). A result other than `.done` shows a message under the grid for 1.5 s. `.notPermitted` opens the onboarding window and does not read the list again. A result that arrives after the switcher has closed changes nothing, except that `.notPermitted` still opens onboarding.

**Pending operations.** An operation is pending until the list has been read again after its result (or until `.notPermitted`). An operation key pressed meanwhile, and the keys after it, wait and then act on the selection in the list as read, so a second ⌘W closes the next window only once the first is gone and never another window while the first shows a save prompt. Releasing ⌥ or a click meanwhile hides the switcher at once and, after that read, focuses the selected window, or the clicked one only if it is still listed. Hovering after a key that waits waits too, and then selects the window the pointer was over if it is still listed, so it never moves an earlier ⌘W or ⌘Q onto another window. A read that an app did not answer in time (`WindowList.skippedApps`) keeps that app's windows listed where they were, since they are unknown rather than gone, so a waiting ⌘W or ⌘Q, or a release, stays on the window it meant; this holds for the read after an operation and for the read when an app quits. Opening the switcher again drops a commit that is still waiting.

**Commit.** The switcher hides at once and runs `.focus` on the selected window. A result other than `.done` shows the panel again with only the message for 1.5 s before it hides, unless a new switch has started; `.notPermitted` opens the onboarding window instead. With no windows, commit only hides the switcher.

| Result | Message (for focus; the other operations read "Couldn't minimize the Xcode window", "Couldn't close the Xcode window", "Couldn't hide Xcode", "Couldn't quit Xcode") |
| --- | --- |
| `.done` | None |
| `.refused` | "Couldn't bring Xcode forward" |
| `.windowGone` | "That Xcode window has closed" (none after ⌘W) |
| `.appGone` | "Xcode has quit" (none after ⌘Q) |
| `.notPermitted` | "Hop needs Accessibility access" in an open switcher; onboarding opens |

Messages name the app, never the window.

**Accessibility.** The panel's content is a group, "Hop window switcher", that contains the grid as an `AXList` ("Windows"). Each cell is labelled with the window's title, its app's name and its badges, such as "Report.pdf, Preview, minimized" (an empty title is left out), and the selected cell is marked selected. When the selection changes, the list posts a selected-children change and the selected cell's label is announced. "No windows" and the message are static text, and a new message is announced too. The SwiftUI drawing is hidden from Accessibility so nothing is read twice.

**Threads and privacy.** The switcher runs on the main thread, as the tap does; reading the list blocks it for at most 0.3 s, and operations run on the operator's own queue. Titles are shown in the panel and given to Accessibility only; Hop logs the switcher's window count, operation names and result kinds (never a reason, title or app name).

**Not verified here.** The live switcher needs the event tap, so it needs a trusted process. Opening over real apps, focus and operations on their windows, hover and clicks reaching the non-activating panel while another app is active, the panel over full-screen apps, on several displays and on other Spaces are checked in SET-98, and VoiceOver and keyboard-only use in SET-99. `SwitcherViewModelTests` and `SwitcherLayoutTests` cover the grid for 1, 7 and 60 windows on two screen widths and on a short screen, row moves at ragged last rows, the scroll-into-view row, hit testing, operation keys acting on the selected window, the selection after ⌘W and after refreshes, each operation's interim effect, and each result's message. `SwitcherPanelTests` inspects the panel's accessibility tree (the `AXList`, cell labels with title, app name and badges, selection, "No windows", the message). `SwitcherControllerTests` runs the controller with `RecordingWindowOperator`: a click committing its window, a click dropped because ⌘W changed the window under it before the release, ⌘W and the refresh that follows, a refused operation's message, commit to focus, a refused focus's message and its hiding after 1.5 s, `.notPermitted`, a result after the switcher closed, and an empty list; and, with an operator that holds ⌘W until the test answers it, a release, a second ⌘W and a click while it is pending, a close that leaves its window listed (a save prompt), and reopening while a commit waits; a hover after a waiting ⌘W or ⌘Q, then a release or Esc; and reads that skip the app of a refused close, a delivered quit, a pending close with a release waiting, or follow an app quitting. `SwitchShortcutTests` drives the tap handler with a window list that takes 0.3 s to read: keys before the switcher opens are held and applied in order without reading the list in the callback, and Esc before then opens nothing. How long real apps take to close a window or quit, compared with the 0.25 s read, is checked in SET-98.

## Settings

**Settings…** in the status menu (or ⌘, while a Hop window is key, or opening Hop again while it runs) shows the Settings window. Every change is saved and applied at once; there is no Apply button.

| Section | What it does |
| --- | --- |
| Shortcut | Shows the hold-to-switch shortcut. **Record Shortcut** takes the next key press: ⌥ or ⌃ held with Tab or ` becomes the shortcut. Any other press is refused with its reason and recording goes on: ⌘ ("switching with ⌘Tab needs a private macOS API"), no ⌥ or ⌃, both ⌥ and ⌃, ⇧ ("⇧ switches backward"), another key, or the same-app shortcut (⌥` until SET-96 makes it a setting). Esc or **Stop** ends recording and keeps the shortcut. **Reset to ⌥Tab** restores the default, unless ⌥Tab is the same-app shortcut, which it refuses with that reason. |
| Shown windows | Minimized windows (on), Windows of hidden apps (on), Apps with no open windows (off), Only windows on the pointer's display (off). |
| Excluded apps | The excluded bundle IDs, with each app's name and icon when it is installed, and a **Remove** button for each. **Add Running App** lists running apps with a Dock icon; **Add…** opens a picker on /Applications. An app without a bundle ID cannot be excluded. |
| Launch at login | **Open Hop at login** registers or unregisters Hop with `SMAppService.mainApp`. While macOS waits for the user to allow it, the toggle stays on, a note says Hop won't start at login until it is allowed, and **Open Login Items** opens System Settings > General > Login Items. A copy of Hop that macOS can't register (an unbundled `swift run` build) says so; a failed change shows its error. The state is read again when the window opens and whenever Hop becomes active. |
| Permissions | Whether Hop has Accessibility, and **Open Privacy & Security**, which opens the Accessibility pane whether or not Hop is allowed (when it is not, it first asks with the prompt option, as onboarding does). |

**Shortcut recording.** While the recorder waits for a press, the event tap lets every key through (`SwitchShortcutController.isSuspended`), so ⌥Tab reaches the window instead of starting a switch, and a switch in progress is cancelled. Recording ends with a new shortcut, Esc, **Stop**, or the Settings window closing or losing focus, so the tap is never left suspended. A new shortcut applies at once (`SwitchShortcutController.settingsChanged(_:)`); a switch under the old one is cancelled.

**Shown windows** (`SwitcherFilter`, pure and unit-tested). The options only remove windows from what `WindowFilter`'s closed rules list, except one that adds app cells:

| Option | Effect |
| --- | --- |
| Excluded apps | Their windows, and their app cells, never appear |
| Minimized windows off | Minimized windows are left out |
| Windows of hidden apps off | Windows of hidden apps are left out, and so are hidden apps' cells |
| Only windows on the pointer's display | A window appears only when its display (`WindowEntry.display`, the display it overlaps most) is the display the switcher opened on; a window on no display does not. If that display is unknown, nothing is left out for it. App cells have no display and stay |
| Apps with no open windows | Each regular app that answered with no switchable window gets a cell after the windows, in source order: its icon, its name and a dashed-window badge, read as "Notes, no open windows". An app whose windows another option removed is not windowless and gets none |

Every item the switcher lists passes the filter, whichever way the list changed: a fresh read, the windows kept for an app that did not answer, a window just minimized or an app just hidden (which leave the list at once when their option is off), and a settings change while the switcher is open, which applies at once (`SwitcherController.settingsChanged()`) and moves the selection to its follower if its item left. A waiting release or click never reaches an item that is no longer listed. Anything a change newly shows appears after the read that follows it. Committing an app cell activates the app: Hop unhides it if hidden, activates it, sets its `kAXFrontmost`, and succeeds when it reads back as frontmost within 0.5 s (otherwise "Couldn't bring Notes forward"). ⌘H and ⌘Q act on an app cell's app as on a window's; ⌘M and ⌘W do nothing on it.

**Storage.** `Settings` is stored as JSON under the `dev.subset.hop.settings` user default with `"schemaVersion": 1`: the shortcut (`{"holdModifier": "option" | "control", "keyCode": 48}`), the same-app shortcut for SET-96, the four options, and the excluded bundle IDs. Within version 1 an absent key takes its default. Anything else that does not decode (not JSON, another version, a value of the wrong type, a disallowed shortcut, or a shortcut equal to the same-app shortcut) reads as the defaults; reading never writes, and the next change overwrites it. Nothing but settings is stored.

**Not verified here.** Unit tests cover each class of allowed and refused shortcut and its reason, recording (including refusals, Esc, and suspending and resuming the tap), a new shortcut taking effect at once, the settings' round trip and each kind of corrupt or unknown data falling back to the defaults and being overwritten by the next change, each Shown-windows option and the excluded apps on a fixture list, app cells appearing only when enabled, the pointer's display filter using each entry's display, committing an app cell and the operator's requests for one, and launch at login with a fake login item. Login-item registration and approval on a signed build are checked in SET-100. Running the Settings window on a Mac, including the Add… picker and recording against the live event tap, is deferred to SET-98, and VoiceOver and keyboard-only use to SET-99.

## Superfunctions evaluated

Inspected `/Users/ar/dev/superfunctions` (this host's copy of `superfunctions-dev`; branch `next`, commit `9cf3812`) and the npm registry on 2026-10-19. Hop has no accounts, billing, sync, upload, MCP server, third-party connection, web UI, or telemetry.

| Family | Version checked | Applies | Gap |
| --- | --- | --- | --- |
| authfn | `@authfn/core` 0.1.1, `authfn/swift` | No | No accounts or sessions. |
| billfn | `@billfn/core` 0.0.1 on npm; `billfn/` is empty on `next` | No | Hop is free; nothing is sold or licensed. |
| datafn | `@datafn/core` 0.0.3, `datafn/swift` | No | Window lists stay in memory; only settings persist, in user defaults. Nothing is synced. |
| filefn | `@filefn/server` 0.1.1, `filefn/swift` | No | No files are uploaded, processed, or stored. |
| mcpfn | `@mcpfn/core` 0.0.5 on npm; no source on `next` | No | No MCP or agent surface is proposed. |
| plugfn | `plugfn` 0.1.0 | No | No third-party service connections; Hop makes no network requests. |
| apifn | `@apifn/core` 0.0.2 | No | No HTTP API is served or called. |
| uifn | `@uifn/core` 0.0.1 (web components) | No | The UI is AppKit and SwiftUI. |
| observability | `@superfunctions/observability` 0.0.1 on npm; not on `next` | No | No telemetry by owner decision. |

**Package/version used: none.** No Superfunctions code was copied or linked.
