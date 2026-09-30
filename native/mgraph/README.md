# M Graph macOS capture spike (SET-4)

This is a local macOS development app that reads the foreground application's Accessibility tree **only when Capture Foreground is selected**. The user can start it from Finder or `open MGraphCapture.app`; it appears in the menu bar. `Request Accessibility Access`, `Capture Foreground`, and `Quit M Graph` are its complete interactive operations. It keeps no history, makes no network requests, and does not include graph inference. The CLI commands `status`, `request-access`, and `capture` are for repeatable native checks; `capture` writes the current text to stdout, so redirect it only to a private temporary file. There is no catalog download or public release.

The native target owns permission checks, foreground app selection, AX traversal, source identity, and the menu. No web host or product adapter consumes it yet. Source identity includes the app name, bundle ID, process ID, window title when exposed, and document URL when exposed. Each JSON result includes an observation time and a state. The collector bounds traversal to 600 elements, depth 12, 6,000 text characters, and a four-second monotonic whole-operation deadline. AX messaging has a 250 ms per-element timeout. The menu dispatches traversal to one serial worker queue and stays responsive; one capture can be active at a time. The CLI waits at most four seconds. A late or queued result is discarded. Both paths recheck permission, deadline, and foreground process identity before returning text; denial, revocation, timeout, or a changed foreground app returns no partial text. Empty accessible trees report `unsupportedApplication`. Secure/password roles are skipped.

## Build and native checks

Requires macOS 14+, Xcode command-line tools, and Python 3 for the checks. From the repository root:

```sh
swift test --package-path native/mgraph
python3 -m unittest discover -s native/mgraph -p 'test_*.py' -v
MGRAPH_SIGN_IDENTITY='Apple Development: YOUR NAME (TEAM)' native/mgraph/build-app.sh
native/mgraph/check-native.py --expect-state available
native/mgraph/fixture-matrix.py
python3 native/mgraph/check-menu.py
```

