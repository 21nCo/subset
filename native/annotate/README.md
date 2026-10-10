# Annotate (iPhone, iPad, Mac Catalyst)

Annotate opens a PDF from Files, lets you mark it up, and exports an annotated copy. The available markup is:

- ink
- highlight, underline, and strike-out
- comments
- free text
- circles, squares, and arrows
- links
- opaque cover boxes

The original file is never modified. This is the native candidate for the catalog's `pdf-review` capability (display name "Annotate"). It is in the `building` state: the source builds and its unit tests pass on Mac Catalyst. There is no signed build, TestFlight or App Store listing, or download. The web surface named in the catalog has not been built.

## Capability boundary

**User outcome:** mark up a PDF quickly on a phone, tablet, or Mac and hand someone an annotated copy, without risking the original.

**Source of truth:** the user-selected PDF, read through a security-scoped URL into an in-memory `PDFDocument`. Annotations live only in that in-memory document until the user exports. Export writes `PDFDocument.dataRepresentation()` to a new file through the system exporter.

**Document and page identity:**
- A document is identified by its source URL and file name.
- A page is identified by its zero-based `PDFPage` index.
- Annotation geometry is in PDF page space (points, `mediaBox` origin bottom-left), as PDFKit defines it.
- There is no content hash or revision ID yet (see Audit).

**Explicit operations**

| Operation | Kind | Notes |
| --- | --- | --- |
| Open PDF | read (user-picked file) | ⌘O; confirms first if unexported changes would be lost |
| Navigate, outline, zoom in/out/fit | read | |
| Add ink, markup, comment, free text, shape, link, cover | in-memory mutation | Recorded on an undo stack (⌘Z). Links accept only absolute `http`/`https` URLs with a host, or `mailto:` |
| Select, edit, delete one annotation | in-memory mutation | |
| Remove all annotations | in-memory mutation | Confirms first and states the count. This includes annotations the PDF already had. Undoable. |
| Export annotated copy | write to a new user-chosen file | ⇧⌘S; default name `<title>-annotated.pdf` |
| Close document | discard | ⌘W; confirms first if there are unexported changes |

The UI and the domain logic are not yet separated: `PDFDocumentStore` (about 2,200 lines) owns both. Extracting a host-independent operation contract is the next step before any web, embed, or agent surface (see Audit).

## Surfaces

| Surface | Status |
| --- | --- |
| iOS/iPadOS app (`Annotate`) | Proposed. Swift sources compile and link for the `iphonesimulator` and `iphoneos` SDKs. The asset catalog step is excluded in this environment (see Verification). Not run on a device or simulator. |
| macOS via Mac Catalyst | Proposed. Full build including the icon catalog, and the unit tests pass. Interactive use is not verified. |
| Web, embed, agent view | Proposed in the catalog; not built. |

Unverified:
- Interactive annotation with touch, Apple Pencil, or a trackpad.
- Text-selection markup on real-world PDFs.
- Hardware-keyboard shortcuts on iPad.
- Export opened in other viewers (Preview, Acrobat).
- A VoiceOver pass.
- Any signed or distributed build.

### Verification (2026-10-09, Xcode 26.4)

- `xcodebuild -scheme Annotate -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO test`: **TEST SUCCEEDED**, 10/10 (re-run 2026-10-10 after the second round of review fixes).
- `xcodebuild -target Annotate -sdk iphonesimulator|iphoneos EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets ... build`: **BUILD SUCCEEDED** for both.
- Without that exclusion, `actool` fails on this machine. It needs the iOS 26.4 simulator runtime, and only iOS 18.3 is installed. The scheme-based `generic/platform=iOS Simulator` build fails for the same reason.

## Build and run

