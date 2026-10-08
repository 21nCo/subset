# Launcher (macOS)

Launcher is a keyboard-first command bar for macOS. Press ⌥Space to open it. From there you can:

- find and open apps and files
- run Siri Shortcuts
- move or resize the front window
- pick and copy an emoji
- calculate, including time-zone conversions
- capture a quick note

It is a Subset capability in the `building` state. The source builds and its unit tests pass. There is no signed build or download.

## Capability boundary

**User outcome:** reach an app, file, shortcut, window layout, emoji, calculation, or note in a few keystrokes without leaving the keyboard.

**Sources of truth:**

| Data | Source |
| --- | --- |
| Apps | Installed bundles in `/Applications`, `/System/Applications`, and `~/Applications` |
| Files | Spotlight via `/usr/bin/mdfind`, plus the top entries of common user folders before typing |
| Siri Shortcuts | `/usr/bin/shortcuts list` and `shortcuts run` |
| Emoji | [EmojiKit](https://github.com/danielsaidi/EmojiKit) 2.5.0 (MIT) plus a bundled annotation index |
| Window positions | The Accessibility API |
| Quick notes | A local Core Data store at `~/Library/Application Support/dev.subset.launcher/QuickNotes.sqlite` |

Nothing is sent over the network. The one exception is Swift Package Manager fetching EmojiKit at build time.

**Explicit operations**

| Operation | Kind | Entry points |
| --- | --- | --- |
| Search apps, files, shortcuts, and window commands; filter by All, Apps, Files, Images, Text, Shortcuts | Read | ⌥Space, menu bar, App Intents |
| Open app or file, run shortcut | Launch | ↵ |
| Reveal app or file in Finder | Launch | ⌘↵ |
| Move or resize the frontmost window (halves, quarters, maximize, center) | Mutation of another app's window; needs Accessibility | ↵ on a window command |
| Copy emoji or image or file reference | Pasteboard write | ↵ in Emoji, preview Copy |
| Calculate expressions and "3pm in Tokyo" style conversions | Read | Calculator tool |
| Create, view, copy, and delete quick notes | Local write | ⌃⌥N, `$` then ↵, Quick Notes window, App Intents |
| Show or hide the floating launcher button | Local preference | Menu bar, App Intents |

The native target owns the global hotkeys, Accessibility window control, Spotlight queries, and App Intents. No shared package was created: no web or agent consumer needs these contracts yet.

## Surfaces

| Surface | Status |
| --- | --- |
| macOS app (`Launcher`) | Proposed. Builds unsigned; 3 unit tests pass. |
| App Intents / Shortcuts actions | Compiled into the app; not verified in the Shortcuts app. |
| Web, iOS, embed, agent CLI/view | Not proposed. |

Not yet verified:

- Hotkeys on a live desktop
- Accessibility-driven window moves
- Spotlight file results
- Running Siri Shortcuts
- The floating button
- App Intents registration in Shortcuts
- A VoiceOver pass
- Any signed distribution

## Build and run

Requires macOS 14+ and Xcode 26, with network access the first time so SwiftPM can resolve EmojiKit (`Package.resolved` is committed).

```sh
cd native/launcher
ruby ProjectGenerator.rb   # optional; regenerates Launcher.xcodeproj (xcodeproj gem)
xcodebuild -project Launcher.xcodeproj -scheme Launcher \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

No `DEVELOPMENT_TEAM` is set. Choose your own team in Xcode to keep Accessibility grants stable across builds.

Unit tests run inside the app as their host. In that mode, global hotkeys are not registered and quick notes use an in-memory store.

### Permissions

- **Accessibility:** window commands only. macOS prompts the first time one runs.
- **Files and Folders / Full Disk Access:** may be requested by macOS depending on which folders Spotlight results come from.
- **Automation of Shortcuts:** handled by the `shortcuts` command line tool.

## UI/UX changes in this port

These changes are informed by Raycast and Alfred: Esc to dismiss, an action footer, ⌘↵ to reveal in Finder, and an Option-based default hotkey with no character side effects for secondary actions.

1. **Esc closes Launcher**, in both search and note modes. The POC had no Escape handling at all. The key monitor now also ignores events for other windows. Previously it stayed installed after the panel hid, so it could intercept Return in other app windows.
2. **Raycast-style action footer.** The bottom bar names the primary action for the selection (Open Application, Open File, Run Shortcut, Copy Emoji, Apply to Window) next to its key. It also shows ⌘↵ Show in Finder for apps and files, and Esc Close. The ⌘↵ reveal action is new.
3. **Safer shortcuts.**
   - New Quick Note moves from **⌥↩** to **⌃⌥N**. The global ⌥↩ captured the line-break key used in Slack, Messages, and other chat apps.
   - Saving a note is now **⌘↵**, so Return can insert line breaks in the details field.
   - The menu bar lists both hotkeys, and Quit has ⌘Q.
4. **Quick Notes window.** The POC's mock "full app" workspace, which showed hard-coded sample Nucleum goals and nodes, is replaced. The new window lists real saved notes with search, a detail view, Copy Text (⇧⌘C), Delete (⌘⌫), and an empty state that explains how to capture notes.
5. **Floating button is opt-in.** The always-on-top button no longer appears on first launch. Its visibility is remembered, and the menu shows its state with a checkmark.
6. **Empty states and accessibility.**
   - "No Results" now suggests window commands and the hidden `$` quick-note command, and tells you when a filter is narrowing the search.
   - Result rows expose title, kind, and location to VoiceOver.
   - Filter chips and tools announce their selected state.
   - The close button has a label.

Competitor features that remain unimplemented: extensions/plugins, clipboard history, snippets, fallback web search, custom hotkey recording, and preferences UI.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) and npm versions on 2026-10-09.

- **searchfn:** the Swift package in `searchfn/swift` provides `SearchFnCore`, the memory and SQLite adapters, and `SearchFnClient`, with BM25-style ranking, prefix, and fuzzy search. It is the best candidate to replace the substring matching over apps, shortcuts, and notes. It was not adopted because this port keeps POC behavior, and file search already delegates to Spotlight. Gap: the Swift package is consumed from the monorepo without a versioned Swift release (npm `@searchfn/core` is 0.3.0, TypeScript).
- **datafn:** `DatafnAppleRuntime`/`DatafnCoreDataStore` could own quick-note persistence and later sync. It was not used: notes are a small local Core Data store, and there is no sync requirement.
- **authfn, filefn, plugfn:** not applicable. There are no accounts, uploads, or third-party connections.
- **uifn, observability:** not applicable to a SwiftUI/AppKit app with no telemetry.

**Package/version used: none.**

Third-party material:

- **EmojiKit 2.5.0** (MIT). The POC already used it.
- **`Shared/Services/EmojiAnnotationIndex.swift`**, generated from Unicode CLDR English emoji annotations (Unicode License v3). Any binary release needs the CLDR and EmojiKit license notices added to the app's acknowledgements. This has not been done yet.

## Provenance

Ported from the private `21nCo/21n` monorepo, branch `dev`, path `poc/ios/SuperBarPOC`. The last commit touching that path is `8c9b11719821de581410a3cb2115c5dfe3a21085` ("Siri shortcuts, Escape shortcuts"). `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when exported.

**Renames**

| Before | After |
| --- | --- |
| `SuperBarPOC.xcodeproj` | `Launcher.xcodeproj` |
| Target and scheme `SuperBarPOCMac` | `Launcher`, plus a new `LauncherTests` target |
| Bundle ID `com.21n.SuperBarPOC.macOS` | `dev.subset.launcher` |
| `SuperBar*` Swift types and files | `Launcher*` |
| User-facing "Super Bar" | "Launcher" |
| Core Data folder `SuperBarPOC` | `dev.subset.launcher` |

**Removed**

- The Apple `DEVELOPMENT_TEAM` ID and fixed `CODE_SIGN_IDENTITY`.
- Hard-coded Nucleum sample data:
  - the `SampleResource` model
  - the Nucleum result kind and filter chip
  - the goals/nodes/memories workspace view
  - the workspace App Intents (Open Nucleum Workspace, Goals, Nodes, Workspace Section)

  A Subset capability must not depend on, or imitate data from, a consuming product. The POC already used Quick Notes, and that intent was kept and repointed to the new window.

**Added**

- The Subset app icon and an asset catalog (the POC had no icon).
- `LSUIElement`.
- A single shared Core Data model instance. Creating several containers previously broke `QuickNote` entity lookup.
- Unit tests.

No API keys, tokens, xcuserdata, `.DS_Store`, or build output were present.
