#!/usr/bin/env node
// Plans the beta builds that the Beta builds workflow makes from dev: each macOS app (native/<id>/macos-release.json)
// and npm package (release-packages.json) named in --only, or else whose inputs changed since its last tagged build,
// gets the next beta tag:
//   macos/<app-id>/v<x.y.z>-beta.<n>   built, signed, and notarized by release-macos.yml as a GitHub pre-release
//   <slug>-v<x.y.z>-beta.<n>           published by publish-tag.yml under the npm `beta` dist-tag
// x.y.z is the app's MARKETING_VERSION or the package.json version, and must not be released live yet. n counts
// up across all test builds of that version (including older -dev.<n> builds), so CFBundleVersion only grows.
//
//   node scripts/beta-builds.mjs [--only "macos/<app-id> npm/<slug> ..."]
//
// --only plans just the named targets, even if they did not change. Prints the plan as JSON and, in CI, writes it
// to the `plan` output. It creates no tags and starts nothing; beta-builds.yml does that.
import { execFileSync } from 'node:child_process';
import { appendFileSync, existsSync, readFileSync, readdirSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath } from 'node:url';
import { validateManifest } from './release-macos.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const versionPattern = /^\d+\.\d+\.\d+$/;

const escapeRegExp = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, String.raw`\$&`);
// The root manifest and lockfile pin the npm dependencies every npm build installs, so a change to either counts as a
// change to each npm package and to each app that bundles npm workspaces.
const npmDependencyFiles = ['package.json', 'package-lock.json'];
// git from a fixed location, never from PATH.
const gitPath = '/usr/bin/git';

