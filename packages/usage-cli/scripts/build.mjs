// Bundles the CLI with the private @subset.dev/usage-core package inlined, and copies the built
// dashboard from apps/usage/dist into web/. The MCP server and @mcpfn/core, which only `subset-usage mcp`
// loads, go to dist/mcp-server.mjs, and code both use to dist/common.mjs. The published package has no
// runtime dependencies, so dist/THIRD_PARTY_NOTICES.md carries the licences of the packages bundled into it.
import { builtinModules } from 'node:module';
import { cp, mkdir, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';
import { notices } from './notices.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const webSource = fileURLToPath(new URL('../../../apps/usage/dist/', import.meta.url));
const exists = (path) => stat(path).then(() => true, () => false);

if (process.argv.includes('--check')) {
  // prepack runs the build first, then this check refuses to pack an incomplete package.
  const files = ['dist/cli.mjs', 'dist/mcp-server.mjs', 'dist/THIRD_PARTY_NOTICES.md', 'web/index.html'];
  const present = await Promise.all(files.map((file) => exists(`${root}${file}`)));
  const missing = files.filter((_, index) => !present[index]);
  if (missing.length) { console.error(`Missing ${missing.join(', ')}. Run npm run build at the repository root first.`); process.exit(1); }
  const head = (await readFile(`${root}dist/cli.mjs`, 'utf8')).slice(0, 40);
  if (!head.startsWith('#!/usr/bin/env node')) { console.error('dist/cli.mjs has no shebang.'); process.exit(1); }
  const chunks = (await readdir(`${root}dist`)).filter((name) => name.endsWith('.mjs'));
  const sources = await Promise.all(chunks.map((name) => readFile(`${root}dist/${name}`, 'utf8')));
  // Code lines only: a kept JSDoc type such as import('@subset.dev/usage-core').UsageStatus is not an import.
  const code = (source) => source.split('\n').filter((line) => !/^\s*(?:\*|\/\/)/.test(line)).join('\n');
  if (sources.some((source) => /(?:\bfrom|\bimport\()\s*["'](?!node:)[^."'/]/.test(code(source)))) { console.error('dist/ still imports a package; bundle it instead.'); process.exit(1); }
  process.exit(0);
}

await rm(`${root}dist`, { recursive: true, force: true });
const { output } = await build({
  input: { cli: `${root}src/server.mjs` },
  platform: 'node',
  external: [/^node:/],
  // Bundled packages (the MCP SDK) import some built-ins without the node: prefix.
  plugins: [{ name: 'node-prefix', resolveId: (id) => (builtinModules.includes(id) ? { id: `node:${id}`, external: true } : null) }],
  output: {
    dir: `${root}dist`,
    format: 'esm',
    entryFileNames: '[name].mjs',
    chunkFileNames: (chunk) => (chunk.isDynamicEntry ? 'mcp-server.mjs' : 'common.mjs'),
    banner: (chunk) => (chunk.isEntry ? '#!/usr/bin/env node' : ''),
  },
});
await writeFile(`${root}dist/THIRD_PARTY_NOTICES.md`, await notices(output));
if (!(await exists(`${webSource}index.html`))) { console.error('apps/usage/dist is missing. Build @subset.dev/usage-web first.'); process.exit(1); }
await rm(`${root}web`, { recursive: true, force: true });
await mkdir(`${root}web`, { recursive: true });
await cp(webSource, `${root}web`, { recursive: true });
