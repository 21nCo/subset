#!/usr/bin/env node
// Builds a Developer ID-signed, notarized, stapled macOS release of one native app:
//   node scripts/release-macos.mjs <app-id> [--version <x.y.z>] [--out <dir>] [--skip-notarize]
//
// The app is described by native/<app-id>/macos-release.json ({ project, scheme, app }). Signing uses the
// "Developer ID Application" identity for the team in that file (or --team / APPLE_TEAM_ID) from the
// keychain. Notarization credentials come from a notarytool keychain profile (--notary-profile or
// NOTARY_PROFILE, set up once with `xcrun notarytool store-credentials`) or, in CI, from an App Store Connect
// API key (APPLE_API_KEY_PATH, APPLE_API_KEY_ID, APPLE_API_ISSUER). Credentials are never printed.
//
// Output: <out>/<App>-<version>.dmg, <App>-<version>.zip, and SHA256SUMS. Nothing is uploaded or published.
import { execFileSync } from 'node:child_process';
import { createHash } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const appIdPattern = /^[a-z0-9][a-z0-9-]*$/;
const versionPattern = /^\d+\.\d+\.\d+$/;
const teamPattern = /^[A-Z0-9]{10}$/;

// A release tag is macos/<app-id>/v<version>. The slashes keep it from matching publish-tag.yml's *-v*.*.*.
export function parseReleaseTag(tag) {
  const match = /^macos\/(?<appId>[a-z0-9][a-z0-9-]*)\/v(?<version>\d+\.\d+\.\d+)$/.exec(tag ?? '');
  if (!match) throw new Error(`Release tag must look like macos/<app-id>/v<x.y.z>, got ${JSON.stringify(tag)}`);
  return { appId: match.groups.appId, version: match.groups.version };
}

