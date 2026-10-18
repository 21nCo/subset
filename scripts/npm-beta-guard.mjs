#!/usr/bin/env node
// Decides whether publish-tag.yml may publish a beta: node scripts/npm-beta-guard.mjs <name> <x.y.z> <x.y.z-beta.n>
// Fails when the registry can't be read, the package has no live release (npm would make the beta `latest`), or
// x.y.z is already released. Writes publish=false, without failing, when the `beta` dist-tag already points at a
// newer beta, so an older run finishing late never moves the channel backward.
import { appendFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';

const betaPattern = /^(\d+)\.(\d+)\.(\d+)-beta\.(\d+)$/;

// Whether beta version `a` is newer than `b`; a `b` that is not an x.y.z-beta.n version counts as older.
export function isNewerBeta(a, b) {
  const left = betaPattern.exec(a)?.slice(1).map(Number);
  const right = betaPattern.exec(b ?? '')?.slice(1).map(Number);
  if (!left) throw new Error(`${a} is not an x.y.z-beta.n version`);
  if (!right) return true;
  const index = left.findIndex((part, position) => part !== right[position]);
  return index !== -1 && left[index] > right[index];
}

// The guard's verdict for a packument (the registry's package document) or null for a missing package.
export function betaVerdict(packument, version, betaVersion) {
  if (!packument?.['dist-tags']?.latest) return { error: 'has no live release yet; publish its first version with a live tag' };
  if (packument.versions?.[version]) return { error: `${version} is already released; bump the version in package.json for a new beta` };
  const current = packument['dist-tags'].beta;
  if (current !== undefined && current !== betaVersion && !isNewerBeta(betaVersion, current)) {
    return { publish: false, reason: `the beta dist-tag already points at ${current}, which is newer than ${betaVersion}` };
  }
  return { publish: true };
}

const namePattern = /^@[a-z0-9][a-z0-9.-]*\/[a-z0-9][a-z0-9.-]*$/;
const versionPattern = /^\d+\.\d+\.\d+$/;

async function main() {
  const [name, version, betaVersion] = process.argv.slice(2);
  if (!namePattern.test(name ?? '') || !versionPattern.test(version ?? '') || !betaPattern.test(betaVersion ?? '')) {
    throw new Error('Usage: npm-beta-guard.mjs <@scope/name> <x.y.z> <x.y.z-beta.n>');
  }
  const response = await fetch(`https://registry.npmjs.org/${name.replace('/', '%2f')}`, { headers: { Accept: 'application/json' } });
  if (!response.ok && response.status !== 404) throw new Error(`The npm registry answered ${response.status} for ${name}`);
  const verdict = betaVerdict(response.status === 404 ? null : await response.json(), version, betaVersion);
  if (verdict.error) throw new Error(`${name} ${verdict.error}`);
  console.log(verdict.publish ? `Publishing ${name}@${betaVersion} under beta.` : `Not publishing ${name}@${betaVersion}: ${verdict.reason}.`);
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `publish=${verdict.publish}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    await main();
  } catch (error) {
    console.error(`npm-beta-guard: ${error.message}`);
    process.exit(1);
  }
}
