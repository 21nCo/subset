#!/usr/bin/env node
// Builds a Developer ID-signed, notarized, stapled macOS release of one native app:
//   node scripts/release-macos.mjs <app-id> [--version <x.y.z>] [--dev <n>] [--out <dir>] [--skip-notarize]
//
// --dev <n> makes development build n of the app's MARKETING_VERSION: the files are named <App>-<x.y.z>-dev.<n>
// and the app's CFBundleVersion (CURRENT_PROJECT_VERSION) is set to n, so each dev build is distinguishable while
// CFBundleShortVersionString stays x.y.z. A dev build is signed and notarized like a live one.
//
// The app is described by native/<app-id>/macos-release.json ({ project, scheme, app }). Signing uses the
// "Developer ID Application" identity for the team in that file (or --team / APPLE_TEAM_ID) from the
// keychain. Notarization credentials come from a notarytool keychain profile (--notary-profile or
// NOTARY_PROFILE, set up once with `xcrun notarytool store-credentials`) or, in CI, from an App Store Connect
// API key (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER). Credentials are never printed.
//
// Output: <out>/<App>-<version>.dmg, <App>-<version>.zip, and SHA256SUMS, where <version> is x.y.z or
// x.y.z-dev.<n>. Nothing is uploaded or published.
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { cpSync, existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const appIdPattern = /^[a-z0-9][a-z0-9-]*$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const teamPattern = /^[A-Z0-9]{10}$/;
// A dev build number is a positive integer without leading zeros; it becomes CFBundleVersion.
const devBuildPattern = /^[1-9]\d{0,8}$/;

// A live release tag is macos/<app-id>/v<x.y.z>; a dev build tag is macos/<app-id>/v<x.y.z>-dev.<n>. The slashes
// keep both from matching publish-tag.yml's *-v*.*.*. Dev tags also return `dev` (n, as a string).
export function parseReleaseTag(tag) {
  const match = /^macos\/(?<appId>[a-z0-9][a-z0-9-]*)\/v(?<version>\d+\.\d+\.\d+)(?:-dev\.(?<dev>[1-9]\d{0,8}))?$/.exec(tag ?? '');
  if (!match) throw new Error(`Release tag must look like macos/<app-id>/v<x.y.z> or macos/<app-id>/v<x.y.z>-dev.<n>, got ${JSON.stringify(tag)}`);
  const { appId, version, dev } = match.groups;
  return dev === undefined ? { appId, version } : { appId, version, dev };
}

// The version a build's files and release are named for: x.y.z for a live release, x.y.z-dev.<n> for a dev build.
export function releaseVersion(version, dev) {
  return dev === undefined ? version : `${version}-dev.${dev}`;
}

// Catalog surfaces list only live releases (AGENTS.md rule 4). The version must be a plain x.y.z, and no link may
// name a pre-release version such as 0.1.1-dev.2 (a dev tag like /v0.1.1-dev.2 or a file like App-0.1.1-dev.2.dmg).
// The lookbehind starts a version only at the beginning of a digit run, so long digit runs scan in linear time.
const liveVersionPattern = /^(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)$/;
const prereleaseLinkPattern = /(?<!\d)\d+\.\d+\.\d+-(?:dev|alpha|beta|rc|pre|preview|canary|nightly)(?![a-z])/i;
export function prereleaseProblems({ version, url, releaseUrl }) {
  const problems = [];
  if (typeof version !== 'string' || !liveVersionPattern.test(version)) problems.push(`version ${JSON.stringify(version)} is not a plain x.y.z release`);
  for (const [name, value] of [['url', url], ['releaseUrl', releaseUrl]]) {
    // Check the decoded form too, so an escaped tag (v0.1.1%2Ddev.1) cannot slip through.
    let decoded = '';
    try {
      decoded = decodeURIComponent(String(value));
    } catch {
      // A malformed escape leaves only the raw text to check.
    }
    if (prereleaseLinkPattern.test(String(value)) || prereleaseLinkPattern.test(decoded)) problems.push(`${name} links a pre-release`);
  }
  return problems;
}

const manifestRules = [
  (m) => ['project', 'scheme', 'app'].filter((key) => typeof m[key] !== 'string' || m[key].length === 0).map((key) => `"${key}" must be a non-empty string`),
  (m) =>
    typeof m.project === 'string' && (!m.project.endsWith('.xcodeproj') || m.project.includes('..') || path.isAbsolute(m.project))
      ? ['"project" must be a .xcodeproj path inside the app directory']
      : [],
  (m) => (typeof m.app === 'string' && !/^[A-Za-z0-9 ._-]+$/.test(m.app) ? ['"app" must be a plain app name'] : []),
  (m) => (m.team !== undefined && !teamPattern.test(m.team) ? ['"team" must be a 10-character Apple team ID'] : []),
  (m) =>
    m.workspaces !== undefined && !(Array.isArray(m.workspaces) && m.workspaces.length > 0 && m.workspaces.every((name) => typeof name === 'string' && workspaceNamePattern.test(name)))
      ? ['"workspaces" must be a non-empty list of npm workspace names']
      : [],
  (m) => (m.prepare !== undefined && !(typeof m.prepare === 'string' && m.prepare.endsWith('.sh') && isRepoRelativePath(m.prepare)) ? ['"prepare" must be a .sh path inside the app directory'] : []),
  (m) => (m.prepared !== undefined && !(Array.isArray(m.prepared) && m.prepared.every(isRepoRelativePath)) ? ['"prepared" must be a list of paths inside the repository'] : []),
  (m) =>
    (m.workspaces || m.prepare) && !m.prepared?.length
      ? ['"prepared" must list the outputs of "workspaces" or "prepare", so a release can build them in a separate step']
      : [],
];

export function validateManifest(manifest, appId) {
  if (!manifest || typeof manifest !== 'object') return [`native/${appId}/macos-release.json must be an object`];
  return manifestRules.flatMap((rule) => rule(manifest));
}

// codesign lists every CodeDirectory flag, e.g. flags=0x12000(library-validation,runtime).
export function hasHardenedRuntime(signature) {
  return /flags=0x[0-9a-f]+\(([^)]*)\)/.exec(signature)?.[1].split(',').includes('runtime') ?? false;
}

