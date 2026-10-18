#!/usr/bin/env node
// Builds a Developer ID-signed, notarized, stapled macOS release of one native app:
//   node scripts/release-macos.mjs <app-id> [--version <x.y.z>] [--beta <n>] [--out <dir>] [--skip-notarize]
//
// --beta <n> makes beta build n of the app's MARKETING_VERSION: the files are named <App>-<x.y.z>-beta.<n> and the
// app's CFBundleVersion (CURRENT_PROJECT_VERSION) is set to n, so each beta build is distinguishable while
// CFBundleShortVersionString stays x.y.z. A beta build is signed and notarized like a live one. --dev <n> makes the
// same kind of build named x.y.z-dev.<n>, the label test builds used before betas.
//
// The app is described by native/<app-id>/macos-release.json ({ project, scheme, app }). Signing uses the
// "Developer ID Application" identity for the team in that file (or --team / APPLE_TEAM_ID) from the
// keychain. Notarization credentials come from a notarytool keychain profile (--notary-profile or
// NOTARY_PROFILE, set up once with `xcrun notarytool store-credentials`) or, in CI, from an App Store Connect
// API key (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER). Credentials are never printed.
//
// Output: <out>/<App>-<version>.dmg, <App>-<version>.zip, and SHA256SUMS, where <version> is x.y.z or
// x.y.z-beta.<n>. Nothing is uploaded or published.
//
// Building and signing can run separately, so no project, package, or npm code ever runs while signing
// credentials are present:
//   --archive-only --archive-out <file>   prepare inputs and archive the app with an ad-hoc signature (no credentials)
//   --from-archive <file> --version <v>   re-sign that archive with Developer ID, notarize, and package; runs nothing
//                                         from the project
import { execFileSync, spawnSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, lstatSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, readlinkSync, realpathSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const appIdPattern = /^[a-z0-9][a-z0-9-]*$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const teamPattern = /^[A-Z0-9]{10}$/;
// A beta (or older dev) build number is a positive integer without leading zeros; it becomes CFBundleVersion.
const buildNumberPattern = /^[1-9]\d{0,8}$/;

// A live release tag is macos/<app-id>/v<x.y.z>; a beta build tag is macos/<app-id>/v<x.y.z>-beta.<n> (older test
// builds used -dev.<n>). The slashes keep them from matching publish-tag.yml's *-v*.*.*. A test build tag also
// returns `prerelease`: its channel and build number n (as a string).
export function parseReleaseTag(tag) {
  const match = /^macos\/(?<appId>[a-z0-9][a-z0-9-]*)\/v(?<version>\d+\.\d+\.\d+)(?:-(?<channel>beta|dev)\.(?<build>[1-9]\d{0,8}))?$/.exec(tag ?? '');
  if (!match) throw new Error(`Release tag must look like macos/<app-id>/v<x.y.z> or macos/<app-id>/v<x.y.z>-beta.<n>, got ${JSON.stringify(tag)}`);
  const { appId, version, channel, build } = match.groups;
  return channel === undefined ? { appId, version } : { appId, version, prerelease: { channel, build } };
}

// The version a build's files and release are named for: x.y.z for a live release, x.y.z-beta.<n> for a beta build.
export function releaseVersion(version, prerelease) {
  return prerelease === undefined ? version : `${version}-${prerelease.channel}.${prerelease.build}`;
}

// Catalog surfaces list only live releases (AGENTS.md rule 4). The version must be a plain x.y.z, and no link may
// name a pre-release version such as 0.1.1-beta.2 (a beta tag like /v0.1.1-beta.2 or a file like App-0.1.1-beta.2.dmg).
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
  '--beta': 'beta',
  '--dev': 'dev',
  '--out': 'out',
  '--team': 'team',
  '--notary-profile': 'notaryProfile',
  '--archive-out': 'archiveOut',
  '--from-archive': 'fromArchive',
};
const optionChecks = [
  ['version', versionPattern, (value) => `--version must be x.y.z, got ${value}`],
  ['beta', buildNumberPattern, (value) => `--beta must be a positive integer, got ${value}`],
  ['dev', buildNumberPattern, (value) => `--dev must be a positive integer, got ${value}`],
  ['team', teamPattern, () => '--team must be a 10-character Apple team ID'],
];

function checkOptions(options) {
  if (options.archiveOnly && options.archiveOut === undefined) throw new Error('--archive-only needs --archive-out');
  if (options.archiveOut !== undefined && !options.archiveOnly) throw new Error('--archive-out needs --archive-only');
  if (options.fromArchive !== undefined && options.archiveOnly) throw new Error('--from-archive and --archive-only cannot be combined');
  // Signing an archive must not run xcodebuild on the project to learn its version, so the version is given.
  if (options.fromArchive !== undefined && options.version === undefined) throw new Error('--from-archive needs --version');
  for (const [key, pattern, message] of optionChecks) {
    if (options[key] !== undefined && !pattern.test(options[key])) throw new Error(message(options[key]));
  }
  if (options.beta !== undefined && options.dev !== undefined) throw new Error('--beta and --dev cannot be combined');
}

