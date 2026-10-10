# Clipboard (macOS, iOS, iOS keyboard)

Clipboard keeps a searchable local history of what you copy and lets you paste any earlier item back. It ships as three native targets: a macOS menu-bar app with bottom and right-side shelves, an iPhone/iPad host app, and an iPhone/iPad custom keyboard that inserts saved items in other apps. The capability is in the `building` state. The source builds and the macOS unit tests pass. There is no signed build, TestFlight or App Store listing, or download.

## Capability boundary

**User outcome:** find something copied earlier and paste it into the current app in a couple of keystrokes, without losing it to the next copy.

**Source of truth:** the system pasteboard (`NSPasteboard.general` on macOS; `UIPasteboard.general` on iOS, read when the host app is foregrounded). History is local only:

- macOS: `~/Library/Application Support/dev.subset.clipboard/history.json`, capped at 250 items. Images are stored inline as PNG data. A history file that cannot be read is moved aside as `history-unreadable-<date>.json`, never overwritten.
- iOS: the `group.dev.subset.clipboard` App Group container, shared by the host app and the keyboard, capped at 200 items. Images are downscaled to 1400 px and stored inline as JPEG. Reads and writes use file coordination so the app and the keyboard do not overwrite each other. Concealed and transient pasteboard content is skipped on iOS as on the Mac. Copying a file clip back on iOS puts its file URLs on the pasteboard; other apps can open them only if they can access that location.

Mac and iOS histories are separate. There is no sync and no network access.

**Explicit operations**

| Operation | Kind | Entry points |
| --- | --- | --- |
| Capture copied text, links, images, and file references | read pasteboard, local write | macOS background poll (0.35 s); iOS host app foreground |
| Search and filter (All, Text, Links, Images, Files) | read | shelf search field (⌘F), filter chips |
| Paste item into the previous app | pasteboard write + synthetic ⌘V (needs Accessibility) | Return, ⌘1–⌘9, click |
| Copy item only (no Accessibility) | pasteboard write | same as above, as a fallback |
| Insert text or link from the keyboard | text insertion via `UITextDocumentProxy` | iOS keyboard |
| Delete one item | local write | ⌘⌫, context menu |
| Pause or resume capture, clear history | local state | menu bar (clear asks for confirmation) |

The native targets own pasteboard access, Accessibility trust, global hotkeys, and the keyboard extension. No shared package was created: no web or agent consumer needs the history contract yet.

## Surfaces

| Surface | Status |
| --- | --- |
| macOS app (`ClipboardMac`) | Proposed. Builds unsigned; 3 unit tests pass. |
| iOS app (`ClipboardiOS`) + keyboard (`ClipboardKeyboardExtension`) | Proposed. Swift sources compile for the iOS simulator and device SDKs. The asset catalog step was excluded in this environment (see Verification). Not installed or run on a device. |
| Web, embed, agent CLI/view | Not proposed. |

Unverified:

- Live capture and direct paste into other apps with Accessibility granted.
- Global-hotkey conflicts with other apps.
- The keyboard extension running with Full Access.
- App Group behavior on a signed build.
- A VoiceOver pass over the new labels.
- Any distribution.

## Build and run

Targets macOS 14+ and iOS 17+. Verified with Xcode 26.4.

