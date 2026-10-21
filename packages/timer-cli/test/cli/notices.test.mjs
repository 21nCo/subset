import assert from 'node:assert/strict';
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { notices } from '../../scripts/notices.mjs';

/** A temporary install tree; `add` writes a package with a licence file at a path below it. */
function tree(t) {
  const dir = mkdtempSync(join(tmpdir(), 'stn-'));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  const add = (at, name, version) => {
    const pkg = join(dir, at);
    mkdirSync(pkg, { recursive: true });
    writeFileSync(join(pkg, 'package.json'), JSON.stringify({ name, version, license: 'MIT' }));
    writeFileSync(join(pkg, 'LICENSE'), `${name} ${version} licence text`);
    return pkg;
  };
  return { dir, add };
}

/** The rolldown output for one chunk bundling a module of each package directory. */
const bundling = (...dirs) => [{ modules: Object.fromEntries(dirs.map((dir) => [join(dir, 'dist/index.js'), {}])) }];
const headings = (text) => [...text.matchAll(/^## (.+)$/gm)].map(([, heading]) => heading);

test('the SDK @mcpfn/core inlines is listed from the copy hoisted beside it', async (t) => {
  const { add } = tree(t);
  const core = add('node_modules/@mcpfn/core', '@mcpfn/core', '0.0.5');
  add('node_modules/@modelcontextprotocol/sdk', '@modelcontextprotocol/sdk', '1.29.0');
  const text = await notices(bundling(core));
  assert.deepEqual(headings(text), ['@mcpfn/core 0.0.5 (MIT)', '@modelcontextprotocol/sdk 1.29.0 (MIT)']);
  assert.match(text, /@modelcontextprotocol\/sdk 1\.29\.0 licence text/);
});

test('a copy of the SDK nested under @mcpfn/core wins over a different one at the root', async (t) => {
  const { add } = tree(t);
  const core = add('node_modules/@mcpfn/core', '@mcpfn/core', '0.0.5');
  add('node_modules/@mcpfn/core/node_modules/@modelcontextprotocol/sdk', '@modelcontextprotocol/sdk', '1.29.0');
  add('node_modules/@modelcontextprotocol/sdk', '@modelcontextprotocol/sdk', '2.0.0');
  const text = await notices(bundling(core));
  assert.deepEqual(headings(text), ['@mcpfn/core 0.0.5 (MIT)', '@modelcontextprotocol/sdk 1.29.0 (MIT)']);
  assert.doesNotMatch(text, /2\.0\.0/);
});

test('the SDK is found for @mcpfn/core installed in a workspace package, and not listed without it', async (t) => {
  const { add } = tree(t);
  const core = add('packages/timer-cli/node_modules/@mcpfn/core', '@mcpfn/core', '0.0.5');
  add('node_modules/@modelcontextprotocol/sdk', '@modelcontextprotocol/sdk', '1.29.0');
  const zod = add('node_modules/zod', 'zod', '3.25.76');
  assert.deepEqual(headings(await notices(bundling(core, zod))), ['@mcpfn/core 0.0.5 (MIT)', '@modelcontextprotocol/sdk 1.29.0 (MIT)', 'zod 3.25.76 (MIT)']);
  assert.deepEqual(headings(await notices(bundling(zod))), ['zod 3.25.76 (MIT)']);
});

test('a missing SDK fails the notices, naming it and the package that needs it', async (t) => {
  const { add } = tree(t);
  const core = add('node_modules/@mcpfn/core', '@mcpfn/core', '0.0.5');
  await assert.rejects(notices(bundling(core)), (error) => error.message.startsWith('Cannot find @modelcontextprotocol/sdk, a dependency of') && error.message.includes(core));
});