```sh
cd native/annotate
ruby ProjectGenerator.rb   # optional; regenerates Annotate.xcodeproj (xcodeproj gem)
xcodebuild -project Annotate.xcodeproj -scheme Annotate \
  -destination 'platform=macOS,variant=Mac Catalyst' CODE_SIGNING_ALLOWED=NO test
# Needs an installed iOS simulator runtime matching the SDK for the asset catalog step;
# see Verification. Add EXCLUDED_SOURCE_FILE_NAMES=Assets.xcassets to compile without it.
xcodebuild -project Annotate.xcodeproj -scheme Annotate \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

No `DEVELOPMENT_TEAM` is set. **Permissions:** none beyond the system document picker. Files are accessed only through the security-scoped URLs that the user picks.

**Release:** the macOS release tooling (`scripts/release-macos.mjs`, see `docs/macos-release.md`) builds a native macOS scheme. Annotate's Mac surface is Mac Catalyst, which that script does not support yet, so this app has no `macos-release.json` and no signed or notarized Mac build.

## POC audit (required by AGENTS.md before transferring POC code)

Audited on 2026-10-09 against `poc/ios/PDFAnnotation` at `21nCo/21n@4d2923b`.

**Licensing and provenance**
- The code was written in the 21n monorepo (PR 21nCo/21n#8, "NPX-6 - PDF viewing, annotation - iOS POC", merged 2026-04-17).
- It imports only Apple frameworks: PDFKit, SwiftUI, UIKit, and UniformTypeIdentifiers.
- There are no third-party packages, vendored code, fonts, or sample PDFs.
- It is compatible with this repository's MIT license as 21n-owned code.
- Removed in the port: a personal `xcuserdata` folder (`UserInterfaceState.xcuserstate`), the Apple `DEVELOPMENT_TEAM` ID, and the placeholder `com.example` bundle ID.

**API**
- `PDFDocumentStore` is one `@MainActor ObservableObject` with about 40 published properties. It mixes:
  - document mutation (add/remove annotation, undo stack, export)
  - view state (zoom labels, sheet flags, palette colors, inline-bar geometry)
- There is no schema for operations or annotations, and no host-independent API. An embed, web, or agent consumer would need a separate contract: document ID, page index, annotation kind, rect/quad points in page space, color, and text.
- Page identity relies on `PDFPage` object references within a session. There is no stable annotation ID across export and reopen.
- Tool metadata is stored by prefixing the PDF annotation author field (`userName`). The prefixes are `markup:…`, `link:…`, and a comment prefix. Other PDF viewers will show these strings as the annotation author. This needs a private key or `/NM` IDs before release.

**Behavior and safety**
- **Original bytes are preserved.** The source file is read once and never written. Export uses the system file exporter to create a new file. A new unit test checks that the source file is byte-identical after annotating.
- **Export re-serializes the whole PDF** with `dataRepresentation()`. It does not use an incremental update. This can change object structure and invalidate existing digital signatures. That is not yet surfaced to the user.
- **The POC's "Redact" tool was not redaction.** It draws an opaque square annotation, so the underlying text stays in the content stream and can be copied or extracted, and the box can be deleted in any viewer. The port renames the tool to **Cover** and states this in its instruction. True redaction (removing page content) is not implemented.
- There was no warning before losing work, and "trash" removed every annotation, including pre-existing ones, without confirmation. Both are fixed (see UI/UX).
- Link annotations open URLs through the system `openURL`. Because PDFs are untrusted, only absolute `http`/`https` links with a host and `mailto:` links are opened or created; `file:`, `tel:`, and app-specific schemes are ignored.

**Test coverage**
- The POC had **no tests**; its README said so.
- The port adds `AnnotateTests` (10 tests, run on Mac Catalyst):
  - the Cover tool is not labelled as redaction
  - an ink stroke marks unexported changes, leaves the source file byte-identical, and is undoable
  - ink paths are placed correctly on pages whose media box does not start at (0, 0)
  - an ink stroke's bounds cover only the stroke, so taps elsewhere on the page do not select it
  - closing with unexported changes requires confirmation; closing without them does not
  - opening another PDF keeps the unexported-changes guard if the picker is cancelled
  - exported data contains the annotation on the correct page only
  - word splitting for text markup advances past emoji and other non-BMP characters
  - link URLs must be absolute web or mail addresses
- Untested: markup on text selections, shapes, link creation in the UI, comments, free text, outline navigation, zoom, and the PDFKit view bridge (`PDFAnnotatorView`, about 950 lines).
- Inherited from the POC and not reachable from the UI: a stamp tool, a tap-to-place link mode, and a drag-to-size shape draft flow. They are not advertised as available.

**Conclusion:** the POC is a reasonable native starting point for the iOS and Mac Catalyst surfaces. Before an embed, web, or agent surface, or any release, it needs:
- extraction of a documented operation contract
- stable annotation IDs and a document revision hash
- safe metadata storage
- a signature-invalidation warning
- broader tests

## UI/UX changes in this port

These are informed by PDF Expert (true redaction is clearly separate from drawing; export is explicit) and Apple Preview markup (keyboard shortcuts, never silently losing edits):

1. **Honest Cover tool.** "Redact" is renamed **Cover**. Its instruction says the text stays in the file and that this is not secure redaction.
2. **No silent data loss.**
   - Closing (⌘W) or opening another PDF with unexported annotations asks first, with three choices: Discard, Export First…, and Cancel.
   - The top bar shows "Not exported" while there are unexported changes.
   - While there are unexported changes, the system window close control (Mac Catalyst title bar, iPad Stage Manager) is disabled through `UIWindowScene.windowingBehaviors`, so the in-app Close, which asks first, is the way out. Not verified by hand on a Catalyst window. Quitting the app (⌘Q) or the system ending it still loses unexported annotations: there is no autosave or state restoration yet.
3. **Confirmed Remove All.** The trash button now confirms, names how many annotations will be removed, and warns that pre-existing annotations are included. It is disabled when there are none.
4. **Keyboard shortcuts** for iPad hardware keyboards and Mac Catalyst:
   - ⌘O Open
   - ⇧⌘S Export Annotated Copy
   - ⌘Z Undo
   - ⌘W Close
   - Esc Stop the current tool
5. **Accessibility labels and tooltips** on the icon-only controls: Contents, Open, Export, Stop tool, Undo, Remove All, Close, Zoom In, Zoom Out, and the inline selection actions. Previously these were unlabelled to VoiceOver. No VoiceOver pass has been done.
6. **Clearer start screen.** "Upload PDF" became **Open PDF**, because nothing is uploaded. The footnote explains that the original is never changed and that Export saves a copy.

Competitor features that remain unimplemented: true redaction, signatures and forms, page organization (reorder, rotate, delete), search, and an annotation list or summary for review.

## Superfunctions reuse review

Reviewed `/Users/ar/dev/superfunctions` (branch `next`, commit `9cf3812`) and npm versions on 2026-10-09.

- **filefn** (`@filefn/server@0.2.0`, `@filefn/client@0.1.1`, Swift `FileFnClient`; there is also a `filefn/viewer` package): relevant once Annotate stores PDFs or annotated revisions server-side, or shares them for review. It was not used because this port is local-only and works with Files-picked documents.
- **drawfn** (`drawfn@0.0.2`, plus `drawfn/core`, `drawfn-react`, and `drawfn-svelte`): a web drawing layer. It is a candidate when the web Annotate surface is built, but it does not apply to the PDFKit/SwiftUI app.
- **datafn:** the Swift Core Data/CloudKit runtime could sync annotation sets separately from PDF bytes. It is not needed without sync.
- **authfn, uifn, observability:** not applicable to this local native app.

**Package/version used: none.** Gaps: no Swift-tagged FileFn release, no PDF-annotation contract in Superfunctions, and drawfn is web-only and pre-1.0.

## Provenance

Ported from the private `21nCo/21n` monorepo, branch `dev`, path `poc/ios/PDFAnnotation`, last changed in commit `4d2923beb0c82f74d930a69556eb914108270e9d` ("NPX-6 - PDF viewing, annotation - iOS POC (#8)"). `origin/dev` was at `cc5215802b77e5386bbc2d37330c228270b162a0` at export.

**Renames**

| Before | After |
| --- | --- |
| Folder `PDFAnnotationPOC/` | `Annotate/` |
| Target, scheme, and product `PDFAnnotationPOC` | `Annotate` |
| App struct `PDFAnnotationPOCApp` | `AnnotateApp` |
| Display name "PDF Annotation POC" | "Annotate" |
| Bundle ID `com.example.PDFAnnotationPOC` | `dev.subset.annotate` |

**Project changes**
- The hand-written `PDFAnnotationPOC.xcodeproj` is replaced by `ProjectGenerator.rb` and a generated `Annotate.xcodeproj`. The generated project keeps the POC's build settings and adds an `AnnotateTests` target.
- Added the Subset app icon. The POC had no asset catalog.
