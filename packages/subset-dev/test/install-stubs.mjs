// Stand-ins for the macOS tools `subset install` asks (hdiutil, ditto, codesign, spctl, sw_vers), so its tests run on
// Linux. A stand-in disk image is JSON: { volumes: [{ "<path in the volume>": "<file contents>" }] }. A stand-in app's
// signature is the file Contents/_CodeSignature/stub.json inside the bundle ({ valid, team, notarized }; no file means
// unsigned), so codesign and spctl judge the copy they are given, as the real tools do. The stand-ins check that they
// get exactly the arguments subset install passes to the real tools, and log each call as a JSON line to $STUB_LOG.
// For the interruption and concurrency tests: STUB_SIGNAL_AT=<tool step> makes that step send STUB_SIGNAL (default
// SIGTERM) to the process that ran it, and sw_vers waits until STUB_BARRIER_COUNT processes have reached it when
// STUB_BARRIER_DIR is set.
import { chmodSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { stubPlutil } from './helpers.mjs';

const COMMON = String.raw`
const fs = require('node:fs');
const path = require('node:path');
const tool = process.argv[2];
const args = process.argv.slice(3);
const same = (expected) => args.length === expected.length && expected.every((value, index) => value === undefined || value === args[index]);
const usage = () => { console.error('stub ' + tool + ': unexpected arguments ' + JSON.stringify(args)); process.exit(64); };
const log = (step) => { if (process.env.STUB_LOG) fs.appendFileSync(process.env.STUB_LOG, JSON.stringify({ step, args }) + '\n'); };
const hook = (step) => { if (process.env.STUB_SIGNAL_AT === step) process.kill(process.ppid, process.env.STUB_SIGNAL || 'SIGTERM'); };
const signature = (bundle) => { try { return JSON.parse(fs.readFileSync(path.join(bundle, 'Contents', '_CodeSignature', 'stub.json'), 'utf8')); } catch { return undefined; } };
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
if (tool === 'hdiutil' && args[0] === 'attach') {
  if (!same(['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountrandom', undefined, undefined])) usage();
  log('hdiutil-attach');
  let image;
  try { image = JSON.parse(fs.readFileSync(args[6], 'utf8')); } catch { console.error('hdiutil: attach failed - image not recognized'); process.exit(1); }
  for (const files of image.volumes) {
    const volume = fs.mkdtempSync(path.join(args[5], 'dmg.'));
    for (const [name, text] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(volume, name)), { recursive: true });
      fs.writeFileSync(path.join(volume, name), text);
    }
  }
  hook('hdiutil-attach');
} else if (tool === 'hdiutil' && args[0] === 'detach') {
  if (!same(['detach', undefined, '-quiet']) && !same(['detach', undefined, '-force', '-quiet'])) usage();
  log('hdiutil-detach');
  fs.rmSync(args[1], { recursive: true, force: true });
} else if (tool === 'ditto') {
  if (!same([undefined, undefined]) || !fs.statSync(args[1]).isDirectory()) usage();
  log('ditto');
  fs.cpSync(args[0], args[1], { recursive: true, verbatimSymlinks: true });
  hook('ditto');
} else if (tool === 'codesign' && args[0] === '--verify') {
  if (!same(['--verify', '--deep', '--strict', undefined])) usage();
  log('codesign-verify');
  hook('codesign-verify');
  const found = signature(args[3]);
  if (!found) { console.error(args[3] + ': code object is not signed at all'); process.exit(1); }
  if (found.valid === false) { console.error(args[3] + ': a sealed resource is missing or invalid'); process.exit(1); }
} else if (tool === 'codesign') {
  if (!same(['-d', '--verbose=2', undefined])) usage();
  log('codesign-display');
  hook('codesign-display');
  const found = signature(args[2]);
  if (!found) { console.error(args[2] + ': code object is not signed at all'); process.exit(1); }
  console.error('Executable=' + args[2] + '/Contents/MacOS/app\n' + (found.team ? 'Authority=Developer ID Application: Example (' + found.team + ')\n' : 'Signature=adhoc\n') + 'TeamIdentifier=' + (found.team || 'not set'));
} else if (tool === 'spctl') {
  if (!same(['--assess', '--type', 'execute', '-vv', undefined])) usage();
  log('spctl');
  hook('spctl');
  const found = signature(args[4]);
  if (found && found.team && found.notarized) console.error(args[4] + ': accepted\nsource=Notarized Developer ID\norigin=Developer ID Application: Example (' + found.team + ')');
  else { console.error(args[4] + ': rejected\nsource=' + (found && found.team ? 'Unnotarized Developer ID' : 'no usable signature')); process.exit(3); }
} else if (tool === 'sw_vers') {
  if (!same(['-productVersion'])) usage();
  log('sw_vers');
  hook('sw_vers');
  const barrier = process.env.STUB_BARRIER_DIR;
  if (barrier) {
    fs.writeFileSync(path.join(barrier, String(process.pid)), '');
    const until = Date.now() + 20000;
    while (fs.readdirSync(barrier).length < Number(process.env.STUB_BARRIER_COUNT) && Date.now() < until) sleep(20);
  }
  console.log(process.env.STUB_MACOS_VERSION || '15.1');
} else usage();
`;

/** Why the stand-in tests are skipped (Windows cannot run shebang scripts), or false. */
export const stubToolsSkip = process.platform === 'win32' && 'the tool stand-ins are shebang scripts, which Windows cannot run';

/** Writes the stand-in tools into `dir`; returns the `tools` object subset install takes. */
export function stubTools(dir) {
  const common = path.join(dir, 'stub-tool.cjs');
  writeFileSync(common, COMMON);
  const tool = (name, role) => {
    const file = path.join(dir, name);
    writeFileSync(file, `#!/usr/bin/env node\nprocess.argv.splice(2, 0, ${JSON.stringify(role)});\nrequire(${JSON.stringify(common)});\n`);
    chmodSync(file, 0o755);
    return file;
  };
  return {
    hdiutil: tool('hdiutil', 'hdiutil'),
    ditto: tool('ditto', 'ditto'),
    codesign: tool('codesign', 'codesign'),
    spctl: tool('spctl', 'spctl'),
    swVers: tool('sw_vers', 'sw_vers'),
    plutil: stubPlutil(dir)
  };
}

const plist = (keys) =>
  `<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
${Object.entries(keys)
  .filter(([, value]) => value !== undefined)
  .map(([key, value]) => `\t<key>${key}</key>\n\t<string>${value}</string>`)
  .join('\n')}
</dict>
</plist>
`;

export const SUBSET_SIGNATURE = Object.freeze({ valid: true, team: 'SAZVPX4CAA', notarized: true });

/**
 * The files of a stand-in app bundle named `name` (Breaks.app): its Info.plist and, unless `signature` is null, its
 * stand-in signature.
 */
export function appFiles(name, { bundleId = 'dev.subset.breaks', version = '0.1.0', build = '1', minimumSystem = '14.0', signature = SUBSET_SIGNATURE } = {}) {
  return {
    [`${name}/Contents/Info.plist`]: plist({ CFBundleIdentifier: bundleId, CFBundleShortVersionString: version, CFBundleVersion: build, LSMinimumSystemVersion: minimumSystem }),
    [`${name}/Contents/MacOS/app`]: 'binary',
    ...(signature ? { [`${name}/Contents/_CodeSignature/stub.json`]: JSON.stringify(signature) } : {})
  };
}

/** A stand-in disk image (bytes) with the given volumes, each a { path: contents } map. */
export const makeImage = (...volumes) => Buffer.from(JSON.stringify({ volumes }));
