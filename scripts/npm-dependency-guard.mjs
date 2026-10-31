#!/usr/bin/env node
// Refuses to publish a packed package while npm lacks a release of a @subset.dev package it depends on:
//   node scripts/npm-dependency-guard.mjs <package.tgz>
// @subset.dev/link-capture depends on @subset.dev/links as ^<version> (SET-186), so a link-capture release published
// before that links version would not install. Releases of the dependency go first; when both tags are pushed at once,
// rerun the dependent's publish job once the dependency is on npm. Registry errors fail the run.
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const caretPattern = /^\^(\d+)\.(\d+)\.(\d+)$/;
const releasePattern = /^(\d+)\.(\d+)\.(\d+)$/;

// Whether release `version` (x.y.z, no prerelease) satisfies `^a.b.c`, as npm reads it: the left-most non-zero part is
// fixed (^1.2.3 is <2.0.0, ^0.1.0 is <0.2.0 and ^0.0.3 is only 0.0.3).
export function satisfiesCaret(version, range) {
  const wanted = caretPattern.exec(range)?.slice(1).map(Number);
  if (!wanted) throw new Error(`${range} is not a ^x.y.z range`);
  const found = releasePattern.exec(version)?.slice(1).map(Number);
  if (!found) return false;
  const fixed = wanted[0] > 0 ? 1 : wanted[1] > 0 ? 2 : 3;
  const index = found.findIndex((part, position) => part !== wanted[position]);
  // The fixed parts match and, at the first part that differs, the version is the higher one.
  return index === -1 || (index >= fixed && found[index] > wanted[index]);
}

// The runtime dependencies on @subset.dev packages that `packuments` (name to registry document, or null when the
// registry has no such package) cannot install, as messages.
export function missingDependencies(manifest, packuments) {
  const missing = [];
  for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const [name, range] of Object.entries(manifest[field] ?? {})) {
      if (!name.startsWith('@subset.dev/')) continue;
      const versions = Object.keys(packuments.get(name)?.versions ?? {});
      if (!versions.some((version) => satisfiesCaret(version, range))) missing.push(`${name}@${range} is not on npm; publish it first`);
    }
  }
  return missing;
}

async function main() {
  const [tarball] = process.argv.slice(2);
  if (!tarball?.endsWith('.tgz')) throw new Error('Usage: npm-dependency-guard.mjs <package.tgz>');
  const manifest = JSON.parse(execFileSync('tar', ['-xzOf', tarball, 'package/package.json'], { encoding: 'utf8' }));
  const packuments = new Map();
  for (const field of ['dependencies', 'optionalDependencies', 'peerDependencies']) {
    for (const name of Object.keys(manifest[field] ?? {})) {
      if (!name.startsWith('@subset.dev/') || packuments.has(name)) continue;
      const response = await fetch(`https://registry.npmjs.org/${name.replace('/', '%2f')}`, {
        headers: { Accept: 'application/json' },
        signal: AbortSignal.timeout(30_000),
      });
      if (!response.ok && response.status !== 404) throw new Error(`The npm registry answered ${response.status} for ${name}`);
      packuments.set(name, response.status === 404 ? null : await response.json());
    }
  }
  const missing = missingDependencies(manifest, packuments);
  if (missing.length) throw new Error(`${manifest.name}@${manifest.version} would not install: ${missing.join('; ')}`);
  console.log(packuments.size ? `npm has every @subset.dev package ${manifest.name} depends on.` : `${manifest.name} depends on no other @subset.dev package.`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    console.error(`npm-dependency-guard: ${error.message}`);
    process.exit(1);
  }
}