// Pick the build settings of the app the manifest names, not just the first .app in the scheme.
export function selectAppSettings(settings, appName) {
  return settings.find(
    (entry) => entry.buildSettings?.WRAPPER_EXTENSION === 'app' && entry.buildSettings?.FULL_PRODUCT_NAME === `${appName}.app`
  )?.buildSettings;
}

// The script clears release files inside --out; refuse folders where a typo would be costly.
export function unsafeOutDirReason(outDir, repoRoot, home) {
  const resolved = path.resolve(outDir);
  if (resolved === path.parse(resolved).root) return 'it is the filesystem root';
  if (home && resolved === path.resolve(home)) return 'it is the home folder';
  const root = path.resolve(repoRoot);
  if (resolved === root || root.startsWith(resolved + path.sep)) return 'it contains the repository';
  return null;
}

// Options that take a value, mapped to their key in the parsed options.
const workspaceNamePattern = /^(@[a-z0-9.-]+\/)?[a-z0-9.-]+$/;

// A plain relative path with no ".", "..", or empty segments, so it can never name the repository root or leave it.
export function isRepoRelativePath(value) {
  return (
    typeof value === 'string' &&
    /^[A-Za-z0-9._/-]+$/.test(value) &&
    value.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..')
  );
}

const valueOptions = {
  '--version': 'version',
  '--dev': 'dev',
  '--out': 'out',
  '--team': 'team',
  '--notary-profile': 'notaryProfile',
  '--prepared-archive': 'preparedArchive',
  '--prepared-from': 'preparedFrom',
};
const optionChecks = [
  ['version', versionPattern, (value) => `--version must be x.y.z, got ${value}`],
  ['dev', devBuildPattern, (value) => `--dev must be a positive integer, got ${value}`],
  ['team', teamPattern, () => '--team must be a 10-character Apple team ID'],
];

