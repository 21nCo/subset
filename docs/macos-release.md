# Signed macOS releases

`scripts/release-macos.mjs` turns one native app into a download that passes Gatekeeper's signature and notarization checks on another Mac, with no untrusted-developer warning: it archives the app with an ad-hoc signature (entitlements and the hardened runtime applied, no signing identity), re-signs the archive with the team's **Developer ID Application** certificate during export, checks the signature, notarizes and staples the app, then builds, signs, notarizes, and staples a DMG. It writes `<App>-<version>.dmg`, `<App>-<version>.zip` (the stapled app), and `SHA256SUMS`; a beta build (`--beta <n>`, see [Beta builds](#beta-builds)) names them `<App>-<version>-beta.<n>`. It never uploads or publishes anything. `--out` may be an existing folder: the script replaces only its own files there (the DMG, the zip, `SHA256SUMS`, and a temporary `.release-macos-work` folder) and refuses the filesystem root, the home folder, and any folder containing the repository.

## Opting an app in

Add `native/<app-id>/macos-release.json` next to the app's Xcode project:

```json
{ "project": "Breaks.xcodeproj", "scheme": "BreaksMac", "app": "Breaks", "team": "SAZVPX4CAA", "bundleId": "dev.subset.breaks" }
```

`scheme` must build a macOS `.app`; `app` is its product name and `bundleId` its `CFBundleIdentifier` (required). An app that bundles a command line tool declares it in `helpers`, so the catalog feed and `subset <command>` can find it without reading the Xcode project:

```json
"helpers": [{ "command": "system", "path": "Contents/Helpers/subset-system", "kind": "native" }]
```

- `command`: the tool ID `subset <command>` runs it as. It is lowercase letters, digits and hyphens, declared by one app only, and not one of `subset`'s own commands (`install`, `uninstall`, `update`, `list`, `help`, `version`).
- `path`: the file, relative to the `.app` and inside its `Contents/` folder, with no `.` or `..` parts.
- `kind`: `native` for an executable, or `node` for an ES module (`.mjs`) run with Node.js.

Omit `helpers` when the app bundles no command. The current helpers are System's `system` (`Contents/Helpers/subset-system`), pointInTime's `point-in-time` (`Contents/Helpers/point-in-time`), and the Node.js CLIs Timer and Minutes embed: `timer` (`Contents/Resources/timer-cli/dist/cli.mjs`) and `minutes` (`Contents/Resources/minutes-cli/dist/cli.mjs`). `scripts/check-workspaces.mjs` (`npm run check`) checks the shape of every manifest, and that every helper has a matching tool, with that app and path, in `packages/subset-dev/src/tools.mjs` (so a new helper needs an entry there); the release script checks the declarations against the app (see below).

Some apps need build inputs the repository doesn't hold:

- `"workspaces"`: npm workspaces to build first, in order (Minutes embeds the built `@subset.dev/minutes` CLI: `["@subset.dev/minutes-core", "@subset.dev/minutes"]`). Runs `npm ci` and `npm run build --workspace=<name>` for each.
- `"prepare"`: a `.sh` path inside the app directory that fetches inputs (Dictate's checksum-pinned whisper.cpp XCFramework: `"scripts/setup-whispercpp.sh"`). Runs from the app directory.

The script runs these steps, resolves any Swift packages, and archives the app with an ad-hoc signature (entitlements and hardened runtime applied, no signing identity), then re-signs the archive with Developer ID through `xcodebuild -exportArchive` and notarizes it. Locally that is one command. In CI, building and signing are separate jobs so no project, package, or npm code runs while credentials are present: the `build` job has no environment, secrets, or write token and runs `--archive-only --archive-out <file>`; the signing job runs `--from-archive <file> --version <x.y.z>`, which lists the archive's entries (only `<App>.xcarchive/...` is accepted), unpacks it, refuses symlinks that resolve outside it, checks the app's version and build number, and only re-signs, notarizes, and packages it. The signing job runs the repository's release script and Apple's tools, but no app, Swift package, or npm build code. The signing job also refuses an archive built from a different commit than the tag it signs.

Both the archived app and the exported, signed app must match the manifest, or the release fails before anything is notarized: `plutil` reads `CFBundleIdentifier` from the app's `Info.plist` and it must equal `bundleId`, and each helper's `path` must be a file inside the app (a link may point only within it), executable by everyone when its `kind` is `native`. Releases made before these checks keep their assets unchanged.

The release version is the target's `MARKETING_VERSION`. Targets that need a restricted entitlement (one that requires a provisioning profile under Developer ID) are not covered yet and fail at export.

## One-time setup

Locally, the certificate is read from the login keychain. Store notarization credentials once as a keychain profile, using an App Store Connect API key with Developer access (App Store Connect → Users and Access → Integrations):

```sh
xcrun notarytool store-credentials subset-notary --key AuthKey_<KEY_ID>.p8 --key-id <KEY_ID> --issuer <ISSUER_ID>
```

For CI, create a `macos-release` environment in the GitHub repository (restrict it to protected tags and add required reviewers) with these secrets. Its deployment tag rule is `macos/*/v*`, which covers both live tags (`macos/breaks/v0.1.1`) and beta tags (`macos/breaks/v0.1.1-beta.3`), because GitHub's `*` matches anything except `/`.

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
node scripts/release-macos.mjs breaks --beta 3 --skip-notarize         # signed-only beta build 3 (Breaks-<version>-beta.3)
```

From CI, push a tag `macos/<app-id>/v<version>` (the version must equal `MARKETING_VERSION`), or run **Release macOS app** manually from that tag (choose the tag under *Use workflow from* and enter the same tag; the run fails if they differ, so the environment's tag policy always covers the code that runs). The slashes keep these tags out of the npm `publish-tag.yml` trigger. The workflow attaches the signed files to a **draft** GitHub Release only; they are never uploaded as workflow artifacts. The build job does upload the ad-hoc-signed `.xcarchive` (artifact `app-archive`, kept 7 days) for the signing job, so anyone who can read the repository can download that unsigned build of the tagged source before the release is published.

A draft is not a release. Before publishing it and before any catalog `availableSurfaces` entry or landing page links it (see [AGENTS.md](../AGENTS.md)): download the DMG on a Mac that has never run the app, confirm it opens without a Gatekeeper prompt beyond the standard "downloaded from the internet" notice, check the checksum, and run the app's first-launch and permission flows.

## Beta builds

Every version is tested as beta builds before it is released live. A beta build is signed and notarized exactly like a live release, but it is published for testers only and is never listed as available.

Work merges into `dev` (the default branch), and betas are built from it on request; `main` only receives pull requests from `dev`, and live releases are tagged from there. The `main` ruleset requires the **Promote / from-dev** check, which runs as `pull_request_target` from main's copy of `promote.yml`, so a pull request can't rewrite it. Until the first promotion brings `promote.yml` to main, no pull request into main can report that check: for that one promotion, remove the required check from the ruleset, merge the `dev` pull request, then restore it. The check is a guard against mistakes, not against people with write access: any workflow job named `from-dev` reports the same check name.

1. **Version.** Set the app's `MARKETING_VERSION` to the next version (x.y.z, never one already released). While it equals a released version, the planner builds no betas of that app.
2. **Request a beta.** Merges to `dev` build nothing on their own: betas are built when a feature is ready for acceptance testing, not for every piece of it. When every implementation issue of a parent issue is merged, the Linear loop ([thyaravind/automations](https://github.com/thyaravind/automations), `beta-handoff.mjs`) runs [beta-builds.yml](../.github/workflows/beta-builds.yml) on `dev` with `only` set to the parent's apps and packages (for example `macos/breaks`), `skip_unchanged` (an app unchanged since its newest beta is tested from that beta, if that beta is of the current version and was published) and `issue` set to the parent, verifies the result, and posts the download and what to verify to the owner. To build one by hand, run **Beta builds** with `only`; with `only` empty it builds every app whose inputs changed since its last tagged build (`native/<app-id>/`, plus, for an app with `"workspaces"` in its manifest, those npm workspaces and the root `package.json` and `package-lock.json`), including apps never tagged. Targets listed in `betaOptOuts` in `scripts/beta-builds.mjs` (currently `macos/system`, until SET-59) are never planned, whether their inputs changed or `only` names them; they appear in the plan's `skipped` list with their reason. `scripts/beta-builds.mjs` creates the tag `macos/<app-id>/v<x.y.z>-beta.<n>` on the current `dev` commit for each, where `n` is one more than the highest test build of x.y.z so far (older `-dev.<n>` builds count), and starts **Release macOS app** from that tag.
3. **Pre-release.** The release workflow builds `<App>-<x.y.z>-beta.<n>.dmg`, `<App>-<x.y.z>-beta.<n>.zip`, and `SHA256SUMS`, with `CFBundleShortVersionString` x.y.z and `CFBundleVersion` n (the script sets `CURRENT_PROJECT_VERSION` for every target and checks the exported app). It publishes them as a GitHub **pre-release** titled "<App> <x.y.z>-beta.<n> (beta build)": not a draft, so anyone can download it without signing in, and never marked latest. Its notes say it is a beta build for testing and not a release.
4. **Dev landing page.** Each app's dev landing page offers the newest pre-release of the app. Dev landing pages are for testers; they are not the directory and not a catalog entry.
5. **Test.** Download each beta from the dev landing page and run the same checks as for a live release (see [Releasing](#releasing)): Gatekeeper, checksum, first launch, and permission flows. Fixes merged to `dev` need another beta run.
6. **Promote and tag live.** Merge `dev` into `main` with a pull request, then push `macos/<app-id>/v<x.y.z>` on the commit of the beta that passed, with no further changes. The workflow builds it and creates a **draft** release named "<App> <x.y.z> for macOS" with files named `<App>-<x.y.z>`.
7. **Publish.** Verify the draft's download as described above, publish it, then add or update the catalog `availableSurfaces` entry and link the live landing page to it.

A beta tag can also be pushed by hand; `macos/<app-id>/v<x.y.z>-dev.<n>` tags from before beta builds still build the same way.

The npm packages in `release-packages.json` get betas the same way: when a run names the package in `only` (or, with `only` empty, one of its `inputs` or the root `package.json` or `package-lock.json` changed) and the package has a live release but its package.json version x.y.z is not released yet, beta-builds.yml tags `<slug>-v<x.y.z>-beta.<n>` and starts **Publish tagged package**, which publishes x.y.z-beta.<n> under the npm `beta` dist-tag (`npx @subset.dev/usage@beta`). The default (`latest`) install changes only with a live `<slug>-v<x.y.z>` tag. A package that has never been released live gets no betas, because npm makes a package's first version `latest` whatever its dist-tag. The workflow builds and packs in one job and publishes in a second job that runs one at a time per package and dist-tag. Right before publishing, that job runs `scripts/npm-beta-guard.mjs`, which reads the registry: it fails on registry errors, and skips a beta when the `beta` dist-tag already points at a newer one, so overlapping runs never move the channel backward.

`scripts/check-workspaces.mjs` rejects an available catalog surface whose version is not a plain x.y.z or whose links name a pre-release version (for example `/v<x.y.z>-beta.<n>` or `<App>-<x.y.z>-beta.<n>.dmg`), so a beta build cannot be listed as available. A beta build's `CFBundleVersion` is its `n`; a live build keeps the project's `CURRENT_PROJECT_VERSION`.

## First npm release of a package

`publish-tag.yml` publishes only through the package's npm trusted publisher (OIDC) and has no npm token. npm can only attach a trusted publisher to a package that already exists, so a package that has never been on npm needs one manual step before its first live tag:

1. A maintainer claims the name with a `0.0.0` placeholder. In a new empty directory outside the repository, write a `package.json` containing only the package's `"name"` and `"version": "0.0.0"`, check that `npm pack --dry-run` lists only `package.json`, then run `npm publish --access public` with 2FA. Don't hand-publish the real version: its live tag would then fail at `npm publish` because the version already exists, and `scripts/beta-builds.mjs` counts a package as released only once a live `<slug>-v<x.y.z>` tag exists.
2. On npmjs.com, add a GitHub Actions trusted publisher for the package: repository `21nCo/subset`, workflow `publish-tag.yml`, with **Allow npm publish** enabled (npm defaults new connections to staged publishing only).
3. Within 2 days, push the live `<slug>-v<x.y.z>` tag. npm expires a trusted publisher that has not completed a successful publish within 2 days of being created; if that happens, delete and recreate it. The live release takes `latest` from the placeholder.
4. Deprecate the placeholder: `npm deprecate <name>@0.0.0 "Name placeholder; install a released version"`.

Until the live tag ships, don't push a beta tag for the package: `scripts/npm-beta-guard.mjs` treats a `latest` of `0.0.0` as no live release and refuses it.