// The one MARKETING_VERSION a project sets. Read from project.pbxproj because planning runs without Xcode;
// release-macos.mjs checks the built app against it.
export function marketingVersion(pbxproj) {
  const versions = new Set([...pbxproj.matchAll(/\bMARKETING_VERSION = "?([^";]+)"?;/g)].map((match) => match[1]));
  if (versions.size !== 1) throw new Error(`expected one MARKETING_VERSION, found ${versions.size === 0 ? 'none' : [...versions].join(', ')}`);
  const [version] = versions;
  if (!versionPattern.test(version)) throw new Error(`MARKETING_VERSION ${version} is not x.y.z`);
  return version;
}

// The next test build number of `<prefix><version>`: one more than any existing -beta.<n> or -dev.<n> tag of it.
export function nextBuildNumber(tags, prefix, version) {
  const base = escapeRegExp(prefix + version);
  const pattern = new RegExp(String.raw`^${base}-(?:beta|dev)\.([1-9]\d*)$`);
  return Math.max(0, ...tags.map((tag) => Number(pattern.exec(tag)?.[1] ?? 0))) + 1;
}

// Decides one target. `changed` is null when the target has never been built.
export function planTarget({ prefix, version, tags, changed, forced }) {
  if (!forced && changed === false) return { skip: 'unchanged since its last build' };
  if (tags.includes(`${prefix}${version}`)) return { skip: `${version} is already released; bump the version to build a beta` };
  return { tag: `${prefix}${version}-beta.${nextBuildNumber(tags, prefix, version)}` };
}

function git(args) {
  return execFileSync(gitPath, args, { cwd: repoRoot, encoding: 'utf8' }).trim();
}

const listTags = (pattern) => git(['tag', '--list', pattern]).split('\n').filter(Boolean);

// Whether `paths` changed between the newest of the target's tags that HEAD contains and HEAD; null if HEAD
// contains none of them.
function changedSinceLastBuild(tagPattern, paths) {
  const last = git(['for-each-ref', '--merged=HEAD', '--sort=-creatordate', '--count=1', '--format=%(refname)', `refs/tags/${tagPattern}`]);
  if (!last) return null;
  try {
    execFileSync(gitPath, ['diff', '--quiet', `${last}^{commit}`, 'HEAD', '--', ...paths], { cwd: repoRoot, stdio: 'ignore' });
    return false;
  } catch (error) {
    if (error.status === 1) return true;
    throw error;
  }
}

// npm workspace name -> repository-relative directory.
function workspaceDirs() {
  const { workspaces } = JSON.parse(readFileSync(path.join(repoRoot, 'package.json'), 'utf8'));
  const dirs = new Map();
  for (const pattern of workspaces) {
    const parent = pattern.replace(/\/\*$/, '');
    for (const entry of readdirSync(path.join(repoRoot, parent), { withFileTypes: true })) {
      const manifest = path.join(repoRoot, parent, entry.name, 'package.json');
      if (entry.isDirectory() && existsSync(manifest)) dirs.set(JSON.parse(readFileSync(manifest, 'utf8')).name, `${parent}/${entry.name}`);
    }
  }
  return dirs;
}

function macosTargets() {
  const dirs = workspaceDirs();
  return readdirSync(path.join(repoRoot, 'native'))
    .filter((id) => existsSync(path.join(repoRoot, 'native', id, 'macos-release.json')))
    .map((id) => {
      const manifest = JSON.parse(readFileSync(path.join(repoRoot, 'native', id, 'macos-release.json'), 'utf8'));
      const problems = validateManifest(manifest, id);
      const name = `macos/${id}`;
      if (problems.length > 0) return { name, error: problems.join('; ') };
      const workspaces = (manifest.workspaces ?? []).map((workspace) => dirs.get(workspace));
      if (workspaces.includes(undefined)) return { name, error: 'a listed npm workspace does not exist' };
      try {
        const version = marketingVersion(readFileSync(path.join(repoRoot, 'native', id, manifest.project, 'project.pbxproj'), 'utf8'));
        const paths = [`native/${id}`, ...workspaces, ...(workspaces.length > 0 ? npmDependencyFiles : [])];
        return { name, kind: 'macos', prefix: `macos/${id}/v`, version, paths };
      } catch (error) {
        return { name, error: error.message };
      }
    });
}

function npmTargets() {
  const entries = JSON.parse(readFileSync(path.join(repoRoot, 'release-packages.json'), 'utf8'));
  return entries.map(({ slug, path: packagePath, inputs }) => {
    const { version, private: isPrivate } = JSON.parse(readFileSync(path.join(repoRoot, packagePath, 'package.json'), 'utf8'));
    const name = `npm/${slug}`;
    if (isPrivate !== false) return { name, error: 'package is not public' };
    if (!versionPattern.test(version)) return { name, error: `package.json version ${version} is not x.y.z` };
    const target = { name, kind: 'npm', prefix: `${slug}-v`, version, paths: [...(inputs ?? [packagePath]), ...npmDependencyFiles] };
    // npm makes the first version of a package `latest` whatever its dist-tag, so a package's first release is live.
    const liveTag = new RegExp(String.raw`^${escapeRegExp(slug)}-v\d+\.\d+\.\d+$`);
    const released = listTags(`${slug}-v*`).some((tag) => liveTag.test(tag));
    return released ? target : { ...target, skip: 'never released; publish its first version live' };
  });
}

function main() {
  const onlyIndex = process.argv.indexOf('--only');
  const only = onlyIndex === -1 ? [] : (process.argv[onlyIndex + 1] ?? '').split(/\s+/).filter(Boolean);
  const targets = [...macosTargets(), ...npmTargets()];
  const unknown = only.filter((name) => !targets.some((target) => target.name === name));
  if (unknown.length > 0) throw new Error(`Unknown target ${unknown.join(', ')}; expected one of ${targets.map((target) => target.name).join(', ')}`);

  const builds = [];
  const skipped = [];
  for (const target of targets) {
    if (only.length > 0 && !only.includes(target.name)) continue;
    if (target.error || target.skip) {
      skipped.push({ name: target.name, reason: target.error ?? target.skip });
      continue;
    }
    const tags = listTags(`${target.prefix}*`);
    const changed = changedSinceLastBuild(`${target.prefix}*`, target.paths);
    const result = planTarget({ ...target, tags, changed, forced: only.includes(target.name) });
    if (result.skip) skipped.push({ name: target.name, reason: result.skip });
    else builds.push({ name: target.name, kind: target.kind, tag: result.tag });
  }

  const plan = { builds, skipped };
  console.log(JSON.stringify(plan, null, 2));
  if (process.env.GITHUB_OUTPUT) appendFileSync(process.env.GITHUB_OUTPUT, `plan=${JSON.stringify(plan)}\n`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  try {
    main();
  } catch (error) {
    console.error(`beta-builds: ${error.message}`);
    process.exit(1);
  }
}
