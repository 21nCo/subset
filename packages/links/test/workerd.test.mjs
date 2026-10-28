// Bundles the built package the way a Worker or browser extension would, failing on any import of a Node
// built-in, then runs it inside workerd (the Cloudflare Workers runtime, without the nodejs_compat flag): the
// parser must return exactly what it returns on Node, and every fetcher case in fetch-cases.mjs must pass.
// Recent workerd serves some node: modules even without that flag, so the bundling step, not workerd, is what
// rejects a Node dependency.
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { builtinModules, createRequire } from 'node:module';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { after, test } from 'node:test';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';
import { canonicalizeUrl, isLinkDetailsV1, parseLinkDetails } from '../dist/index.js';
import { cases } from './fetch-cases.mjs';

const workerd = createRequire(import.meta.url)('workerd').default;
const directory = mkdtempSync(join(tmpdir(), 'links-workerd-'));
after(() => rmSync(directory, { recursive: true, force: true }));

const fixture = (name) => readFileSync(new URL(`fixtures/${name}`, import.meta.url), 'utf8');
const url = 'https://example.com/docs/page.html';
const latin1 = (text) => [...Buffer.from(text, 'latin1')];
// Inputs as JSON: `bytes` become a Uint8Array and `repeat` a large string inside the worker.
const parseCases = [
  { html: fixture('missing-head.html'), options: { url } },
  { html: fixture('multiple-og-image.html'), options: { url } },
  { html: fixture('relative-icons.html'), options: { url } },
  { html: fixture('malformed.html'), options: { url } },
  { html: '<html lang=en><meta property="og:title" content="Fish &amp; chips"><link rel=canonical href="/a?utm_source=x&b=1#c">', options: { url } },
  { bytes: [...latin1('<meta charset="windows-1251"><title>'), 0xcf, 0xf0, 0xe8, 0xe2, 0xe5, 0xf2, ...latin1('</title>')], options: { url, contentType: 'text/html' } },
  { bytes: [...latin1('<title>Caf'), 0xe9, ...latin1('</title>')], options: { url, contentType: 'text/html; charset=iso-8859-1' } },
  { repeat: { prefix: '<title>Big</title>', unit: '<div><a href="/x">x</a>', count: 150_000, suffix: '<meta property="og:title" content="Too late">' }, options: { url } }
];
const urlCases = ['HTTPS://Bücher.Example:443?utm_source=a&b=%20c&flag&fbclid=1#x', 'http://example.com:80/#!/route', 'https://example.com/a?mc_cid=1'];

const materialize = (input) =>
  input.bytes ? Uint8Array.from(input.bytes) : input.repeat ? `${input.repeat.prefix}${input.repeat.unit.repeat(input.repeat.count)}${input.repeat.suffix}` : input.html;

test('the parser and canonicalizer run unchanged in workerd', async () => {
  const expected = {
    parsed: parseCases.map((input) => parseLinkDetails(materialize(input), input.options)),
    canonical: urlCases.map((input) => canonicalizeUrl(input))
  };
  assert.ok(expected.parsed.every(isLinkDetailsV1));
  assert.equal(expected.parsed[5].title, 'Привет');
  assert.equal(expected.parsed[7].title, 'Big');

  const entry = join(directory, 'entry.mjs');
  writeFileSync(entry, `
import { canonicalizeUrl, isLinkDetailsV1, parseLinkDetails } from ${JSON.stringify(fileURLToPath(new URL('../dist/index.js', import.meta.url)))};
const materialize = ${materialize.toString()};
const parseCases = ${JSON.stringify(parseCases)};
const urlCases = ${JSON.stringify(urlCases)};
const expected = ${JSON.stringify(JSON.stringify(expected))};
export default {
  async test() {
    const parsed = parseCases.map((input) => parseLinkDetails(materialize(input), input.options));
    if (!parsed.every(isLinkDetailsV1)) throw new Error('A record failed isLinkDetailsV1');
    const actual = JSON.stringify({ parsed, canonical: urlCases.map((input) => canonicalizeUrl(input)) });
    if (actual !== expected) throw new Error('workerd output differs from Node:\\n' + actual + '\\n' + expected);
    console.log('links: workerd output matches Node');
  }
};
`);
  assert.match(await runInWorkerd('parse', entry), /links: workerd output matches Node/);
});

test('the fetcher cases run unchanged in workerd', async () => {
  const entry = join(directory, 'fetch-entry.mjs');
  writeFileSync(entry, `
import * as lib from ${JSON.stringify(fileURLToPath(new URL('../dist/index.js', import.meta.url)))};
import { cases } from ${JSON.stringify(fileURLToPath(new URL('fetch-cases.mjs', import.meta.url)))};
export default {
  async test() {
    for (const { name, run } of cases) {
      await run(lib);
      console.log('links fetch case passed: ' + name);
    }
  }
};
`);
  const output = await runInWorkerd('fetch', entry);
  for (const { name } of cases) assert.ok(output.includes(`links fetch case passed: ${name}`), `workerd did not pass: ${name}`);
});

/** Bundles `entry` for the browser platform, failing on any Node built-in import, runs it with `workerd test` and returns its output. */
async function runInWorkerd(name, entry) {
  const nodeImports = [];
  const rejectNodeBuiltins = {
    name: 'reject-node-builtins',
    resolveId(source, importer) {
      if (source.startsWith('node:') || builtinModules.includes(source.split('/')[0])) nodeImports.push(`${importer} imports ${source}`);
    }
  };
  await build({ input: entry, platform: 'browser', plugins: [rejectNodeBuiltins], logLevel: 'silent', output: { file: join(directory, `${name}.js`), format: 'esm' } });
  assert.deepEqual(nodeImports, [], 'the package imports a Node built-in');

  writeFileSync(join(directory, `${name}.capnp`), `using Workerd = import "/workerd/workerd.capnp";
const config :Workerd.Config = (services = [(name = "links", worker = .worker)]);
const worker :Workerd.Worker = (modules = [(name = "worker", esModule = embed "${name}.js")], compatibilityDate = "2026-10-01");
`);
  const run = spawnSync(workerd, ['test', '--verbose', join(directory, `${name}.capnp`)], { encoding: 'utf8', timeout: 60_000 });
  const output = `${run.stdout}\n${run.stderr}`;
  assert.equal(run.status, 0, output);
  assert.match(output, /\[ PASS \]/);
  return output;
}
