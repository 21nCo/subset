// Proves that an app bundle is a Subset app before `subset install` puts it in place (SET-230). The checks run on the
// staged copy in the destination folder, in this order, and the first that fails names itself:
//   signature        codesign --verify --deep --strict accepts the bundle
//   team             codesign -d --verbose=2 reports TeamIdentifier=SAZVPX4CAA (21n's Developer ID team)
//   notarization     spctl --assess --type execute accepts it, as a notarized Developer ID app
//   bundle ID        Info.plist's CFBundleIdentifier is the feed's bundleId
//   version          its CFBundleShortVersionString is the channel's version (and, for a beta, CFBundleVersion its build)
//   macOS version    its LSMinimumSystemVersion is not above the running macOS
// Signature, team and notarization come from the tools, never from parsing the binary.
import { execFile } from 'node:child_process';
import { readInfoPlist } from './apps.mjs';

export const TEAM_ID = 'SAZVPX4CAA';
/** The tools the checks ask. Tests replace them with stand-ins. */
export const VERIFY_TOOLS = Object.freeze({
  codesign: '/usr/bin/codesign',
  spctl: '/usr/sbin/spctl',
  plutil: '/usr/bin/plutil',
  swVers: '/usr/bin/sw_vers'
});
const TOOL_TIMEOUT_MS = 5 * 60 * 1000;
const MAX_OUTPUT_BYTES = 1024 * 1024;

/** A check refused the app: `check` names it (signature, team, notarization, bundle ID, version, macOS version). */
export class VerificationError extends Error {
  constructor(check, message) {
    super(message);
    this.check = check;
  }
}

/**
 * Runs a tool without a shell and resolves { code, signal, stdout, stderr } whatever its exit status. Rejects only
 * when it cannot be started, or when `signal` (an AbortSignal) aborts it.
 */
export function runTool(file, args, { signal, timeout = TOOL_TIMEOUT_MS } = {}) {
  return new Promise((resolve, reject) => {
    const child = execFile(file, args, { encoding: 'utf8', timeout, maxBuffer: MAX_OUTPUT_BYTES, signal }, (error, stdout, stderr) => {
      if (signal?.aborted) return reject(signal.reason ?? error);
      if (error && typeof error.code !== 'number' && error.signal == null) return reject(error);
      resolve({ code: error ? (error.code ?? null) : 0, signal: error?.signal ?? null, stdout: String(stdout), stderr: String(stderr) });
    });
    // Nothing is typed into a tool (hdiutil would otherwise wait for an answer to a licence prompt).
    child.stdin?.end();
  });
}

/** Compares two x.y.z versions: negative, 0 or positive. Each must match ^\d+\.\d+\.\d+$. */
export function compareVersions(a, b) {
  const left = a.split('.').map(Number);
  const right = b.split('.').map(Number);
  for (let index = 0; index < 3; index += 1) {
    if (left[index] !== right[index]) return left[index] - right[index];
  }
  return 0;
}

// A macOS version (14, 14.0, 14.2.1) as three numbers, or undefined when it is not one.
function macosVersion(text) {
  if (typeof text !== 'string' || !/^\d+(?:\.\d+){0,2}$/.test(text)) return undefined;
  const parts = text.split('.').map(Number);
  while (parts.length < 3) parts.push(0);
  return parts.join('.');
}

// The last line a tool wrote, for a refusal message.
const lastLine = (text) => text.trim().split('\n').at(-1)?.trim() || 'no output';

/**
 * Checks the app bundle at `bundle` against what the feed says it is: { bundleId, version, build? } (build for a beta).
 * Resolves when every check passes; rejects with a VerificationError naming the first that does not.
 */
export async function verifyApp(bundle, expected, { tools = VERIFY_TOOLS, signal } = {}) {
  const verify = await runTool(tools.codesign, ['--verify', '--deep', '--strict', bundle], { signal });
  if (verify.code !== 0) throw new VerificationError('signature', `the code signature is not valid (codesign: ${lastLine(verify.stderr)})`);

  const details = await runTool(tools.codesign, ['-d', '--verbose=2', bundle], { signal });
  const teams = [...`${details.stderr}\n${details.stdout}`.matchAll(/^TeamIdentifier=(.*)$/gm)].map((match) => match[1].trim());
  if (details.code !== 0 || teams.length !== 1 || teams[0] !== TEAM_ID) {
    const found = teams.length === 1 ? teams[0] : 'not reported';
    throw new VerificationError('team', `it is not signed by the Subset team ${TEAM_ID} (TeamIdentifier: ${found})`);
  }

  const assessment = await runTool(tools.spctl, ['--assess', '--type', 'execute', '-vv', bundle], { signal });
  const source = /^source=(.*)$/m.exec(`${assessment.stderr}\n${assessment.stdout}`)?.[1].trim();
  if (assessment.code !== 0 || source !== 'Notarized Developer ID') {
    throw new VerificationError('notarization', `Gatekeeper does not accept it as a notarized Developer ID app (spctl: ${source ? `source=${source}` : lastLine(assessment.stderr)})`);
  }

  const info = await readInfoPlist(bundle, tools.plutil);
  if (info === undefined) throw new VerificationError('bundle ID', 'its Contents/Info.plist cannot be read');
  if (info.CFBundleIdentifier !== expected.bundleId) {
    throw new VerificationError('bundle ID', `its bundle ID is ${JSON.stringify(info.CFBundleIdentifier ?? null)}, not ${expected.bundleId}`);
  }
  if (info.CFBundleShortVersionString !== expected.version) {
    throw new VerificationError('version', `its version is ${JSON.stringify(info.CFBundleShortVersionString ?? null)}, not ${expected.version}`);
  }
  if (expected.build !== undefined && info.CFBundleVersion !== String(expected.build)) {
    throw new VerificationError('version', `its build is ${JSON.stringify(info.CFBundleVersion ?? null)}, not ${expected.build}`);
  }

  if (info.LSMinimumSystemVersion !== undefined) {
    const minimum = macosVersion(info.LSMinimumSystemVersion);
    if (minimum === undefined) throw new VerificationError('macOS version', `its minimum macOS version ${JSON.stringify(info.LSMinimumSystemVersion)} is not a version`);
    const product = await runTool(tools.swVers, ['-productVersion'], { signal });
    const running = product.code === 0 ? macosVersion(product.stdout.trim()) : undefined;
    if (running === undefined) throw new VerificationError('macOS version', 'the running macOS version cannot be read (sw_vers)');
    if (compareVersions(minimum, running) > 0) {
      throw new VerificationError('macOS version', `it needs macOS ${info.LSMinimumSystemVersion} or later, and this Mac runs ${product.stdout.trim()}`);
    }
  }
}