Without `MGRAPH_SIGN_IDENTITY`, `build-app.sh` makes an ad hoc signed local bundle. This host has an Apple Development identity, so the recorded check used that identity and hardened runtime. `codesign --verify --deep --strict` verifies the signature. `otool -L` and `check-native.py` reject non-system dynamic dependencies; Swift uses the runtime in `/usr/lib/swift`, so no separately installed Swift, Python, or Node runtime is needed to launch the app. The bundle is **not notarized** and Gatekeeper rejected this development build. No app sandbox entitlement is supplied; sandboxed AX behavior remains unverified. This is a viable local development packaging route, not a public download. A Developer ID signature, notarization, a fresh-Mac launch, and release distribution remain unverified. Apple requires a [Developer ID certificate and hardened runtime for notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

`check-native.py` launches the actual bundle through LaunchServices. This matters because invoking its executable from a terminal can inherit the terminal's Accessibility grant and report a misleading result. The check validates the signature and linked libraries, reads bundled permission state, verifies startup/shutdown, and captures one foreground result. Pass `--expect-state available` or `--expect-state permissionRequired` to make a grant or denial assertion. `fixture-matrix.py` opens nonsensitive local fixtures in TextEdit, Safari, Chrome, and Firefox; it requires the fixture body and matching bundle ID in all four apps and reports only text length, source identity, and fixture matches. It deliberately does not print captured page text. Firefox opens the file in a background tab when another window is present, so the fixture check selects its last tab through System Events. It closes its uniquely titled fixture window after each measurement and deletes the private result files. Each LaunchServices check tags its process with an invocation UUID, terminates only that invocation on timeout or interruption, and verifies it exited. Foreground activation can race with other desktop automation; a mismatched source identity fails the matrix and should be rerun in a quiet session. `check-menu.py` verifies the real menu click, alert text, and Quit path; it also needs System Events automation access on the test Mac.

To repeat denial and revocation, run `tccutil reset Accessibility dev.subset.mgraph.capture`, then run `native/mgraph/check-native.py --expect-state permissionRequired`. The bundled `status` and `capture` operations must report `permissionRequired`, with no text. Choose `Request Accessibility Access` in the menu bar app and enable this bundle in System Settings > Privacy & Security > Accessibility, then repeat with `--expect-state available`. Reset only this bundle ID; this command removes its existing grant. Turn its System Settings switch off and repeat the denied check to test revocation, then restore the original setting. Each capture checks the current grant, so a revoked grant is reported on the next capture. `request-access` opens the OS permission route but cannot grant permission itself.

## Measured host evidence (2026-09-30, macOS 27.0, Apple Silicon)

The Apple Development signed, hardened-runtime bundle passed `codesign --verify --deep --strict`; `otool -L` listed only system frameworks and `/usr/lib` Swift libraries. `check-native.py` observed bundle start and stop. LaunchServices `status` and `capture` reported `permissionRequired` with zero text after `tccutil reset Accessibility dev.subset.mgraph.capture`; the System Settings switch was off. Enabling the switch produced `available` on the next bundled check, and bundled `request-access` returned `available` without changing the grant. Turning the switch off again produced `permissionRequired` with zero text; it was restored to on after the check. A direct executable call under the granted terminal previously reported `available` even while the bundle lacked access, which is why the launch-context check is required. A menu-bar capture showed a local TextEdit fixture in the alert, and the Quit menu item stopped the app process.

| Foreground app | Bundle source identity | Fixture text | Observed quality and limits |
| --- | --- | --- | --- |
| TextEdit | `com.apple.TextEdit` | Found | 124 characters; document URL and window title exposed. |
| Safari | `com.apple.Safari` | Found | 371 characters; window title exposed, document URL absent for the local file page. |
| Google Chrome | `com.google.Chrome` | Found | 643 characters; window title and document URL exposed. |
| Firefox | `org.mozilla.firefox` | Found | 502 characters; window title exposed, document URL absent. |

These observations are from one successful local fixture run on this Apple Silicon host. Earlier Firefox runs returned only browser chrome because the fixture tab was in the background; the matrix now activates that tab and rejects a missing fixture body. No app in this four-app fixture matrix is confirmed unsupported. Other apps, protected content, multiple windows, Intel Macs, older macOS versions, and fresh-Mac behavior need separate evidence before any broader claim. A structured `available` result can still contain only UI chrome for a particular page, so consumers must inspect source identity and text quality rather than treating the state as proof of document-body coverage.

On the recovery branch, focused Swift tests exercise the synchronous and asynchronous deadline paths with delayed text, empty-tree classification, and one-time delivery. Python checks inject launcher timeout, SIGINT, and SIGTERM and run a real tagged-process cleanup while a preexisting instance remains alive. Before the final serial-queue edit, the rebuilt development bundle again passed signed startup/shutdown, menu capture/quit, and the four-app fixture matrix (TextEdit 124, Safari 393, Chrome 442, Firefox 458 characters with matching IDs and fixture text). The latest rebuild passed signature/system-library inspection, startup/shutdown, and a post-reset `permissionRequired` status/capture with zero text. The system's password sheet is required to reenable the Accessibility switch; grant, revocation, menu capture, and the four-app matrix still need repeating against the final exact head before PR acceptance. The first Firefox recovery run timed out during app activation; a quiet-session retry passed. If an external app is hung, its own fixture window may remain and the matrix reports that cleanup failure without terminating the preexisting app.

The exact-head acceptance check for SET-4 is a signed bundle run on a macOS host: observe grant, denial, revocation, the four-app fixture matrix, menu capture/quit, linked libraries, sandbox entitlements, and Gatekeeper result. Railway Postgres, Cloudflare Preview, connected provider sandboxes, and Aside Browser are not part of this native-only issue. They supply no evidence for Accessibility permission or packaging. A second clean Mac would be useful for distribution testing but is outside this local development proof.

## Risk and contract map

| Boundary | Risk | Focused evidence |
| --- | --- | --- |
| Permission transitions | Terminal grant can mask bundle denial; reset or revocation can leak stale text | LaunchServices status/capture before grant, after grant, and after reset; per-capture permission check |
| AX traversal | Empty or slow trees, protected fields, huge values | Four-second monotonic deadline, 250 ms AX calls, late-text and empty-tree tests, secure-role and normalization tests, app fixture matrix |
| Foreground source | Another app can gain focus between activation and capture | Bundle ID/PID/window/document fields; matrix rejects identity mismatch |
| Packaging | External runtime, invalid signature, sandbox or Gatekeeper restriction | `codesign`, `otool`, bundle start/stop, `spctl` observation |
| CLI/UI operation | Invalid command, repeated capture, interruption or launcher timeout | Exit 64 on malformed command, asynchronous menu capture and Quit smoke check, injected timeout/SIGINT/SIGTERM cleanup tests |

The operations are read-only except for the OS permission request. There is no retry loop or persistent background capture. AX calls run on a worker while the menu stays active. Capture data is ephemeral in the menu dialog or explicit CLI output; the integration scripts delete their private temporary result files. The current app has no persistence layer. macOS alone is supported; web/iOS do not have this cross-app permission model.

## Superfunctions reuse gate

Evaluated `@superfunctions/observability` 0.0.1 in `superfunctions-dev/packages/observability` (manifest and source; no package README exists). It is a TypeScript/Node runtime and does not provide a native Swift AX adapter or logging needed for this local, no-storage spike. Used: none. No auth, storage, billing, MCP, upload, or UI framework layer was added. The NPX-31 prototype was treated as background evidence; no code was copied from it.
