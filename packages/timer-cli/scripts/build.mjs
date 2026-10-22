// Bundles the CLI, its daemon and alert sinks with the private @subset/timer package (and its zod
// dependency) inlined into dist/cli.mjs, and copies the built board from apps/timer/dist into web/
// for `serve`. The apps/timer build writes the MCP App view to mcp-app/board.html itself. The MCP server and @mcpfn/core, which `subset-timer mcp` alone loads, go to
// dist/mcp-server.mjs, and code both use to dist/common.mjs. The published package has no runtime dependencies,
// so dist/THIRD_PARTY_NOTICES.md carries the licences of the packages bundled into it. The build also stages
// app-runtime/, the copy the Timer macOS app embeds (dist, web, mcp-app and skills); it is not part of the npm package.
import { builtinModules } from 'node:module';
import { chmod, cp, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';
import { pidAlive } from '../src/daemon/lock.mjs';
import { notices } from './notices.mjs';

const root = fileURLToPath(new URL('..', import.meta.url));
const webSource = fileURLToPath(new URL('../../../apps/timer/dist/', import.meta.url));
const exists = (file) => stat(file).then(() => true, () => false);

if (process.argv.includes('--check')) {
  // prepack runs the build first; this refuses to pack an incomplete package.
  const cli = path.join(root, 'dist/cli.mjs');
  for (const file of [cli, path.join(root, 'dist/THIRD_PARTY_NOTICES.md'), path.join(root, 'web/index.html'), path.join(root, 'mcp-app/board.html'), path.join(root, 'skills/subset-timer/SKILL.md'), path.join(root, 'README.md')]) {
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

if (process.argv.includes('--stage-app-runtime')) {
  // Restages app-runtime/ from the current build alone.
  await stageAppRuntime();
  process.exit(0);
}

if (!(await exists(path.join(webSource, 'index.html'))) || !(await exists(path.join(root, 'mcp-app/board.html')))) { console.error('apps/timer/dist or mcp-app/board.html is missing. Build @subset/timer-web first.'); process.exit(1); }
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

await stageAppRuntime();

// Stages the macOS app runtime from the built dist, web, mcp-app and skills. It is assembled in a temporary folder
// and renamed into place only when complete, so the app never embeds a partial copy. Staging folders an
// interrupted build left behind (their pid is gone) are removed first; a running build's folder is kept.
async function stageAppRuntime() {
  for (const name of await readdir(root)) {
    if (/^\.app-runtime-\d+$/.test(name) && !pidAlive(Number(name.slice(13)))) await rm(path.join(root, name), { recursive: true, force: true });
  }
  const runtime = path.join(root, 'app-runtime');
  const staging = path.join(root, `.app-runtime-${process.pid}`);
  try {
    for (const folder of ['dist', 'web', 'mcp-app', 'skills']) await cp(path.join(root, folder), path.join(staging, folder), { recursive: true });
    await rm(runtime, { recursive: true, force: true });
    await rename(staging, runtime);
  } catch (error) {
    await rm(staging, { recursive: true, force: true });
    throw error;
  }
}
