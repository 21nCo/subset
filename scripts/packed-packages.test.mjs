// Packs the published library packages the way the tag workflow does (`npm pack`), installs the tarballs into a
// throwaway project outside the repository and imports them there, so a missing file, export, type or runtime
// dependency fails here instead of after `npm publish` (SET-186). @subset.dev/links also runs from its tarball inside
// workerd. Needs the built workspaces (`npm run build`) and the npm registry for the packages' own dependencies.
//
//   node --test scripts/packed-packages.test.mjs
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, rmSync, writeFileSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, before, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';

const root = fileURLToPath(new URL('../', import.meta.url));
const require = createRequire(import.meta.url);
const workerd = require('workerd').default;
const tsc = require.resolve('typescript/bin/tsc');

// Each published library and the paths its tarball must not ship.
const packages = [
  { name: '@subset.dev/links', path: 'packages/links', forbidden: /^(?:src|test|node_modules)\// },
  { name: '@subset.dev/link-capture', path: 'packages/link-capture', forbidden: /^(?:test|extension|dist-extension|scripts|node_modules)\// }
];

// The real path, so resolved file URLs (macOS's /var is /private/var) compare equal to it.
const directory = realpathSync(mkdtempSync(join(tmpdir(), 'subset-packed-')));
const consumer = join(directory, 'consumer');
after(() => rmSync(directory, { recursive: true, force: true }));

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, encoding: 'utf8', timeout: 240_000, env: { ...process.env, npm_config_update_notifier: 'false' } });
  const output = `${result.stdout}\n${result.stderr}`;
  assert.equal(result.status, 0, `${command} ${args.join(' ')} failed in ${cwd}:\n${output}`);
  return { stdout: result.stdout, output };
}

