// Bundles the CLI, its daemon and alert sinks with the private @subset/timer package (and its zod
// dependency) inlined into dist/cli.mjs, and copies the built board from apps/timer/dist into web/
// for `serve`. The MCP server and @mcpfn/core, which `subset-timer mcp` alone loads, go to
// dist/mcp-server.mjs, and code both use to dist/common.mjs. The published package has no runtime dependencies,
// so dist/THIRD_PARTY_NOTICES.md carries the licences of the packages bundled into it.
import { builtinModules } from 'node:module';
import { chmod, cp, readdir, readFile, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';

const root = fileURLToPath(new URL('..', import.meta.url));
const webSource = fileURLToPath(new URL('../../../apps/timer/dist/', import.meta.url));
const exists = (file) => stat(file).then(() => true, () => false);

if (process.argv.includes('--check')) {
  // prepack runs the build first; this refuses to pack an incomplete package.
  const cli = path.join(root, 'dist/cli.mjs');
  for (const file of [cli, path.join(root, 'dist/THIRD_PARTY_NOTICES.md'), path.join(root, 'web/index.html'), path.join(root, 'skills/subset-timer/SKILL.md'), path.join(root, 'README.md')]) {
    if (!(await exists(file))) { console.error(`Missing ${path.relative(root, file)}. Run npm run build at the repository root first.`); process.exit(1); }
  }
  if (!(await readFile(cli, 'utf8')).startsWith('#!/usr/bin/env node')) { console.error('dist/cli.mjs has no shebang.'); process.exit(1); }
  const chunks = (await readdir(path.join(root, 'dist'))).filter((name) => name.endsWith('.mjs'));
  const sources = await Promise.all(chunks.map((name) => readFile(path.join(root, 'dist', name), 'utf8')));
  // Code lines only: a kept JSDoc type such as import('@subset/timer').TimerDefinition is not an import.
  const code = (source) => source.split('\n').filter((line) => !/^\s*(?:\*|\/\/)/.test(line)).join('\n');
  if (sources.some((source) => /(?:\bfrom|\bimport\()\s*["'](?!node:)[^."'/]/.test(code(source)))) { console.error('dist/ still imports a package; bundle it instead.'); process.exit(1); }
  process.exit(0);
}

if (!(await exists(path.join(webSource, 'index.html')))) { console.error('apps/timer/dist is missing. Build @subset/timer-web first.'); process.exit(1); }
await rm(path.join(root, 'dist'), { recursive: true, force: true });
const { output } = await build({
  input: { cli: path.join(root, 'src/cli.mjs') },
  platform: 'node',
  external: [/^node:/],
  // Bundled packages (the MCP SDK) import some built-ins without the node: prefix.
  plugins: [{ name: 'node-prefix', resolveId: (id) => (builtinModules.includes(id) ? { id: `node:${id}`, external: true } : null) }],
  output: {
    dir: path.join(root, 'dist'),
    format: 'esm',
    entryFileNames: '[name].mjs',
    chunkFileNames: (chunk) => (chunk.isDynamicEntry ? 'mcp-server.mjs' : 'common.mjs')
  }
});
// src/cli.mjs starts with a shebang; make sure the bundle does too, once, and is executable.
const cliFile = path.join(root, 'dist/cli.mjs');
const bundled = (await readFile(cliFile, 'utf8')).replace(/^#!.*\n/, '');
await writeFile(cliFile, `#!/usr/bin/env node\n${bundled}`);
await chmod(cliFile, 0o755);
await writeFile(path.join(root, 'dist/THIRD_PARTY_NOTICES.md'), await notices(output));
await rm(path.join(root, 'web'), { recursive: true, force: true });
await cp(webSource, path.join(root, 'web'), { recursive: true });

/**
 * The name, version, licence and licence text of every package in the bundle, read from the module
 * paths rolldown bundled. @mcpfn/core's own build inlines @modelcontextprotocol/sdk (and zod, listed
 * already), so the SDK is added from the copy installed as its dependency.
 */
async function notices(chunks) {
  const roots = new Set([path.join(root, '../../node_modules/@modelcontextprotocol/sdk')]);
  for (const chunk of chunks) {
    for (const id of Object.keys(chunk.modules ?? {})) {
      const match = /^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(id);
      if (match) roots.add(match[1]);
    }
  }
  const entries = [];
  for (const dir of roots) {
    const manifest = JSON.parse(await readFile(path.join(dir, 'package.json'), 'utf8'));
    const licenceFile = (await readdir(dir)).find((name) => /^(?:licen[cs]e|copying)(?:\.\w+)?$/i.test(name));
    const author = typeof manifest.author === 'string' ? manifest.author : manifest.author?.name;
    const text = licenceFile
      ? (await readFile(path.join(dir, licenceFile), 'utf8')).trim()
      : `${manifest.license}${author ? `, copyright ${author}` : ''}. The package ships no licence file.`;
    entries.push({ heading: `${manifest.name} ${manifest.version} (${manifest.license})`, text });
  }
  entries.sort((a, b) => a.heading.localeCompare(b.heading));
  const sections = entries.map(({ heading, text }) => `## ${heading}\n\n\`\`\`\n${text}\n\`\`\`\n`);
  return `# Third-party notices\n\nThe files in dist/ bundle these packages.\n\n${sections.join('\n')}`;
}