function checkOptions(options) {
  if (options.prepareOnly && options.noPrepare) throw new Error('--prepare-only and --no-prepare cannot be combined');
  if (options.preparedArchive !== undefined && !options.prepareOnly) throw new Error('--prepared-archive needs --prepare-only');
  if (options.preparedFrom !== undefined && !options.noPrepare) throw new Error('--prepared-from needs --no-prepare');
  for (const [key, pattern, message] of optionChecks) {
    if (options[key] !== undefined && !pattern.test(options[key])) throw new Error(message(options[key]));
  }
}

export function parseArgs(argv) {
  const options = { skipNotarize: false };
  const rest = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    if (Object.hasOwn(valueOptions, arg)) {
      const next = argv[index + 1];
      if (next === undefined || next.startsWith('--')) throw new Error(`${arg} needs a value`);
      options[valueOptions[arg]] = next;
      index += 1;
    } else if (arg === '--skip-notarize') options.skipNotarize = true;
    else if (arg === '--prepare-only') options.prepareOnly = true;
    else if (arg === '--no-prepare') options.noPrepare = true;
    else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}`);
    else rest.push(arg);
  }
  if (rest.length !== 1) {
    throw new Error('Usage: release-macos.mjs <app-id> [--version x.y.z] [--dev n] [--out dir] [--team ID] [--notary-profile name] [--skip-notarize] [--prepare-only [--prepared-archive file] | --no-prepare]');
  }
  if (!appIdPattern.test(rest[0])) throw new Error(`Invalid app id ${JSON.stringify(rest[0])}`);
  checkOptions(options);
  return { appId: rest[0], ...options };
}

function run(command, args, { capture = false, cwd = repoRoot } = {}) {
  console.log(`$ ${command} ${args.map((arg) => (/\s/.test(arg) ? JSON.stringify(arg) : arg)).join(' ')}`);
  return execFileSync(command, args, { cwd, encoding: 'utf8', stdio: capture ? ['ignore', 'pipe', 'inherit'] : 'inherit', maxBuffer: 64 * 1024 * 1024 });
}

function notaryAuthArgs(options) {
  const profile = options.notaryProfile ?? process.env.NOTARY_PROFILE;
  if (profile) return ['--keychain-profile', profile];
  const { APPLE_API_KEY_PATH: key, APPLE_API_KEY_ID: keyId, APPLE_API_ISSUER: issuer } = process.env;
  if (key && keyId && issuer) return ['--key', key, '--key-id', keyId, '--issuer', issuer];
  throw new Error('No notarization credentials: pass --notary-profile, set NOTARY_PROFILE, or set APPLE_API_KEY_PATH, APPLE_API_KEY_ID, and APPLE_API_ISSUER (or use --skip-notarize for a signed-only test build).');
}

function notarize(file, authArgs, workDir) {
  const output = run('xcrun', ['notarytool', 'submit', file, ...authArgs, '--wait', '--output-format', 'json'], { capture: true });
  const result = JSON.parse(output);
  console.log(`Notarization ${result.id}: ${result.status}`);
  if (result.status !== 'Accepted') {
    const logPath = path.join(workDir, `notary-${result.id}.json`);
    try {
      writeFileSync(logPath, run('xcrun', ['notarytool', 'log', result.id, ...authArgs], { capture: true }));
      console.error(`Notary log: ${logPath}`);
    } catch {
      // The log can lag behind the status; the submission id above is enough to fetch it later.
    }
    throw new Error(`Notarization of ${path.basename(file)} ended with status ${result.status}`);
  }
}

// Sign the disk image with the exact identity that signed the app, so a keychain holding several Developer ID
// certificates cannot mix teams.
function signingIdentity(signature) {
  const authority = /^Authority=(Developer ID Application: .+)$/m.exec(signature)?.[1];
  if (!authority) throw new Error('Could not read the Developer ID authority from the app signature');
  return authority;
}

function sha256(file) {
  return createHash('sha256').update(readFileSync(file)).digest('hex');
}

// Reads and checks the app's manifest and Xcode settings; returns what the build needs.
function readManifest(appId) {
  const manifestPath = path.join(repoRoot, 'native', appId, 'macos-release.json');
  if (!existsSync(manifestPath)) throw new Error(`Missing ${path.relative(repoRoot, manifestPath)}`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const problems = validateManifest(manifest, appId);
  if (problems.length > 0) throw new Error(`${path.relative(repoRoot, manifestPath)}: ${problems.join('; ')}`);
  return manifest;
}

// Builds or fetches the inputs an app's Xcode build needs but the repository doesn't hold: the npm workspaces it
// bundles (Minutes embeds the built CLI) and anything its prepare script fetches (Dictate's checksum-pinned
// whisper.cpp XCFramework). This runs dependency code, so CI runs it in a job that has no signing credentials
// (--prepare-only) and hands the "prepared" outputs to the signing job (--no-prepare).
// Swift packages are resolved (fetched, and their manifests evaluated) while preparing, into a folder that is handed
// to the signing job like any other prepared output; the signing job then builds with resolution turned off.
function usesSwiftPackages(manifest, appId) {
  const pbxproj = path.join(repoRoot, 'native', appId, manifest.project, 'project.pbxproj');
  return existsSync(pbxproj) && /XC(Remote|Local)SwiftPackageReference/.test(readFileSync(pbxproj, 'utf8'));
}

const swiftPackagesFolder = (appId) => `native/${appId}/.release-packages`;

function preparedPaths(manifest, appId) {
  return [...(manifest.prepared ?? []), ...(usesSwiftPackages(manifest, appId) ? [swiftPackagesFolder(appId)] : [])];
}

function swiftPackageArgs(manifest, appId) {
  if (!usesSwiftPackages(manifest, appId)) return [];
  return ['-clonedSourcePackagesDirPath', path.join(repoRoot, swiftPackagesFolder(appId)), '-disableAutomaticPackageResolution', '-onlyUsePackageVersionsFromResolvedFile'];
}

function prepareInputs(manifest, appId) {
  if (manifest.workspaces) {
    run('npm', ['ci', '--no-audit', '--no-fund']);
    for (const name of manifest.workspaces) run('npm', ['run', 'build', `--workspace=${name}`]);
  }
  if (manifest.prepare) {
    const appDir = path.join(repoRoot, 'native', appId);
    const prepareScript = path.join(appDir, manifest.prepare);
    if (!existsSync(prepareScript)) throw new Error(`Missing prepare script native/${appId}/${manifest.prepare}`);
    run('/bin/bash', [prepareScript], { cwd: appDir });
  }
  if (usesSwiftPackages(manifest, appId)) {
    run('xcodebuild', [
      '-resolvePackageDependencies',
      '-project', path.join(repoRoot, 'native', appId, manifest.project),
      '-scheme', manifest.scheme,
      '-clonedSourcePackagesDirPath', path.join(repoRoot, swiftPackagesFolder(appId)),
      '-onlyUsePackageVersionsFromResolvedFile',
    ]);
  }
  requirePrepared(manifest, appId);
}

function requirePrepared(manifest, appId) {
  const missing = preparedPaths(manifest, appId).filter((relative) => !existsSync(path.join(repoRoot, relative)));
  if (missing.length > 0) throw new Error(`Prepared build inputs are missing: ${missing.join(', ')}`);
}

// Every symlink under root must resolve inside root (framework bundles use internal Versions/Current links).
// Every symlink under root must be relative and, followed through the filesystem (so chained links can't hide a
// "..", and dangling links fail), land inside root. Framework bundles legitimately use internal links such as
// Versions/Current -> A.
export function escapingSymlinks(root) {
  const realRoot = realpathSync(root);
  const inside = (target) => target === realRoot || target.startsWith(`${realRoot}${path.sep}`);
  const escaping = [];
  const walk = (dir) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const entryPath = path.join(dir, entry.name);
      if (entry.isSymbolicLink()) {
        let resolved = null;
        try {
          resolved = realpathSync(entryPath);
        } catch {
          // Dangling or looping link.
        }
        if (path.isAbsolute(readlinkSync(entryPath)) || !resolved || !inside(resolved)) escaping.push(path.relative(root, entryPath));
      } else if (entry.isDirectory()) walk(entryPath);
    }
  };
  if (lstatSync(root).isDirectory()) walk(root);
  return escaping;
}

// Archive member names are file names from built output (for example node_modules/@scope/pkg), so unlike manifest
// paths they may use any printable characters; only the structure is restricted.
function isSafeMemberPath(name) {
  return (
    name !== '' &&
    !name.startsWith('/') &&
    !/[\u0000-\u001f\u007f-\u009f\\]/.test(name) &&
    name.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..')
  );
}

// Archive members must be relative, free of "..", and inside one of the declared outputs.
export function unexpectedArchiveMembers(members, prepared) {
  return members.filter((member) => {
    let name = member;
    while (name.endsWith('/')) name = name.slice(0, -1);
    if (!isSafeMemberPath(name)) return true;
    return !prepared.some((root) => name === root || name.startsWith(`${root}/`) || root.startsWith(`${name}/`));
  });
}

// Copies only the manifest's declared outputs from an unpacked prepare-job archive into the checkout. The
// archive comes from a job that ran dependency code, so nothing else in it may land in the repository.
// Installs only the manifest's declared outputs from the prepare job's archive. That archive comes from a job that
// ran dependency code, so it is listed and checked before anything is unpacked, unpacked into a fresh folder, and
// each output must really (not just textually) live inside that folder before it is copied into the checkout.
function installPrepared(manifest, appId, archive) {
  const prepared = preparedPaths(manifest, appId);
  const members = run('tar', ['-tzf', archive], { capture: true }).split('\n').filter(Boolean);
  const unexpected = unexpectedArchiveMembers(members, prepared);
  if (unexpected.length > 0) throw new Error(`Prepared archive has unexpected entries: ${unexpected.slice(0, 5).join(', ')}`);

  const staging = mkdtempSync(path.join(tmpdir(), 'release-macos-prepared-'));
  try {
    // bsdtar refuses absolute paths, ".." and writes through symlinks unless -P is given.
    run('tar', ['-xzf', archive, '-C', staging]);
    const realStaging = realpathSync(staging);
    for (const relative of prepared) {
      const from = path.join(realStaging, relative);
      if (!existsSync(from) || lstatSync(from).isSymbolicLink() || realpathSync(from) !== from) {
        throw new Error(`Prepared input ${relative} is missing or not a real path in the archive`);
      }
      const escaping = escapingSymlinks(from);
      if (escaping.length > 0) throw new Error(`Prepared input ${relative} has symlinks pointing outside it: ${escaping.join(', ')}`);
      const to = path.join(repoRoot, relative);
      rmSync(to, { recursive: true, force: true });
      mkdirSync(path.dirname(to), { recursive: true });
      cpSync(from, to, { recursive: true, verbatimSymlinks: true });
    }
  } finally {
    rmSync(staging, { recursive: true, force: true });
  }
}

function archivePrepared(manifest, appId, archive) {
  const target = path.resolve(archive);
  const prepared = preparedPaths(manifest, appId);
  // An app with nothing to prepare still gets an (empty) archive, so the workflow handles every app the same way.
  if (prepared.length > 0) run('tar', ['-czf', target, '-C', repoRoot, ...prepared]);
  else run('tar', ['-czf', target, '-T', '/dev/null']);
}

function loadRelease(options) {
  const appDir = path.join(repoRoot, 'native', options.appId);
  const manifest = readManifest(options.appId);

  const team = options.team ?? process.env.APPLE_TEAM_ID ?? manifest.team;
  if (!team || !teamPattern.test(team)) throw new Error('Set the Apple team ID with "team" in the manifest, --team, or APPLE_TEAM_ID');

  const project = path.join(appDir, manifest.project);
  const settings = JSON.parse(
    run(
      'xcodebuild',
      ['-showBuildSettings', '-json', '-project', project, '-scheme', manifest.scheme, '-configuration', 'Release', '-destination', 'generic/platform=macOS', ...swiftPackageArgs(manifest, options.appId)],
      { capture: true }
    )
  );
  const appSettings = selectAppSettings(settings, manifest.app);
  if (!appSettings) throw new Error(`Scheme ${manifest.scheme} does not build ${manifest.app}.app`);
  if (appSettings.PLATFORM_NAME !== 'macosx') throw new Error(`Scheme ${manifest.scheme} builds for ${appSettings.PLATFORM_NAME}, not macOS`);
  const version = appSettings.MARKETING_VERSION;
  if (!versionPattern.test(version ?? '')) {
    throw new Error(`${manifest.scheme} must set MARKETING_VERSION as x.y.z, got ${JSON.stringify(version)}`);
  }
  if (options.version && options.version !== version) {
    throw new Error(`Requested version ${options.version} but ${manifest.scheme} has MARKETING_VERSION ${version}`);
  }
  return { manifest, team, project, version, appId: options.appId };
}

// Archives and exports the app with the Developer ID identity, then refuses anything not signed by this team's
// Developer ID with the hardened runtime. Returns the exported app and its signature details.
function buildSignedApp({ manifest, team, project, version, appId }, dev, workDir) {
  const archivePath = path.join(workDir, `${manifest.app}.xcarchive`);
  run('xcodebuild', [
    'archive',
    '-project', project,
    '-scheme', manifest.scheme,
    '-configuration', 'Release',
    '-destination', 'generic/platform=macOS',
    '-archivePath', archivePath,
    '-derivedDataPath', path.join(workDir, 'DerivedData'),
    ...swiftPackageArgs(manifest, appId),
    `DEVELOPMENT_TEAM=${team}`,
    'CODE_SIGN_STYLE=Manual',
    'CODE_SIGN_IDENTITY=Developer ID Application',
    'PROVISIONING_PROFILE_SPECIFIER=',
    'ENABLE_HARDENED_RUNTIME=YES',
    'OTHER_CODE_SIGN_FLAGS=--timestamp',
    // A dev build stamps its number into CFBundleVersion for every target, so embedded extensions still match.
    ...(dev === undefined ? [] : [`CURRENT_PROJECT_VERSION=${dev}`]),
  ]);

  const exportOptions = path.join(workDir, 'ExportOptions.plist');
  writeFileSync(
    exportOptions,
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
  <key>teamID</key><string>${team}</string>
</dict>
</plist>
`
  );
  const exportDir = path.join(workDir, 'export');
  run('xcodebuild', ['-exportArchive', '-archivePath', archivePath, '-exportPath', exportDir, '-exportOptionsPlist', exportOptions]);
  const appPath = path.join(exportDir, `${manifest.app}.app`);
  if (!existsSync(appPath)) throw new Error(`Export did not produce ${manifest.app}.app`);
  checkBundleVersions(appPath, version, dev);

  run('/usr/bin/codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]);
  // codesign prints signature details on stderr.
  const details = spawnSync('/usr/bin/codesign', ['-dvv', appPath], { encoding: 'utf8' });
  if (details.status !== 0) throw new Error(`codesign -dvv failed: ${details.stderr.trim()}`);
  const signature = details.stdout + details.stderr;
  if (!signature.includes(`Authority=Developer ID Application:`) || !signature.includes(`TeamIdentifier=${team}`)) {
    throw new Error('App is not signed with a Developer ID Application certificate for the expected team');
  }
  if (!hasHardenedRuntime(signature)) throw new Error('App is not signed with the hardened runtime');
  return { appPath, signature };
}

