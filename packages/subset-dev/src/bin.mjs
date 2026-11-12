import { readFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';

/**
 * The JavaScript file of a resolved tool's bin, found through the PATH `npm exec` reported: the first
 * <folder>/node_modules/.bin entry whose <folder>/node_modules/<package> is that package (at the requested version when
 * it is exact) and declares the bin. Returns undefined when none does.
 */
export function findToolBin(pathValue, tool, { platform = process.platform, readFile = readFileSync } = {}) {
  const paths = platform === 'win32' ? path.win32 : path.posix;
  const exact = /^\d/.test(tool.version);
  for (const folder of pathValue.split(paths.delimiter)) {
    if (paths.basename(folder) !== '.bin' || paths.basename(paths.dirname(folder)) !== 'node_modules') continue;
    const packageDir = paths.join(paths.dirname(folder), ...tool.package.split('/'));
    let manifest;
    try {
      manifest = JSON.parse(readFile(paths.join(packageDir, 'package.json'), 'utf8'));
    } catch {
      continue;
    }
    if (manifest.name !== tool.package || (exact && manifest.version !== tool.version)) continue;
    const bin = typeof manifest.bin === 'string' ? { [tool.bin]: manifest.bin } : manifest.bin;
    const file = bin?.[tool.bin];
    if (typeof file !== 'string') continue;
    const resolved = paths.resolve(packageDir, file);
    // A bin must stay inside its package.
    if (paths.relative(packageDir, resolved).startsWith('..')) continue;
    return resolved;
  }
  return undefined;
}