export function validateManifest(manifest, appId) {
  const problems = [];
  if (!manifest || typeof manifest !== 'object') return [`native/${appId}/macos-release.json must be an object`];
  for (const key of ['project', 'scheme', 'app']) {
    if (typeof manifest[key] !== 'string' || manifest[key].length === 0) problems.push(`"${key}" must be a non-empty string`);
  }
  if (typeof manifest.project === 'string' && (!manifest.project.endsWith('.xcodeproj') || manifest.project.includes('..') || path.isAbsolute(manifest.project))) {
    problems.push('"project" must be a .xcodeproj path inside the app directory');
  }
  if (typeof manifest.app === 'string' && !/^[A-Za-z0-9 ._-]+$/.test(manifest.app)) problems.push('"app" must be a plain app name');
  if (manifest.team !== undefined && !teamPattern.test(manifest.team)) problems.push('"team" must be a 10-character Apple team ID');
  return problems;
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

export function parseArgs(argv) {
  const options = { skipNotarize: false };
  const rest = [];
  for (let index = 0; index < argv.length; index += 1) {
    const arg = argv[index];
    const value = () => {
      const next = argv[index + 1];
      if (next === undefined || next.startsWith('--')) throw new Error(`${arg} needs a value`);
      index += 1;
      return next;
    };
    if (arg === '--version') options.version = value();
    else if (arg === '--out') options.out = value();
    else if (arg === '--team') options.team = value();
    else if (arg === '--notary-profile') options.notaryProfile = value();
    else if (arg === '--skip-notarize') options.skipNotarize = true;
    else if (arg.startsWith('--')) throw new Error(`Unknown option ${arg}`);
    else rest.push(arg);
  }
  if (rest.length !== 1) throw new Error('Usage: release-macos.mjs <app-id> [--version x.y.z] [--out dir] [--team ID] [--notary-profile name] [--skip-notarize]');
  if (!appIdPattern.test(rest[0])) throw new Error(`Invalid app id ${JSON.stringify(rest[0])}`);
  if (options.version !== undefined && !versionPattern.test(options.version)) throw new Error(`--version must be x.y.z, got ${options.version}`);
  if (options.team !== undefined && !teamPattern.test(options.team)) throw new Error('--team must be a 10-character Apple team ID');
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

function main() {
  const options = parseArgs(process.argv.slice(2));
  const appDir = path.join(repoRoot, 'native', options.appId);
  const manifestPath = path.join(appDir, 'macos-release.json');
  if (!existsSync(manifestPath)) throw new Error(`Missing ${path.relative(repoRoot, manifestPath)}`);
  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  const problems = validateManifest(manifest, options.appId);
  if (problems.length > 0) throw new Error(`${path.relative(repoRoot, manifestPath)}: ${problems.join('; ')}`);

  const team = options.team ?? process.env.APPLE_TEAM_ID ?? manifest.team;
  if (!team || !teamPattern.test(team)) throw new Error('Set the Apple team ID with "team" in the manifest, --team, or APPLE_TEAM_ID');
  // Resolve credentials before the slow build so a missing setup fails fast.
  const authArgs = options.skipNotarize ? null : notaryAuthArgs(options);

  const project = path.join(appDir, manifest.project);
  const settings = JSON.parse(
    run('xcodebuild', ['-showBuildSettings', '-json', '-project', project, '-scheme', manifest.scheme, '-configuration', 'Release', '-destination', 'generic/platform=macOS'], { capture: true })
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

  const outDir = path.resolve(options.out ?? path.join(repoRoot, 'dist', 'macos', options.appId, version));
  const outDirProblem = unsafeOutDirReason(outDir, repoRoot, process.env.HOME);
  if (outDirProblem) throw new Error(`Refusing to use ${outDir} as --out: ${outDirProblem}`);
  // Only remove what this script writes; --out may be a folder with other files in it.
  const workDir = path.join(outDir, '.release-macos-work');
  const base = `${manifest.app.replace(/\s+/g, '-')}-${version}`;
  const zipPath = path.join(outDir, `${base}.zip`);
  const dmgPath = path.join(outDir, `${base}.dmg`);
  for (const owned of [workDir, zipPath, dmgPath, path.join(outDir, 'SHA256SUMS')]) rmSync(owned, { recursive: true, force: true });
  mkdirSync(workDir, { recursive: true });

  const archivePath = path.join(workDir, `${manifest.app}.xcarchive`);
  run('xcodebuild', [
    'archive',
    '-project', project,
    '-scheme', manifest.scheme,
    '-configuration', 'Release',
    '-destination', 'generic/platform=macOS',
    '-archivePath', archivePath,
    '-derivedDataPath', path.join(workDir, 'DerivedData'),
    `DEVELOPMENT_TEAM=${team}`,
    'CODE_SIGN_STYLE=Manual',
    'CODE_SIGN_IDENTITY=Developer ID Application',
    'PROVISIONING_PROFILE_SPECIFIER=',
    'ENABLE_HARDENED_RUNTIME=YES',
    'OTHER_CODE_SIGN_FLAGS=--timestamp',
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

  // Refuse to ship anything not signed by this team's Developer ID with the hardened runtime.
  run('codesign', ['--verify', '--deep', '--strict', '--verbose=2', appPath]);
  // codesign prints signature details on stderr.
  const signature = execFileSync('sh', ['-c', 'codesign -dvv "$1" 2>&1', 'sh', appPath], { encoding: 'utf8' });
  if (!signature.includes(`Authority=Developer ID Application:`) || !signature.includes(`TeamIdentifier=${team}`)) {
    throw new Error('App is not signed with a Developer ID Application certificate for the expected team');
  }
  if (!hasHardenedRuntime(signature)) throw new Error('App is not signed with the hardened runtime');

  if (authArgs) {
    const submitZip = path.join(workDir, `${base}-submit.zip`);
    run('ditto', ['-c', '-k', '--keepParent', appPath, submitZip]);
    notarize(submitZip, authArgs, workDir);
    run('xcrun', ['stapler', 'staple', appPath]);
    run('xcrun', ['stapler', 'validate', appPath]);
  }

  // The zip holds the stapled app, so it opens offline without a Gatekeeper lookup.
  run('ditto', ['-c', '-k', '--keepParent', appPath, zipPath]);

  const dmgRoot = path.join(workDir, 'dmg');
  mkdirSync(dmgRoot);
  run('ditto', [appPath, path.join(dmgRoot, `${manifest.app}.app`)]);
  symlinkSync('/Applications', path.join(dmgRoot, 'Applications'));
  run('hdiutil', ['create', '-volname', manifest.app, '-srcfolder', dmgRoot, '-fs', 'HFS+', '-format', 'UDZO', '-ov', dmgPath]);
  run('codesign', ['--sign', signingIdentity(signature), '--timestamp', dmgPath]);

  if (authArgs) {
    notarize(dmgPath, authArgs, workDir);
    run('xcrun', ['stapler', 'staple', dmgPath]);
    run('xcrun', ['stapler', 'validate', dmgPath]);
    // Gatekeeper's own verdict on what a downloader gets.
    run('spctl', ['--assess', '--type', 'execute', '--verbose=4', appPath]);
    run('spctl', ['--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=4', dmgPath]);
  }

  const sums = [dmgPath, zipPath].map((file) => `${sha256(file)}  ${path.basename(file)}`).join('\n') + '\n';
  writeFileSync(path.join(outDir, 'SHA256SUMS'), sums);
  rmSync(workDir, { recursive: true, force: true });

  console.log(`\n${authArgs ? 'Signed, notarized, and stapled' : 'Signed (NOT notarized)'} ${manifest.app} ${version}:`);
  console.log(sums.trimEnd().replace(/^/gm, '  '));
  console.log(`  in ${outDir}`);
  if (process.env.GITHUB_OUTPUT) {
    writeFileSync(process.env.GITHUB_OUTPUT, `out_dir=${outDir}\nversion=${version}\napp=${manifest.app}\n`, { flag: 'a' });
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