function plistValue(plist, key) {
  return execFileSync('/usr/libexec/PlistBuddy', ['-c', `Print :${key}`, plist], { encoding: 'utf8' }).trim();
}

// The exported app must carry the release's version, and a dev build its build number.
function checkBundleVersions(appPath, version, dev) {
  const plist = path.join(appPath, 'Contents', 'Info.plist');
  const shortVersion = plistValue(plist, 'CFBundleShortVersionString');
  const bundleVersion = plistValue(plist, 'CFBundleVersion');
  if (shortVersion !== version) throw new Error(`App has CFBundleShortVersionString ${shortVersion}, expected ${version}`);
  if (dev !== undefined && bundleVersion !== dev) throw new Error(`Dev build ${dev} has CFBundleVersion ${bundleVersion}, expected ${dev}`);
  console.log(`CFBundleShortVersionString ${shortVersion}, CFBundleVersion ${bundleVersion}`);
}

// Submits `submission` for notarization, then staples the ticket to `target` (an app is submitted as a zip but
// stapled as the .app; a DMG is both).
function notarizeAndStaple(submission, target, authArgs, workDir) {
  notarize(submission, authArgs, workDir);
  run('xcrun', ['stapler', 'staple', target]);
  run('xcrun', ['stapler', 'validate', target]);
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.prepareOnly) {
    const manifest = readManifest(options.appId);
    prepareInputs(manifest, options.appId);
    if (options.preparedArchive) archivePrepared(manifest, options.appId, options.preparedArchive);
    return;
  }
  // Inputs go in place before the first xcodebuild call, which already needs resolved Swift packages.
  const appManifest = readManifest(options.appId);
  if (options.preparedFrom) installPrepared(appManifest, options.appId, options.preparedFrom);
  if (options.noPrepare) requirePrepared(appManifest, options.appId);
  else prepareInputs(appManifest, options.appId);

  const release = loadRelease(options);
  const { manifest, version } = release;
  const fullVersion = releaseVersion(version, options.dev);
  // Resolve credentials before the slow build so a missing setup fails fast.
  const authArgs = options.skipNotarize ? null : notaryAuthArgs(options);

  const outDir = path.resolve(options.out ?? path.join(repoRoot, 'dist', 'macos', options.appId, fullVersion));
  const outDirProblem = unsafeOutDirReason(outDir, repoRoot, process.env.HOME);
  if (outDirProblem) throw new Error(`Refusing to use ${outDir} as --out: ${outDirProblem}`);
  // Only remove what this script writes; --out may be a folder with other files in it.
  const workDir = path.join(outDir, '.release-macos-work');
  const base = `${manifest.app.replace(/\s+/g, '-')}-${fullVersion}`;
  const zipPath = path.join(outDir, `${base}.zip`);
  const dmgPath = path.join(outDir, `${base}.dmg`);
  for (const owned of [workDir, zipPath, dmgPath, path.join(outDir, 'SHA256SUMS')]) rmSync(owned, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });

  const { appPath, signature } = buildSignedApp(release, options.dev, workDir);

  if (authArgs) {
    const submitZip = path.join(workDir, `${base}-submit.zip`);
    run('ditto', ['-c', '-k', '--keepParent', appPath, submitZip]);
    notarizeAndStaple(submitZip, appPath, authArgs, workDir);
  }

  // The zip holds the stapled app, so it opens offline without a Gatekeeper lookup.
  run('ditto', ['-c', '-k', '--keepParent', appPath, zipPath]);

  const dmgRoot = path.join(workDir, 'dmg');
  mkdirSync(dmgRoot);
  run('ditto', [appPath, path.join(dmgRoot, `${manifest.app}.app`)]);
  symlinkSync('/Applications', path.join(dmgRoot, 'Applications'));
  run('hdiutil', ['create', '-volname', manifest.app, '-srcfolder', dmgRoot, '-fs', 'HFS+', '-format', 'UDZO', '-ov', dmgPath]);
  run('/usr/bin/codesign', ['--sign', signingIdentity(signature), '--timestamp', dmgPath]);

  if (authArgs) {
    notarizeAndStaple(dmgPath, dmgPath, authArgs, workDir);
    // Gatekeeper's own verdict on what a downloader gets.
    run('spctl', ['--assess', '--type', 'execute', '--verbose=4', appPath]);
    run('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', dmgPath]);
  }

  const sums = [dmgPath, zipPath].map((file) => `${sha256(file)}  ${path.basename(file)}`).join('\n') + '\n';
  writeFileSync(path.join(outDir, 'SHA256SUMS'), sums);
  rmSync(workDir, { recursive: true, force: true });

  console.log(`\n${authArgs ? 'Signed, notarized, and stapled' : 'Signed (NOT notarized)'} ${manifest.app} ${fullVersion}:`);
  console.log(sums.trimEnd().replace(/^/gm, '  '));
  console.log(`  in ${outDir}`);
  if (process.env.GITHUB_OUTPUT) {
    writeFileSync(process.env.GITHUB_OUTPUT, `out_dir=${outDir}\nversion=${fullVersion}\napp=${manifest.app}\n`, { flag: 'a' });
  }
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`release-macos: ${error.message}`);
    process.exit(1);
  }
}
