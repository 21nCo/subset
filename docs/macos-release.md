# Signed macOS releases

`scripts/release-macos.mjs` turns one native app into a download that passes Gatekeeper's signature and notarization checks on another Mac, with no untrusted-developer warning: it archives the app with the team's **Developer ID Application** certificate and the hardened runtime, exports it, checks the signature, notarizes and staples the app, then builds, signs, notarizes, and staples a DMG. It writes `<App>-<version>.dmg`, `<App>-<version>.zip` (the stapled app), and `SHA256SUMS`. It never uploads or publishes anything. `--out` may be an existing folder: the script replaces only its own files there (the DMG, the zip, `SHA256SUMS`, and a temporary `.release-macos-work` folder) and refuses the filesystem root, the home folder, and any folder containing the repository.

## Opting an app in

Add `native/<app-id>/macos-release.json` next to the app's Xcode project:

```json
{ "project": "Breaks.xcodeproj", "scheme": "BreaksMac", "app": "Breaks", "team": "SAZVPX4CAA" }
```

`scheme` must build a macOS `.app`; `app` is its product name. The release version is the target's `MARKETING_VERSION`. Targets that need a restricted entitlement (one that requires a provisioning profile under Developer ID) are not covered yet and fail at export.

## One-time setup

Locally, the certificate is read from the login keychain. Store notarization credentials once as a keychain profile, using an App Store Connect API key with Developer access (App Store Connect → Users and Access → Integrations):

```sh
xcrun notarytool store-credentials subset-notary --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

For CI, create a `macos-release` environment in the GitHub repository (restrict it to protected tags and add required reviewers) with these secrets:

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
```

From CI, push a tag `macos/<app-id>/v<version>` (the version must equal `MARKETING_VERSION`), or run **Release macOS app** manually from that tag (choose the tag under *Use workflow from* and enter the same tag; the run fails if they differ, so the environment's tag policy always covers the code that runs). The slashes keep these tags out of the npm `publish-tag.yml` trigger. The workflow attaches the files to a **draft** GitHub Release only; it uploads no public workflow artifact.

A draft is not a release. Before publishing it and before any catalog `availableSurfaces` entry or landing page links it (see [AGENTS.md](../AGENTS.md)): download the DMG on a Mac that has never run the app, confirm it opens without a Gatekeeper prompt beyond the standard "downloaded from the internet" notice, check the checksum, and run the app's first-launch and permission flows.