// Every file path an exports map, `main` or `types` names.
function exportedFiles(manifest) {
  const targets = [manifest.main, manifest.types];
  const walk = (value) => {
    if (typeof value === 'string') targets.push(value);
    else if (value && typeof value === 'object') Object.values(value).forEach(walk);
  };
  walk(manifest.exports);
  return targets.filter(Boolean).map((target) => target.replace(/^\.\//, ''));
}

// Runs in Node and, bundled, in workerd: the same calls must give the same JSON.
const linksSmoke = `
export async function smoke(lib) {
  const url = 'https://example.com/docs/page.html?utm_source=x&id=7#top';
  const html = '<html lang="en"><head><title>Page</title><meta property="og:title" content="Fish &amp; chips"><link rel="icon" href="/i.png"></head></html>';
  const parsed = lib.parseLinkDetails(new TextEncoder().encode(html), { url, contentType: 'text/html; charset=utf-8' });
  const fetch = async () => new Response(html, { status: 200, headers: { 'content-type': 'text/html' } });
  const fetched = await lib.fetchLinkDetails('https://example.com/fetched', { fetch });
  let rejected;
  try { lib.canonicalizeUrl('ftp://example.com/'); } catch (error) { rejected = error instanceof lib.LinkUrlError && error.reason; }
  return {
    canonical: lib.canonicalizeUrl(url),
    parsed,
    valid: lib.isLinkDetailsV1(parsed) && lib.isLinkDetailsV1(fetched),
    fetched,
    rejected,
    maxDocumentBytes: lib.MAX_DOCUMENT_BYTES,
    blocked: lib.isBlockedHostname('localhost')
  };
}
`;

const tarballs = new Map();
before(() => {
  for (const pkg of packages) {
    const [packed] = JSON.parse(run('npm', ['pack', '--json', '--pack-destination', directory], join(root, pkg.path)).stdout);
    tarballs.set(pkg.name, join(directory, packed.filename));
  }
  mkdirSync(consumer);
  writeFileSync(join(consumer, 'package.json'), JSON.stringify({ name: 'consumer', private: true, type: 'module' }));
  // Both tarballs at once: @subset.dev/link-capture's dependency on @subset.dev/links is met by the packed copy, as it
  // will be by the registry once links is published first. Everything else comes from the registry.
  run('npm', ['install', '--no-audit', '--no-fund', '--ignore-scripts', '--prefer-offline', ...tarballs.values()], consumer);
  writeFileSync(join(consumer, 'links-smoke.mjs'), linksSmoke);
  writeFileSync(join(consumer, 'links-node.mjs'), `import * as lib from '@subset.dev/links';\nimport { smoke } from './links-smoke.mjs';\nconsole.log(JSON.stringify(await smoke(lib)));\n`);
});

for (const pkg of packages) {
  test(`${pkg.name}: npm pack --dry-run lists what the package needs and nothing private`, () => {
    const manifest = JSON.parse(readFileSync(join(root, pkg.path, 'package.json'), 'utf8'));
    assert.equal(manifest.private, false);
    const [listing] = JSON.parse(run('npm', ['pack', '--dry-run', '--json', '--ignore-scripts'], join(root, pkg.path)).stdout);
    assert.equal(listing.name, pkg.name);
    assert.equal(listing.version, manifest.version);
    const files = new Set(listing.files.map((file) => file.path));
    for (const file of ['package.json', 'README.md', 'LICENSE', ...exportedFiles(manifest)]) assert.ok(files.has(file), `${pkg.name} does not ship ${file}`);
    for (const file of files) assert.doesNotMatch(file, pkg.forbidden, `${pkg.name} ships ${file}`);
    for (const file of files) assert.doesNotMatch(file, /\.test\.|\.tsbuildinfo$/, `${pkg.name} ships ${file}`);
  });
}

test('the installed tarballs resolve from the consumer, with one shared copy of @subset.dev/links', () => {
  const { stdout: resolved } = run(process.execPath, ['--input-type=module', '-e', `
console.log(JSON.stringify([import.meta.resolve('@subset.dev/links'), import.meta.resolve('@subset.dev/link-capture'), import.meta.resolve('@subset.dev/link-capture/popup')]));
`], consumer);
  for (const url of JSON.parse(resolved)) {
    assert.ok(fileURLToPath(url).startsWith(join(consumer, 'node_modules')), `${url} is not the installed tarball`);
    assert.ok(existsSync(fileURLToPath(url)), `${url} does not exist`);
  }
  // A nested copy would give the host and link-capture different LinkDetailsV1 code.
  assert.equal(existsSync(join(consumer, 'node_modules/@subset.dev/link-capture/node_modules/@subset.dev/links')), false);
  const installed = JSON.parse(readFileSync(join(consumer, 'node_modules/@subset.dev/link-capture/package.json'), 'utf8'));
  assert.equal(installed.dependencies['@subset.dev/links'], `^${JSON.parse(readFileSync(join(root, 'packages/links/package.json'), 'utf8')).version}`);
});

test('@subset.dev/links imports and runs from its tarball on Node', async () => {
  const result = JSON.parse(run(process.execPath, ['links-node.mjs'], consumer).stdout);
  assert.equal(result.canonical, 'https://example.com/docs/page.html?id=7');
  assert.equal(result.parsed.version, 1);
  assert.equal(result.parsed.title, 'Fish & chips');
  assert.equal(result.parsed.language, 'en');
  assert.deepEqual(result.parsed.icons, [{ url: 'https://example.com/i.png', rel: 'icon' }]);
  assert.equal(result.fetched.url, 'https://example.com/fetched');
  assert.equal(result.valid, true);
  assert.equal(result.rejected, 'unsupported-scheme');
  assert.equal(result.maxDocumentBytes, 524_288);
  assert.equal(result.blocked, true);
});

test('@subset.dev/links runs from its tarball in workerd with the same results as on Node', async () => {
  const expected = run(process.execPath, ['links-node.mjs'], consumer).stdout.trim();
  const entry = join(consumer, 'links-worker.mjs');
  writeFileSync(entry, `import * as lib from '@subset.dev/links';
import { smoke } from './links-smoke.mjs';
const expected = ${JSON.stringify(expected)};
export default {
  async test() {
    const actual = JSON.stringify(await smoke(lib));
    if (actual !== expected) throw new Error('workerd output differs from Node:\\n' + actual + '\\n' + expected);
    console.log('packed links: workerd output matches Node');
  }
};
`);
  // Bundled the way a Worker would be, from the consumer's node_modules; any Node built-in import fails the test.
  const nodeImports = [];
  const imported = [];
  const plugins = [{
    name: 'record-imports',
    resolveId(source, importer) {
      imported.push(source);
      if (source.startsWith('node:') || builtinModules.includes(source.split('/')[0])) nodeImports.push(`${importer} imports ${source}`);
    }
  }];
  await build({ input: entry, cwd: consumer, platform: 'browser', plugins, logLevel: 'silent', output: { file: join(consumer, 'links-worker.js'), format: 'esm' } });
  assert.deepEqual(nodeImports, [], 'the packed package imports a Node built-in');
  assert.ok(imported.includes('@subset.dev/links'));
  writeFileSync(join(consumer, 'links-worker.capnp'), `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (services = [(name = "links", worker = .worker)]);
const worker :Workerd.Worker = (modules = [(name = "worker", esModule = embed "links-worker.js")], compatibilityDate = "2026-10-01");
`);
  const { output } = run(workerd, ['test', '--verbose', join(consumer, 'links-worker.capnp')], consumer);
  assert.match(output, /packed links: workerd output matches Node/);
  assert.match(output, /\[ PASS \]/);
});

test('@subset.dev/link-capture imports and runs from its tarball on Node', () => {
  writeFileSync(join(consumer, 'capture-node.mjs'), `
import { captureLink, linkCaptureManifest, LinkCaptureError } from '@subset.dev/link-capture';
const capture = captureLink('https://user:pw@example.com/a?utm_source=x&b=1', '  Example  link ', { now: () => new Date(0) });
let refused;
try { captureLink('chrome://settings'); } catch (error) { refused = error instanceof LinkCaptureError && error.code; }
console.log(JSON.stringify({ capture, refused, manifest: linkCaptureManifest() }));
`);
  const result = JSON.parse(run(process.execPath, ['capture-node.mjs'], consumer).stdout);
  assert.deepEqual(result.capture, {
    source: 'link',
    url: 'https://example.com/a?utm_source=x&b=1',
    canonicalUrl: 'https://example.com/a?b=1',
    title: 'Example link',
    capturedAt: '1970-01-01T00:00:00.000Z'
  });
  assert.equal(result.refused, 'unsupported-page');
  assert.ok(result.manifest.permissions.includes('activeTab'));
});

test('@subset.dev/link-capture/popup compiles from its tarball with the svelte peer and resolves its imports', () => {
  // The popup ships as a Svelte component for the host's bundler to compile; compile it with the consumer's svelte.
  writeFileSync(join(consumer, 'popup-compile.mjs'), `
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { compile } from 'svelte/compiler';
const file = fileURLToPath(import.meta.resolve('@subset.dev/link-capture/popup'));
const { js, warnings } = compile(readFileSync(file, 'utf8'), { filename: file, generate: 'client' });
const imports = [...js.code.matchAll(/^import\\b[^'"]*['"]([^'"]+)['"]/gm)].map((match) => match[1]);
for (const specifier of imports) import.meta.resolve(specifier);
console.log(JSON.stringify({ imports, warnings: warnings.map((warning) => warning.code) }));
`);
  const result = JSON.parse(run(process.execPath, ['popup-compile.mjs'], consumer).stdout);
  assert.ok(result.imports.includes('@subset.dev/link-capture'), result.imports.join(', '));
  assert.deepEqual(result.warnings, []);
});

test('the packed type declarations, ./popup included, type-check in a strict TypeScript consumer', () => {
  writeFileSync(join(consumer, 'types.ts'), `
import { canonicalizeUrl, isLinkDetailsV1, parseLinkDetails, type LinkDetailsV1 } from '@subset.dev/links';
import { captureLink, type Capture, type SaveTarget, type TabCapture } from '@subset.dev/link-capture';
import CapturePopup from '@subset.dev/link-capture/popup';
import { mount, type ComponentProps } from 'svelte';
const details: LinkDetailsV1 = parseLinkDetails('<title>x</title>', { url: canonicalizeUrl('https://example.com/') });
const capture: Capture = captureLink('https://example.com/');
const sameRecord = (tab: TabCapture): LinkDetailsV1 => tab.details;
const target: Pick<SaveTarget, 'status'> | undefined = undefined;
// The popup as the README wires it: its declaration gives these props their types.
declare const saveTarget: SaveTarget;
const props: ComponentProps<typeof CapturePopup> = { target: saveTarget, capture: async () => captureLink('https://example.com/'), onsetup: () => {} };
export const mountPopup = (element: HTMLElement) => mount(CapturePopup, { target: element, props });
// @ts-expect-error capture is a required prop
const missingCapture: ComponentProps<typeof CapturePopup> = { target: saveTarget };
// @ts-expect-error capture returns a Promise<Capture>
const wrongCapture: ComponentProps<typeof CapturePopup> = { target: saveTarget, capture: () => 'https://example.com/' };
export const used = [details, capture, sameRecord, target, isLinkDetailsV1(details), missingCapture, wrongCapture];
`);
  writeFileSync(join(consumer, 'tsconfig.json'), JSON.stringify({
    compilerOptions: { target: 'ES2022', module: 'NodeNext', moduleResolution: 'NodeNext', lib: ['ES2022', 'DOM'], types: [], strict: true, noEmit: true, skipLibCheck: false },
    files: ['types.ts']
  }));
  run(process.execPath, [tsc, '-p', 'tsconfig.json'], consumer);
});
