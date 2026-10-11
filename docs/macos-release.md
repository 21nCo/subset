# Signed macOS releases

`scripts/release-macos.mjs` turns one native app into a download that passes Gatekeeper's signature and notarization checks on another Mac, with no untrusted-developer warning: it archives the app with the team's **Developer ID Application** certificate and the hardened runtime, exports it, checks the signature, notarizes and staples the app, then builds, signs, notarizes, and staples a DMG. It writes `<App>-<version>.dmg`, `<App>-<version>.zip` (the stapled app), and `SHA256SUMS`; a dev build (`--dev <n>`, see [Dev builds](#dev-builds)) names them `<App>-<version>-dev.<n>`. It never uploads or publishes anything. `--out` may be an existing folder: the script replaces only its own files there (the DMG, the zip, `SHA256SUMS`, and a temporary `.release-macos-work` folder) and refuses the filesystem root, the home folder, and any folder containing the repository.

## Opting an app in

Add `native/<app-id>/macos-release.json` next to the app's Xcode project:

```json
{ "project": "Breaks.xcodeproj", "scheme": "BreaksMac", "app": "Breaks", "team": "SAZVPX4CAA" }
```

`scheme` must build a macOS `.app`; `app` is its product name. Some apps need build inputs the repository doesn't hold:

- `"workspaces"`: npm workspaces to build first, in order (Minutes embeds the built `@subset.dev/minutes` CLI: `["@subset/minutes", "@subset.dev/minutes"]`). Runs `npm ci` and `npm run build --workspace=<name>` for each.
- `"prepare"`: a `.sh` path inside the app directory that fetches inputs (Dictate's checksum-pinned whisper.cpp XCFramework: `"scripts/setup-whispercpp.sh"`). Runs from the app directory.
- `"prepared"`: the repository-relative outputs of those steps (`["packages/minutes-cli/app-runtime"]`, `["native/dictate/.build/whisper.xcframework"]`). Required whenever `workspaces` or `prepare` is set.

Locally the script runs these steps before archiving. In CI they run dependency code, so the workflow's `prepare` job runs them with no environment, secrets, or write token (`--prepare-only --prepared-archive`), and the signing job passes the archive to `--no-prepare --prepared-from`, which rejects any entry that isn't a declared output, something inside one, or one of their parent folders, unpacks it into a temporary folder, checks that every output and every symlink in it really resolves inside that output (absolute and dangling links are refused), and copies in only the `prepared` paths. Nothing in the signing job runs npm or fetches.

The release version is the target's `MARKETING_VERSION`. Targets that need a restricted entitlement (one that requires a provisioning profile under Developer ID) are not covered yet and fail at export.

## One-time setup

Locally, the certificate is read from the login keychain. Store notarization credentials once as a keychain profile, using an App Store Connect API key with Developer access (App Store Connect → Users and Access → Integrations):

```sh
xcrun notarytool store-credentials subset-notary --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

For CI, create a `macos-release` environment in the GitHub repository (restrict it to protected tags and add required reviewers) with these secrets. Its deployment tag rule is `macos/*/v*`, which covers both live tags (`macos/breaks/v0.1.1`) and dev tags (`macos/breaks/v0.1.1-dev.3`), because GitHub's `*` matches anything except `/`.

| Secret | Value |
| --- | --- |
| `MACOS_CERTIFICATE_P12` | base64 of the exported Developer ID Application certificate and private key (`.p12`) |
| `MACOS_CERTIFICATE_PASSWORD` | the `.p12` export password |
| `APPLE_API_KEY_P8` | contents of `AuthKey_<KEY_ID>.p8` |
| `APPLE_API_KEY_ID` | the key ID |
| `APPLE_API_ISSUER` | the issuer ID |
| `APPLE_TEAM_ID` | the team ID |

## Releasing

Locally:

```sh
node scripts/release-macos.mjs breaks --notary-profile subset-notary   # dist/macos/breaks/<version>/
node scripts/release-macos.mjs breaks --skip-notarize                  # signed-only build to test signing
node scripts/release-macos.mjs breaks --dev 3 --skip-notarize          # signed-only dev build 3 (Breaks-<version>-dev.3)
```

From CI, push a tag `macos/<app-id>/v<version>` (the version must equal `MARKETING_VERSION`), or run **Release macOS app** manually from that tag (choose the tag under *Use workflow from* and enter the same tag; the run fails if they differ, so the environment's tag policy always covers the code that runs). The slashes keep these tags out of the npm `publish-tag.yml` trigger. The workflow attaches the files to a **draft** GitHub Release only; it uploads no public workflow artifact.

A draft is not a release. Before publishing it and before any catalog `availableSurfaces` entry or landing page links it (see [AGENTS.md](../AGENTS.md)): download the DMG on a Mac that has never run the app, confirm it opens without a Gatekeeper prompt beyond the standard "downloaded from the internet" notice, check the checksum, and run the app's first-launch and permission flows.

## Dev builds

Every version is tested as dev builds before it is released live. A dev build is signed and notarized exactly like a live release, but it is published for testers only and is never listed as available.

1. **Dev tag.** Set the app's `MARKETING_VERSION` to the next version (x.y.z, never one already released) and push `macos/<app-id>/v<x.y.z>-dev.<n>`, where `n` is a positive integer with no leading zeros (1, 2, 3, ...). `x.y.z` must equal `MARKETING_VERSION`, as for a live tag. Use a new `n` for each build.
2. **Pre-release.** The workflow builds `<App>-<x.y.z>-dev.<n>.dmg`, `<App>-<x.y.z>-dev.<n>.zip`, and `SHA256SUMS`, with `CFBundleShortVersionString` x.y.z and `CFBundleVersion` n (the script sets `CURRENT_PROJECT_VERSION` for every target and checks the exported app). It publishes them as a GitHub **pre-release** titled "<App> <x.y.z>-dev.<n> (dev build)": not a draft, so anyone can download it without signing in, and never marked latest. Its notes say it is a development build for testing and not a release.
3. **Dev landing page.** Link the pre-release's DMG from the app's dev landing page. Dev landing pages are for testers; they are not the directory and not a catalog entry.
4. **Test.** Download each dev build from the dev landing page and run the same checks as for a live release (see [Releasing](#releasing)): Gatekeeper, checksum, first launch, and permission flows. Fix problems and push the next dev tag (`-dev.<n+1>`) until a build passes.
5. **Live tag.** Push `macos/<app-id>/v<x.y.z>` from the commit of the dev build that passed, with no further changes. The workflow builds it and creates a **draft** release named "<App> <x.y.z> for macOS" with files named `<App>-<x.y.z>`.
6. **Publish.** Verify the draft's download as described above, publish it, then add or update the catalog `availableSurfaces` entry and link the live landing page to it.

`scripts/check-workspaces.mjs` rejects an available catalog surface whose version is not a plain x.y.z or whose links name a pre-release version (for example `/v<x.y.z>-dev.<n>` or `<App>-<x.y.z>-dev.<n>.dmg`), so a dev build cannot be listed as available. A dev build's `CFBundleVersion` is its `n`; a live build keeps the project's `CURRENT_PROJECT_VERSION`.
