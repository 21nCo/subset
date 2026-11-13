// Stand-ins for the macOS tools `subset install` asks (hdiutil, ditto, find, codesign, spctl, sw_vers), so its tests
// run on Linux. find runs the real find (with the real chflags and chmod) on macOS and does nothing on Linux. A stand-in disk image is JSON: { volumes: [{ "<path in the volume>": "<file contents>" }], modes?: { "<path in
// each volume>": <mode> } }. The stand-in hdiutil attaches an image as one device (/dev/disk<n>, a slice per volume),
// recorded in the folder `attached` beside the tools, which `hdiutil info` lists and `hdiutil detach <device>`
// removes; attachedImages() reads it. A stand-in app's
// signature is the file Contents/_CodeSignature/stub.json inside the bundle ({ valid, team, notarized }; no file means
// unsigned), so codesign and spctl judge the copy they are given, as the real tools do. The stand-ins check that they
// get exactly the arguments subset install passes to the real tools, and log each call as a JSON line to $STUB_LOG.
// For the interruption and concurrency tests: STUB_SIGNAL_AT=<tool step> makes that step send STUB_SIGNAL (default
// SIGTERM) to the process that ran it, or with STUB_SIGNAL_GROUP=1 to that process's group (as Ctrl-C at a terminal
// does; the process must lead its group). With STUB_LINGER_MS the step signals before doing its work, then ignores
// SIGTERM and does its work only after that many milliseconds, as a tool slow to stop would. sw_vers waits until
// STUB_BARRIER_COUNT processes have reached it when STUB_BARRIER_DIR is set.
import { chmodSync, existsSync, readdirSync, readFileSync, writeFileSync } from 'node:fs';
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
const sleep = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
const linger = Number(process.env.STUB_LINGER_MS || 0);
const hook = (step) => {
  if (process.env.STUB_SIGNAL_AT !== step) return;
  process.kill(process.env.STUB_SIGNAL_GROUP ? -process.ppid : process.ppid, process.env.STUB_SIGNAL || 'SIGTERM');
  if (linger) {
    process.on('SIGTERM', () => {});
    sleep(linger);
  }
};
// Steps that change files signal before their work when lingering, so the work happens after the signal.
const before = (step) => { if (linger) hook(step); };
const after = (step) => { if (!linger) hook(step); };
const signature = (bundle) => { try { return JSON.parse(fs.readFileSync(path.join(bundle, 'Contents', '_CodeSignature', 'stub.json'), 'utf8')); } catch { return undefined; } };
const registry = path.join(path.dirname(process.argv[1]), 'attached');
const writable = (dir) => { for (const entry of fs.readdirSync(dir, { withFileTypes: true })) if (entry.isDirectory()) { fs.chmodSync(path.join(dir, entry.name), 0o755); writable(path.join(dir, entry.name)); } };
if (tool === 'hdiutil' && args[0] === 'attach') {
  if (!same(['attach', '-readonly', '-nobrowse', '-noautoopen', '-mountrandom', undefined, undefined])) usage();
  log('hdiutil-attach');
  let image;
  try { image = JSON.parse(fs.readFileSync(args[6], 'utf8')); } catch { console.error('hdiutil: attach failed - image not recognized'); process.exit(1); }
  before('hdiutil-attach');
  const device = '/dev/disk' + process.pid + String(Math.floor(Math.random() * 1000)).padStart(3, '0');
  const mounts = [];
  for (const files of image.volumes) {
    const volume = fs.mkdtempSync(path.join(args[5], 'dmg.'));
    mounts.push(volume);
    for (const [name, text] of Object.entries(files)) {
      fs.mkdirSync(path.dirname(path.join(volume, name)), { recursive: true });
      fs.writeFileSync(path.join(volume, name), text);
    }
    for (const [name, mode] of Object.entries(image.modes ?? {}).sort(([a], [b]) => b.length - a.length)) fs.chmodSync(path.join(volume, name), mode);
  }
  fs.mkdirSync(registry, { recursive: true });
  fs.writeFileSync(path.join(registry, path.basename(device)), JSON.stringify({ image: args[6], device, mounts }));
  console.log(device + '\tGUID_partition_scheme\t\n' + mounts.map((mount, index) => device + 's' + (index + 1) + '\tApple_HFS\t' + mount).join('\n'));
  after('hdiutil-attach');
} else if (tool === 'hdiutil' && args[0] === 'info') {
  if (!same(['info'])) usage();
  log('hdiutil-info');
  let out = 'framework       : stub\n';
  for (const name of fs.existsSync(registry) ? fs.readdirSync(registry) : []) {
    const entry = JSON.parse(fs.readFileSync(path.join(registry, name), 'utf8'));
    out += '================================================\nimage-path      : ' + entry.image + '\n' + entry.device + '\tGUID_partition_scheme\t\n' + entry.mounts.map((mount, index) => entry.device + 's' + (index + 1) + '\tApple_HFS\t' + mount + '\n').join('');
  }
  process.stdout.write(out);
} else if (tool === 'hdiutil' && args[0] === 'detach') {
  if (!same(['detach', undefined, '-quiet']) && !same(['detach', undefined, '-force', '-quiet'])) usage();
  log('hdiutil-detach');
  before('hdiutil-detach');
  const file = path.join(registry, path.basename(args[1]));
  if (!/^\/dev\/disk\d+$/.test(args[1]) || !fs.existsSync(file)) { console.error('hdiutil: detach failed - No such file or directory'); process.exit(1); }
  for (const mount of JSON.parse(fs.readFileSync(file, 'utf8')).mounts) { writable(mount); fs.rmSync(mount, { recursive: true, force: true }); }
  fs.rmSync(file);
  after('hdiutil-detach');
} else if (tool === 'ditto') {
  if (!same([undefined, undefined]) || !fs.statSync(args[1]).isDirectory()) usage();
  log('ditto');
  before('ditto');
  fs.cpSync(args[0], args[1], { recursive: true, verbatimSymlinks: true });
  // Like ditto, the copy's folders get the source's permissions (deepest first, so a read-only folder is still filled).
  const modes = (from, to) => { for (const entry of fs.readdirSync(from, { withFileTypes: true })) if (entry.isDirectory()) { modes(path.join(from, entry.name), path.join(to, entry.name)); fs.chmodSync(path.join(to, entry.name), fs.statSync(path.join(from, entry.name)).mode & 0o7777); } };
  modes(args[0], args[1]);
  after('ditto');
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
} else if (tool === 'find') {
  // find -P <copy> -exec <chflags or chmod> -h <change> {} +: run by the real find on macOS (changing the real flags and
  // ACLs of the copy), and nothing to clear on Linux.
  if (!same(['-P', undefined, '-exec', undefined, '-h', undefined, '{}', '+']) || !['nouchg,nouappnd', '-N'].includes(args[5])) usage();
  const step = 'find-' + path.basename(args[3]);
  log(step);
  hook(step);
  if (process.platform === 'darwin') {
    const run = require('node:child_process').spawnSync('/usr/bin/find', args, { stdio: 'inherit' });
    process.exit(run.status ?? 1);
  }
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
    plutil: stubPlutil(dir),
    find: tool('find', 'find'),
    chflags: '/usr/bin/chflags',
    chmod: '/bin/chmod'
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

/** A stand-in disk image with one volume whose paths in `modes` ({ path: mode }) get that mode. */
export const makeImageWithModes = (files, modes) => Buffer.from(JSON.stringify({ volumes: [files], modes }));

/** The image files the stand-in hdiutil in `toolsDir` still has attached. */
export function attachedImages(toolsDir) {
  const registry = path.join(toolsDir, 'attached');
  return existsSync(registry) ? readdirSync(registry).map((name) => JSON.parse(readFileSync(path.join(registry, name), 'utf8')).image) : [];
}
