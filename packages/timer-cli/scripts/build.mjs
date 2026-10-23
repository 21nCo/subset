// Bundles the CLI, its daemon and alert sinks with the private @subset/timer package (and its zod
// dependency) inlined into dist/cli.mjs, and copies the built board from apps/timer/dist into web/
// for `serve`. The apps/timer build writes the MCP App view to mcp-app/board.html itself. The MCP server and @mcpfn/core, which `subset-timer mcp` alone loads, go to
// dist/mcp-server.mjs, and code both use to dist/common.mjs. The published package has no runtime dependencies,
// so dist/THIRD_PARTY_NOTICES.md carries the licences of the packages bundled into it. The build also stages
// app-runtime, the copy the Timer macOS app embeds (dist, web, mcp-app and skills); it is not part of the npm package.
import { builtinModules } from 'node:module';
import { chmod, cp, lstat, readdir, readFile, readlink, rename, rm, stat, symlink, writeFile } from 'node:fs/promises';
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

// Stages the macOS app runtime from the built dist, web, mcp-app and skills. Each build assembles its own generation,
// .app-runtime/<pid>-<time>, which is never changed once complete, and publishes it by renaming a symlink over
// app-runtime, so app-runtime always names a complete generation, even across overlapping or interrupted builds. The
// Embed Timer CLI phase copies the generation the link names and copies again if it was removed meanwhile. A
// generation is removed only when no link names it and its build is gone, and is renamed away first, so a copy that
// still finds it afterwards copied all of it.
async function stageAppRuntime() {
  const runtime = path.join(root, 'app-runtime');
  const generations = path.join(root, '.app-runtime');
  const name = `${process.pid}-${Date.now()}`;
  const link = path.join(generations, `${name}.link`);
  try {
    for (const folder of ['dist', 'web', 'mcp-app', 'skills']) await cp(path.join(root, folder), path.join(generations, name, folder), { recursive: true });
    await symlink(path.join('.app-runtime', name), link);
    // A build before generations left app-runtime as a folder, which a link cannot replace.
    if (!(await lstat(runtime).then((entry) => entry.isSymbolicLink(), () => true))) await rm(runtime, { recursive: true, force: true });
    await rename(link, runtime);
  } catch (error) {
    await rm(path.join(generations, name), { recursive: true, force: true });
    await rm(link, { force: true });
    throw error;
  }
  for (const entry of await readdir(generations)) {
    // This build's own generation once replaced, and those of builds that are gone. The link is read after the
    // liveness check, because a build that is gone publishes nothing more.
    const pid = Number(/^\d+/.exec(entry)?.[0]);
    if ((pid !== process.pid && pidAlive(pid)) || entry === path.basename(await readlink(runtime))) continue;
    const doomed = path.join(generations, `${process.pid}-removing-${entry}`);
    await rename(path.join(generations, entry), doomed).then(() => rm(doomed, { recursive: true, force: true }), () => {});
  }
}