```sh
cd native/clipboard
ruby ProjectGenerator.rb    # optional; regenerates Clipboard.xcodeproj (xcodeproj gem)
xcodebuild -project Clipboard.xcodeproj -scheme ClipboardMac \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Clipboard.xcodeproj -scheme ClipboardiOS \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

No `DEVELOPMENT_TEAM` is set. A signed iOS build needs your own team and an App Group named `group.dev.subset.clipboard`, or edit `SharedContainer.swift` and both `.entitlements` files to match yours. Unit tests use the app as their host. In test mode the app does not monitor the pasteboard, write the real history file, or register global shortcuts.

### Verification (2026-10-09, Xcode 26.4)

- `ClipboardMac`: build succeeded. `test` succeeded with 8/8 tests: concealed/transient type filtering, history store round trip (including contents), delete persistence, whitespace-preserving text, kind-aware signatures, image write-back signature, unreadable-history backup, and coordinated update.
- Review-fix pass (2026-10-10): the iOS app and keyboard sources were typechecked with `swiftc -typecheck` against the iOS 26.4 simulator SDK; no iOS build or device run was possible on this machine.
- `ClipboardiOS` with the embedded `ClipboardKeyboardExtension`: Swift compile and link succeeded for both `iphonesimulator` and `iphoneos` (target build with `EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets`).
  - On this machine, `actool` refuses the iOS asset catalog because the iOS 26.4 simulator runtime is not installed; only iOS 18.3 is.
  - The scheme-based `generic/platform=iOS Simulator` build fails for the same reason.
  - The iOS icon catalog itself has not been compiled here.

`ClipboardKeyboardExtension` is a build-only scheme: run `ClipboardiOS`, then switch to the keyboard in any text field.

### Release

`macos-release.json` opts the `ClipboardMac` scheme into the signed Developer ID flow in [docs/macos-release.md](../../docs/macos-release.md). A signed, un-notarized build was verified locally; nothing has been notarized or published. The iOS app and keyboard are not covered by that flow.

### Permissions

- **macOS Accessibility:** needed to paste directly into the previous app. Without it, choosing an item copies it, and you press ⌘V yourself. The menu shows "Enable Direct Paste…" while it is missing.
- **iOS App Group:** shares history between the host app and the keyboard.
- **iOS keyboard Full Access:** lets the keyboard read the shared container and write images or files to the pasteboard. Text and links can be inserted without restoring the pasteboard.
- iOS shows its own paste-permission prompt when the host app reads the clipboard.

## UI/UX changes in this port

These are informed by Paste (pasteapp.io: ⇧⌘V shelf, ⌘-number quick paste, delete from history) and Maccy (ignoring password-manager entries, confirmations):

1. **Safe global shortcuts.** The POC registered **Shift-V** and **Option-V** as system-wide hotkeys. That captured every capital "V" and "√" typed in any app. The shelves now open with **⇧⌘V** (bottom, as in Paste) and **⌥⇧⌘V** (right). The menu bar items show these shortcuts.
2. **Password-manager privacy.** Pasteboard changes marked `org.nspasteboard.ConcealedType`, `TransientType`, or `AutoGeneratedType`, plus legacy 1Password and TextExpander transient markers, are never saved (the nspasteboard.org convention that Maccy follows). The empty state says so.
3. **Quick paste and delete from the keyboard.**
   - ⌘1–⌘9 paste the matching visible card, and the first nine cards show a ⌘-number badge.
   - ⌘⌫ deletes the selected card from history.
   - Each card has a context menu with Paste (or Copy when Accessibility is missing) and Delete from History.
4. **Shortcut discoverability.**
   - The shelf header shows the full key legend (Return/⌘1–9, ⌘⌫, ⌘F, Esc) whenever the panel is wider than 900 pt, instead of only on very wide displays.
   - A search with no results tells you how to leave search.
5. **Safer menu bar.**
   - "Clear History…" confirms before deleting saved items.
   - "Enable Direct Paste…" appears while Accessibility is missing.
   - Quit has ⌘Q and the app name.
6. **Accessibility.** Cards expose kind, title, source app, and a paste hint to VoiceOver. Filter chips announce their item count and selected state. The close and Enable Paste buttons have labels and tooltips.

Pinboards, iCloud sync, paste-as-plain-text, and per-app exclusion lists are competitor features that remain unimplemented.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) and npm versions on 2026-10-09.

- **datafn:** the Swift `DatafnAppleRuntime` and `DatafnCloudKitSync` products (in `datafn/swift`) and `@datafn/client@0.1.1` are the natural path if Mac↔iOS history sync is added. That would mean Core Data locally and CloudKit or a DataFn server remotely. They were not used, because this port has no sync. The Swift package uses `unsafeFlags` for test framework paths, so it can only be consumed by revision or path rather than by a semantic version. Clipboard contents are sensitive and would also need an end-to-end encryption decision before any sync.
- **authfn** (`authfn@0.4.0`): not applicable. There are no accounts.
- **filefn:** not applicable. Image and file items stay local.
- **uifn**, **@superfunctions/observability:** not applicable to a SwiftUI/AppKit app with no telemetry.

**Package/version used: none.** Gaps: no versioned Swift release of DataFn, and no encrypted-sync guidance for sensitive local data.

## Provenance

Ported from the private `21nCo/21n` monorepo, branch `dev`, path `poc/ios/Clipboard manager POC`, last changed in commit `b78f62836792003e3c5ca307e6ed047da1ce89cf` ("Clipboard POC for Ipad * Ios"). `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` when exported.

**Renames**

| What | Before | After |
| --- | --- | --- |
| Project | `ClipboardManagerPOC.xcodeproj` | `Clipboard.xcodeproj` |
| Targets and schemes | `ClipboardManagerPOCMac`, `ClipboardManagerPOCiOS` | `ClipboardMac`, `ClipboardiOS`; the keyboard keeps `ClipboardKeyboardExtension` |
| Product name (both apps) | — | `Clipboard` |
| Bundle IDs | `com.example.ClipboardManagerPOC.*` | `dev.subset.clipboard.macos`, `.ios`, `.ios.keyboard` |
| App Group | `group.com.example.ClipboardManagerPOC` | `group.dev.subset.clipboard` |
| History namespace and defaults keys | `ClipboardManagerPOC` | `dev.subset.clipboard` |
| User-facing strings | "Clipboard Manager (POC)" | "Clipboard" |

**Added**

- macOS and iOS asset catalogs with the Subset pixel-art icon. The POC had no app icon.
- A `ClipboardMacTests` unit-test target.
- `FileUtils.rm_rf` before regeneration in `ProjectGenerator.rb`.

No secrets, tokens, team IDs, xcuserdata, `.DS_Store`, or build output were present.
