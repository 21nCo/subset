// Test helpers: app bundles in a folder standing in for /Applications, install receipts, and a plutil stand-in for
// Linux, where there is no plutil.
import { chmodSync, mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import path from 'node:path';

const escape = (text) => text.replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;');

/** Writes `<dir>/<appName>.app` with an XML Info.plist holding the given string keys (undefined ones left out). */
export function makeApp(dir, appName, { bundleId, version, build, extra = '' }) {
  const contents = path.join(dir, `${appName}.app`, 'Contents');
  mkdirSync(contents, { recursive: true });
  const entries = Object.entries({ CFBundleIdentifier: bundleId, CFBundleShortVersionString: version, CFBundleVersion: build })
    .filter(([, value]) => value !== undefined)
    .map(([key, value]) => `\t<key>${key}</key>\n\t<string>${escape(value)}</string>\n`)
    .join('');
  writeFileSync(
    path.join(contents, 'Info.plist'),
    `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
${entries}${extra}</dict>
</plist>
`
  );
  return path.join(dir, `${appName}.app`);
}

/** Links `<dir>/<appName>.app` to an app bundle elsewhere. */
export function linkApp(dir, appName, target) {
  symlinkSync(target, path.join(dir, `${appName}.app`));
}

/** Writes the install receipt of `bundleId` in `home`. */
export function writeReceipt(home, bundleId, receipt) {
  const folder = path.join(home, 'Library', 'Application Support', 'Subset', 'receipts');
  mkdirSync(folder, { recursive: true });
  writeFileSync(path.join(folder, `${bundleId}.json`), typeof receipt === 'string' ? receipt : JSON.stringify(receipt));
}

/**
 * Writes an executable plutil stand-in into `dir` and returns its path. Like `plutil -convert json -o - <file>`, it
 * prints the <key>/<string> pairs of an XML plist's top-level dict as JSON, and fails on anything else or other
 * arguments.
 */
export function stubPlutil(dir) {
  const file = path.join(dir, 'plutil');
  writeFileSync(
    file,
    `#!/usr/bin/env node
const { readFileSync } = require('node:fs');
const args = process.argv.slice(2);
if (args.length !== 5 || args.slice(0, 4).join(' ') !== '-convert json -o -') { console.error('stub plutil: unexpected arguments'); process.exit(64); }
let text;
try { text = readFileSync(args[4], 'utf8'); } catch (error) { console.error(error.message); process.exit(1); }
const dict = /<plist[^>]*>\\s*<dict>([\\s\\S]*)<\\/dict>\\s*<\\/plist>/.exec(text);
if (!dict) { console.error(args[4] + ': Property List error: Unexpected character'); process.exit(1); }
const unescape = (s) => s.replace(/&lt;/g, '<').replace(/&gt;/g, '>').replace(/&amp;/g, '&');
const out = {};
for (const [, key, value] of dict[1].matchAll(/<key>([^<]*)<\\/key>\\s*<string>([^<]*)<\\/string>/g)) out[unescape(key)] = unescape(value);
process.stdout.write(JSON.stringify(out));
`
  );
  chmodSync(file, 0o755);
  return file;
}
