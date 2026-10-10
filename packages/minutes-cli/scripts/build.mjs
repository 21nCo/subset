// Bundles the CLI with the private @subset/minutes package inlined. playwright-core stays an
// external runtime dependency: it resolves files relative to its own install and does not survive
// bundling. The build also stages app-runtime/, the self-contained copy the macOS app embeds
// (dist plus playwright-core); app-runtime/ is not part of the npm package.
import { chmod, cp, mkdir, readdir, readFile, rename, rm, stat, writeFile } from 'node:fs/promises';
import { createRequire } from 'node:module';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { build } from 'rolldown';

const root = fileURLToPath(new URL('..', import.meta.url));
const exists = (file) => stat(file).then(() => true, () => false);

if (process.argv.includes('--check')) {
  const cli = path.join(root, 'dist/cli.mjs');
  if (!(await exists(cli))) { console.error('Missing dist/cli.mjs. Run npm run build at the repository root first.'); process.exit(1); }
  const text = await readFile(cli, 'utf8');
  if (!text.startsWith('#!/usr/bin/env node')) { console.error('dist/cli.mjs has no shebang.'); process.exit(1); }
  const chunks = (await readdir(path.join(root, 'dist'))).filter((name) => name.endsWith('.mjs'));
  const sources = await Promise.all(chunks.map((name) => readFile(path.join(root, 'dist', name), 'utf8')));
  if (sources.some((source) => /(?:from|import\()\s*["']@subset\//.test(source))) { console.error('dist/ still imports a private @subset/* workspace.'); process.exit(1); }
  process.exit(0);
}

await rm(path.join(root, 'dist'), { recursive: true, force: true });
await build({
  input: { cli: path.join(root, 'src/cli.mjs') },
  platform: 'node',
  external: [/^node:/, /^playwright-core(\/|$)/],
  output: { dir: path.join(root, 'dist'), format: 'esm', entryFileNames: '[name].mjs', chunkFileNames: '[name].mjs' },
});
// rolldown's banner option would also prefix chunks, so add the shebang to the entry only.
const cliFile = path.join(root, 'dist/cli.mjs');
await writeFile(cliFile, `#!/usr/bin/env node\n${await readFile(cliFile, 'utf8')}`);
await chmod(cliFile, 0o755);

// Stage the macOS app runtime: the same bundle plus its one runtime dependency. It is assembled in a
// temporary folder and renamed into place only when complete, so the app never embeds a partial copy.
const manifest = JSON.parse(await readFile(path.join(root, 'package.json'), 'utf8'));
const runtime = path.join(root, 'app-runtime');
const staging = path.join(root, `.app-runtime-${process.pid}`);
await rm(staging, { recursive: true, force: true });
try {
  await mkdir(path.join(staging, 'node_modules'), { recursive: true });
  await cp(path.join(root, 'dist'), path.join(staging, 'dist'), { recursive: true });
  await writeFile(path.join(staging, 'package.json'), `${JSON.stringify({ name: manifest.name, version: manifest.version, private: true, type: 'module' }, null, 2)}\n`);
  const require = createRequire(path.join(root, 'package.json'));
  const playwrightRoot = path.dirname(require.resolve('playwright-core/package.json'));
  // Skip playwright-core's browser installer scripts; Minutes uses the system Chrome.
  const installers = path.join(playwrightRoot, 'bin');
  await cp(playwrightRoot, path.join(staging, 'node_modules/playwright-core'), {
    recursive: true,
    dereference: true,
    filter: (source) => source !== installers && !source.startsWith(`${installers}${path.sep}`),
  });
  await rm(runtime, { recursive: true, force: true });
  await rename(staging, runtime);
} catch (error) {
  await rm(staging, { recursive: true, force: true });
  throw error;
}