// --beta n and --dev n become { channel, build }.
function withPrerelease({ beta, dev, ...options }) {
  if (beta !== undefined) return { ...options, prerelease: { channel: 'beta', build: beta } };
  if (dev !== undefined) return { ...options, prerelease: { channel: 'dev', build: dev } };
  return options;
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
    else if (arg === '--archive-only') options.archiveOnly = true;
    else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}`);
    else rest.push(arg);
  }
  if (rest.length !== 1) {
    throw new Error('Usage: release-macos.mjs <app-id> [--version x.y.z] [--beta n] [--out dir] [--team ID] [--notary-profile name] [--skip-notarize] [--archive-only --archive-out file | --from-archive file]');
  }
  if (!appIdPattern.test(rest[0])) throw new Error(`Invalid app id ${JSON.stringify(rest[0])}`);
  checkOptions(options);
  return { appId: rest[0], ...withPrerelease(options) };
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

function readManifest(appId) {
  const manifestPath = path.join(repoRoot, 'native', appId, 'macos-release.json');
  if (!existsSync(manifestPath)) throw new Error(`Missing ${path.relative(repoRoot, manifestPath)}`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const problems = validateManifest(manifest, appId);
  if (problems.length > 0) throw new Error(`${path.relative(repoRoot, manifestPath)}: ${problems.join('; ')}`);
  return manifest;
}

function resolveTeam(options, manifest) {
  const team = options.team ?? process.env.APPLE_TEAM_ID ?? manifest.team;
  if (!team || !teamPattern.test(team)) throw new Error('Set the Apple team ID with "team" in the manifest, --team, or APPLE_TEAM_ID');
  return team;
}

// Builds or fetches what the Xcode build needs but the repository doesn't hold: the npm workspaces the app bundles
// (Minutes embeds the built CLI) and anything its prepare script fetches (Dictate's checksum-pinned whisper.cpp
// XCFramework).
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
}

// Every symlink under root must be relative and, followed through the filesystem (so chained links can't hide a
// "..", and dangling links fail), land inside root. App and framework bundles legitimately use internal links such
// as Versions/Current -> A.
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

// Archive member names are file names from built output, so they may use any printable characters; only the
// structure is restricted.
function isSafeMemberPath(name) {
  return (
    name !== '' &&
    !name.startsWith('/') &&
    !/[\u0000-\u001f\u007f-\u009f\\]/.test(name) &&
    name.split('/').every((segment) => segment !== '' && segment !== '.' && segment !== '..')
  );
}

// Archive members must be relative, free of "..", and inside one of the allowed roots (or a parent folder of one).
export function unexpectedArchiveMembers(members, roots) {
  return members.filter((member) => {
    let name = member;
    while (name.endsWith('/')) name = name.slice(0, -1);
    if (!isSafeMemberPath(name)) return true;
    return !roots.some((root) => name === root || name.startsWith(`${root}/`) || root.startsWith(`${name}/`));
  });
}

// Builds of an app that uses Swift packages must use exactly the versions in its committed Package.resolved.
function swiftPackageArgs(manifest, appId) {
  const pbxproj = path.join(repoRoot, 'native', appId, manifest.project, 'project.pbxproj');
  const usesPackages = existsSync(pbxproj) && /XC(Remote|Local)SwiftPackageReference/.test(readFileSync(pbxproj, 'utf8'));
  return usesPackages ? ['-onlyUsePackageVersionsFromResolvedFile'] : [];
}

// Reads the version from the project. Only used where the project is built anyway: it can evaluate Swift package
// manifests.
function projectVersion(options, manifest) {
  const project = path.join(repoRoot, 'native', options.appId, manifest.project);
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
  return version;
}

// Archives the app with an ad-hoc signature: entitlements and the hardened runtime are applied, but no signing
// identity is used, so this step needs no credentials. Export re-signs it with Developer ID.
function archiveApp({ appId, manifest, team, version }, prerelease, workDir) {
  const archivePath = path.join(workDir, `${manifest.app}.xcarchive`);
  run('xcodebuild', [
    'archive',
    '-project', path.join(repoRoot, 'native', appId, manifest.project),
    '-scheme', manifest.scheme,
    '-configuration', 'Release',
    '-destination', 'generic/platform=macOS',
    '-archivePath', archivePath,
    '-derivedDataPath', path.join(workDir, 'DerivedData'),
    ...swiftPackageArgs(manifest, appId),
    `DEVELOPMENT_TEAM=${team}`,
    'CODE_SIGN_STYLE=Manual',
    'CODE_SIGN_IDENTITY=-',
    'PROVISIONING_PROFILE_SPECIFIER=',
    'ENABLE_HARDENED_RUNTIME=YES',
    // A beta build stamps its number into CFBundleVersion for every target, so embedded extensions still match.
    ...(prerelease === undefined ? [] : [`CURRENT_PROJECT_VERSION=${prerelease.build}`]),
  ]);
  checkBundleVersions(archivedApp(archivePath, manifest), version, prerelease);
  return archivePath;
}

const archivedApp = (archivePath, manifest) => path.join(archivePath, 'Products', 'Applications', `${manifest.app}.app`);

// Unpacks an archive made by --archive-only. It comes from a job that ran project, package, and npm code, so its
// entries are checked before anything is written, it is unpacked into the work folder, and every symlink in it must
// resolve inside it. Nothing in it is executed: export only re-signs it.
function unpackArchive(file, manifest, workDir) {
  const root = `${manifest.app}.xcarchive`;
  const members = run('tar', ['-tzf', file], { capture: true }).split('\n').filter(Boolean);
  const unexpected = unexpectedArchiveMembers(members, [root]);
  if (unexpected.length > 0) throw new Error(`Archive has unexpected entries: ${unexpected.slice(0, 5).join(', ')}`);
  // bsdtar refuses absolute paths, ".." and writes through symlinks unless -P is given.
  run('tar', ['-xzf', file, '-C', workDir]);
  const archivePath = path.join(realpathSync(workDir), root);
  if (!existsSync(archivePath) || lstatSync(archivePath).isSymbolicLink()) throw new Error(`Archive does not contain ${root}`);
  const escaping = escapingSymlinks(archivePath);
  if (escaping.length > 0) throw new Error(`Archive has symlinks pointing outside it: ${escaping.slice(0, 5).join(', ')}`);
  if (!existsSync(archivedApp(archivePath, manifest))) throw new Error(`Archive does not contain ${manifest.app}.app`);
  return archivePath;
}

// Re-signs the archive with the Developer ID identity, then refuses anything not signed by this team's Developer
// ID with the hardened runtime. Returns the exported app and its signature details.
function exportSigned(archivePath, { manifest, team, version }, prerelease, workDir) {
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
  checkBundleVersions(appPath, version, prerelease);

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

// The app must carry the release's version, and a beta build its build number.
function checkBundleVersions(appPath, version, prerelease) {
  const plist = path.join(appPath, 'Contents', 'Info.plist');
  const shortVersion = plistValue(plist, 'CFBundleShortVersionString');
  const bundleVersion = plistValue(plist, 'CFBundleVersion');
  if (shortVersion !== version) throw new Error(`App has CFBundleShortVersionString ${shortVersion}, expected ${version}`);
  if (prerelease !== undefined && bundleVersion !== prerelease.build) {
    throw new Error(`Build ${releaseVersion(version, prerelease)} has CFBundleVersion ${bundleVersion}, expected ${prerelease.build}`);
  }
  console.log(`CFBundleShortVersionString ${shortVersion}, CFBundleVersion ${bundleVersion}`);
}

// Submits `submission` for notarization, then staples the ticket to `target` (an app is submitted as a zip but
// stapled as the .app; a DMG is both).
function notarizeAndStaple(submission, target, authArgs, workDir) {
  notarize(submission, authArgs, workDir);
  run('xcrun', ['stapler', 'staple', target]);
  run('xcrun', ['stapler', 'validate', target]);
}

// --archive-only: prepare and archive, then write the archive for the signing step. Needs no credentials.
function writeArchiveOnly(options) {
  const manifest = readManifest(options.appId);
  const team = resolveTeam(options, manifest);
  prepareInputs(manifest, options.appId);
  const version = projectVersion(options, manifest);
  const workDir = mkdtempSync(path.join(tmpdir(), 'release-macos-archive-'));
  try {
    const archivePath = archiveApp({ appId: options.appId, manifest, team, version }, options.prerelease, workDir);
    run('tar', ['-czf', path.resolve(options.archiveOut), '-C', workDir, path.basename(archivePath)]);
    console.log(`\nArchived ${manifest.app} ${releaseVersion(version, options.prerelease)} (ad-hoc signed) to ${options.archiveOut}`);
  } finally {
    rmSync(workDir, { recursive: true, force: true });
  }
}

function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.archiveOnly) return writeArchiveOnly(options);

  const manifest = readManifest(options.appId);
  const team = resolveTeam(options, manifest);
  if (!options.fromArchive) prepareInputs(manifest, options.appId);
  const version = options.fromArchive ? options.version : projectVersion(options, manifest);
  const release = { appId: options.appId, manifest, team, version };
  const fullVersion = releaseVersion(version, options.prerelease);
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

  let archivePath;
  if (options.fromArchive) {
    archivePath = unpackArchive(options.fromArchive, manifest, workDir);
    checkBundleVersions(archivedApp(archivePath, manifest), version, options.prerelease);
  } else {
    archivePath = archiveApp(release, options.prerelease, workDir);
  }
  const { appPath, signature } = exportSigned(archivePath, release, options.prerelease, workDir);

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
