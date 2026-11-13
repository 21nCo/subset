#!/usr/bin/env node
// Builds the Subset catalog feed, a subset.catalog@1 document (packages/catalog/feed/catalog.schema.json) saying what
// Subset ships and where to get it. `subset` and the Subset manager app read it.
//   node scripts/catalog-feed.mjs [--out <file>] [--recorded <file>]
//
// Sources:
//   apps   every catalog listing that proposes macOS and has native/<id>/macos-release.json, with a live channel or a
//          beta: name and summary from packages/catalog (build it first), appName, bundleId and helpers from
//          macos-release.json.
//   live   the listing's available macOS surface in packages/catalog.
//   beta   the newest published (non-draft) GitHub pre-release tagged macos/<id>/v<x.y.z>-beta.<n> that has the
//          app's DMG and a SHA256SUMS line for it, from the GitHub REST releases list (with GITHUB_TOKEN when set).
//          -dev.<n> builds are never listed.
//   tools  release-packages.json entries whose package has a bin (other than the subset launcher), with the
//          latest and beta dist-tags from `npm view <package>@latest dist-tags --json` (or `<package>@beta` when the
//          package has no latest). A package the registry does not have, or with neither tag, is left out, and so is a
//          tag whose version the schema does not allow (a latest that is a pre-release). Other npm errors stop the build.
//
// The document is checked against the schema, the 256 KiB limit and the uniqueness rules before it is written, and
// written to --out (atomically) or stdout. --recorded <file> answers every GitHub and npm request from a file of
// recorded responses ({ github: { <url>: <body> }, npm: { <package>: <dist-tags> | null } }) and fails on any other
// request, so the feed can be built offline. Nothing is uploaded or published.
import { Ajv2020 } from 'ajv/dist/2020.js';
import { execFile } from 'node:child_process';
import { readFileSync, renameSync, rmSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import process from 'node:process';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { parseReleaseTag, readMacosReleaseManifests, releaseFileBase, releaseVersion } from './release-macos.mjs';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const feedDirectory = path.join(repoRoot, 'packages/catalog/feed');

export const CATALOG_SCHEMA = 'subset.catalog@1';
export const RECEIPT_SCHEMA = 'subset.receipt@1';
export const MAX_FEED_BYTES = 256 * 1024;
// Every download in the feed must come from a 21nCo/subset GitHub release; readers refuse anything else.
export const DOWNLOAD_PREFIX = 'https://github.com/21nCo/subset/releases/download/';
const RELEASE_PAGE_PREFIX = 'https://github.com/21nCo/subset/releases/tag/';
const RELEASES_API = 'https://api.github.com/repos/21nCo/subset/releases';
const RELEASES_PER_PAGE = 100;
const MAX_RELEASE_PAGES = 50;
const MAX_SUMS_BYTES = 64 * 1024;
const REQUEST_TIMEOUT_MS = 30_000;
// The launcher runs the tools; it is not one of them.
const LAUNCHER_PACKAGE = 'subset.dev';

// --- Validation -----------------------------------------------------------------------------------------------------

const ajv = new Ajv2020({ allErrors: true, strict: true });
const catalogSchema = JSON.parse(readFileSync(path.join(feedDirectory, 'catalog.schema.json'), 'utf8'));
const schemas = {
  catalog: ajv.compile(catalogSchema),
  receipt: ajv.compile(JSON.parse(readFileSync(path.join(feedDirectory, 'receipt.schema.json'), 'utf8')))
};

function schemaProblems(validate, document) {
  if (validate(document)) return [];
  return validate.errors.map((error) => `${error.instancePath || '/'} ${error.message}${error.params?.additionalProperty ? ` (${error.params.additionalProperty})` : ''}`);
}

function parseDocument(text) {
  try {
    return { document: JSON.parse(text) };
  } catch (error) {
    return { problems: [`not JSON: ${error.message}`] };
  }
}

// Values the schema cannot keep unique: two entries for one app, bundle ID, command or tool would be ambiguous.
function duplicateProblems(feed) {
  const problems = [];
  const unique = (label, values) => {
    const seen = new Set();
    for (const value of values) {
      if (seen.has(value)) problems.push(`${label} ${JSON.stringify(value)} appears more than once`);
      seen.add(value);
    }
  };
  unique('app id', feed.apps.map((app) => app.id));
  unique('bundleId', feed.apps.map((app) => app.bundleId));
  unique('helper command', feed.apps.flatMap((app) => app.helpers.map((helper) => helper.command)));
  unique('tool id', feed.tools.map((tool) => tool.id));
  return problems;
}

/** The reasons a subset.catalog@1 document (a string or bytes, as read) is refused, or [] when it is valid. */
export function catalogFeedProblems(text) {
  const bytes = typeof text === 'string' ? Buffer.byteLength(text) : text.byteLength;
  if (bytes > MAX_FEED_BYTES) return [`the feed is ${bytes} bytes, more than ${MAX_FEED_BYTES}`];
  const { document, problems } = parseDocument(Buffer.from(text).toString('utf8'));
  if (problems) return problems;
  const invalid = schemaProblems(schemas.catalog, document);
  return invalid.length > 0 ? invalid : duplicateProblems(document);
}

/** The reasons a subset.receipt@1 document is refused, or [] when it is valid. */
export function receiptProblems(text) {
  const { document, problems } = parseDocument(Buffer.from(text).toString('utf8'));
  return problems ?? schemaProblems(schemas.receipt, document);
}

// --- Building the feed ----------------------------------------------------------------------------------------------

// Orders beta builds newest first: by x.y.z numerically, then by build number.
function newestFirst(a, b) {
  const key = (candidate) => [...candidate.version.split('.').map(Number), candidate.build];
  const [left, right] = [key(a), key(b)];
  const differs = left.findIndex((part, i) => part !== right[i]);
  return differs === -1 ? 0 : right[differs] - left[differs];
}

// SHA256SUMS lines are `<sha256>  <file>` (or ` *<file>` for binary mode); returns the hashes listed for `fileName`.
export function sumsFor(text, fileName) {
  return text
    .split(/\r?\n/)
    .map((line) => /^([0-9a-f]{64}) [ *](.+)$/.exec(line))
    .filter((match) => match && match[2] === fileName)
    .map((match) => match[1]);
}

// The beta builds of an app in a GitHub releases list that have a published DMG and a SHA256SUMS asset, newest first.
// Drafts, live releases, -dev.<n> builds and releases without the app's DMG or SHA256SUMS are left out.
export function betaCandidates(releases, appId, appName) {
  const candidates = [];
  for (const release of releases) {
    let tag;
    try {
      tag = parseReleaseTag(release.tag_name);
    } catch {
      continue;
    }
    if (tag.appId !== appId || tag.prerelease?.channel !== 'beta' || release.draft !== false || release.prerelease !== true) continue;
    // release-macos.mjs names the DMG, and its SHA256SUMS line, <App-Name>-<x.y.z>-beta.<n>.dmg (whitespace as hyphens).
    const dmgName = `${releaseFileBase(appName, releaseVersion(tag.version, tag.prerelease))}.dmg`;
    const uploaded = (release.assets ?? []).filter((asset) => asset.state === 'uploaded');
    const dmg = uploaded.find((asset) => asset.name === dmgName);
    const sums = uploaded.find((asset) => asset.name === 'SHA256SUMS');
    if (!dmg || !sums) continue;
    const expected = { url: `${DOWNLOAD_PREFIX}${release.tag_name}/${dmg.name}`, releaseUrl: `${RELEASE_PAGE_PREFIX}${release.tag_name}`, sums: `${DOWNLOAD_PREFIX}${release.tag_name}/SHA256SUMS` };
    if (dmg.browser_download_url !== expected.url || sums.browser_download_url !== expected.sums || release.html_url !== expected.releaseUrl) {
      throw new Error(`GitHub release ${release.tag_name} links its DMG, SHA256SUMS or page somewhere other than ${DOWNLOAD_PREFIX} and ${RELEASE_PAGE_PREFIX}`);
    }
    candidates.push({ tag: release.tag_name, version: tag.version, build: Number(tag.prerelease.build), dmg, dmgName, sumsUrl: sums.browser_download_url, releaseUrl: release.html_url });
  }
  return candidates.sort(newestFirst);
}

// The newest beta candidate whose SHA256SUMS lists its DMG, as a feed channel, or undefined.
async function betaChannel(candidates, fetchText) {
  for (const candidate of candidates) {
    const sums = await fetchText(candidate.sumsUrl);
    const hashes = new Set(sumsFor(sums, candidate.dmgName));
    if (hashes.size === 0) continue;
    if (hashes.size > 1) throw new Error(`${candidate.tag} SHA256SUMS lists ${candidate.dmgName} with different checksums`);
    const [sha256] = hashes;
    // GitHub records its own SHA-256 of each upload; it must agree with the release's SHA256SUMS.
    if (candidate.dmg.digest !== undefined && candidate.dmg.digest !== null && candidate.dmg.digest !== `sha256:${sha256}`) {
      throw new Error(`${candidate.tag}: GitHub's digest of ${candidate.dmg.name} (${candidate.dmg.digest}) disagrees with SHA256SUMS (${sha256})`);
    }
    return { version: candidate.version, build: candidate.build, url: candidate.dmg.browser_download_url, sha256, releaseUrl: candidate.releaseUrl };
  }
  return undefined;
}

function liveChannel(listing) {
  const surface = listing.availableSurfaces.find((entry) => entry.surface === 'macos');
  if (surface === undefined) return undefined;
  if (!surface.url.startsWith(DOWNLOAD_PREFIX)) throw new Error(`${listing.id}: the catalog's macOS download ${surface.url} is not under ${DOWNLOAD_PREFIX}`);
  if (!surface.sha256) throw new Error(`${listing.id}: the catalog's macOS surface has no sha256`);
  return { version: surface.version, url: surface.url, sha256: surface.sha256, releaseUrl: surface.releaseUrl };
}

// The dist-tags a feed lists, with the versions the schema allows each: latest is x.y.z, beta is x.y.z-beta.<n>.
const DIST_TAG_PATTERNS = Object.fromEntries(
  Object.entries(catalogSchema.$defs.tool.properties.distTags.properties).map(([name, { pattern }]) => [name, new RegExp(pattern)])
);

// The tool a release-packages.json entry names: its one `subset-<slug>` bin, or undefined when it has no bin.
export function toolFor(target, packageManifest) {
  const { bin } = packageManifest;
  if (bin === undefined || target.name === LAUNCHER_PACKAGE) return undefined;
  const bins = typeof bin === 'string' ? [packageManifest.name.replace(/^@[^/]+\//, '')] : Object.keys(bin);
  if (bins.length !== 1 || bins[0] !== `subset-${target.slug}`) {
    throw new Error(`${target.name} must have exactly one bin, subset-${target.slug}, to be listed as the ${target.slug} tool; it has ${bins.join(', ')}`);
  }
  return { id: target.slug, package: target.name, bin: bins[0] };
}

/**
 * Builds a subset.catalog@1 feed from the repository's metadata and the answers of GitHub and npm.
 *   capabilities     packages/catalog's listings
 *   manifests        { appId, manifest } for every native/<app-id>/macos-release.json
 *   releaseTargets   release-packages.json, each with its package.json as `manifest`
 *   github           { releases(): Promise<release[]>, text(url): Promise<string> }
 *   npm              { distTags(package): Promise<object | null> } (null when npm has no such package)
 */
export async function buildCatalogFeed({ capabilities, manifests, releaseTargets, github, npm, generatedAt = new Date() }) {
  const releases = await github.releases();
  const manifestById = new Map(manifests.map(({ appId, manifest }) => [appId, manifest]));
  const apps = [];
  for (const listing of capabilities) {
    if (!listing.proposedSurfaces.includes('macos')) continue;
    const manifest = manifestById.get(listing.id);
    const live = liveChannel(listing);
    if (manifest === undefined) {
      if (live !== undefined) throw new Error(`${listing.id} has an available macOS surface but no native/${listing.id}/macos-release.json`);
      continue;
    }
    const beta = await betaChannel(betaCandidates(releases, listing.id, manifest.app), github.text);
    if (live === undefined && beta === undefined) continue;
    apps.push({
      id: listing.id,
      name: listing.name,
      summary: listing.summary,
      appName: manifest.app,
      bundleId: manifest.bundleId,
      helpers: (manifest.helpers ?? []).map(({ command, path: helperPath, kind }) => ({ command, path: helperPath, kind })),
      channels: { ...(live && { live }), ...(beta && { beta }) }
    });
  }

  const tools = [];
  for (const target of releaseTargets) {
    const tool = toolFor(target, target.manifest);
    if (tool === undefined) continue;
    const published = await npm.distTags(tool.package);
    if (published === null) continue;
    const distTags = Object.fromEntries(
      Object.entries(DIST_TAG_PATTERNS)
        .filter(([name, pattern]) => typeof published[name] === 'string' && pattern.test(published[name]))
        .map(([name]) => [name, published[name]])
    );
    if (Object.keys(distTags).length === 0) continue;
    tools.push({ ...tool, distTags });
  }

  return { schema: CATALOG_SCHEMA, generatedAt: generatedAt.toISOString().replace(/\.\d{3}Z$/, 'Z'), apps, tools };
}

// --- GitHub and npm -------------------------------------------------------------------------------------------------

async function request(url, headers) {
  const response = await fetch(url, { headers, redirect: 'follow', signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS) });
  if (!response.ok) throw new Error(`GET ${url} returned ${response.status}`);
  return response;
}

export function liveGitHub(token = process.env.GITHUB_TOKEN) {
  const apiHeaders = {
    accept: 'application/vnd.github+json',
    'x-github-api-version': '2022-11-28',
    'user-agent': 'subset-catalog-feed',
    ...(token ? { authorization: `Bearer ${token}` } : {})
  };
  return {
    async releases() {
      const all = [];
      for (let page = 1; page <= MAX_RELEASE_PAGES; page += 1) {
        const batch = await (await request(`${RELEASES_API}?per_page=${RELEASES_PER_PAGE}&page=${page}`, apiHeaders)).json();
        if (!Array.isArray(batch)) throw new Error('The GitHub releases list is not an array');
        all.push(...batch);
        if (batch.length < RELEASES_PER_PAGE) return all;
      }
      throw new Error(`GitHub listed more than ${MAX_RELEASE_PAGES * RELEASES_PER_PAGE} releases`);
    },
    // Release downloads are public; the token goes only to the API, never to github.com or its download redirects.
    async text(url) {
      if (!url.startsWith(DOWNLOAD_PREFIX)) throw new Error(`Refusing to download ${url}`);
      const body = await (await request(url, { 'user-agent': 'subset-catalog-feed' })).arrayBuffer();
      if (body.byteLength > MAX_SUMS_BYTES) throw new Error(`${url} is larger than ${MAX_SUMS_BYTES} bytes`);
      return Buffer.from(body).toString('utf8');
    }
  };
}

// Runs npm and settles with its exit status and stdout; npm that cannot start, times out or prints too much rejects.
function runNpm(command, args) {
  return new Promise((resolve, reject) => {
    execFile(command, args, { timeout: REQUEST_TIMEOUT_MS * 2, maxBuffer: 1024 * 1024 }, (error, stdout) => {
      if (error && typeof error.code !== 'number') reject(new Error(`npm ${args.join(' ')} did not finish: ${error.message}`));
      else resolve({ status: error ? error.code : 0, stdout });
    });
  });
}

const isObject = (value) => typeof value === 'object' && value !== null && !Array.isArray(value);

// npm's E404 messages: the registry has no such package (or every version was unpublished), or the package has no
// version for the tag asked for. Any other E404 is not understood and stops the build.
const PACKAGE_MISSING = /^(?:404 )?Not Found - GET |^Unpublished on /;
const TAG_MISSING = /^No match found for version /;

// One `npm view <package>@<tag> dist-tags --json`. The tag is always named, so npm's configured `tag` is never used.
// Settles with { tags } for the package's dist-tags (npm 10 prints the object, npm 12 a one-element array of it),
// { packageMissing: true }, or { tagMissing: true } (npm prints nothing when the package has no latest, and answers
// E404 "No match found" for another missing tag). Another error or an answer it cannot read rejects.
async function viewDistTags(command, name, tag) {
  const args = ['view', `${name}@${tag}`, 'dist-tags', '--json'];
  const { status, stdout } = await runNpm(command, args);
  if (status === 0 && stdout.trim() === '') return { tagMissing: true };
  let answer;
  try {
    answer = JSON.parse(stdout);
  } catch {
    answer = undefined;
  }
  if (status === 0 && Array.isArray(answer) && answer.length === 1) [answer] = answer;
  if (status === 0 && isObject(answer) && answer.error === undefined) return { tags: answer };
  const error = isObject(answer) && isObject(answer.error) ? answer.error : undefined;
  if (status !== 0 && error?.code === 'E404' && typeof error.summary === 'string') {
    if (PACKAGE_MISSING.test(error.summary)) return { packageMissing: true };
    if (TAG_MISSING.test(error.summary)) return { tagMissing: true };
  }
  const reason = error ? `${error.code}: ${error.summary}` : 'no JSON dist-tags answer';
  throw new Error(`npm ${args.join(' ')} failed (exit ${status}): ${reason}`);
}

/**
 * The npm registry's dist-tags, through the npm command (`command`, npm by default): the package's dist-tags, null
 * when the registry has no such package, or {} when it has the package but neither a latest nor a beta. It asks for
 * <package>@latest and, when the package has no latest, <package>@beta; either answer holds all the package's
 * dist-tags. (`npm dist-tag ls` is not used: the registry answers 401, not 404, for a scoped package it does not have.)
 */
export function liveNpm({ command = 'npm' } = {}) {
  return {
    async distTags(name) {
      for (const tag of ['latest', 'beta']) {
        const answer = await viewDistTags(command, name, tag);
        if (answer.packageMissing) return null;
        if (answer.tags) return answer.tags;
      }
      return {};
    }
  };
}

// Answers from a recorded-responses file; any request it does not hold fails, so nothing reaches the network.
export function recordedSources(recorded) {
  const github = recorded.github ?? {};
  const npm = recorded.npm ?? {};
  const answer = (table, key, kind) => {
    if (!Object.hasOwn(table, key)) throw new Error(`No recorded ${kind} response for ${key}`);
    return table[key];
  };
  return {
    github: {
      async releases() {
        const all = [];
        for (let page = 1; page <= MAX_RELEASE_PAGES; page += 1) {
          const batch = answer(github, `${RELEASES_API}?per_page=${RELEASES_PER_PAGE}&page=${page}`, 'GitHub');
          all.push(...batch);
          if (batch.length < RELEASES_PER_PAGE) return all;
        }
        throw new Error(`GitHub listed more than ${MAX_RELEASE_PAGES * RELEASES_PER_PAGE} releases`);
      },
      text: async (url) => answer(github, url, 'GitHub')
    },
    npm: { distTags: async (name) => answer(npm, name, 'npm') }
  };
}

// --- Command line ---------------------------------------------------------------------------------------------------

export function parseArgs(argv) {
  const options = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = { '--out': 'out', '--recorded': 'recorded' }[argv[i]];
    if (argv[i] === '--help' || argv[i] === '-h') return { help: true };
    if (key === undefined) throw new Error(`Unknown argument ${JSON.stringify(argv[i])}`);
    const value = argv[i + 1];
    if (value === undefined || value.startsWith('--')) throw new Error(`${argv[i]} needs a value`);
    options[key] = value;
    i += 1;
  }
  return options;
}

const readJson = (file) => JSON.parse(readFileSync(file, 'utf8'));

async function main() {
  const options = parseArgs(process.argv.slice(2));
  if (options.help) {
    console.log('Usage: node scripts/catalog-feed.mjs [--out <file>] [--recorded <responses.json>]');
    return;
  }
  let capabilities;
  try {
    ({ capabilities } = await import(pathToFileURL(path.join(repoRoot, 'packages/catalog/dist/index.js')).href));
  } catch (error) {
    throw new Error(`Could not load packages/catalog/dist; run npm run build --workspace=@subset.dev/catalog first (${error.message})`);
  }
  const releaseTargets = readJson(path.join(repoRoot, 'release-packages.json')).map((target) => ({ ...target, manifest: readJson(path.join(repoRoot, target.path, 'package.json')) }));
  const sources = options.recorded ? recordedSources(readJson(options.recorded)) : { github: liveGitHub(), npm: liveNpm() };
  const feed = await buildCatalogFeed({ capabilities, manifests: readMacosReleaseManifests(path.join(repoRoot, 'native')), releaseTargets, ...sources });
  const text = `${JSON.stringify(feed, null, 2)}\n`;
  const problems = catalogFeedProblems(text);
  if (problems.length > 0) throw new Error(`The built feed is not a valid ${CATALOG_SCHEMA} document:\n  ${problems.join('\n  ')}`);
  if (!options.out) {
    process.stdout.write(text);
    return;
  }
  const temporary = `${options.out}.${process.pid}.tmp`;
  try {
    writeFileSync(temporary, text);
    renameSync(temporary, options.out);
  } finally {
    rmSync(temporary, { force: true });
  }
  console.error(`Wrote ${CATALOG_SCHEMA} with ${feed.apps.length} apps and ${feed.tools.length} tools to ${options.out}`);
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(error.message);
    process.exitCode = 1;
  });
}
